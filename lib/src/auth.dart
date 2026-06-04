import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:t/t.dart' as t;
import 'package:tg/tg.dart' as tg;

import '../models/models.dart';
import 'logger.dart';
import 'socket.dart';

/// Timeout for establishing the TCP connection to Telegram.
const _connectTimeout = Duration(seconds: 15);

/// Timeout for the authorization key exchange (DH).
const _authorizeTimeout = Duration(seconds: 30);

/// Timeout for general API method invocations (initConnection, getUsers, etc.).
const _invokeTimeout = Duration(seconds: 20);

/// Maximum number of consecutive login retries on session expiry.
const _maxLoginRetries = 2;

/// Handles the Telegram authentication lifecycle using a state-machine approach.
final class TeliAuth {
  tg.Client? _client;
  TeliSocket? _teliSocket;
  final TeliCredentials credentials;

  TeliAuth(this.credentials, {tg.Client? client, TeliSocket? teliSocket})
      : _client = client,
        _teliSocket = teliSocket;

  /// Initializes the connection and attempts to resume session or start login.
  ///
  /// Timeouts:
  /// - TCP connect: 15s
  /// - DH key exchange: 30s
  /// - API calls (initConnection, getUsers, sendCode, etc.): 20s
  ///
  /// Automatically retries once on `AUTH_KEY_UNREGISTERED` / `AUTH_RESTART`.
  /// Returns [TeliAuthError] on timeout or unrecoverable failure.
  Future<TeliAuthState> login({String? ip, int? port, int? dcId}) {
    return _loginWithRetry(ip: ip, port: port, dcId: dcId);
  }

  Future<TeliAuthState> _loginWithRetry({
    String? ip,
    int? port,
    int? dcId,
    int retryCount = 0,
  }) async {
    log.i('Login attempt${retryCount > 0 ? ' (retry $retryCount)' : ''}');
    try {
      final host = credentials.getHost();
      ip ??= host.ip;
      port ??= host.port;
      dcId ??= host.dcId;

      credentials.validateApiCredentials();

      if (_teliSocket == null) {
        log.d('Connecting socket to $ip:$port (DC $dcId)');
        final socket = await Socket.connect(
          ip,
          port,
          timeout: _connectTimeout,
        );
        _teliSocket = TeliSocket(socket);
      }

      final obfuscation = tg.Obfuscation.random(false, dcId);
      final idGenerator = tg.MessageIdGenerator();

      if (_client == null) {
        await _teliSocket!.send(obfuscation.preamble);

        tg.AuthorizationKey? authKey;
        final sessionData = credentials.sessionData;
        if (sessionData != null && sessionData.isNotEmpty) {
          try {
            authKey = tg.AuthorizationKey.fromJson(
              jsonDecode(sessionData) as Map<String, dynamic>,
            );
            log.d('Restored auth key from session data');
          } catch (_) {
            log.w('Failed to parse stored session data');
          }
        }

        if (authKey == null) {
          log.d('No stored session — performing DH key exchange');
          authKey = await tg.Client.authorize(
            _teliSocket!,
            obfuscation,
            idGenerator,
          ).timeout(_authorizeTimeout);
          credentials.sessionData = jsonEncode(authKey.toJson());
        }

        _client = tg.Client(
          socket: _teliSocket!,
          obfuscation: obfuscation,
          authorizationKey: authKey,
          idGenerator: idGenerator,
        );

        log.d('Initializing connection (HelpGetConfig)');
        await _client!
            .initConnection<t.Config>(
              apiId: credentials.apiId,
              deviceModel: 'Desktop',
              systemVersion: 'Unknown',
              appVersion: '1.0.0',
              systemLangCode: 'en',
              langPack: '',
              langCode: 'en',
              query: const t.HelpGetConfig(),
            )
            .timeout(_invokeTimeout);
      }

      try {
        final userResponse = await _client!
            .users
            .getUsers(
              id: [const t.InputUserSelf()],
            )
            .timeout(_invokeTimeout);
        if (userResponse.result is t.Vector &&
            (userResponse.result as t.Vector).items.isNotEmpty) {
          log.i('Session valid — user already authenticated');
          final result = TeliAuthSuccess(
            credentials,
            rawData: userResponse.result,
          );
          await dispose();
          return result;
        }
      } catch (e) {
        if (e.toString().contains('AUTH_KEY_UNREGISTERED') ||
            e.toString().contains('AUTH_RESTART')) {
          log.w('Session expired ($e) — retrying login');
          if (retryCount >= _maxLoginRetries) {
            log.e('Login failed after $_maxLoginRetries retries');
            await dispose();
            return TeliAuthError(
              'Authentication failed after $_maxLoginRetries retries.',
            );
          }
          credentials.sessionData = null;
          await dispose();
          return _loginWithRetry(
            ip: ip,
            port: port,
            dcId: dcId,
            retryCount: retryCount + 1,
          );
        }
      }

      log.i('No valid session — proceeding with OTP login');
      return await _sendCode();
    } catch (e) {
      log.e('Login failed', e);
      await dispose();
      return TeliAuthError(e.toString());
    }
  }

  Future<TeliAuthState> _sendCode() async {
    log.i('Sending OTP code');
    try {
      final fullPhone = credentials.validatePhoneNumber();

      final response = await _client!
          .auth
          .sendCode(
            phoneNumber: fullPhone,
            apiId: credentials.apiId,
            apiHash: credentials.apiHash,
            settings: const t.CodeSettings(
              allowFlashcall: false,
              currentNumber: true,
              allowAppHash: false,
              allowMissedCall: false,
              allowFirebase: false,
              unknownNumber: false,
            ),
          )
          .timeout(_invokeTimeout);

      if (response.error != null) {
        log.e('sendCode failed: ${response.error!.errorMessage}');
        final err = TeliAuthError(response.error!.errorMessage);
        await dispose();
        return err;
      }

      final sentCode = response.result as t.AuthSentCode;
      credentials.phoneCodeHash = sentCode.phoneCodeHash;
      log.i('OTP sent — awaiting user input');

      return const TeliAuthWaitOtp();
    } catch (e) {
      log.e('sendCode error', e);
      await dispose();
      return TeliAuthError(e.toString());
    }
  }

  /// Submits the OTP code received by the user.
  Future<TeliAuthState> submitOtp(String code) async {
    log.i('Submitting OTP');
    if (_client == null) return const TeliAuthError('Client not initialized.');

    try {
      final fullPhone = credentials.validatePhoneNumber();
      final signInResponse = await _client!
          .auth
          .signIn(
            phoneNumber: fullPhone,
            phoneCodeHash: credentials.phoneCodeHash!,
            phoneCode: code,
          )
          .timeout(_invokeTimeout);

      if (signInResponse.error != null) {
        if (signInResponse.error!.errorMessage == 'SESSION_PASSWORD_NEEDED') {
          log.i('2FA required — redirecting to password flow');
          return await _get2faState();
        }
        log.e('signIn failed: ${signInResponse.error!.errorMessage}');
        final err = TeliAuthError(signInResponse.error!.errorMessage);
        await dispose();
        return err;
      }

      credentials.sessionData = jsonEncode(_client!.authorizationKey.toJson());
      log.i('Sign-in successful');
      final result = TeliAuthSuccess(
        credentials,
        rawData: signInResponse.result,
      );
      await dispose();
      return result;
    } catch (e) {
      log.e('submitOtp error', e);
      await dispose();
      return TeliAuthError(e.toString());
    }
  }

  Future<TeliAuthState> _get2faState() async {
    log.d('Fetching 2FA password info');
    try {
      final response = await _client!
          .account
          .getPassword()
          .timeout(_invokeTimeout);
      if (response.result is t.AccountPassword) {
        final pwd = response.result as t.AccountPassword;
        log.i('2FA required — hint: ${pwd.hint ?? "none"}');
        return TeliAuthWaitPassword(pwd.hint ?? '');
      }
      log.e('getPassword returned unexpected type: ${response.result.runtimeType}');
      final err = const TeliAuthError('Failed to retrieve 2FA details.');
      await dispose();
      return err;
    } catch (e) {
      log.e('getPassword error', e);
      await dispose();
      return TeliAuthError(e.toString());
    }
  }

  /// Submits the 2FA password.
  Future<TeliAuthState> submitPassword(String password) async {
    log.i('Submitting 2FA password');
    if (_client == null) return const TeliAuthError('Client not initialized.');

    try {
      final response = await _client!
          .account
          .getPassword()
          .timeout(_invokeTimeout);
      if (response.result is! t.AccountPassword) {
        log.e('getPassword returned unexpected type: ${response.result.runtimeType}');
        final err = const TeliAuthError('Failed to retrieve 2FA details.');
        await dispose();
        return err;
      }

      final accountPassword = response.result as t.AccountPassword;
      log.d('Calculating SRP for 2FA');
      final srp = await tg.check2FA(accountPassword, password);
      final checkPasswordResponse = await _client!
          .auth
          .checkPassword(password: srp)
          .timeout(_invokeTimeout);

      if (checkPasswordResponse.error != null) {
        log.e('checkPassword failed: ${checkPasswordResponse.error!.errorMessage}');
        final err = TeliAuthError(checkPasswordResponse.error!.errorMessage);
        await dispose();
        return err;
      }

      credentials.sessionData = jsonEncode(_client!.authorizationKey.toJson());
      log.i('2FA sign-in successful');
      final result = TeliAuthSuccess(
        credentials,
        rawData: checkPasswordResponse.result,
      );
      await dispose();
      return result;
    } catch (e) {
      log.e('submitPassword error', e);
      await dispose();
      return TeliAuthError(e.toString());
    }
  }

  /// Closes the underlying connection.
  Future<void> dispose() async {
    log.d('Disposing TeliAuth');
    await _teliSocket?.close();
    _client = null;
    _teliSocket = null;
  }
}

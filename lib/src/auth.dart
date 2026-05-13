import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:t/t.dart' as t;
import 'package:tg/tg.dart' as tg;

import '../models/models.dart';
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
    try {
      final host = credentials.getHost();
      ip ??= host.ip;
      port ??= host.port;
      dcId ??= host.dcId;

      credentials.validateApiCredentials();

      if (_teliSocket == null) {
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
          } catch (_) {}
        }

        if (authKey == null) {
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
          if (retryCount >= _maxLoginRetries) {
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

      return await _sendCode();
    } catch (e) {
      await dispose();
      return TeliAuthError(e.toString());
    }
  }

  Future<TeliAuthState> _sendCode() async {
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
        final err = TeliAuthError(response.error!.errorMessage);
        await dispose();
        return err;
      }

      final sentCode = response.result as t.AuthSentCode;
      credentials.phoneCodeHash = sentCode.phoneCodeHash;

      return const TeliAuthWaitOtp();
    } catch (e) {
      await dispose();
      return TeliAuthError(e.toString());
    }
  }

  /// Submits the OTP code received by the user.
  Future<TeliAuthState> submitOtp(String code) async {
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
          return await _get2faState();
        }
        final err = TeliAuthError(signInResponse.error!.errorMessage);
        await dispose();
        return err;
      }

      credentials.sessionData = jsonEncode(_client!.authorizationKey.toJson());
      final result = TeliAuthSuccess(
        credentials,
        rawData: signInResponse.result,
      );
      await dispose();
      return result;
    } catch (e) {
      await dispose();
      return TeliAuthError(e.toString());
    }
  }

  Future<TeliAuthState> _get2faState() async {
    try {
      final response = await _client!
          .account
          .getPassword()
          .timeout(_invokeTimeout);
      if (response.result is t.AccountPassword) {
        final pwd = response.result as t.AccountPassword;
        return TeliAuthWaitPassword(pwd.hint ?? '');
      }
      final err = const TeliAuthError('Failed to retrieve 2FA details.');
      await dispose();
      return err;
    } catch (e) {
      await dispose();
      return TeliAuthError(e.toString());
    }
  }

  /// Submits the 2FA password.
  Future<TeliAuthState> submitPassword(String password) async {
    if (_client == null) return const TeliAuthError('Client not initialized.');

    try {
      final response = await _client!
          .account
          .getPassword()
          .timeout(_invokeTimeout);
      if (response.result is! t.AccountPassword) {
        final err = const TeliAuthError('Failed to retrieve 2FA details.');
        await dispose();
        return err;
      }

      final accountPassword = response.result as t.AccountPassword;
      final srp = await tg.check2FA(accountPassword, password);
      final checkPasswordResponse = await _client!
          .auth
          .checkPassword(password: srp)
          .timeout(_invokeTimeout);

      if (checkPasswordResponse.error != null) {
        final err = TeliAuthError(checkPasswordResponse.error!.errorMessage);
        await dispose();
        return err;
      }

      credentials.sessionData = jsonEncode(_client!.authorizationKey.toJson());
      final result = TeliAuthSuccess(
        credentials,
        rawData: checkPasswordResponse.result,
      );
      await dispose();
      return result;
    } catch (e) {
      await dispose();
      return TeliAuthError(e.toString());
    }
  }

  /// Closes the underlying connection.
  Future<void> dispose() async {
    await _teliSocket?.close();
    _client = null;
    _teliSocket = null;
  }
}

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:t/t.dart' as t;
import 'package:tg/tg.dart' as tg;

import 'teli_credentials.dart';
import 'teli_socket.dart';
export 'package:tg/tg.dart' show check2FA;


/// Defines the result of an authentication attempt.
class AuthResult {
  /// Whether the authentication was successful.
  final bool success;

  /// An optional message describing the result (e.g., error message).
  final String? message;

  /// The credentials containing the resulting session data if successful.
  final TeliCredentials? credentials;

  /// Optional raw data associated with the result (e.g., the signed-in user).
  final dynamic rawData;

  /// Creates a new [AuthResult].
  const AuthResult({
    required this.success,
    this.message,
    this.credentials,
    this.rawData,
  });
}

/// Handles the Telegram authentication lifecycle.
///
/// This class is responsible for establishing the initial connection,
/// performing the MTProto handshake, and managing the OTP and 2FA flows.
final class TeliAuth {
  tg.Client? _client;
  TeliSocket? _teliSocket;
  final TeliCredentials credentials;

  /// Callback triggered only when a new authentication process (OTP/2FA) is about to start.
  FutureOr<void> Function()? onAuthRequired;

  /// Callback used to retrieve the OTP code from the user.
  Future<String> Function()? onGetOtp;

  /// Callback triggered when 2-step verification (2FA) is required.
  Future<String> Function(String hint)? on2faRequired;

  /// Callback triggered when the authentication process completes.
  void Function(AuthResult result)? onAuthResult;

  /// Creates a new [TeliAuth] with the given [credentials].
  TeliAuth(this.credentials);

  /// Initializes the authentication and starts the automated login flow.
  ///
  /// Returns an [AuthResult] containing credentials on success.
  Future<AuthResult> login({
    String? ip,
    int? port,
    int? dcId,
  }) async {
    try {
      final host = credentials.getHost();
      ip ??= host.ip;
      port ??= host.port;
      dcId ??= host.dcId;

      credentials.validateApiCredentials();

      final socket = await Socket.connect(ip, port);
      _teliSocket = TeliSocket(socket);
      final obfuscation = tg.Obfuscation.random(false, dcId);
      final idGenerator = tg.MessageIdGenerator();

      await _teliSocket!.send(obfuscation.preamble);

      tg.AuthorizationKey? authKey;
      final sessionData = credentials.sessionData;
      if (sessionData != null && sessionData.isNotEmpty) {
        try {
          authKey = tg.AuthorizationKey.fromJson(
            jsonDecode(sessionData) as Map<String, dynamic>,
          );
        } catch (e) {
          // Fallback to DH exchange if session is invalid
        }
      }

      if (authKey == null) {
        authKey = await tg.Client.authorize(
          _teliSocket!,
          obfuscation,
          idGenerator,
        );
        credentials.sessionData = jsonEncode(authKey.toJson());
      }

      _client = tg.Client(
        socket: _teliSocket!,
        obfuscation: obfuscation,
        authorizationKey: authKey,
        idGenerator: idGenerator,
      );

      await _client!.initConnection<t.Config>(
        apiId: credentials.apiId,
        deviceModel: 'Desktop',
        systemVersion: 'Unknown',
        appVersion: '1.0.0',
        systemLangCode: 'en',
        langPack: '',
        langCode: 'en',
        query: const t.HelpGetConfig(),
      );

      bool alreadySignedIn = false;
      try {
        final userResponse = await _client!.users.getUsers(
          id: [const t.InputUserSelf()],
        );
        if (userResponse.result is t.Vector &&
            (userResponse.result as t.Vector).items.isNotEmpty) {
          alreadySignedIn = true;
        }
      } catch (e) {
        if (e.toString().contains('AUTH_KEY_UNREGISTERED') ||
            e.toString().contains('AUTH_RESTART')) {
          credentials.sessionData = null;
          await _teliSocket?.close();
          return login(ip: ip, port: port, dcId: dcId);
        }
      }

      if (alreadySignedIn) {
        final res = AuthResult(
          success: true,
          message: 'Session resumed.',
          credentials: credentials,
        );
        onAuthResult?.call(res);
        return res;
      } else {
        if (onAuthRequired != null) {
          await onAuthRequired!();
        }
        return await _startOtpFlow();
      }
    } catch (e) {
      final res = AuthResult(success: false, message: e.toString());
      onAuthResult?.call(res);
      return res;
    } finally {
      // We don't close the socket here because the client might need it,
      // but for TeliAuth, it might be safer to close if we are done.
      // However, the sessionData is what the user wants.
      await _teliSocket?.close();
    }
  }

  Future<AuthResult> _startOtpFlow() async {
    try {
      final fullPhone = credentials.validatePhoneNumber();

      final response = await _client!.auth.sendCode(
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
      );

      if (response.error != null) {
        final res = AuthResult(
          success: false,
          message: response.error!.errorMessage,
        );
        onAuthResult?.call(res);
        return res;
      }

      final sentCode = response.result as t.AuthSentCode;
      credentials.phoneCodeHash = sentCode.phoneCodeHash;

      if (onGetOtp == null) {
        throw StateError('onGetOtp callback is required but not provided.');
      }
      final otp = await onGetOtp!();

      final signInResponse = await _client!.auth.signIn(
        phoneNumber: fullPhone,
        phoneCodeHash: credentials.phoneCodeHash!,
        phoneCode: otp,
      );

      if (signInResponse.error != null) {
        if (signInResponse.error!.errorMessage == 'SESSION_PASSWORD_NEEDED') {
          return await _handle2FA();
        } else {
          final res = AuthResult(
            success: false,
            message: signInResponse.error!.errorMessage,
          );
          onAuthResult?.call(res);
          return res;
        }
      } else {
        credentials.sessionData = jsonEncode(_client!.authorizationKey.toJson());
        final res = AuthResult(
          success: true,
          credentials: credentials,
          rawData: signInResponse.result,
        );
        onAuthResult?.call(res);
        return res;
      }
    } catch (e) {
      final res = AuthResult(success: false, message: e.toString());
      onAuthResult?.call(res);
      return res;
    }
  }

  Future<AuthResult> _handle2FA() async {
    final accountPasswordResponse = await _client!.account.getPassword();
    if (accountPasswordResponse.result is t.AccountPassword) {
      final accountPassword =
          accountPasswordResponse.result as t.AccountPassword;
      final hint = accountPassword.hint ?? '';

      final passwordProvider = on2faRequired;

      if (passwordProvider == null) {
        final res = const AuthResult(
          success: false,
          message: '2FA required but no password callback provided.',
        );
        onAuthResult?.call(res);
        return res;
      }

      final password = await passwordProvider(hint);
      final srp = await tg.check2FA(accountPassword, password);
      final checkPasswordResponse = await _client!.auth.checkPassword(
        password: srp,
      );

      if (checkPasswordResponse.error != null) {
        final res = AuthResult(
          success: false,
          message: checkPasswordResponse.error!.errorMessage,
        );
        onAuthResult?.call(res);
        return res;
      } else {
        credentials.sessionData = jsonEncode(_client!.authorizationKey.toJson());
        final res = AuthResult(
          success: true,
          credentials: credentials,
          rawData: checkPasswordResponse.result,
        );
        onAuthResult?.call(res);
        return res;
      }
    }
    return const AuthResult(
      success: false,
      message: 'Failed to retrieve 2FA details.',
    );
  }
}

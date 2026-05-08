import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:t/t.dart' as t;
import 'package:tg/tg.dart' as tg;

import 'telidemo_credentials.dart';
import 'telidemo_socket.dart';

/// Defines the result of an authentication attempt.
class AuthResult {
  /// Whether the authentication was successful.
  final bool success;

  /// An optional message describing the result (e.g., error message).
  final String? message;

  /// Optional data associated with the result (e.g., the signed-in user).
  final dynamic data;

  /// Creates a new [AuthResult].
  const AuthResult({
    required this.success,
    this.message,
    this.data,
  });
}

/// A high-level Telegram client with an automated authentication flow.
///
/// This client wraps [tg.Client] and provides a simplified interface for
/// connecting, authenticating, and interacting with the Telegram API.
final class TeliDemoClient {
  tg.Client? _client;
  TeliDemoSocket? _teliSocket;
  final TeliDemoCredentials credentials;
  final StreamController<dynamic> _updateController =
      StreamController<dynamic>.broadcast();

  /// Callback triggered only when a new authentication process (OTP/2FA) is about to start.
  FutureOr<void> Function()? onAuthRequired;

  /// Callback used to retrieve the OTP code from the user.
  Future<String> Function()? onGetOtp;

  /// Callback triggered when 2-step verification (2FA) is required.
  ///
  /// This callback must return the 2FA password. The [hint] provides the
  /// password hint configured by the user.
  Future<String> Function(String hint)? on2faRequired;

  /// Callback used to retrieve the 2FA password from the user.
  ///
  /// The [hint] provides the password hint configured by the user.
  @Deprecated('Use on2faRequired instead')
  Future<String> Function(String hint)? onGetPassword;

  /// Callback triggered when the authentication process completes.
  void Function(AuthResult result)? onAuthResult;

  /// Creates a new [TeliDemoClient] with the given [credentials].
  TeliDemoClient(this.credentials);

  /// The underlying raw [tg.Client] instance.
  ///
  /// This is `null` until [login] is called and the initial handshake is successful.
  tg.Client? get rawClient => _client;

  /// Initializes the client and starts the automated login flow.
  ///
  /// Returns an [AuthResult] indicating the outcome of the login process.
  Future<AuthResult> login({
    String ip = '91.108.56.130',
    int port = 443,
    int dcId = 5,
  }) async {
    try {
      credentials.validateApiCredentials();

      final socket = await Socket.connect(ip, port);
      _teliSocket = TeliDemoSocket(socket);
      final obfuscation = tg.Obfuscation.random(false, dcId);
      final idGenerator = tg.MessageIdGenerator();

      await _teliSocket!.send(obfuscation.preamble);

      tg.AuthorizationKey? authKey;
      final session = credentials.sessionData;
      if (session != null && session.isNotEmpty) {
        try {
          authKey = tg.AuthorizationKey.fromJson(
            jsonDecode(session) as Map<String, dynamic>,
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

      _client!.stream.listen((event) {
        _updateController.add(event);
      });

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
          _teliSocket?.close();
          return login(ip: ip, port: port, dcId: dcId);
        }
      }

      if (alreadySignedIn) {
        final res = const AuthResult(success: true, message: 'Session resumed.');
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
          print('[Auth] OTP accepted. 2-Step Verification (2FA) is enabled.');
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
        final res = AuthResult(success: true, data: signInResponse.result);
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

      final passwordProvider = on2faRequired ?? onGetPassword;

      if (passwordProvider == null) {
        final res = const AuthResult(
          success: false,
          message: '2FA required but no password callback provided.',
        );
        onAuthResult?.call(res);
        return res;
      }

      print('[Auth] Requesting 2FA password (Hint: $hint)...');
      final password = await passwordProvider(hint);
      final srp = await tg.check2FA(accountPassword, password);
      final checkPasswordResponse =
          await _client!.auth.checkPassword(password: srp);

      if (checkPasswordResponse.error != null) {
        final res = AuthResult(
          success: false,
          message: checkPasswordResponse.error!.errorMessage,
        );
        onAuthResult?.call(res);
        return res;
      } else {
        final res = AuthResult(success: true, data: checkPasswordResponse.result);
        onAuthResult?.call(res);
        return res;
      }
    }
    return const AuthResult(success: false, message: 'Failed to retrieve 2FA details.');
  }

  /// Listens for updates from the Telegram server.
  void onUpdate(FutureOr<void> Function(dynamic data) callback) {
    _updateController.stream.listen((data) async {
      await callback(data);
    });
  }

  /// Invokes a raw Telegram method (RPC call).
  Future<dynamic> invoke(t.TlMethod method) async {
    final client = _client;
    if (client == null) {
      throw StateError('Client not initialized. Call login() first.');
    }
    return await client.invoke(method);
  }

  /// Retrieves a list of all channels and chats the user is subscribed to.
  Future<t.Result<t.MessagesDialogsBase>> getSubscribedChannels() async {
    final client = _client;
    if (client == null) {
      throw StateError('Client not initialized. Call login() first.');
    }

    return await client.messages.getDialogs(
      excludePinned: false,
      offsetDate: DateTime.fromMillisecondsSinceEpoch(0),
      offsetId: 0,
      offsetPeer: const t.InputPeerEmpty(),
      limit: 100,
      hash: 0,
    );
  }

  /// Retrieves message history for a specific chat.
  Future<dynamic> getChatHistory(
    t.InputPeerBase peer, {
    int offsetId = 0,
    int offsetDate = 0,
    int addOffset = 0,
    int limit = 10,
    int maxId = 0,
    int minId = 0,
  }) async {
    final client = _client;
    if (client == null) {
      throw StateError('Client not initialized. Call login() first.');
    }

    return await client.messages.getHistory(
      peer: peer,
      offsetId: offsetId,
      offsetDate: DateTime.fromMillisecondsSinceEpoch(offsetDate * 1000),
      addOffset: addOffset,
      limit: limit,
      maxId: maxId,
      minId: minId,
      hash: 0,
    );
  }

  /// Closes the connection and releases resources.
  ///
  /// This method saves the latest authorization state (including any updated
  /// server salts) to [credentials.sessionData] before closing the network socket.
  Future<void> close() async {
    print('[Client] Shutting down client and saving local state...');
    
    // Capture the latest state from the raw client before it's cleared
    final raw = _client;
    if (raw != null) {
      credentials.sessionData = jsonEncode(raw.authorizationKey.toJson());
    }

    await _teliSocket?.close();
    await _updateController.close();
    _client = null;
    _teliSocket = null;
    print('[Client] Client shutdown complete.');
  }
}

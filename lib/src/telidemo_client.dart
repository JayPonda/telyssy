import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:tg/tg.dart' as tg;
import 'package:t/t.dart' as t;
import 'telidemo_credentials.dart';
import 'telidemo_socket.dart';

/// Defines the result of an authentication attempt.
class AuthResult {
  final bool success;
  final String? message;
  final dynamic data;

  AuthResult({required this.success, this.message, this.data});
}

/// A wrapper around [tg.Client] with an automated callback-driven auth flow.
final class TeliDemoClient {
  tg.Client? _client;
  final TeliDemoCredentials credentials;
  final StreamController<dynamic> _updateController = StreamController<dynamic>.broadcast();

  // Callbacks
  FutureOr<void> Function()? onBeforeAuth;
  Future<String> Function()? onGetOtp;
  Future<String> Function(String hint)? onGetPassword; // For 2FA
  void Function(AuthResult result)? onAuthResult;

  TeliDemoClient(this.credentials);

  /// Validates the API credentials before starting the auth flow.
  void validateApiCredentials() {
    // API ID: numeric, typically 7-10 digits
    final apiIdStr = credentials.apiId.toString();
    if (!RegExp(r'^\d{7,10}$').hasMatch(apiIdStr)) {
      throw ArgumentError('Invalid API ID: Must be a 7-10 digit number.');
    }

    // API Hash: 32 character hex-like string
    if (credentials.apiHash.length != 32) {
      throw ArgumentError('Invalid API Hash: Must be 32 characters long.');
    }
  }

  /// Validates the phone number before starting the OTP flow.
  void validatePhoneNumber() {
    // Phone Number: Should have country code and 10+ digits
    final phone = credentials.phoneNumber;
    if (phone == null || !RegExp(r'^\+\d{11,15}$').hasMatch(phone)) {
      throw ArgumentError(
          'Invalid Phone Number: Must start with + and include country code (e.g., +919876543210).');
    }
  }

  /// Initializes the client and starts the automated login flow.
  Future<void> login({String ip = '91.108.56.130', int port = 443, int dcId = 5}) async {
    // 1. Validate API Credentials
    validateApiCredentials();

    // 2. Before Auth Callback
    if (onBeforeAuth != null) {
      await onBeforeAuth!();
    }

    // 3. Connect & Authorize (DH Handshake)
    final socket = await Socket.connect(ip, port);
    // ... rest of the method unchanged ...
    final teliSocket = TeliDemoSocket(socket);
    final obfuscation = tg.Obfuscation.random(false, dcId);
    final idGenerator = tg.MessageIdGenerator();

    await teliSocket.send(obfuscation.preamble);

    tg.AuthorizationKey? authKey;
    final session = credentials.sessionData;
    if (session != null && session.isNotEmpty) {
      try {
        authKey = tg.AuthorizationKey.fromJson(jsonDecode(session));
      } catch (e) {
        // Fallback to DH exchange if session is invalid
      }
    }

    if (authKey == null) {
      authKey = await tg.Client.authorize(
        teliSocket,
        obfuscation,
        idGenerator,
      );
      credentials.sessionData = jsonEncode(authKey.toJson());
    }

    _client = tg.Client(
      socket: teliSocket,
      obfuscation: obfuscation,
      authorizationKey: authKey,
      idGenerator: idGenerator,
    );

    _client!.stream.listen((event) {
      _updateController.add(event);
      _handleAuthUpdates(event);
    });

    // 4. Init Connection
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

    // 5. Check if already signed in
    bool alreadySignedIn = false;
    try {
      final userResponse = await _client!.users.getUsers(id: [const t.InputUserSelf()]);
      if (userResponse.result is List && (userResponse.result as List).isNotEmpty) {
        alreadySignedIn = true;
      }
    } catch (e) {
      // Not signed in
    }

    if (alreadySignedIn) {
      onAuthResult?.call(AuthResult(success: true, message: 'Session resumed.'));
    } else {
      // 6. Start OTP Flow
      await _startOtpFlow();
    }
  }

  Future<void> _startOtpFlow() async {
    try {
      validatePhoneNumber();

      final response = await _client!.auth.sendCode(
        phoneNumber: credentials.phoneNumber!,
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
        onAuthResult?.call(AuthResult(success: false, message: response.error!.errorMessage));
        return;
      }

      final sentCode = response.result as t.AuthSentCode;
      credentials.phoneCodeHash = sentCode.phoneCodeHash;

      // Request OTP via callback
      if (onGetOtp == null) {
        throw StateError('onGetOtp callback is required but not provided.');
      }
      final otp = await onGetOtp!();

      final signInResponse = await _client!.auth.signIn(
        phoneNumber: credentials.phoneNumber!,
        phoneCodeHash: credentials.phoneCodeHash!,
        phoneCode: otp,
      );

      if (signInResponse.error != null) {
        if (signInResponse.error!.errorMessage == 'SESSION_PASSWORD_NEEDED') {
          await _handle2FA();
        } else {
          onAuthResult?.call(AuthResult(success: false, message: signInResponse.error!.errorMessage));
        }
      } else {
        onAuthResult?.call(AuthResult(success: true, data: signInResponse.result));
      }
    } catch (e) {
      onAuthResult?.call(AuthResult(success: false, message: e.toString()));
    }
  }

  Future<void> _handle2FA() async {
    final accountPasswordResponse = await _client!.account.getPassword();
    if (accountPasswordResponse.result is t.AccountPassword) {
      final accountPassword = accountPasswordResponse.result as t.AccountPassword;
      
      if (onGetPassword == null) {
        onAuthResult?.call(AuthResult(success: false, message: '2FA required but onGetPassword callback not provided.'));
        return;
      }

      final password = await onGetPassword!(accountPassword.hint ?? '');
      final srp = await tg.check2FA(accountPassword, password);
      final checkPasswordResponse = await _client!.auth.checkPassword(password: srp);

      if (checkPasswordResponse.error != null) {
        onAuthResult?.call(AuthResult(success: false, message: checkPasswordResponse.error!.errorMessage));
      } else {
        onAuthResult?.call(AuthResult(success: true, data: checkPasswordResponse.result));
      }
    }
  }

  void _handleAuthUpdates(dynamic event) {
    // We can add logic here to handle t.UpdateAuthorizationState if needed,
    // though MTProto usually uses direct RPC responses for login.
  }

  /// Listens for updates.
  void onUpdate(FutureOr<void> Function(dynamic data) callback) {
    _updateController.stream.listen((data) async {
      await callback(data);
    });
  }

  /// Invokes a Telegram method.
  Future<dynamic> invoke(t.TlMethod method) async {
    if (_client == null) throw StateError('Client not initialized. Call login() first.');
    return await _client!.invoke(method);
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
    if (_client == null) throw StateError('Client not initialized. Call login() first.');
    
    return await _client!.messages.getHistory(
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

  tg.Client? get rawClient => _client;
}

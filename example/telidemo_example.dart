import 'dart:io';

import 'package:t/t.dart' as t;
import 'package:telidemo/telidemo.dart';

/// A custom credentials class that saves/loads session data from a local file.
/// 
/// This implementation demonstrates how to persist the MTProto session data
/// to a JSON file, allowing the client to resume sessions without OTP.
class PersistentCredentials extends TeliDemoCredentials {
  final File _sessionFile = File('session.json');

  PersistentCredentials({required super.apiId, required super.apiHash});

  @override
  String? get sessionData {
    if (_sessionFile.existsSync()) {
      return _sessionFile.readAsStringSync();
    }
    return null;
  }

  @override
  set sessionData(String? value) {
    if (value != null) {
      _sessionFile.writeAsStringSync(value);
    } else if (_sessionFile.existsSync()) {
      _sessionFile.deleteSync();
    }
  }

  /// Returns true if a session file already exists on disk.
  bool get hasSession => _sessionFile.existsSync();
}

void main() async {
  print('=========================================');
  print('   TeliDemo Standalone Management Tool   ');
  print('=========================================');

  // 1. Setup API Credentials
  final sessionExists = File('session.json').existsSync();

  int? apiId;
  String? apiHash;

  if (!sessionExists) {
    print('[Setup] No existing session found. Please enter your API credentials.');
    stdout.write('Enter your API ID: ');
    final apiIdInput = stdin.readLineSync();
    stdout.write('Enter your API Hash: ');
    final apiHashInput = stdin.readLineSync();

    if (apiIdInput == null || apiHashInput == null) return;
    apiId = int.tryParse(apiIdInput);
    apiHash = apiHashInput;
  } else {
    print('[Setup] Existing session detected.');
    stdout.write('Enter your API ID to resume: ');
    apiId = int.tryParse(stdin.readLineSync() ?? '');
    stdout.write('Enter your API Hash: ');
    apiHash = stdin.readLineSync();
  }

  if (apiId == null || apiHash == null) {
    print('[Error] API ID and Hash are mandatory for connection.');
    return;
  }

  final credentials = PersistentCredentials(
    apiId: apiId,
    apiHash: apiHash,
  );

  // 2. Initialize the High-Level Client
  final client = TeliDemoClient(credentials);

  // --- Register Authentication Callbacks ---

  // Triggered only if the session is invalid/missing and a full login is needed.
  client.onAuthRequired = () {
    print('\n[Notice] Full authentication required (OTP flow).');
    
    if (credentials.countryCode == null) {
      stdout.write('Enter Country Code (e.g., 91): ');
      credentials.countryCode = stdin.readLineSync();
    }
    if (credentials.phoneNumber == null) {
      stdout.write('Enter Phone Number (e.g., 9876543210): ');
      credentials.phoneNumber = stdin.readLineSync();
    }
  };

  // Triggered when Telegram sends the OTP code.
  client.onGetOtp = () async {
    stdout.write('\n[Auth] Enter the OTP code received: ');
    return stdin.readLineSync() ?? '';
  };

  // Triggered only if 2-Step Verification is enabled on the account.
  client.on2faRequired = (hint) async {
    stdout.write('\n[2FA] 2-Step Verification Enabled. \n[2FA] Hint: $hint\n[2FA] Enter Password: ');
    return stdin.readLineSync() ?? '';
  };

  // Triggered when the final authentication result is determined.
  client.onAuthResult = (result) {
    if (result.success) {
      print('\n[Success] ${result.message ?? "Authentication successful."}');
    } else {
      print('\n[Failure] ${result.message}');
    }
  };

  // 3. Automated Login Flow
  try {
    print('\n[Action] Connecting to Telegram servers...');
    final loginResult = await client.login();
    
    if (!loginResult.success) {
      print('[Status] Login failed. Invalidating session data for security.');
      credentials.sessionData = null;
      await client.close();
      exit(1);
    }
    
    print('[Status] Connected and authenticated successfully.');

    // 4. Standalone API Task: Retrieve Subscribed Channels
    print('\n[Action] Fetching subscribed channels...');
    final response = await client.getSubscribedChannels();

    if (response.error == null) {
      final result = response.result;
      List<t.ChatBase> chats = [];
      
      if (result is t.MessagesDialogs) {
        chats = result.chats;
      } else if (result is t.MessagesDialogsSlice) {
        chats = result.chats;
      }

      if (chats.isNotEmpty) {
        print('\n[Data] Subscribed Channels and Chats:');
        for (final chat in chats) {
          if (chat is t.Chat) {
            print('  • [Chat]    ${chat.title}');
          } else if (chat is t.Channel) {
            print('  • [Channel] ${chat.title}');
          }
        }
      } else {
        print('\n[Data] No subscriptions found for this account.');
      }
    } else {
      print('\n[Error] API Request failed: ${response.error?.errorMessage}');
    }

    // 5. Cleanup and Connection Teardown
    print('\n[Action] Task completed. Shutting down connection...');
    await client.close();
    print('[Status] Session state preserved. Done.');
    exit(0);
  } catch (e) {
    print('\n[Fatal] An unexpected error occurred: $e');
    await client.close();
    exit(1);
  }
}

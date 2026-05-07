import 'dart:io';
import 'package:telidemo/telidemo.dart';
import 'package:t/t.dart' as t;

/// A custom credentials class that saves/loads session data from a local file.
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
}

void main() async {
  print('--- TeliDemo Persistent Userbot ---');

  // 1. Setup API Credentials (Interactive for first time)
  // In a real app, these could be hardcoded or from .env
  stdout.write('Enter your API ID: ');
  final apiIdInput = stdin.readLineSync();
  stdout.write('Enter your API Hash: ');
  final apiHashInput = stdin.readLineSync();

  if (apiIdInput == null || apiHashInput == null) return;

  final credentials = PersistentCredentials(
    apiId: int.parse(apiIdInput),
    apiHash: apiHashInput,
  );

  // 2. Setup Client
  final client = TeliDemoClient(credentials);

  // --- Register Callbacks ---

  client.onBeforeAuth = () {
    print('\n[Step 1] Credentials validated. Connecting to Telegram...');

    // Prompt for phone number if not already stored
    if (credentials.phoneNumber == null) {
      stdout.write('Enter your Phone Number (e.g., +919876543210): ');
      credentials.phoneNumber = stdin.readLineSync();
    }
  };

  client.onGetOtp = () async {
    stdout.write('\n[Step 2] OTP Sent! Enter the code you received: ');
    final otp = stdin.readLineSync() ?? '';
    return otp;
  };

  client.onGetPassword = (hint) async {
    stdout.write('\n[Step 2FA] Password required (Hint: $hint): ');
    final password = stdin.readLineSync() ?? '';
    return password;
  };

  client.onAuthResult = (result) {
    if (result.success) {
      print('\n[Result] Login Successful! Welcome.');
    } else {
      print('\n[Result] Login Failed: ${result.message}');
      exit(1);
    }
  };

  // Setup listener for real-time messages
  client.onUpdate((data) {
    if (data is t.Updates) {
      for (final update in data.updates) {
        if (update is t.UpdateNewMessage) {
          final msg = update.message;
          if (msg is t.Message) {
            print('\n>> New Message: ${msg.message}');
          }
        }
      }
    }
  });

  // 3. Run the automated flow
  try {
    await client.login();

    print('\nUserbot is active. Listening for messages... (Ctrl+C to stop)');
    await Future.delayed(const Duration(days: 1));
  } catch (e) {
    print('\nInitialization Error: $e');
  }
}

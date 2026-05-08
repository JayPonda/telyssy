import 'dart:io';
import 'dart:convert';

import 'package:t/t.dart' as t;
import 'package:telidemo/telidemo.dart';

/// A utility to persist credentials with session data to a local file.
class SessionStore {
  static final File _file = File('session.json');

  static void save(TeliCredentials credentials) {
    _file.writeAsStringSync(
      jsonEncode({
        'apiId': credentials.apiId,
        'apiHash': credentials.apiHash,
        'sessionData': credentials.sessionData,
      }),
    );
  }

  static TeliCredentials? load() {
    if (!_file.existsSync()) return null;
    try {
      final data = jsonDecode(_file.readAsStringSync()) as Map<String, dynamic>;
      return TeliCredentials(
        apiId: data['apiId'] as int,
        apiHash: data['apiHash'] as String,
        sessionData: data['sessionData'] as String?,
      );
    } catch (_) {
      return null;
    }
  }

  static void clear() {
    if (_file.existsSync()) _file.deleteSync();
  }
}

List<t.MessageBase> _extractMessages(t.MessagesMessagesBase? result) {
  if (result == null) return [];
  if (result is t.MessagesMessages) return result.messages;
  if (result is t.MessagesMessagesSlice) return result.messages;
  if (result is t.MessagesChannelMessages) return result.messages;
  return [];
}

void main() async {
  print('=========================================');
  print('   TeliDemo Client Example');
  print('=========================================');

  TeliCredentials? credentials = SessionStore.load();

  if (credentials == null || credentials.sessionData == null) {
    print('[Auth] No valid session found. Starting authentication...');

    stdout.write('Enter your API ID: ');
    final apiId = int.tryParse(stdin.readLineSync() ?? '');

    stdout.write('Enter your API Hash: ');
    final apiHash = stdin.readLineSync();

    if (apiId == null || apiHash == null || apiHash.isEmpty) {
      print('[Error] API ID and Hash are mandatory.');
      return;
    }

    stdout.write('Enter Country Code (e.g., 91): ');
    final countryCode = stdin.readLineSync() ?? '';
    stdout.write('Enter Phone Number (e.g., 9876543210): ');
    final phoneNumber = stdin.readLineSync() ?? '';

    credentials = TeliCredentials(
      apiId: apiId,
      apiHash: apiHash,
      countryCode: countryCode,
      phoneNumber: phoneNumber,
    );

    print('[Auth] Authenticating...');
    final auth = TeliAuth(credentials);

    auth.onGetOtp = () async {
      stdout.write('[Auth] Enter OTP code: ');
      return stdin.readLineSync() ?? '';
    };

    auth.on2faRequired = (hint) async {
      print('[2FA] Hint: $hint');
      stdout.write('[2FA] Enter Password: ');
      return stdin.readLineSync() ?? '';
    };

    try {
      await auth.login();

      SessionStore.save(credentials);
      print('[Auth] Authentication successful. Session saved.');
    } catch (e) {
      print('[Error] Authentication failed: $e');
      return;
    }
  } else {
    print(
      '[Session] Resuming existing session for API ID: ${credentials.apiId}',
    );
  }

  // Create client with credentials
  final client = TeliClient(credentials);

  // Setup logout hooks
  client.onBeforeLogout = () {
    print('[Hook] Cleaning up before logout...');
  };

  client.onAfterLogout = (result) {
    print('[Hook] Logout complete. Server confirmation received.');
  };

  try {
    print('[Action] Connecting to Telegram...');
    await client.connect();
    print('[Status] Connected.');

    print('[Action] Fetching dialogs...');
    final response = await client.getSubscribedChannels(limit: 10);

    if (response.error == null) {
      final result = response.result;
      List<t.ChatBase> chats = [];
      if (result is t.MessagesDialogs) {
        chats = result.chats;
      } else if (result is t.MessagesDialogsSlice) {
        chats = result.chats;
      }

      print('[Data] Found ${chats.length} chats:');
      for (var i = 0; i < chats.length; i++) {
        final chat = chats[i];
        String title = 'Unknown';
        if (chat is t.Chat) title = chat.title;
        if (chat is t.Channel) title = chat.title;
        print('  [$i] $title');
      }

      if (chats.isNotEmpty) {
        stdout.write(
          '\nEnter index to view messages, "L" to logout, or enter to skip: ',
        );
        final input = stdin.readLineSync();
        if (input != null && input.toUpperCase() == 'L') {
          print('[Action] Logging out...');
          final res = await client.logout();
          if (res.error == null) {
            SessionStore.clear();
            print('[Status] Logged out and session cleared.');
            return;
          } else {
            print('[Error] Logout failed: ${res.error!.errorMessage}');
            print('[Action] Continuing with session...');
          }
        }

        if (input != null && input.isNotEmpty) {
          final index = int.tryParse(input);
          if (index != null && index >= 0 && index < chats.length) {
            final selectedChat = chats[index];
            String selectedTitle = 'Unknown';
            if (selectedChat is t.Chat) selectedTitle = selectedChat.title;
            if (selectedChat is t.Channel) selectedTitle = selectedChat.title;

            int channelId = 0;
            int? accessHash;

            if (selectedChat is t.Channel) {
              channelId = selectedChat.id;
              accessHash = selectedChat.accessHash;
            } else if (selectedChat is t.ChannelForbidden) {
              channelId = selectedChat.id;
              accessHash = selectedChat.accessHash;
            } else if (selectedChat is t.Chat) {
              channelId = selectedChat.id;
            }

            stdout.write('\nSelect fetch mode:\n');
            stdout.write('  1 - Time range (start to end datetime)\n');
            stdout.write(
              '  2 - Until message (now backwards to last message ID)\n',
            );
            stdout.write('  3 - Latest N messages (simple)\n');
            stdout.write('Enter choice: ');
            final modeInput = stdin.readLineSync();

            List<t.MessageBase> messages = [];

            if (modeInput == '1') {
              if (selectedChat is! t.Channel) {
                print('[Error] Time range fetch only supported for channels.');
                await client.close();
                return;
              }
              stdout.write(
                'Enter START datetime (YYYY-MM-DD HH:MM:SS, or empty for 24h ago): ',
              );
              final startInput = stdin.readLineSync();
              DateTime? startDate;
              if (startInput != null && startInput.isNotEmpty) {
                startDate = DateTime.tryParse(startInput);
                if (startDate == null) {
                  print(
                    '[Warning] Could not parse START datetime, using default.',
                  );
                }
              }

              stdout.write(
                'Enter END datetime (YYYY-MM-DD HH:MM:SS, or empty for now): ',
              );
              final endInput = stdin.readLineSync();
              DateTime? endDate;
              if (endInput != null && endInput.isNotEmpty) {
                endDate = DateTime.tryParse(endInput);
                if (endDate == null) {
                  print(
                    '[Warning] Could not parse END datetime, using default.',
                  );
                }
              }

              print('\n[Action] Fetching by time range for: $selectedTitle...');
              messages = await client.getMessagesByTimeRange(
                channelId,
                accessHash: accessHash,
                startDate: startDate,
                endDate: endDate,
              );
            } else if (modeInput == '2') {
              if (selectedChat is! t.Channel) {
                print('[Error] Until message fetch only supported for channels.');
                await client.close();
                return;
              }
              stdout.write('Enter message ID to stop at (required): ');
              final idInput = stdin.readLineSync();
              int? lastMessageId;
              if (idInput != null && idInput.isNotEmpty) {
                lastMessageId = int.tryParse(idInput);
              }

              if (lastMessageId == null) {
                print('[Error] Message ID is required.');
                await client.close();
                return;
              }

              print('\n[Action] Fetching backwards for: $selectedTitle...');
              messages = await client.getMessagesUntil(
                channelId,
                accessHash: accessHash,
                lastMessageId: lastMessageId,
              );
            } else {
              print(
                '\n[Action] Fetching latest messages for: $selectedTitle...',
              );
              final msgRes = await client.getMessages(selectedChat, limit: 5);
              if (msgRes.error == null) {
                messages = _extractMessages(msgRes.result);
              } else {
                print('[Error] ${msgRes.error?.errorMessage}');
              }
            }

            print('\n[Data] Fetched ${messages.length} messages:');
            for (final msg in messages) {
              if (msg is t.Message) {
                print('  - [ID: ${msg.id}] [${msg.date}] ${msg.message}');
              } else if (msg is t.MessageService) {
                print('  - [ID: ${msg.id}] [${msg.date}] Service Message');
              }
            }
          }
        }
      }
    } else {
      print('[Error] Failed to fetch dialogs: ${response.error?.errorMessage}');
    }

    stdout.write('\nWould you like to logout before exiting? (y/N): ');
    final logoutChoice = stdin.readLineSync()?.toLowerCase();
    if (logoutChoice == 'y') {
      print('[Action] Logging out...');
      final res = await client.logout();
      if (res.error == null) {
        SessionStore.clear();
        print('[Status] Logged out and session cleared.');
      } else {
        print('[Error] Logout failed: ${res.error!.errorMessage}');
        await client.close();
      }
    } else {
      print('\n[Action] Shutting down...');
      await client.close();
    }
    print('[Status] Done.');
  } catch (e) {
    print('[Fatal] Error: $e');
    if (e.toString().contains('AUTH_KEY_UNREGISTERED')) {
      SessionStore.clear();
      print(
        '[Notice] Session expired and cleared. Please run again to re-authenticate.',
      );
    }
    await client.close();
  }
}

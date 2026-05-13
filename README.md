# telidemo

A high-level, pure Dart wrapper around the Telegram MTProto API. `telidemo` provides a simplified interface for building Telegram clients, handling authentication, and managing message history with ease.

Built on top of the `tg` transport layer and `t` TL schema packages.

## Features

- **100% Pure Dart:** No native binaries, works across all platforms supported by Dart.
- **Simplified Authentication:** Automated login flow handling OTP and 2-step verification (2FA) via callbacks.
- **High-Level Messaging:** 
    - Fetch messages by time range.
    - Backward pagination until a specific message ID.
    - Transparent RPC invocation for the full MTProto API.
- **Session Persistence:** Easy serialization and restoration of authorization keys.
- **Smart DC Selection:** Automatic selection of the nearest Telegram datacenter based on country code.
- **Update Handling:** Stream-based interface for receiving server-side updates.

## Getting started

Add `telidemo` to your `pubspec.yaml`. Since it's currently a wrapper for internal use, you can point to the repository or use it locally.

```yaml
dependencies:
  telidemo:
    path: ../telyBelly # or git dependency
  t: ^225.0.0
  tg: ^0.0.18
```

## Usage

### 1. Configure Credentials

```dart
import 'package:telidemo/telidemo.dart';

final credentials = TeliCredentials(
  apiId: 123456,
  apiHash: 'your_api_hash',
  countryCode: '91',
  phoneNumber: '9876543210',
);
```

### 2. Authentication (TeliAuth)

```dart
final auth = TeliAuth(credentials);

auth.onGetOtp = () async {
  // Logic to get OTP from user (e.g., via UI or stdin)
  return '12345';
};

auth.on2faRequired = (hint) async {
  // Logic to get 2FA password if enabled
  print('Hint: $hint');
  return 'your_password';
};

final result = await auth.login();
if (result.success) {
  print('Signed in as: ${result.rawData}');
  // Save credentials.sessionData for future use
}
```

### 3. Using the Client (TeliClient)

```dart
final client = TeliClient(credentials);

// Connect and resume session
await client.connect();

// Fetch last 24 hours of messages from a channel
final messages = await client.getMessagesByTimeRange(
  channelId,
  accessHash: accessHash,
  startDate: DateTime.now().subtract(Duration(hours: 24)),
);

// Listen for updates
client.onUpdate((data) {
  print('New Update: $data');
});

// Invoke raw MTProto methods
final config = await client.invoke(const t.HelpGetConfig());
```

## Additional information

### MTProto Schema
This library uses `package:t` for the TL schema. All result types from `invoke`, `getMessages`, etc., are from the `t` namespace.

### Contributing
Contributions are welcome! Please see the `planning/` directory for upcoming features and architectural decisions.

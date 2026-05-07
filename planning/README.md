# Telegram Universe Wrapper Planning

This document outlines the plan for building a wrapper around the `telegram_universe` library to simplify its usage for the `telidemo` project.

## Goals
- Simplify client initialization and authentication.
- Provide a high-level API for sending and receiving messages.
- Abstract the event-driven update system into a more manageable interface.

## Tasks
- [x] Create `TeliDemoClient` class in `lib/src/telidemo_client.dart`.
- [x] Create `TeliDemoCredentials` class in `lib/src/telidemo_credentials.dart`.
- [x] Implement initialization logic using `TeliDemoCredentials`.
- [ ] Implement authentication methods.
- [x] Implement message sending functionality. (Generic `invoke` implemented)
- [x] Implement update listening functionality.
- [x] Export the new classes in `lib/telidemo.dart`.
- [x] Add unit tests for the wrapper.

## Architecture
The `TeliDemoClient` acts as a facade for `telegram_universe.TelegramUniverse`. For security, it is marked as `final` to prevent inheritance and ensure its behavior remains predictable and secure.

```dart
class TeliDemoCredentials {
  int apiId;
  String apiHash;
  String? phoneNumber;
  
  TeliDemoCredentials({required this.apiId, required this.apiHash});
}

final class TeliDemoClient {
  final TeliDemoCredentials credentials;
  
  TeliDemoClient(this.credentials);
  
  Future<void> init({String pathTdlib = ""});
  void onUpdate(FutureOr<void> Function(Map data) callback);
  Future<Map> invoke(Map parameters);
}
```

## Verification
- Run tests using `dart test`.
- Verify compilation and linting.

# Changelog

## 1.1.1 (2026-05-14)

### Bug Fixes
- **Timeout enforcement on all network operations.** Previously, `Socket.connect`, DH key exchange, `initConnection`, and all API method invocations lacked timeouts, causing the app to hang indefinitely when the Telegram server was unreachable or slow. Added:
  - 15s timeout on TCP socket connection.
  - 30s timeout on authorization key exchange (Diffie-Hellman).
  - 20s timeout on all API calls (`initConnection`, `users.getUsers`, `auth.sendCode`, `auth.signIn`, `account.getPassword`, `auth.checkPassword`).
  - Timeout errors are surfaced as `TeliAuthError` states instead of silent hangs.
- **Fixed unbounded recursion on session expiry.** The `login()` method recursed infinitely when `AUTH_KEY_UNREGISTERED` or `AUTH_RESTART` errors persisted. Now limited to 2 consecutive retries before returning `TeliAuthError`.

## 1.1.0 (2026-05-13)

### Rebranding & Architecture Refactor
- Renamed library from `telidemo` to `telissy`.
- Introduced a **Reactive Auth State Machine**. Replaced blocking callbacks in `TeliAuth` with non-blocking states (`NeedOtp`, `NeedPassword`, `Success`).
- Refactored `TeliClient` to use **Dart Streams** for message fetching. Large message histories are now yielded in memory-efficient batches.
- Implemented **Facade Data Models**:
    - `TeliMessage`, `TeliChannel`, and `TeliUser` provide a clean abstraction over raw MTProto types.
    - Raw types from `package:t` are now handled internally and not leaked to the consumer.
- Refactored `TeliCredentials` into an abstract base class to improve OOP reusability and custom persistence support.
- Standardized nomenclature across the entire package.

### Features
- `TeliClient.getMessagesByTimeRange`: Stream-based message retrieval for specific time windows.
- `TeliClient.getMessagesUntil`: Stream-based message retrieval until a specific message ID is reached.
- `TeliClient.getSubscribedChannels`: Simplified retrieval of user's chats and channels.

### Breaking Changes
- `TeliAuth` callbacks (`onGetOtp`, `on2faRequired`) have been removed. Use the state machine flow instead.
- Message fetching methods now return `Stream<List<TeliMessage>>` or `Future<List<TeliMessage>>` using facade models instead of raw `t` library types.
- `TeliCredentials` is now an abstract class; use the factory constructor or extend it.

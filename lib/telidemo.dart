/// A high-level library for building Telegram clients with ease.
///
/// The `telidemo` library provides a simplified interface over the MTProto
/// protocol, allowing developers to quickly implement Telegram functionality
/// such as authentication, messaging, and update handling.
///
/// To get started, use the [TeliClient] class.
library;

export 'src/teli_client.dart';
export 'src/teli_auth.dart';
// teli_session.dart is internal-only
export 'src/teli_credentials.dart';
// teli_socket.dart is internal-only



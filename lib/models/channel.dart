import 'package:t/t.dart' as t;

/// Represents a Telegram channel, supergroup, or legacy chat.
class TeliChannel {
  final int id;
  final String title;
  final int? accessHash;

  /// Whether this is a modern MTProto Channel (Broadcast or Supergroup).
  final bool isChannel;

  /// Whether this is a broadcast-only channel.
  final bool isBroadcast;

  /// Whether the user has been kicked or the chat is otherwise inaccessible.
  final bool isForbidden;
  final String? username;
  final int? participantsCount;

  const TeliChannel({
    required this.id,
    required this.title,
    this.accessHash,
    this.isChannel = false,
    this.isBroadcast = false,
    this.isForbidden = false,
    this.username,
    this.participantsCount,
  });

  factory TeliChannel.fromRaw(t.ChatBase raw) {
    return switch (raw) {
      t.Channel c => TeliChannel(
          id: c.id,
          title: c.title,
          accessHash: c.accessHash,
          isChannel: true,
          isBroadcast: c.broadcast,
          username: c.username,
          participantsCount: c.participantsCount,
        ),
      t.Chat c => TeliChannel(
          id: c.id,
          title: c.title,
          isChannel: false,
          isBroadcast: false,
          participantsCount: c.participantsCount,
        ),
      t.ChannelForbidden c => TeliChannel(
          id: c.id,
          title: c.title,
          accessHash: c.accessHash,
          isChannel: true,
          isBroadcast: true,
          isForbidden: true,
        ),
      t.ChatForbidden c => TeliChannel(
          id: c.id,
          title: c.title,
          isChannel: false,
          isBroadcast: false,
          isForbidden: true,
        ),
      t.ChatEmpty c => TeliChannel(
          id: c.id,
          title: 'Empty Chat',
          isForbidden: true,
        ),
      _ => const TeliChannel(id: 0, title: 'Unknown', isForbidden: true),
    };
  }

  @override
  String toString() => 'TeliChannel(id: $id, title: $title, isForbidden: $isForbidden)';
}

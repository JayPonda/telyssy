import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:t/t.dart' as t;
import 'package:tg/tg.dart' as tg;

import 'teli_socket.dart';
import 'teli_credentials.dart';

/// A high-level Telegram client for executing API methods.
///
/// This client requires [TeliCredentials] with valid session data to operate.
/// It provides a simplified interface for common tasks like retrieving
/// messages and channels, while maintaining full transparent access
/// to the raw MTProto schema objects.
final class TeliClient {
  tg.Client? _client;
  TeliSocket? _teliSocket;
  final TeliCredentials credentials;
  final StreamController<dynamic> _updateController =
      StreamController<dynamic>.broadcast();

  /// Creates a new [TeliClient] with the given [credentials].
  TeliClient(this.credentials);

  /// The underlying raw [tg.Client] instance.
  ///
  /// This is `null` until [connect] is called.
  tg.Client? get rawClient => _client;

  /// Establishes a connection to Telegram using the provided credentials.
  Future<void> connect({
    String ip = '91.108.56.130',
    int port = 443,
    int dcId = 5,
  }) async {
    final sessionData = credentials.sessionData;
    if (sessionData == null || sessionData.isEmpty) {
      throw StateError(
        'No session data found in credentials. Call TeliAuth.login() first.',
      );
    }

    credentials.validateApiCredentials();

    final socket = await Socket.connect(ip, port);
    _teliSocket = TeliSocket(socket);
    final obfuscation = tg.Obfuscation.random(false, dcId);
    final idGenerator = tg.MessageIdGenerator();

    await _teliSocket!.send(obfuscation.preamble);

    final authKey = tg.AuthorizationKey.fromJson(
      jsonDecode(sessionData) as Map<String, dynamic>,
    );

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
  }

  /// Listens for updates from the Telegram server.
  void onUpdate(FutureOr<void> Function(dynamic data) callback) {
    _updateController.stream.listen((data) async {
      await callback(data);
    });
  }

  /// Invokes any Telegram method (RPC call) transparently.
  ///
  /// This is the primary method for accessing the full MTProto API.
  /// Returns a strongly-typed [t.Result<T>].
  Future<t.Result<T>> invoke<T extends t.TlObject>(t.TlMethod method) async {
    final client = _client;
    if (client == null) {
      throw StateError('Client not connected. Call connect() first.');
    }
    final response = await client.invoke(method);

    if (response.error != null) {
      return t.Result<T>.error(response.error!);
    }

    return t.Result<T>.ok(response.result as T);
  }

  /// Retrieves a list of all channels and chats the user is subscribed to.
  ///
  /// This is a transparent wrapper for [t.MessagesGetDialogs].
  Future<t.Result<t.MessagesDialogsBase>> getSubscribedChannels({
    bool excludePinned = false,
    int? folderId,
    DateTime? offsetDate,
    int offsetId = 0,
    t.InputPeerBase offsetPeer = const t.InputPeerEmpty(),
    int limit = 100,
    int hash = 0,
  }) async {
    return invoke<t.MessagesDialogsBase>(
      t.MessagesGetDialogs(
        excludePinned: excludePinned,
        folderId: folderId,
        offsetDate: offsetDate ?? DateTime.fromMillisecondsSinceEpoch(0),
        offsetId: offsetId,
        offsetPeer: offsetPeer,
        limit: limit,
        hash: hash,
      ),
    );
  }

  /// Retrieves message history for a specific chat or channel.
  ///
  /// [chatOrPeer] can be either a [t.ChatBase] (for convenience) or a
  /// raw [t.InputPeerBase] identifier.
  ///
  /// This is a transparent wrapper for [t.MessagesGetHistory].
  Future<t.Result<t.MessagesMessagesBase>> getMessages(
    dynamic chatOrPeer, {
    int offsetId = 0,
    DateTime? offsetDate,
    int addOffset = 0,
    int limit = 20,
    int maxId = 0,
    int minId = 0,
    int hash = 0,
  }) async {
    t.InputPeerBase peer;

    if (chatOrPeer is t.InputPeerBase) {
      peer = chatOrPeer;
    } else if (chatOrPeer is t.Channel) {
      if (chatOrPeer.accessHash == null) {
        throw ArgumentError('Channel access hash is missing.');
      }
      peer = t.InputPeerChannel(
        channelId: chatOrPeer.id,
        accessHash: chatOrPeer.accessHash!,
      );
    } else if (chatOrPeer is t.Chat) {
      peer = t.InputPeerChat(chatId: chatOrPeer.id);
    } else if (chatOrPeer is t.User) {
      if (chatOrPeer.accessHash == null) {
        throw ArgumentError('User access hash is missing.');
      }
      peer = t.InputPeerUser(
        userId: chatOrPeer.id,
        accessHash: chatOrPeer.accessHash!,
      );
    } else {
      throw ArgumentError(
        'Unsupported type: ${chatOrPeer.runtimeType}. '
        'Expected ChatBase or InputPeerBase.',
      );
    }

    return invoke<t.MessagesMessagesBase>(
      t.MessagesGetHistory(
        peer: peer,
        offsetId: offsetId,
        offsetDate: offsetDate ?? DateTime.fromMillisecondsSinceEpoch(0),
        addOffset: addOffset,
        limit: limit,
        maxId: maxId,
        minId: minId,
        hash: hash,
      ),
    );
  }

  /// Fetches messages from a channel within a datetime range.
  ///
  /// [channelId] is required.
  /// [accessHash] is recommended (required for private channels).
  /// [startDate] start of range (inclusive). Defaults to 24h before [endDate].
  /// [endDate] end of range (exclusive). Defaults to now.
  ///
  /// Fetches 100 messages per batch (Telegram's max) using standard pagination
  /// via [offsetDate]. Max 1000 messages per call.
  Future<List<t.MessageBase>> getMessagesByTimeRange(
    int channelId, {
    int? accessHash,
    DateTime? startDate,
    DateTime? endDate,
  }) async {
    final end = endDate ?? DateTime.now();
    final start = startDate ?? end.subtract(const Duration(hours: 24));

    final peer = t.InputPeerChannel(
      channelId: channelId,
      accessHash: accessHash ?? 0,
    );

    return _fetchPaginatedMessages(
      peer,
      start: start,
      end: end,
      stopAtId: null,
    );
  }

  /// Fetches messages from a channel backwards from now until [lastMessageId] is reached.
  ///
  /// [channelId] is required.
  /// [accessHash] is recommended (required for private channels).
  /// [lastMessageId] is required. Fetching stops once this message is found.
  ///
  /// Fetches 100 messages per batch (Telegram's max) using standard pagination
  /// via [offsetDate]. Max 1000 messages per call.
  Future<List<t.MessageBase>> getMessagesUntil(
    int channelId, {
    int? accessHash,
    required int lastMessageId,
  }) async {
    final peer = t.InputPeerChannel(
      channelId: channelId,
      accessHash: accessHash ?? 0,
    );

    return _fetchPaginatedMessages(
      peer,
      start: null,
      end: DateTime.now(),
      stopAtId: lastMessageId,
    );
  }

  List<t.MessageBase> _extractMessages(t.MessagesMessagesBase? result) {
    if (result == null) return [];
    if (result is t.MessagesMessages) return result.messages;
    if (result is t.MessagesMessagesSlice) return result.messages;
    if (result is t.MessagesChannelMessages) return result.messages;
    return [];
  }

  Future<List<t.MessageBase>> _fetchPaginatedMessages(
    t.InputPeerChannel peer, {
    DateTime? start,
    required DateTime end,
    int? stopAtId,
  }) async {
    final allMessages = <t.MessageBase>[];
    DateTime? cursorDate = end;
    int? cursorId;

    while (true) {
      if (allMessages.length >= 1000) break;

      final response = await invoke<t.MessagesMessagesBase>(
        t.MessagesGetHistory(
          peer: peer,
          offsetId: cursorId ?? 0,
          offsetDate: cursorDate ?? end,
          addOffset: 0,
          limit: 100,
          maxId: 0,
          minId: 0,
          hash: 0,
        ),
      );

      final batch = _extractMessages(response.result);
      if (batch.isEmpty) break;

      DateTime? oldestDate;
      int? oldestId;
      bool reachedStop = false;
      final filtered = <t.MessageBase>[];

      for (final msg in batch) {
        DateTime msgDate;
        int? msgId;
        if (msg is t.Message) {
          msgDate = msg.date;
          msgId = msg.id;
        } else if (msg is t.MessageService) {
          msgDate = msg.date;
          msgId = msg.id;
        } else {
          continue;
        }

        // Check stop conditions - stop processing if found
        if (stopAtId != null && msgId == stopAtId) {
          reachedStop = true;
          break;
        }

        if (start != null &&
            (msgDate.isBefore(start) || msgDate.isAtSameMomentAs(start))) {
          break;
        }

        // Add message to results
        filtered.add(msg);

        // Track oldest message for pagination cursor
        if (oldestDate == null || msgDate.isBefore(oldestDate)) {
          oldestDate = msgDate;
          oldestId = msgId;
        }
      }

      allMessages.addAll(filtered);

      // Stop pagination if we reached the target
      if (reachedStop) break;
      if (oldestDate == null) break;
      if (start != null &&
          (oldestDate.isBefore(start) || oldestDate.isAtSameMomentAs(start))) {
        break;
      }

      // Update cursor for next batch - move backwards in time
      cursorDate = oldestDate;
      cursorId = oldestId;

      if (batch.length < 100) break;
    }

    return allMessages;
  }

  /// Closes the connection and releases resources.
  Future<void> close() async {
    print('[Client] Shutting down client...');
    await _teliSocket?.close();
    await _updateController.close();
    _client = null;
    _teliSocket = null;
    print('[Client] Client shutdown complete.');
  }
}

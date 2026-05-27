import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:t/t.dart' as t;
import 'package:tg/tg.dart' as tg;

import 'socket.dart';
import '../models/models.dart';

  /// A high-level Telegram client for executing API methods.
class TeliClient {
  tg.Client? _client;
  TeliSocket? _teliSocket;
  StreamSubscription<dynamic>? _streamSubscription;
  final TeliCredentials credentials;
  final StreamController<dynamic> _updateController =
      StreamController<dynamic>.broadcast();

  TeliClient(this.credentials, {tg.Client? client, TeliSocket? teliSocket})
      : _client = client,
        _teliSocket = teliSocket;

  tg.Client? get rawClient => _client;

  /// Connects to Telegram using the stored session.
  ///
  /// Uses a 15s timeout on TCP socket connection.
  Future<void> connect({
    String? ip,
    int? port,
    int? dcId,
  }) async {
    final host = credentials.getHost();
    ip ??= host.ip;
    port ??= host.port;
    dcId ??= host.dcId;

    final sessionData = credentials.sessionData;
    if (sessionData == null || sessionData.isEmpty) {
      throw StateError('No session data found. Call TeliAuth.login() first.');
    }

    credentials.validateApiCredentials();

    if (_teliSocket == null) {
      final socket = await Socket.connect(
        ip,
        port,
        timeout: const Duration(seconds: 15),
      );
      _teliSocket = TeliSocket(socket);
    }
    
    final obfuscation = tg.Obfuscation.random(false, dcId);
    final idGenerator = tg.MessageIdGenerator();

    if (_client == null) {
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

    _streamSubscription ??= _client!.stream.listen((event) {
      if (!_updateController.isClosed) {
        _updateController.add(event);
      }
    });
  }

  void onUpdate(FutureOr<void> Function(dynamic data) callback) {
    _updateController.stream.listen((data) async {
      await callback(data);
    });
  }

  Future<t.TlObject?> invoke(t.TlMethod method) async {
    final client = _client;
    if (client == null) throw StateError('Client not connected.');
    final response = await client.invoke(method);
    if (response.error != null) throw Exception(response.error!.errorMessage);
    return response.result;
  }

  Future<List<TeliChannel>> getSubscribedChannels({
    int limit = 100,
  }) async {
    final result = await invoke(
      t.MessagesGetDialogs(
        excludePinned: false,
        offsetDate: DateTime.fromMillisecondsSinceEpoch(0),
        offsetId: 0,
        offsetPeer: const t.InputPeerEmpty(),
        limit: limit,
        hash: 0,
      ),
    );

    if (result is t.MessagesDialogsBase) {
      final chats = switch (result) {
        t.MessagesDialogs d => d.chats,
        t.MessagesDialogsSlice d => d.chats,
        t.MessagesDialogsNotModified _ => <t.ChatBase>[],
        _ => <t.ChatBase>[],
      };
      return chats.map((c) => TeliChannel.fromRaw(c)).toList();
    }
    return [];
  }

  Future<List<TeliMessage>> getMessages(
    TeliChannel channel, {
    int limit = 20,
    int offsetId = 0,
  }) async {
    final peer = _getPeer(channel);
    final allMessages = <TeliMessage>[];
    int currentOffsetId = offsetId;

    while (allMessages.length < limit) {
      final remaining = limit - allMessages.length;
      final pageLimit = remaining < 100 ? remaining : 100;

      final result = await invoke(
        t.MessagesGetHistory(
          peer: peer,
          offsetId: currentOffsetId,
          offsetDate: DateTime.fromMillisecondsSinceEpoch(0),
          addOffset: 0,
          limit: pageLimit,
          maxId: 0,
          minId: 0,
          hash: 0,
        ),
      );

      if (result is! t.MessagesMessagesBase) break;

      final messages = switch (result) {
        t.MessagesMessages m => m.messages,
        t.MessagesMessagesSlice m => m.messages,
        t.MessagesChannelMessages m => m.messages,
        t.MessagesMessagesNotModified _ => <t.MessageBase>[],
        _ => <t.MessageBase>[],
      };

      if (messages.isEmpty) break;

      final converted = messages.map((m) => TeliMessage.fromRaw(m)).toList();
      allMessages.addAll(converted);

      if (messages.length < pageLimit) break;

      currentOffsetId = converted.last.id;
    }

    return allMessages;
  }

  /// Fetch a single message by its ID from a specific channel and return it
  /// with fresh document references (fileReference, documentId, documentAccessHash).
  ///
  /// Returns `null` if the message is not found or has no media document.
  Future<TeliMessage?> getMessageById(
    int messageId, {
    required int channelId,
    required int accessHash,
  }) async {
    final result = await invoke(
      t.ChannelsGetMessages(
        channel: t.InputChannel(channelId: channelId, accessHash: accessHash),
        id: [t.InputMessageID(id: messageId)],
      ),
    );

    if (result is! t.MessagesMessagesBase) return null;

    final messages = switch (result) {
      t.MessagesMessages m => m.messages,
      t.MessagesMessagesSlice m => m.messages,
      t.MessagesChannelMessages m => m.messages,
      t.MessagesMessagesNotModified _ => <t.MessageBase>[],
      _ => <t.MessageBase>[],
    };

    if (messages.isEmpty) return null;

    for (final msg in messages) {
      if (msg is t.Message) {
        return TeliMessage.fromRaw(msg);
      }
    }
    return null;
  }

  /// Fetch a single message AND look up the channel access hash using
  /// [t.MessagesGetMessages] (no peer needed). This is a fallback for when
  /// the channel access hash is unknown.
  ///
  /// Returns the message and the channel's access hash extracted from the
  /// response's chat list, or `null` if not found.
  Future<({TeliMessage message, int channelAccessHash})?>
      getMessageAndChannelAccessHash(
    int messageId, {
    required int channelId,
  }) async {
    print('[TeliClient] getMessageAndChannelAccessHash: '
        'messageId=$messageId channelId=$channelId');
    final result = await invoke(
      t.MessagesGetMessages(id: [t.InputMessageID(id: messageId)]),
    );
    print('[TeliClient] getMessageAndChannelAccessHash: '
        'result type=${result.runtimeType}');

    if (result is! t.MessagesMessagesBase) {
      print('[TeliClient] getMessageAndChannelAccessHash: '
          'result is not MessagesMessagesBase (got ${result.runtimeType})');
      return null;
    }

    // Extract channel access hash from the chats list
    int? channelAccessHash;
    final chats = switch (result) {
      t.MessagesMessages m => m.chats,
      t.MessagesMessagesSlice m => m.chats,
      t.MessagesChannelMessages m => m.chats,
      _ => <t.ChatBase>[],
    };
    print('[TeliClient] getMessageAndChannelAccessHash: '
        'found ${chats.length} chats in response');
    for (final chat in chats) {
      if (chat is t.Channel) {
        print('[TeliClient]   chat: id=${chat.id} type=${chat.runtimeType} '
            'accessHash=${chat.accessHash}');
        if (chat.id == channelId) {
          channelAccessHash = chat.accessHash;
          print('[TeliClient]   => matched channel, accessHash=$channelAccessHash');
          break;
        }
      } else {
        print('[TeliClient]   chat: type=${chat.runtimeType} (not a Channel)');
      }
    }
    if (channelAccessHash == null) {
      print('[TeliClient] getMessageAndChannelAccessHash: '
          'channel $channelId not found in chats');
      return null;
    }

    // Extract the message
    final messages = switch (result) {
      t.MessagesMessages m => m.messages,
      t.MessagesMessagesSlice m => m.messages,
      t.MessagesChannelMessages m => m.messages,
      t.MessagesMessagesNotModified _ => <t.MessageBase>[],
      _ => <t.MessageBase>[],
    };
    print('[TeliClient] getMessageAndChannelAccessHash: '
        'found ${messages.length} messages');
    if (messages.isEmpty) {
      print('[TeliClient] getMessageAndChannelAccessHash: messages list empty');
      return null;
    }

    for (final msg in messages) {
      if (msg is t.Message) {
        print('[TeliClient]   msg: id=${msg.id} type=${msg.runtimeType}');
      } else {
        print('[TeliClient]   msg: type=${msg.runtimeType} (not a Message)');
      }
      if (msg is t.Message) {
        final teliMsg = TeliMessage.fromRaw(msg);
        print('[TeliClient] getMessageAndChannelAccessHash: '
            'found Message, documentId=${teliMsg.documentId} '
            'fileReference=${teliMsg.fileReference != null}');
        return (message: teliMsg, channelAccessHash: channelAccessHash);
      }
    }
    print('[TeliClient] getMessageAndChannelAccessHash: '
        'no t.Message found in messages');
    return null;
  }

  Stream<List<TeliMessage>> getMessagesStream(
    TeliChannel channel, {
    int limit = 20,
    int offsetId = 0,
  }) async* {
    final peer = _getPeer(channel);
    int currentOffsetId = offsetId;
    int remaining = limit;

    while (remaining > 0) {
      final pageLimit = remaining < 100 ? remaining : 100;

      final result = await invoke(
        t.MessagesGetHistory(
          peer: peer,
          offsetId: currentOffsetId,
          offsetDate: DateTime.fromMillisecondsSinceEpoch(0),
          addOffset: 0,
          limit: pageLimit,
          maxId: 0,
          minId: 0,
          hash: 0,
        ),
      );

      if (result is! t.MessagesMessagesBase) break;

      final messages = switch (result) {
        t.MessagesMessages m => m.messages,
        t.MessagesMessagesSlice m => m.messages,
        t.MessagesChannelMessages m => m.messages,
        t.MessagesMessagesNotModified _ => <t.MessageBase>[],
        _ => <t.MessageBase>[],
      };

      if (messages.isEmpty) break;

      final batch =
          messages.map((m) => TeliMessage.fromRaw(m)).toList();
      yield batch;
      remaining -= batch.length;

      if (messages.length < pageLimit) break;
      currentOffsetId = batch.last.id;
    }
  }

  Stream<List<TeliMessage>> getMessagesByTimeRange(
    TeliChannel channel, {
    DateTime? startDate,
    DateTime? endDate,
  }) async* {
    final end = endDate ?? DateTime.now();
    final start = startDate ?? end.subtract(const Duration(hours: 24));
    final peer = _getPeer(channel);
    yield* _fetchPaginatedMessagesStream(peer, start: start, end: end);
  }

  Stream<List<TeliMessage>> getMessagesUntil(
    TeliChannel channel, {
    required int lastMessageId,
  }) async* {
    final peer = _getPeer(channel);
    yield* _fetchPaginatedMessagesStream(
      peer,
      end: DateTime.now(),
      stopAtId: lastMessageId,
    );
  }

  t.InputPeerBase _getPeer(TeliChannel channel) {
    if (channel.isForbidden) {
      throw Exception('Cannot access a forbidden or deleted chat: ${channel.title}');
    }

    if (channel.isChannel) {
      return t.InputPeerChannel(
        channelId: channel.id,
        accessHash: channel.accessHash ?? 0,
      );
    } else {
      return t.InputPeerChat(chatId: channel.id);
    }
  }

  Stream<List<TeliMessage>> _fetchPaginatedMessagesStream(
    t.InputPeerBase peer, {
    DateTime? start,
    required DateTime end,
    int? stopAtId,
  }) async* {
    DateTime? cursorDate = end;
    int? cursorId;

    while (true) {
      final result = await invoke(
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

      if (result is! t.MessagesMessagesBase) break;

      final batch = switch (result) {
        t.MessagesMessages m => m.messages,
        t.MessagesMessagesSlice m => m.messages,
        t.MessagesChannelMessages m => m.messages,
        t.MessagesMessagesNotModified _ => <t.MessageBase>[],
        _ => <t.MessageBase>[],
      };

      if (batch.isEmpty) break;

      final filtered = <TeliMessage>[];
      DateTime? oldestDate;
      int? oldestId;
      bool reachedStop = false;

      for (final raw in batch) {
        final msg = TeliMessage.fromRaw(raw);

        if (stopAtId != null && msg.id == stopAtId) {
          reachedStop = true;
          break;
        }

        if (start != null &&
            (msg.date.isBefore(start) || msg.date.isAtSameMomentAs(start))) {
          reachedStop = true;
          break;
        }

        filtered.add(msg);
        if (oldestDate == null || msg.date.isBefore(oldestDate)) {
          oldestDate = msg.date;
          oldestId = msg.id;
        }
      }

      if (filtered.isNotEmpty) yield filtered;
      if (reachedStop || batch.length < 100 || oldestDate == null) break;

      cursorDate = oldestDate;
      cursorId = oldestId;
    }
  }

  /// Download a file (document) from Telegram.
  ///
  /// [documentId] and [accessHash] come from [TeliMessage.documentId] /
  /// [TeliMessage.documentAccessHash]. [fileReference] comes from
  /// [TeliMessage.fileReference].
  ///
  /// Downloads in [chunkSize]-byte chunks and yields them as they arrive.
  Stream<Uint8List> downloadFile({
    required int documentId,
    required int accessHash,
    required Uint8List fileReference,
    int offset = 0,
    int chunkSize = 1024 * 1024,
    void Function(int downloadedBytes)? onProgress,
  }) async* {
    final location = t.InputDocumentFileLocation(
      id: documentId,
      accessHash: accessHash,
      fileReference: fileReference,
      thumbSize: '',
    );

    int downloadedBytes = offset;

    while (true) {
      final result = await invoke(t.UploadGetFile(
        precise: false,
        cdnSupported: false,
        location: location,
        offset: downloadedBytes,
        limit: chunkSize,
      ));

      if (result is t.UploadFile) {
        yield result.bytes;
        downloadedBytes += result.bytes.length;
        onProgress?.call(downloadedBytes);
        if (result.bytes.length < chunkSize) break;
      } else if (result is t.UploadFileCdnRedirect) {
        throw UnsupportedError('CDN redirect not implemented');
      } else {
        throw Exception('Unexpected upload response: ${result.runtimeType}');
      }
    }
  }

  /// Get the currently authenticated user.
  Future<TeliUser?> getCurrentUser() async {
    final result = await invoke(
      t.UsersGetUsers(id: [const t.InputUserSelf()]),
    );

    if (result is! t.Vector) return null;
    final users = result.items.cast<t.User>();
    if (users.isEmpty) return null;
    return TeliUser.fromRaw(users.first);
  }

  Future<void> logout() async {
    await invoke(const t.AuthLogOut());
    credentials.sessionData = null;
    await close();
  }

  Future<void> close() async {
    await _streamSubscription?.cancel();
    await _teliSocket?.close();
    await _updateController.close();
    _client = null;
    _teliSocket = null;
    _streamSubscription = null;
  }
}

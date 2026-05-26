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
  /// Downloads in [chunkSize]-byte chunks and returns the complete raw bytes.
  Future<Uint8List> downloadFile({
    required int documentId,
    required int accessHash,
    required Uint8List fileReference,
    int chunkSize = 1024 * 1024,
  }) async {
    final location = t.InputDocumentFileLocation(
      id: documentId,
      accessHash: accessHash,
      fileReference: fileReference,
      thumbSize: '',
    );

    final chunks = <Uint8List>[];

    while (true) {
      final result = await invoke(t.UploadGetFile(
        precise: false,
        cdnSupported: false,
        location: location,
        offset: chunks.fold<int>(0, (s, c) => s + c.length),
        limit: chunkSize,
      ));

      if (result is t.UploadFile) {
        chunks.add(result.bytes);
        if (result.bytes.length < chunkSize) break;
      } else if (result is t.UploadFileCdnRedirect) {
        throw UnsupportedError('CDN redirect not implemented');
      } else {
        throw Exception('Unexpected upload response: ${result.runtimeType}');
      }
    }

    final total = chunks.fold<int>(0, (s, c) => s + c.length);
    final output = Uint8List(total);
    int pos = 0;
    for (final chunk in chunks) {
      output.setRange(pos, pos + chunk.length, chunk);
      pos += chunk.length;
    }
    return output;
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

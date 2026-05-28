import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:t/t.dart' as t;
import 'package:tg/tg.dart' as tg;

import 'socket.dart';
import '../models/models.dart';

/// Known Telegram datacenter IPs and ports.
///
/// See https://core.telegram.org/methods#infrastructure
final _dcOptions = <int, _DcHost>{
  1: _DcHost(ip: '149.154.175.53', port: 443),
  2: _DcHost(ip: '149.154.167.51', port: 443),
  3: _DcHost(ip: '149.154.175.100', port: 443),
  4: _DcHost(ip: '149.154.167.91', port: 443),
  5: _DcHost(ip: '91.108.56.130', port: 443),
};

class _DcHost {
  final String ip;
  final int port;
  const _DcHost({required this.ip, required this.port});
}

  /// A high-level Telegram client for executing API methods.
class TeliClient {
  tg.Client? _client;
  TeliSocket? _teliSocket;
  StreamSubscription<dynamic>? _streamSubscription;
  final TeliCredentials credentials;
  final StreamController<dynamic> _updateController =
      StreamController<dynamic>.broadcast();

  /// Pool of clients connected to non-home DCs, keyed by DC ID.
  /// Used for FILE_MIGRATE_X resolution — files stored on a different
  /// DC must be downloaded from that DC.
  final Map<int, _DcClient> _dcPool = {};

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

  /// Re-fetch a message to obtain a fresh file reference.
  ///
  /// When Telegram returns `FILE_REFERENCE_EXPIRED`, use this method to
  /// get updated `documentId`, `documentAccessHash`, and `fileReference`
  /// fields for a message's media attachment.
  ///
  /// - If [channelAccessHash] is provided, uses `ChannelsGetMessages` directly.
  /// - If not, falls back to `MessagesGetMessages` and extracts the
  ///   access hash from the response's chat list.
  ///
  /// Returns `null` if the message is not found or has no media.
  /// Throws on network errors (caller decides whether to retry).
  Future<TeliMessage?> refreshFileReference(
    int messageId, {
    required int channelId,
    int? channelAccessHash,
  }) async {
    if (channelAccessHash != null) {
      return getMessageById(
        messageId,
        channelId: channelId,
        accessHash: channelAccessHash,
      );
    }

    // Fallback: no access hash — use MessagesGetMessages without peer
    final result = await invoke(
      t.MessagesGetMessages(id: [t.InputMessageID(id: messageId)]),
    );

    if (result is! t.MessagesMessagesBase) return null;

    // Extract the access hash from the chats list
    int? resolvedAccessHash;
    final chats = switch (result) {
      t.MessagesMessages m => m.chats,
      t.MessagesMessagesSlice m => m.chats,
      t.MessagesChannelMessages m => m.chats,
      _ => <t.ChatBase>[],
    };
    for (final chat in chats) {
      if (chat is t.Channel && chat.id == channelId) {
        resolvedAccessHash = chat.accessHash;
        break;
      }
    }
    if (resolvedAccessHash == null) return null;

    // Extract the message
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
        final teliMsg = TeliMessage.fromRaw(msg);
        if (teliMsg.documentId != null && teliMsg.fileReference != null) {
          return teliMsg;
        }
      }
    }
    return null;
  }

  /// Fetch a single message by its ID from a specific channel.
  ///
  /// Returns `null` if the message is not found.
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
  ///
  /// Automatically handles `FILE_MIGRATE_X` errors by connecting to the
  /// correct DC and retrying — callers never see these errors.
  Stream<Uint8List> downloadFile({
    required int documentId,
    required int accessHash,
    required Uint8List fileReference,
    int offset = 0,
    int chunkSize = 1024 * 1024,
    void Function(int downloadedBytes)? onProgress,
  }) {
    return _downloadWithDcMigration(
      location: t.InputDocumentFileLocation(
        id: documentId,
        accessHash: accessHash,
        fileReference: fileReference,
        thumbSize: '',
      ),
      offset: offset,
      chunkSize: chunkSize,
      onProgress: onProgress,
    );
  }

  /// Download a photo from Telegram.
  ///
  /// [photoId] and [accessHash] come from [TeliMessage.documentId] /
  /// [TeliMessage.documentAccessHash] (reused for photos). [fileReference]
  /// comes from [TeliMessage.fileReference].
  ///
  /// Downloads the largest available size in [chunkSize]-byte chunks.
  ///
  /// Automatically handles `FILE_MIGRATE_X` errors by connecting to the
  /// correct DC and retrying — callers never see these errors.
  Stream<Uint8List> downloadPhoto({
    required int photoId,
    required int accessHash,
    required Uint8List fileReference,
    String thumbSize = 'y',
    int offset = 0,
    int chunkSize = 1024 * 1024,
    void Function(int downloadedBytes)? onProgress,
  }) {
    return _downloadWithDcMigration(
      location: t.InputPhotoFileLocation(
        id: photoId,
        accessHash: accessHash,
        fileReference: fileReference,
        thumbSize: thumbSize,
      ),
      offset: offset,
      chunkSize: chunkSize,
      onProgress: onProgress,
    );
  }

  /// High-level download API that writes chunks directly to a file.
  ///
  /// This method owns the [IOSink] lifecycle and handles protocol errors
  /// internally so that callers never need to manage file handles or
  /// retry logic:
  ///
  /// - **FILE_MIGRATE_X**: Connects to the correct DC and restarts.
  /// - **OFFSET_INVALID**: Restarts from offset 0, truncates the file, continues.
  /// - **FILE_REFERENCE_EXPIRED**: Re-fetches the message via
  ///   [refreshFileReference] to obtain a fresh file reference, then retries.
  ///
  /// Returns a progress stream that emits 0.0–1.0, completes on success,
  /// and throws on unrecoverable errors.
  ///
  /// To cancel, call `StreamSubscription.cancel()` on the returned stream.
  /// Partial file data remains on disk.
  ///
  /// To resume, pass [offset] matching the already-downloaded bytes.
  Stream<double> downloadToFile({
    required String filePath,
    required int documentId,
    required int accessHash,
    required Uint8List fileReference,
    required String mediaType,
    String? thumbSize,
    int channelId = 0,
    int? channelAccessHash,
    int messageId = 0,
    int offset = 0,
    int? fileSize,
    int chunkSize = 1024 * 1024,
  }) {
    return _downloadToFileWithRetry(
      filePath: filePath,
      documentId: documentId,
      accessHash: accessHash,
      fileReference: fileReference,
      mediaType: mediaType,
      thumbSize: thumbSize,
      channelId: channelId,
      channelAccessHash: channelAccessHash,
      messageId: messageId,
      offset: offset,
      fileSize: fileSize,
      chunkSize: chunkSize,
      freRetryCount: 0,
    );
  }

  /// Internal retry loop for [downloadToFile].
  ///
  /// Handles FILE_REFERENCE_EXPIRED by refreshing and retrying (up to 2 times),
  /// and OFFSET_INVALID by restarting from offset 0.
  Stream<double> _downloadToFileWithRetry({
    required String filePath,
    required int documentId,
    required int accessHash,
    required Uint8List fileReference,
    required String mediaType,
    required String? thumbSize,
    required int channelId,
    required int? channelAccessHash,
    required int messageId,
    required int offset,
    required int? fileSize,
    required int chunkSize,
    required int freRetryCount,
  }) async* {
    final isPhoto = mediaType == 'photo';
    final location = isPhoto
        ? t.InputPhotoFileLocation(
            id: documentId,
            accessHash: accessHash,
            fileReference: fileReference,
            thumbSize: thumbSize ?? 'y',
          )
        : t.InputDocumentFileLocation(
            id: documentId,
            accessHash: accessHash,
            fileReference: fileReference,
            thumbSize: '',
          );

    final file = File(filePath);
    int downloadedBytes = offset;

    // Open the file for writing — append if resuming, write-only otherwise
    final sink = file.openWrite(
      mode: offset > 0 ? FileMode.append : FileMode.writeOnly,
    );

    try {
      await for (final chunk in _downloadWithDcMigration(
        location: location,
        offset: offset,
        chunkSize: chunkSize,
      )) {
        sink.add(chunk);
        downloadedBytes += chunk.length;
        final progress =
            fileSize != null && fileSize > 0 ? downloadedBytes / fileSize : 0.0;
        yield progress;
      }

      await sink.flush();
      await sink.close();
    } on Object catch (e) {
      // Ensure sink is closed on error so we don't leak file handles
      try {
        await sink.close();
      } catch (_) {}

      final errorStr = e.toString();

      // OFFSET_INVALID — restart from offset 0
      if (errorStr.contains('OFFSET_INVALID') && offset > 0) {
        // Truncate the file and restart
        if (await file.exists()) {
          await file.writeAsBytes([]);
        }
        yield* _downloadToFileWithRetry(
          filePath: filePath,
          documentId: documentId,
          accessHash: accessHash,
          fileReference: fileReference,
          mediaType: mediaType,
          thumbSize: thumbSize,
          channelId: channelId,
          channelAccessHash: channelAccessHash,
          messageId: messageId,
          offset: 0,
          fileSize: fileSize,
          chunkSize: chunkSize,
          freRetryCount: freRetryCount,
        );
        return;
      }

      // FILE_REFERENCE_EXPIRED — refresh and retry (max 2 times)
      if (freRetryCount < 2 &&
          (errorStr.contains('FILE_REFERENCE_EXPIRED') ||
              errorStr.contains('FILE_REFERENCE')) &&
          channelId != 0 &&
          messageId != 0) {
        final freshMessage = await refreshFileReference(
          messageId,
          channelId: channelId,
          channelAccessHash: channelAccessHash,
        );

        if (freshMessage != null &&
            freshMessage.documentId != null &&
            freshMessage.fileReference != null) {
          // Truncate the file for a fresh start
          if (await file.exists()) {
            await file.writeAsBytes([]);
          }
          yield* _downloadToFileWithRetry(
            filePath: filePath,
            documentId: freshMessage.documentId!,
            accessHash: freshMessage.documentAccessHash ?? accessHash,
            fileReference: freshMessage.fileReference!,
            mediaType: mediaType,
            thumbSize: freshMessage.photoThumbSize ?? thumbSize,
            channelId: channelId,
            channelAccessHash: channelAccessHash ?? 0,
            messageId: messageId,
            offset: 0,
            fileSize: fileSize,
            chunkSize: chunkSize,
            freRetryCount: freRetryCount + 1,
          );
          return;
        }
      }

      rethrow;
    }
  }

  /// Core download stream with automatic FILE_MIGRATE_X handling.
  ///
  /// On `FILE_MIGRATE_X`, connects to the target DC and restarts the
  /// download from [offset]. The caller never sees FILE_MIGRATE errors.
  Stream<Uint8List> _downloadWithDcMigration({
    required t.TlObject location,
    required int offset,
    required int chunkSize,
    void Function(int downloadedBytes)? onProgress,
    int migrateRetryCount = 0,
  }) async* {
    int? dcId;
    int downloadedBytes = offset;

    while (true) {
      t.TlObject? result;
      try {
        result = dcId != null
            ? await _invokeOnDc(dcId, t.UploadGetFile(
                precise: false,
                cdnSupported: false,
                location: location as t.InputFileLocationBase,
                offset: downloadedBytes,
                limit: chunkSize,
              ))
            : await invoke(t.UploadGetFile(
                precise: false,
                cdnSupported: false,
                location: location as t.InputFileLocationBase,
                offset: downloadedBytes,
                limit: chunkSize,
              ));
      } on Object catch (e) {
        final migrateDc = _parseFileMigrateDc(e.toString());
        if (migrateDc != null && migrateRetryCount < 2) {
          await connectToDc(migrateDc);
          dcId = migrateDc;
          migrateRetryCount++;
          continue; // Retry the chunk on the correct DC
        }
        rethrow;
      }

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

  /// Invoke, catching AUTH_KEY expiry and stale connections on DC clients
  /// and auto-reconnecting.
  ///
  /// Handles two failure modes:
  /// - **AUTH_KEY_***: The DC session key has expired — evict, reconnect, retry.
  /// - **TimeoutException**: The DC socket is dead/stale (no response within
  ///   30 s) — evict, reconnect, retry.
  Future<t.TlObject?> _invokeOnDc(int dcId, t.TlMethod method) async {
    try {
      return await _invokeOnDcRaw(dcId, method);
    } on TimeoutException {
      // DC socket is dead/stale — evict and reconnect
      final old = _dcPool.remove(dcId);
      await old?.dispose();
      await credentials.removeDcSession(dcId);

      await connectToDc(dcId);
      return await _invokeOnDcRaw(dcId, method);
    } catch (e) {
      final errorStr = e.toString();
      if (errorStr.contains('AUTH_KEY_UNREGISTERED') ||
          errorStr.contains('AUTH_KEY_INVALID')) {
        final old = _dcPool.remove(dcId);
        await old?.dispose();
        await credentials.removeDcSession(dcId);

        await connectToDc(dcId);
        return await _invokeOnDcRaw(dcId, method);
      }
      rethrow;
    }
  }

  /// Raw invoke on a DC client without auto-reconnect logic.
  ///
  /// Applies a 30-second timeout — if the DC socket is dead/stale, the
  /// invoke will never complete (a dead TCP socket produces no error), so
  /// we must bail out explicitly so the caller can evict and reconnect.
  Future<t.TlObject?> _invokeOnDcRaw(int dcId, t.TlMethod method) async {
    final dcEntry = _dcPool[dcId];
    if (dcEntry == null || dcEntry.client == null) {
      throw StateError(
          'DC $dcId client not connected. Call connectToDc($dcId) first.');
    }
    final response = await dcEntry.client!.invoke(method).timeout(
      const Duration(seconds: 30),
      onTimeout: () => throw TimeoutException(
        'DC $dcId invoke timed out after 30s — likely stale connection',
      ),
    );
    if (response.error != null) {
      throw Exception(response.error!.errorMessage);
    }
    return response.result;
  }

  /// Ensures a client connected to [dcId] exists in the pool.
  ///
  /// **Restore-first strategy:**
  /// 1. If already in pool → return immediately.
  /// 2. If persisted DC session exists for this DC → try restoring the
  ///    `AuthorizationKey` from JSON, connect a socket, and call
  ///    `initConnection` with `HelpGetConfig`. On `AUTH_KEY_UNREGISTERED`,
  ///    fall through to fresh export+import.
  /// 3. Fresh export+import → `auth.exportAuthorization` on home DC →
  ///    DH key exchange on target DC → `initConnection` wrapping
  ///    `auth.importAuthorization`.
  ///
  /// After a successful connection (via either path), the `AuthorizationKey`
  /// is saved via `credentials.saveDcSession` for reuse on next app launch.
  Future<void> connectToDc(int dcId) async {
    if (_dcPool.containsKey(dcId) && _dcPool[dcId]!.client != null) {
      return; // Already connected
    }

    final dcHost = _dcOptions[dcId];
    if (dcHost == null) {
      throw StateError('Unknown DC ID: $dcId');
    }

    // ── Try restore from stored DC session ──
    final storedKeyJson = await credentials.loadDcSession(dcId);
    if (storedKeyJson != null) {
      try {
        final restored = await _connectDcWithStoredKey(dcId, dcHost, storedKeyJson);
        _dcPool[dcId] = restored;
        return; // Restored successfully
      } catch (e) {
        // Stored key is expired/invalid — fall through to fresh export+import
        await credentials.removeDcSession(dcId);
      }
    }

    // ── Fresh export + import ──
    final dcEntry = await _connectDcWithExportImport(dcId, dcHost);
    _dcPool[dcId] = dcEntry;
  }

  /// Restore a DC client using a previously saved `AuthorizationKey`.
  ///
  /// Connects a socket, restores the key, and calls `initConnection`.
  /// Throws if the key is expired (e.g. `AUTH_KEY_UNREGISTERED`).
  Future<_DcClient> _connectDcWithStoredKey(
    int dcId,
    _DcHost dcHost,
    String storedKeyJson,
  ) async {
    final socket = await Socket.connect(
      dcHost.ip,
      dcHost.port,
      timeout: const Duration(seconds: 15),
    );
    final teliSocket = TeliSocket(socket);
    final obfuscation = tg.Obfuscation.random(false, dcId);
    final idGenerator = tg.MessageIdGenerator();
    await teliSocket.send(obfuscation.preamble);

    final authKey = tg.AuthorizationKey.fromJson(
      jsonDecode(storedKeyJson) as Map<String, dynamic>,
    );

    final dcClient = tg.Client(
      socket: teliSocket,
      obfuscation: obfuscation,
      authorizationKey: authKey,
      idGenerator: idGenerator,
    );

    await dcClient
        .initConnection<t.Config>(
          apiId: credentials.apiId,
          deviceModel: 'Desktop',
          systemVersion: 'Unknown',
          appVersion: '1.0.0',
          systemLangCode: 'en',
          langPack: '',
          langCode: 'en',
          query: const t.HelpGetConfig(),
        )
        .timeout(const Duration(seconds: 20));

    return _DcClient(client: dcClient, socket: teliSocket, authKey: authKey);
  }

  /// Connect a DC client via export+import authorization transfer.
  ///
  /// This is the full flow: export auth from home DC → DH key exchange on
  /// target DC → initConnection wrapping `auth.importAuthorization`.
  Future<_DcClient> _connectDcWithExportImport(
    int dcId,
    _DcHost dcHost,
  ) async {
    // 1. Export authorization from home DC
    final exportResult = await invoke(
      t.AuthExportAuthorization(dcId: dcId),
    );
    if (exportResult is! t.AuthExportedAuthorization) {
      throw Exception(
        'Failed to export authorization for DC $dcId: '
        '${exportResult.runtimeType}',
      );
    }
    final exported = exportResult as t.AuthExportedAuthorization;

    // 2. Connect socket + DH key exchange on target DC
    final socket = await Socket.connect(
      dcHost.ip,
      dcHost.port,
      timeout: const Duration(seconds: 15),
    );
    final teliSocket = TeliSocket(socket);
    final obfuscation = tg.Obfuscation.random(false, dcId);
    final idGenerator = tg.MessageIdGenerator();
    await teliSocket.send(obfuscation.preamble);

    final authKey = await tg.Client.authorize(
      teliSocket,
      obfuscation,
      idGenerator,
    ).timeout(const Duration(seconds: 30));

    final dcClient = tg.Client(
      socket: teliSocket,
      obfuscation: obfuscation,
      authorizationKey: authKey,
      idGenerator: idGenerator,
    );

    // 3. Init + import authorization
    await dcClient
        .initConnection<t.AuthAuthorizationBase>(
          apiId: credentials.apiId,
          deviceModel: 'Desktop',
          systemVersion: 'Unknown',
          appVersion: '1.0.0',
          systemLangCode: 'en',
          langPack: '',
          langCode: 'en',
          query: t.AuthImportAuthorization(
            id: exported.id,
            bytes: exported.bytes,
          ),
        )
        .timeout(const Duration(seconds: 20));

    // 4. Persist the auth key for future reuse
    await credentials.saveDcSession(dcId, jsonEncode(authKey.toJson()));

    return _DcClient(client: dcClient, socket: teliSocket, authKey: authKey);
  }

  /// Parse a `FILE_MIGRATE_X` error to extract the DC number.
  ///
  /// Returns the DC ID, or `null` if the error string doesn't match.
  static int? _parseFileMigrateDc(String error) {
    final match = RegExp(r'FILE_MIGRATE_(\d+)').firstMatch(error);
    return match != null ? int.tryParse(match.group(1)!) : null;
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
    await credentials.clearDcSessions();
    await close();
  }

  Future<void> close() async {
    await _streamSubscription?.cancel();
    await _teliSocket?.close();
    await _updateController.close();
    // Close all DC pool connections
    for (final dc in _dcPool.values) {
      await dc.dispose();
    }
    _dcPool.clear();
    _client = null;
    _teliSocket = null;
    _streamSubscription = null;
  }
}

/// Holds a [tg.Client] and its [TeliSocket] for a non-home DC connection.
class _DcClient {
  final tg.Client? client;
  final TeliSocket? socket;
  final tg.AuthorizationKey? authKey;

  _DcClient({this.client, this.socket, this.authKey});

  Future<void> dispose() async {
    try {
      await socket?.close();
    } catch (_) {}
  }
}

import 'dart:convert';
import 'dart:typed_data';
import 'package:t/t.dart' as t;

/// Media type extracted from a Telegram message's [t.MessageMediaBase].
enum TeliMediaType {
  text,
  photo,
  video,
  audio,
  voice,
  document,
  sticker,
  poll,
  webPage,
  geo,
  contact,
  game,
  invoice,
  story,
  unsupported,
  service;

  /// Parse a media type string (e.g. from DB) into a [TeliMediaType].
  ///
  /// Returns [TeliMediaType.text] for null or unrecognized values,
  /// matching the convention used throughout the app.
  static TeliMediaType fromString(String? name) {
    if (name == null) return TeliMediaType.text;
    return TeliMediaType.values.firstWhere(
      (e) => e.name == name,
      orElse: () => TeliMediaType.text,
    );
  }
}

/// Represents a message in Telegram.
class TeliMessage {
  final int id;
  final DateTime date;
  final String? text;
  final int? senderId;
  final bool isService;
  final TeliMediaType mediaType;
  final int? views;
  final int? forwards;
  final DateTime? editDate;
  final bool isPost;
  final int? documentId;
  final int? documentAccessHash;
  final Uint8List? fileReference;
  final String? documentMimeType;
  final int? documentSize;
  final String? audioTitle;
  final String? audioPerformer;
  final int? audioDuration;
  final int? groupedId;
  final String? photoThumbSize;

  const TeliMessage({
    required this.id,
    required this.date,
    this.text,
    this.senderId,
    this.isService = false,
    this.mediaType = TeliMediaType.text,
    this.views,
    this.forwards,
    this.editDate,
    this.isPost = false,
    this.documentId,
    this.documentAccessHash,
    this.fileReference,
    this.documentMimeType,
    this.documentSize,
    this.audioTitle,
    this.audioPerformer,
    this.audioDuration,
    this.groupedId,
    this.photoThumbSize,
  });

  factory TeliMessage.fromRaw(t.MessageBase raw) {
    return switch (raw) {
      t.Message m => TeliMessage._withDocument(m),
      t.MessageService ms => TeliMessage(
          id: ms.id,
          date: ms.date,
          isService: true,
          mediaType: TeliMediaType.service,
        ),
      t.MessageEmpty _ => TeliMessage(
          id: 0,
          date: DateTime.now(),
          mediaType: TeliMediaType.unsupported,
        ),
      _ => throw ArgumentError('Unsupported message type: ${raw.runtimeType}'),
    };
  }

  factory TeliMessage._withDocument(t.Message m) {
    final mediaType = _extractMediaType(m.media);
    int? docId;
    int? docAccessHash;
    Uint8List? docFileRef;
    String? docMimeType;
    int? docSize;
    String? audioTitle;
    String? audioPerformer;
    int? audioDuration;
    String? photoThumbSize;

    if (m.media is t.MessageMediaPhoto) {
      // Extract photo access fields — these are needed to construct
      // an InputPhotoFileLocation for downloading.
      final photo = (m.media as t.MessageMediaPhoto).photo;
      if (photo is t.Photo) {
        docId = photo.id;
        docAccessHash = photo.accessHash;
        docFileRef = photo.fileReference;
        docMimeType = 'image/jpeg'; // Telegram always stores photos as JPEG
        // Find the largest PhotoSize and its type string (required for
        // InputPhotoFileLocation.thumbSize — empty string is invalid).
        int maxSize = 0;
        String? largestType;
        for (final size in photo.sizes) {
          if (size is t.PhotoSize && size.size > maxSize) {
            maxSize = size.size;
            largestType = size.type;
          } else if (size is t.PhotoSizeProgressive &&
              size.sizes.isNotEmpty &&
              size.sizes.last > maxSize) {
            maxSize = size.sizes.last;
            largestType = size.type;
          }
        }
        docSize = maxSize > 0 ? maxSize : null;
        // Fall back to 'y' (largest standard size) if no type found
        photoThumbSize = largestType ?? 'y';
      }
    } else if (m.media is t.MessageMediaDocument) {
      final doc = (m.media as t.MessageMediaDocument).document;
      if (doc is t.Document) {
        docId = doc.id;
        docAccessHash = doc.accessHash;
        docFileRef = doc.fileReference;
        docMimeType = doc.mimeType;
        docSize = doc.size;
        for (final attr in doc.attributes) {
          if (attr is t.DocumentAttributeAudio) {
            audioTitle = attr.title;
            audioPerformer = attr.performer;
            audioDuration = attr.duration;
          }
        }
      }
    }

    return TeliMessage(
      id: m.id,
      date: m.date,
      text: m.message,
      senderId: m.fromId is t.PeerUser ? (m.fromId as t.PeerUser).userId : null,
      isService: false,
      mediaType: mediaType,
      views: m.views,
      forwards: m.forwards,
      editDate: m.editDate,
      isPost: m.post,
      documentId: docId,
      documentAccessHash: docAccessHash,
      fileReference: docFileRef,
      documentMimeType: docMimeType,
      documentSize: docSize,
      audioTitle: audioTitle,
      audioPerformer: audioPerformer,
      audioDuration: audioDuration,
      groupedId: m.groupedId,
      photoThumbSize: photoThumbSize,
    );
  }

  static TeliMediaType _extractMediaType(t.MessageMediaBase? media) {
    if (media == null) return TeliMediaType.text;
    return switch (media) {
      t.MessageMediaEmpty _ => TeliMediaType.text,
      t.MessageMediaPhoto _ => TeliMediaType.photo,
      t.MessageMediaDocument doc => _documentSubtype(doc),
      t.MessageMediaWebPage _ => TeliMediaType.webPage,
      t.MessageMediaGeo _ => TeliMediaType.geo,
      t.MessageMediaContact _ => TeliMediaType.contact,
      t.MessageMediaGame _ => TeliMediaType.game,
      t.MessageMediaInvoice _ => TeliMediaType.invoice,
      t.MessageMediaPoll _ => TeliMediaType.poll,
      t.MessageMediaVenue _ => TeliMediaType.geo,
      t.MessageMediaStory _ => TeliMediaType.story,
      t.MessageMediaDice _ => TeliMediaType.game,
      t.MessageMediaUnsupported _ => TeliMediaType.unsupported,
      _ => TeliMediaType.text,
    };
  }

  static TeliMediaType _documentSubtype(t.MessageMediaDocument doc) {
    if (doc.voice) return TeliMediaType.voice;
    if (doc.video) return TeliMediaType.video;

    final rawDoc = doc.document;
    if (rawDoc is t.Document) {
      for (final attr in rawDoc.attributes) {
        if (attr is t.DocumentAttributeSticker) return TeliMediaType.sticker;
        if (attr is t.DocumentAttributeAudio) {
          return attr.voice ? TeliMediaType.voice : TeliMediaType.audio;
        }
        if (attr is t.DocumentAttributeVideo) return TeliMediaType.video;
        if (attr is t.DocumentAttributeAnimated) return TeliMediaType.video;
      }
    }

    return TeliMediaType.document;
  }

  /// Serialize this message to a JSON map suitable for isolate transfer.
  ///
  /// [Uint8List.fileReference] is encoded as base64.
  /// [DateTime] fields are stored as epoch seconds.
  /// [TeliMediaType] is stored by name.
  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'date': date.millisecondsSinceEpoch ~/ 1000,
      'text': text,
      'senderId': senderId,
      'isService': isService,
      'mediaType': mediaType.name,
      'views': views,
      'forwards': forwards,
      'editDate': editDate?.millisecondsSinceEpoch,
      'isPost': isPost,
      'documentId': documentId,
      'documentAccessHash': documentAccessHash,
      'fileReference': fileReference != null ? base64Encode(fileReference!) : null,
      'documentMimeType': documentMimeType,
      'documentSize': documentSize,
      'audioTitle': audioTitle,
      'audioPerformer': audioPerformer,
      'audioDuration': audioDuration,
      'groupedId': groupedId,
      'photoThumbSize': photoThumbSize,
    };
  }

  /// Deserialize a message from a JSON map.
  ///
  /// This is the inverse of [toJson]. Unknown keys are silently ignored
  /// so that new fields added to [toJson] don't crash older consumers.
  static TeliMessage fromJson(Map<String, dynamic> json) {
    return TeliMessage(
      id: json['id'] as int,
      date: DateTime.fromMillisecondsSinceEpoch((json['date'] as int) * 1000),
      text: json['text'] as String?,
      senderId: json['senderId'] as int?,
      isService: json['isService'] as bool? ?? false,
      mediaType: TeliMediaType.fromString(json['mediaType'] as String?),
      views: json['views'] as int?,
      forwards: json['forwards'] as int?,
      editDate: json['editDate'] != null
          ? DateTime.fromMillisecondsSinceEpoch(json['editDate'] as int)
          : null,
      isPost: json['isPost'] as bool? ?? false,
      documentId: json['documentId'] as int?,
      documentAccessHash: json['documentAccessHash'] as int?,
      fileReference: json['fileReference'] != null
          ? base64Decode(json['fileReference'] as String)
          : null,
      documentMimeType: json['documentMimeType'] as String?,
      documentSize: json['documentSize'] as int?,
      audioTitle: json['audioTitle'] as String?,
      audioPerformer: json['audioPerformer'] as String?,
      audioDuration: json['audioDuration'] as int?,
      groupedId: json['groupedId'] as int?,
      photoThumbSize: json['photoThumbSize'] as String?,
    );
  }

  @override
  String toString() => 'TeliMessage(id: $id, date: $date, text: $text, mediaType: $mediaType)';
}

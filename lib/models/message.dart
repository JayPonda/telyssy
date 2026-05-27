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
  service,
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

    if (m.media is t.MessageMediaDocument) {
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

  @override
  String toString() => 'TeliMessage(id: $id, date: $date, text: $text, mediaType: $mediaType)';
}

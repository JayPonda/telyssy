import 'dart:typed_data';
import 'package:test/test.dart';
import 'package:telissy/models/models.dart';
import 'package:t/t.dart' as t;

void main() {
  group('TeliAuthState', () {
    test('TeliAuthSuccess works', () {
      final creds = TeliCredentials(apiId: 1, apiHash: 'abc');
      final state = TeliAuthSuccess(creds, rawData: 'some raw data');
      expect(state.credentials, equals(creds));
      expect(state.rawData, equals('some raw data'));
    });

    test('TeliAuthError works', () {
      const state = TeliAuthError('error');
      expect(state.message, equals('error'));
    });

    test('TeliAuthWaitOtp works', () {
      const state = TeliAuthWaitOtp();
      expect(state, isA<TeliAuthWaitOtp>());
    });

    test('TeliAuthWaitPassword works', () {
      const state = TeliAuthWaitPassword('hint');
      expect(state.hint, equals('hint'));
    });
  });

  group('TeliUser', () {
    test('fromRaw handles t.User', () {
      final raw = t.User(
        id: 123,
        self: false,
        contact: false,
        mutualContact: false,
        deleted: false,
        bot: false,
        botChatHistory: false,
        botNochats: false,
        verified: false,
        restricted: false,
        min: false,
        botInlineGeo: false,
        support: false,
        scam: false,
        applyMinPhoto: false,
        fake: false,
        botAttachMenu: false,
        premium: false,
        attachMenuEnabled: false,
        botCanEdit: false,
        closeFriend: false,
        storiesHidden: false,
        storiesUnavailable: false,
        contactRequirePremium: false,
        botBusiness: false,
        botHasMainApp: false,
        botForumView: false,
        botForumCanManageTopics: false,
        botCanManageBots: false,
        botGuestchat: false,
        firstName: 'John',
      );
      final user = TeliUser.fromRaw(raw);
      expect(user.id, equals(123));
      expect(user.firstName, equals('John'));
    });

    test('toString works', () {
      const user = TeliUser(id: 123, username: 'test');
      expect(user.toString(), contains('id: 123'));
      expect(user.toString(), contains('username: test'));
    });
  });

  group('TeliChannel', () {
    test('fromRaw handles t.Channel', () {
      final raw = t.Channel(
        id: 1,
        title: 'Channel',
        accessHash: 123,
        photo: const t.ChatPhotoEmpty(),
        date: DateTime.now(),
        creator: true,
        left: false,
        broadcast: true,
        verified: false,
        megagroup: false,
        restricted: false,
        signatures: false,
        min: false,
        scam: false,
        hasLink: false,
        hasGeo: false,
        slowmodeEnabled: false,
        callActive: false,
        callNotEmpty: false,
        fake: false,
        gigagroup: false,
        noforwards: false,
        joinToSend: false,
        joinRequest: false,
        forum: false,
        storiesHidden: false,
        storiesHiddenMin: false,
        storiesUnavailable: false,
        signatureProfiles: false,
        broadcastMessagesAllowed: false,
        forumTabs: false,
        autotranslation: false,
        monoforum: false,
      );
      final channel = TeliChannel.fromRaw(raw);
      expect(channel.id, equals(1));
      expect(channel.isChannel, isTrue);
      expect(channel.isBroadcast, isTrue);
    });

    test('fromRaw handles t.ChannelForbidden', () {
      final raw = const t.ChannelForbidden(
        id: 1,
        accessHash: 123,
        title: 'Forbidden',
        broadcast: true,
        megagroup: false,
        monoforum: false,
      );
      final channel = TeliChannel.fromRaw(raw);
      expect(channel.isForbidden, isTrue);
    });

    test('fromRaw handles t.ChatForbidden', () {
      final raw = const t.ChatForbidden(id: 456, title: 'Forbidden');
      final channel = TeliChannel.fromRaw(raw);
      expect(channel.id, equals(456));
      expect(channel.isForbidden, isTrue);
    });
  });

  group('TeliMessage', () {
    test('fromRaw handles t.Message', () {
      final raw = t.Message(
        out: false,
        mentioned: false,
        mediaUnread: false,
        silent: false,
        post: false,
        fromScheduled: false,
        legacy: false,
        editHide: false,
        pinned: false,
        noforwards: false,
        invertMedia: false,
        offline: false,
        videoProcessingPending: false,
        paidSuggestedPostStars: false,
        paidSuggestedPostTon: false,
        id: 1,
        date: DateTime.now(),
        message: 'Hello',
        peerId: const t.PeerChat(chatId: 1),
      );
      final msg = TeliMessage.fromRaw(raw);
      expect(msg.id, equals(1));
      expect(msg.text, equals('Hello'));
      expect(msg.isService, isFalse);
    });

    test('fromRaw handles t.MessageService', () {
      final raw = t.MessageService(
        out: false,
        mentioned: false,
        mediaUnread: false,
        reactionsArePossible: false,
        silent: false,
        post: false,
        legacy: false,
        id: 789,
        peerId: t.PeerUser(userId: 123),
        date: DateTime.fromMillisecondsSinceEpoch(1600000000 * 1000),
        action: t.MessageActionChatCreate(title: 'Title', users: []),
      );
      final msg = TeliMessage.fromRaw(raw);
      expect(msg.id, equals(789));
      expect(msg.isService, isTrue);
    });

    test('toJson and fromJson roundtrip correctly', () {
      final now = DateTime.now();
      final fileRef = Uint8List.fromList([1, 2, 3, 4]);

      final original = TeliMessage(
        id: 123,
        date: now,
        text: 'Test message',
        senderId: 456,
        isService: false,
        mediaType: TeliMediaType.photo,
        views: 100,
        forwards: 50,
        editDate: now.add(Duration(hours: 1)),
        isPost: true,
        documentId: 789,
        documentAccessHash: 987,
        fileReference: fileRef,
        documentMimeType: 'image/jpeg',
        documentSize: 1024,
        audioTitle: 'Song Title',
        audioPerformer: 'Artist Name',
        audioDuration: 180,
        groupedId: 321,
        photoThumbSize: 'y',
      );

      // Convert to JSON and back
      final json = original.toJson();
      final restored = TeliMessage.fromJson(json);

      // Verify all fields match
      expect(restored.id, equals(original.id));
      expect(restored.date.millisecondsSinceEpoch ~/ 1000,
             equals(original.date.millisecondsSinceEpoch ~/ 1000)); // Compare as seconds
      expect(restored.text, equals(original.text));
      expect(restored.senderId, equals(original.senderId));
      expect(restored.isService, equals(original.isService));
      expect(restored.mediaType, equals(original.mediaType));
      expect(restored.views, equals(original.views));
      expect(restored.forwards, equals(original.forwards));
      expect(restored.editDate != null ? restored.editDate!.millisecondsSinceEpoch ~/ 1000 : null,
             equals(original.editDate != null ? original.editDate!.millisecondsSinceEpoch ~/ 1000 : null)); // Compare as seconds
      expect(restored.isPost, equals(original.isPost));
      expect(restored.documentId, equals(original.documentId));
      expect(restored.documentAccessHash, equals(original.documentAccessHash));
      expect(restored.fileReference, equals(original.fileReference));
      expect(restored.documentMimeType, equals(original.documentMimeType));
      expect(restored.documentSize, equals(original.documentSize));
      expect(restored.audioTitle, equals(original.audioTitle));
      expect(restored.audioPerformer, equals(original.audioPerformer));
      expect(restored.audioDuration, equals(original.audioDuration));
      expect(restored.groupedId, equals(original.groupedId));
      expect(restored.photoThumbSize, equals(original.photoThumbSize));
    });

    test('toJson and fromJson handle null values correctly', () {
      final now = DateTime.now();

      final original = TeliMessage(
        id: 123,
        date: now,
        // All other fields are null by default
      );

      // Convert to JSON and back
      final json = original.toJson();
      final restored = TeliMessage.fromJson(json);

      // Verify all fields match
      expect(restored.id, equals(original.id));
      expect(restored.date.millisecondsSinceEpoch ~/ 1000,
             equals(original.date.millisecondsSinceEpoch ~/ 1000)); // Compare as seconds
      expect(restored.text, isNull);
      expect(restored.senderId, isNull);
      expect(restored.isService, equals(original.isService));
      expect(restored.mediaType, equals(original.mediaType));
      expect(restored.views, isNull);
      expect(restored.forwards, isNull);
      expect(restored.editDate, isNull);
      expect(restored.isPost, equals(original.isPost));
      expect(restored.documentId, isNull);
      expect(restored.documentAccessHash, isNull);
      expect(restored.fileReference, isNull);
      expect(restored.documentMimeType, isNull);
      expect(restored.documentSize, isNull);
      expect(restored.audioTitle, isNull);
      expect(restored.audioPerformer, isNull);
      expect(restored.audioDuration, isNull);
      expect(restored.groupedId, isNull);
      expect(restored.photoThumbSize, isNull);
    });

    test('fromJson ignores unknown keys', () {
      final json = <String, dynamic>{
        'id': 123,
        'date': DateTime.now().millisecondsSinceEpoch ~/ 1000,
        'text': 'Test message',
        'unknown_field': 'should_be_ignored',
        'another_unknown': 42,
      };

      // Should not throw an exception
      final restored = TeliMessage.fromJson(json);

      expect(restored.id, equals(123));
      expect(restored.text, equals('Test message'));
    });
  });

  group('TeliChannel toJson/fromJson', () {
    test('toJson and fromJson roundtrip correctly', () {
      final original = TeliChannel(
        id: 123,
        title: 'Test Channel',
        accessHash: 456,
        isChannel: true,
        isBroadcast: true,
        isForbidden: false,
        username: 'test_channel',
        participantsCount: 1000,
      );

      // Convert to JSON and back
      final json = original.toJson();
      final restored = TeliChannel.fromJson(json);

      // Verify all fields match
      expect(restored.id, equals(original.id));
      expect(restored.title, equals(original.title));
      expect(restored.accessHash, equals(original.accessHash));
      expect(restored.isChannel, equals(original.isChannel));
      expect(restored.isBroadcast, equals(original.isBroadcast));
      expect(restored.isForbidden, equals(original.isForbidden));
      expect(restored.username, equals(original.username));
      expect(restored.participantsCount, equals(original.participantsCount));
    });

    test('toJson and fromJson handle null values correctly', () {
      final original = TeliChannel(
        id: 123,
        title: 'Test Channel',
        // All other fields are null by default
      );

      // Convert to JSON and back
      final json = original.toJson();
      final restored = TeliChannel.fromJson(json);

      // Verify all fields match
      expect(restored.id, equals(original.id));
      expect(restored.title, equals(original.title));
      expect(restored.accessHash, isNull);
      expect(restored.isChannel, equals(original.isChannel));
      expect(restored.isBroadcast, equals(original.isBroadcast));
      expect(restored.isForbidden, equals(original.isForbidden));
      expect(restored.username, isNull);
      expect(restored.participantsCount, isNull);
    });

    test('fromJson ignores unknown keys', () {
      final json = <String, dynamic>{
        'id': 123,
        'title': 'Test Channel',
        'unknown_field': 'should_be_ignored',
        'another_unknown': 42,
      };

      // Should not throw an exception
      final restored = TeliChannel.fromJson(json);

      expect(restored.id, equals(123));
      expect(restored.title, equals('Test Channel'));
    });
  });
}

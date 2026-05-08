import 'package:telidemo/telidemo.dart';
import 'package:test/test.dart';
import 'package:t/t.dart' as t;

void main() {
  group('Teli Architecture', () {
    late TeliCredentials credentials;

    setUp(() {
      credentials = TeliCredentials(
        apiId: 1234567,
        apiHash: '0123456789abcdef0123456789abcdef',
        sessionData: '{"key": [1, 2, 3]}',
      );
    });

    test('TeliClient can be instantiated with credentials', () {
      final client = TeliClient(credentials);
      expect(client.credentials, credentials);
      expect(client.rawClient, isNull);
    });

    group('TeliCredentials', () {
      test('validateApiCredentials accepts valid API ID and Hash', () {
        expect(() => credentials.validateApiCredentials(), returnsNormally);
      });

      test(
        'validateApiCredentials throws ArgumentError for invalid API ID',
        () {
          final invalid = TeliCredentials(
            apiId: 123,
            apiHash: '0123456789abcdef0123456789abcdef',
          );
          expect(
            () => invalid.validateApiCredentials(),
            throwsArgumentError,
          );
        },
      );

      test('validatePhoneNumber accepts valid phone number components', () {
        credentials.countryCode = '91';
        credentials.phoneNumber = '9876543210';
        expect(() => credentials.validatePhoneNumber(), returnsNormally);
        expect(credentials.fullPhoneNumber, '+919876543210');
      });
    });

    group('Client State', () {
      test('invoke throws StateError if not connected', () {
        final client = TeliClient(credentials);
        expect(() => client.invoke(const t.HelpGetConfig()), throwsStateError);
      });
    });
  });
}

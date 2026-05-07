import 'package:telidemo/telidemo.dart';
import 'package:test/test.dart';
import 'package:t/t.dart' as t;

void main() {
  group('TeliDemoClient', () {
    late TeliDemoClient client;
    late TeliDemoCredentials credentials;

    setUp(() {
      credentials = TeliDemoCredentials(apiId: 12345, apiHash: 'abcde');
      client = TeliDemoClient(credentials);
    });

    test('can be instantiated', () {
      expect(client, isNotNull);
      expect(client.credentials.apiId, 12345);
      expect(client.credentials.apiHash, 'abcde');
    });

    test('credentials can be updated via setters', () {
      client.credentials.apiId = 67890;
      expect(client.credentials.apiId, 67890);
    });

    test('phoneNumber can be set and retrieved', () {
      client.credentials.phoneNumber = '+987654321';
      expect(client.credentials.phoneNumber, '+987654321');
    });

    test('rawClient is null before init', () {
      expect(client.rawClient, isNull);
    });

    group('Validation', () {
      test('validateApiCredentials accepts valid API ID and Hash', () {
        credentials.apiId = 1234567;
        credentials.apiHash = 'a' * 32;
        expect(() => client.validateApiCredentials(), returnsNormally);
      });

      test('validateApiCredentials throws ArgumentError for invalid API ID', () {
        credentials.apiId = 123;
        expect(() => client.validateApiCredentials(), throwsArgumentError);
      });

      test('validateApiCredentials throws ArgumentError for invalid API Hash', () {
        credentials.apiId = 1234567;
        credentials.apiHash = 'short';
        expect(() => client.validateApiCredentials(), throwsArgumentError);
      });

      test('validatePhoneNumber accepts valid phone number', () {
        credentials.phoneNumber = '+919876543210';
        expect(() => client.validatePhoneNumber(), returnsNormally);
      });

      test('validatePhoneNumber throws ArgumentError for invalid phone number', () {
        credentials.phoneNumber = '919876543210'; // missing +
        expect(() => client.validatePhoneNumber(), throwsArgumentError);
        
        credentials.phoneNumber = '+12345'; // too short
        expect(() => client.validatePhoneNumber(), throwsArgumentError);
      });
    });

    group('OTP methods', () {
      test('getChatHistory throws StateError if not initialized', () {
        expect(() => client.getChatHistory(const t.InputPeerEmpty()), throwsStateError);
      });
    });
  });
}

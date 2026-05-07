import 'package:telidemo/telidemo.dart';
import 'package:test/test.dart';

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

    test('clientId is null before init', () {
      expect(client.clientId, isNull);
    });
  });
}

// ignore_for_file: unnecessary_getters_setters

/// Credentials required for TeliDemoClient.
/// Follows a POJO-like pattern with getters and setters.
class TeliDemoCredentials {
  int _apiId;
  String _apiHash;
  String? _phoneNumber;

  TeliDemoCredentials({
    required int apiId,
    required String apiHash,
  })  : _apiId = apiId,
        _apiHash = apiHash;

  int get apiId => _apiId;
  set apiId(int value) => _apiId = value;

  String get apiHash => _apiHash;
  set apiHash(String value) => _apiHash = value;

  String? get phoneNumber => _phoneNumber;
  set phoneNumber(String? value) => _phoneNumber = value;
}

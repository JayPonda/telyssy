/// An interface for credentials and session data required for [TeliClient].
///
/// Implement this class if you need custom logic for managing API credentials,
/// phone numbers, or session persistence.
abstract interface class TeliCredentials {
  /// The API ID obtained from https://my.telegram.org.
  abstract int apiId;

  /// The API Hash obtained from https://my.telegram.org.
  abstract String apiHash;

  /// The country code without the '+' prefix (e.g., "91" for India).
  abstract String? countryCode;

  /// The subscriber phone number without the country code (e.g., "9876543210").
  abstract String? phoneNumber;

  /// The hash received after sending the OTP code, used for signing in.
  abstract String? phoneCodeHash;

  /// The serialized session data (JSON) for persistence.
  abstract String? sessionData;

  /// Validates the API ID and API Hash.
  void validateApiCredentials();

  /// Validates the phone number components and returns the full number.
  String validatePhoneNumber();

  /// Returns the full phone number in international format.
  String get fullPhoneNumber;

  /// Creates a default [TeliCredentials] implementation.
  factory TeliCredentials({
    required int apiId,
    required String apiHash,
    String? countryCode,
    String? phoneNumber,
    String? phoneCodeHash,
    String? sessionData,
  }) = _TeliCredentialsImpl;
}

/// Default implementation of [TeliCredentials].
class _TeliCredentialsImpl implements TeliCredentials {
  @override
  int apiId;

  @override
  String apiHash;

  @override
  String? countryCode;

  @override
  String? phoneNumber;

  @override
  String? phoneCodeHash;

  @override
  String? sessionData;

  _TeliCredentialsImpl({
    required this.apiId,
    required this.apiHash,
    this.countryCode,
    this.phoneNumber,
    this.phoneCodeHash,
    this.sessionData,
  });

  @override
  void validateApiCredentials() {
    final apiIdStr = apiId.toString();
    if (!RegExp(r'^\d{7,10}$').hasMatch(apiIdStr)) {
      throw ArgumentError('Invalid API ID: Must be a 7-10 digit number.');
    }

    if (apiHash.length != 32) {
      throw ArgumentError('Invalid API Hash: Must be 32 characters long.');
    }
  }

  @override
  String validatePhoneNumber() {
    final cc = countryCode?.replaceAll(RegExp(r'\D'), '');
    final ph = phoneNumber?.replaceAll(RegExp(r'\D'), '');

    if (cc == null || cc.isEmpty) {
      throw ArgumentError('Country code is required and cannot be empty.');
    }
    if (ph == null || ph.isEmpty) {
      throw ArgumentError('Phone number is required and cannot be empty.');
    }

    final full = '+$cc$ph';

    if (!RegExp(r'^\+\d{7,15}$').hasMatch(full)) {
      throw ArgumentError(
        'Invalid phone number format: $full. '
        'The combined number must be between 7 and 15 digits.',
      );
    }

    return full;
  }

  @override
  String get fullPhoneNumber => validatePhoneNumber();
}

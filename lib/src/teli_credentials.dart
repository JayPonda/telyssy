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

  /// Returns the preferred Telegram datacenter host based on country code.
  ///
  /// Selects the nearest datacenter for lower latency:
  /// - Americas: DC1 (Miami)
  /// - Europe/Africa: DC2 (Amsterdam)
  /// - Asia/Oceania: DC5 (Singapore)
  ({String ip, int port, int dcId}) getHost() {
    final cc = countryCode?.replaceAll(RegExp(r'\D'), '') ?? '';

    final americas = [
      '1', '1242', '1246', '1264', '1268', '1284', '1340', '1345', '1441',
      '1473', '1649', '1664', '1671', '1684', '1758', '1767', '1784', '1787',
      '1809', '1829', '1849', '1868', '1869', '1876', '1939', '1952', '501',
      '502', '503', '504', '505', '506', '507', '508', '509', '51', '52', '53',
      '54', '55', '56', '57', '58', '591', '592', '593', '594', '595', '596',
      '597', '598', '599', '670', '672', '674', '675', '676', '677', '678',
      '679', '680', '681', '682', '683', '684', '685', '686', '687', '688',
      '689', '690', '691', '692', '693', '694', '695', '696', '697', '698',
      '699', '784', '808', '870', '872', '874', '876', '878', '880', '882',
      '883', '886', '960', '962', '964', '966', '967', '968', '970', '971',
      '972', '973', '974', '975', '976', '977', '979', '992', '993', '994',
      '995', '996', '998',
    ];

    final europeAfrica = [
      '30', '31', '32', '33', '34', '35', '36', '37', '38', '39', '40', '41',
      '42', '43', '44', '45', '46', '47', '48', '49', '51', '52', '53', '54',
      '55', '56', '57', '58', '59', '60', '61', '62', '63', '64', '65', '66',
      '67', '68', '69', '70', '71', '72', '73', '74', '75', '76', '77', '78',
      '79', '20', '27', '211', '212', '213', '216', '218', '220', '221', '222',
      '223', '224', '225', '226', '227', '228', '229', '230', '231', '232',
      '233', '234', '235', '236', '237', '238', '239', '240', '241', '242',
      '243', '244', '245', '246', '247', '248', '249', '250', '251', '252',
      '253', '254', '255', '256', '257', '258', '259', '260', '261', '262',
      '263', '264', '265', '266', '267', '268', '269', '290', '291', '292',
      '293', '294', '295', '296', '297', '298', '299',
    ];

    if (europeAfrica.contains(cc)) {
      return (ip: '149.154.167.51', port: 443, dcId: 2);
    } else if (americas.contains(cc)) {
      return (ip: '149.154.167.50', port: 443, dcId: 1);
    } else {
      return (ip: '91.108.56.130', port: 443, dcId: 5);
    }
  }

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

  @override
  ({String ip, int port, int dcId}) getHost() {
    final cc = countryCode?.replaceAll(RegExp(r'\D'), '') ?? '';

    final americas = [
      '1', '1242', '1246', '1264', '1268', '1284', '1340', '1345', '1441',
      '1473', '1649', '1664', '1671', '1684', '1758', '1767', '1784', '1787',
      '1809', '1829', '1849', '1868', '1869', '1876', '1939', '1952', '501',
      '502', '503', '504', '505', '506', '507', '508', '509', '51', '52', '53',
      '54', '55', '56', '57', '58', '591', '592', '593', '594', '595', '596',
      '597', '598', '599', '670', '672', '674', '675', '676', '677', '678',
      '679', '680', '681', '682', '683', '684', '685', '686', '687', '688',
      '689', '690', '691', '692', '693', '694', '695', '696', '697', '698',
      '699', '784', '808', '870', '872', '874', '876', '878', '880', '882',
      '883', '886', '960', '962', '964', '966', '967', '968', '970', '971',
      '972', '973', '974', '975', '976', '977', '979', '992', '993', '994',
      '995', '996', '998',
    ];

    final europeAfrica = [
      '30', '31', '32', '33', '34', '35', '36', '37', '38', '39', '40', '41',
      '42', '43', '44', '45', '46', '47', '48', '49', '51', '52', '53', '54',
      '55', '56', '57', '58', '59', '60', '61', '62', '63', '64', '65', '66',
      '67', '68', '69', '70', '71', '72', '73', '74', '75', '76', '77', '78',
      '79', '20', '27', '211', '212', '213', '216', '218', '220', '221', '222',
      '223', '224', '225', '226', '227', '228', '229', '230', '231', '232',
      '233', '234', '235', '236', '237', '238', '239', '240', '241', '242',
      '243', '244', '245', '246', '247', '248', '249', '250', '251', '252',
      '253', '254', '255', '256', '257', '258', '259', '260', '261', '262',
      '263', '264', '265', '266', '267', '268', '269', '290', '291', '292',
      '293', '294', '295', '296', '297', '298', '299',
    ];

    if (europeAfrica.contains(cc)) {
      return (ip: '149.154.167.51', port: 443, dcId: 2);
    } else if (americas.contains(cc)) {
      return (ip: '149.154.167.50', port: 443, dcId: 1);
    } else {
      return (ip: '91.108.56.130', port: 443, dcId: 5);
    }
  }
}

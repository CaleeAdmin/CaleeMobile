class ClientProfile {
  const ClientProfile({
    required this.accountId,
    required this.email,
    required this.firstName,
    required this.lastName,
    this.displayName,
    this.timeZone,
    this.postalCode,
    this.countryCode,
    this.locale,
    this.warnings = const [],
  });

  factory ClientProfile.fromJson(Map<String, dynamic> json) {
    return ClientProfile(
      accountId: json['accountId'] as String? ?? '',
      email: json['email'] as String? ?? '',
      firstName: json['firstName'] as String? ?? '',
      lastName: json['lastName'] as String? ?? '',
      displayName: json['displayName'] as String?,
      timeZone: json['timeZone'] as String?,
      postalCode: json['postalCode'] as String?,
      countryCode: json['countryCode'] as String?,
      locale: json['locale'] as String?,
      warnings: (json['warnings'] as List<dynamic>? ?? const [])
          .whereType<String>()
          .toList(),
    );
  }

  final String accountId;
  final String email;
  final String firstName;
  final String lastName;
  final String? displayName;
  final String? timeZone;
  final String? postalCode;
  final String? countryCode;
  final String? locale;
  final List<String> warnings;

  bool get hasWarnings => warnings.isNotEmpty;
}

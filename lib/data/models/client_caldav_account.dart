class ClientCalDavAccount {
  const ClientCalDavAccount({
    required this.serviceId,
    required this.serviceName,
    required this.server,
    required this.username,
    required this.appPassword,
    required this.description,
  });

  factory ClientCalDavAccount.fromJson(Map<String, dynamic> json) {
    return ClientCalDavAccount(
      serviceId: json['serviceId'] as String? ?? '',
      serviceName: json['serviceName'] as String? ?? '',
      server: json['server'] as String? ?? '',
      username: json['username'] as String? ?? '',
      appPassword: json['password'] as String? ?? '',
      description: json['description'] as String? ?? '',
    );
  }

  final String serviceId;
  final String serviceName;
  final String server;
  final String username;

  /// CalDAV/Nextcloud service credential returned by Hub for external calendar setup.
  /// This is not the CaleeMobile app login password and is not used as app
  /// session auth.
  final String appPassword;
  final String description;
}

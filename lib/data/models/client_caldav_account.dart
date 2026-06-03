class ClientCalDavAccount {
  const ClientCalDavAccount({
    required this.serviceId,
    required this.serviceName,
    required this.server,
    required this.username,
    required this.password,
    required this.description,
  });

  factory ClientCalDavAccount.fromJson(Map<String, dynamic> json) {
    return ClientCalDavAccount(
      serviceId: json['serviceId'] as String? ?? '',
      serviceName: json['serviceName'] as String? ?? '',
      server: json['server'] as String? ?? '',
      username: json['username'] as String? ?? '',
      password: json['password'] as String? ?? '',
      description: json['description'] as String? ?? '',
    );
  }

  final String serviceId;
  final String serviceName;
  final String server;
  final String username;
  final String password;
  final String description;
}

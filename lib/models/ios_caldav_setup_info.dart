class IosCaldavSetupInfo {
  const IosCaldavSetupInfo({
    required this.server,
    required this.username,
    required this.password,
    required this.description,
    required this.isReady,
    this.missingReason,
  });

  final String server;
  final String username;
  final String password;
  final String description;
  final bool isReady;
  final String? missingReason;
}

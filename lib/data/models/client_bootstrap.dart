class ClientBootstrap {
  const ClientBootstrap({
    required this.account,
    required this.services,
    required this.contexts,
    required this.availableContexts,
    required this.capabilities,
  });

  factory ClientBootstrap.fromJson(Map<String, dynamic> json) {
    return ClientBootstrap(
      account: ClientAccount.fromJson(
        json['account'] as Map<String, dynamic>? ?? const {},
      ),
      services: (json['services'] as List<dynamic>? ?? const [])
          .whereType<Map<String, dynamic>>()
          .map(ClientService.fromJson)
          .toList(),
      contexts: ClientContexts.fromJson(
        json['contexts'] as Map<String, dynamic>? ?? const {},
      ),
      availableContexts:
          (json['availableContexts'] as List<dynamic>? ?? const [])
              .whereType<Map<String, dynamic>>()
              .map(ClientContext.fromJson)
              .toList(),
      capabilities: Map<String, dynamic>.from(
        json['capabilities'] as Map<String, dynamic>? ?? const {},
      ),
    );
  }

  final ClientAccount account;
  final List<ClientService> services;
  final ClientContexts contexts;
  final List<ClientContext> availableContexts;
  final Map<String, dynamic> capabilities;
}

class ClientAccount {
  const ClientAccount({
    required this.id,
    required this.displayName,
    required this.primaryEmail,
    required this.timeZone,
    required this.status,
  });

  factory ClientAccount.fromJson(Map<String, dynamic> json) {
    return ClientAccount(
      id: json['id'] as String? ?? '',
      displayName: json['displayName'] as String?,
      primaryEmail: json['primaryEmail'] as String?,
      timeZone: json['timeZone'] as String?,
      status: json['status'] as String?,
    );
  }

  final String id;
  final String? displayName;
  final String? primaryEmail;
  final String? timeZone;
  final String? status;
}

class ClientService {
  const ClientService({
    required this.id,
    required this.displayName,
    required this.baseUrl,
    required this.launchUrl,
    required this.serviceType,
    required this.accessStatus,
    required this.calendarCredentialStatus,
    required this.source,
    required this.capabilities,
  });

  factory ClientService.fromJson(Map<String, dynamic> json) {
    return ClientService(
      id: json['id'] as String? ?? '',
      displayName: json['displayName'] as String? ?? '',
      baseUrl: json['baseUrl'] as String? ?? '',
      launchUrl: json['launchUrl'] as String? ?? '',
      serviceType: json['serviceType'] as String? ?? '',
      accessStatus: json['accessStatus'] as String? ?? '',
      calendarCredentialStatus:
          json['calendarCredentialStatus'] as String? ?? 'unsupported',
      source: json['source'] as String? ?? '',
      capabilities: Map<String, dynamic>.from(
        json['capabilities'] as Map<String, dynamic>? ?? const {},
      ),
    );
  }

  final String id;
  final String displayName;
  final String baseUrl;
  final String launchUrl;
  final String serviceType;
  final String accessStatus;
  final String calendarCredentialStatus;
  final String source;
  final Map<String, dynamic> capabilities;

  bool get hasConnectedCalendarCredential =>
      calendarCredentialStatus == 'connected';
  bool get hasMissingCalendarCredential =>
      calendarCredentialStatus == 'missing';

  bool get supportsCalendar => capabilities['calendar'] == true;

  bool get supportsTasks => capabilities['tasks'] == true;

  bool get supportsChores {
    if (capabilities.containsKey('chores')) {
      return capabilities['chores'] == true;
    }
    // Backwards compatibility with old deployed backend.
    return id == 'portal' || serviceType == 'nextcloud_portal';
  }

  bool get supportsChoreMetadata {
    if (capabilities.containsKey('choreMetadata')) {
      return capabilities['choreMetadata'] == true;
    }
    // Backwards compatibility with old deployed backend.
    return supportsChores;
  }

  bool get supportsCalendarCredentials {
    if (capabilities.containsKey('calendarCredentials')) {
      return capabilities['calendarCredentials'] == true;
    }
    // Backwards compatibility with old deployed backend.
    return calendarCredentialStatus != 'unsupported';
  }

  bool get supportsCalendarAppSetup {
    if (capabilities.containsKey('calendarAppSetup')) {
      return capabilities['calendarAppSetup'] == true;
    }
    // Backwards compatibility with old deployed backend.
    return supportsCalendarCredentials;
  }

  bool get supportsCalendarCredential => supportsCalendarCredentials;

  bool get supportsCalendarSharingAddress {
    if (capabilities.containsKey('calendarSharingAddress')) {
      return capabilities['calendarSharingAddress'] == true;
    }
    return false;
  }
}

class ClientContexts {
  const ClientContexts({
    required this.households,
    required this.organisations,
  });

  factory ClientContexts.fromJson(Map<String, dynamic> json) {
    return ClientContexts(
      households: (json['households'] as List<dynamic>? ?? const [])
          .whereType<Map<String, dynamic>>()
          .map(ClientContext.fromJson)
          .toList(),
      organisations: (json['organisations'] as List<dynamic>? ?? const [])
          .whereType<Map<String, dynamic>>()
          .map(ClientContext.fromJson)
          .toList(),
    );
  }

  final List<ClientContext> households;
  final List<ClientContext> organisations;
}

class ClientContext {
  const ClientContext({
    required this.id,
    required this.type,
    required this.name,
    required this.role,
    required this.status,
    this.organisationId,
    this.organisationName,
    this.organisationUnitId,
    this.organisationUnitName,
  });

  factory ClientContext.fromJson(Map<String, dynamic> json) {
    return ClientContext(
      id: json['id'] as String? ?? '',
      type: json['type'] as String? ?? '',
      name: json['name'] as String? ?? '',
      role: json['role'] as String? ?? '',
      status: json['status'] as String? ?? '',
      organisationId: json['organisationId'] as String?,
      organisationName: json['organisationName'] as String?,
      organisationUnitId: json['organisationUnitId'] as String?,
      organisationUnitName: json['organisationUnitName'] as String?,
    );
  }

  final String id;
  final String type;
  final String name;
  final String role;
  final String status;
  final String? organisationId;
  final String? organisationName;
  final String? organisationUnitId;
  final String? organisationUnitName;
}

class ClientLoginResult {
  const ClientLoginResult({
    required this.accessToken,
    required this.refreshToken,
    required this.tokenType,
    required this.expiresIn,
    required this.refreshExpiresIn,
    required this.bootstrap,
  });

  factory ClientLoginResult.fromJson(Map<String, dynamic> json) {
    return ClientLoginResult(
      accessToken: json['accessToken'] as String? ?? '',
      refreshToken: json['refreshToken'] as String? ?? '',
      tokenType: json['tokenType'] as String? ?? 'Bearer',
      expiresIn: json['expiresIn'] as int? ?? 0,
      refreshExpiresIn: json['refreshExpiresIn'] as int? ?? 0,
      bootstrap: ClientBootstrap.fromJson(
        json['bootstrap'] as Map<String, dynamic>? ?? const {},
      ),
    );
  }

  final String accessToken;
  final String refreshToken;
  final String tokenType;
  final int expiresIn;
  final int refreshExpiresIn;
  final ClientBootstrap bootstrap;
}

class ClientRefreshResult {
  const ClientRefreshResult({
    required this.accessToken,
    required this.tokenType,
    required this.expiresIn,
  });

  factory ClientRefreshResult.fromJson(Map<String, dynamic> json) {
    return ClientRefreshResult(
      accessToken: json['accessToken'] as String? ?? '',
      tokenType: json['tokenType'] as String? ?? 'Bearer',
      expiresIn: json['expiresIn'] as int? ?? 0,
    );
  }

  final String accessToken;
  final String tokenType;
  final int expiresIn;
}

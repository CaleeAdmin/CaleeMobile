class ClientBootstrap {
  const ClientBootstrap({
    required this.account,
    required this.services,
    required this.contexts,
    required this.availableContexts,
    required this.capabilities,
    this.readiness = const {},
    this.experienceMode,
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
      readiness: Map<String, dynamic>.from(
        json['readiness'] as Map<String, dynamic>? ?? const {},
      ),
      experienceMode:
          (json['experience'] as Map<String, dynamic>?)?['mode'] as String?,
    );
  }

  final ClientAccount account;
  final List<ClientService> services;
  final ClientContexts contexts;
  final List<ClientContext> availableContexts;
  final Map<String, dynamic> capabilities;

  /// Authoritative `experience.mode` reported by the backend ('family',
  /// 'business', or 'custom'). Null on older backends that don't send it yet.
  final String? experienceMode;

  bool get supportsMeals => capabilities['meals'] == true;

  bool get supportsMealTemplates =>
      capabilities['mealTemplates'] == true || supportsMeals;

  bool get hasActiveHouseholdContext =>
      contexts.households.any((c) => c.status == 'active' || c.status.isEmpty);

  bool get hasActiveOrganisationContext => contexts.organisations.any(
    (c) => c.status == 'active' || c.status.isEmpty,
  );

  bool get _hasBusinessOrCustomService =>
      services.any((s) => s.isActive && (s.id == 'business' || s.id == 'cewa'));

  // UX-only: hide family modules (Chores, Meals, People) for business/custom
  // accounts. Prefers the backend's authoritative experience.mode — the same
  // signal Calee/Android reads — so both apps agree. Falls back to the
  // previous context/service heuristic when an older backend hasn't
  // populated experience.mode yet.
  bool get isFamilyUxContext {
    switch (experienceMode) {
      case 'family':
        return true;
      case 'business':
      case 'custom':
        return false;
    }
    if (_hasBusinessOrCustomService) return false;
    return hasActiveHouseholdContext && !hasActiveOrganisationContext;
  }

  /// Server-reported readiness flags. Keys: calendarServiceReady (bool),
  /// problem (String?). Absent on older backends — treat missing as ready.
  final Map<String, dynamic> readiness;

  bool get calendarServiceReady =>
      readiness['calendarServiceReady'] as bool? ?? true;

  String? get readinessProblem => readiness['problem'] as String?;
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

  bool get isActive => accessStatus == 'active';

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

  bool get supportsRecentlyDeleted {
    return capabilities['deletedItems'] == true ||
        capabilities['recentlyDeleted'] == true;
  }

  bool get supportsDeletedItemsRestore {
    return capabilities['deletedItemsRestore'] == true ||
        supportsRecentlyDeleted;
  }

  bool get supportsDeletedItemsPermanentDelete {
    return capabilities['deletedItemsPermanentDelete'] == true ||
        supportsRecentlyDeleted;
  }

  bool get supportsMeals => capabilities['meals'] == true;

  bool get supportsMealTemplates =>
      capabilities['mealTemplates'] == true || supportsMeals;
}

class ClientContexts {
  const ClientContexts({required this.households, required this.organisations});

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
    this.onboardingSessionId,
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
      onboardingSessionId: json['onboardingSessionId'] as String?,
    );
  }

  final String accessToken;
  final String refreshToken;
  final String tokenType;
  final int expiresIn;
  final int refreshExpiresIn;
  final ClientBootstrap bootstrap;
  // Present on /client/v1/auth/register responses; absent on login. Kept
  // only for support/observability — it is not required for the client to
  // function and is not sent back to the server by CaleeMobile in this slice.
  final String? onboardingSessionId;
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

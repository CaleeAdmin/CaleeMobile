class ExternalCalendarProvider {
  const ExternalCalendarProvider({
    required this.providerKey,
    required this.displayName,
    required this.authType,
    required this.supportsRead,
    required this.supportsWrite,
    required this.supportsCalendarList,
    required this.supportsIncrementalSync,
    required this.supportsPush,
  });

  factory ExternalCalendarProvider.fromJson(Map<String, dynamic> json) {
    return ExternalCalendarProvider(
      providerKey: json['providerKey'] as String? ?? '',
      displayName: json['displayName'] as String? ?? '',
      authType: json['authType'] as String? ?? '',
      supportsRead: json['supportsRead'] as bool? ?? false,
      supportsWrite: json['supportsWrite'] as bool? ?? false,
      supportsCalendarList: json['supportsCalendarList'] as bool? ?? false,
      supportsIncrementalSync:
          json['supportsIncrementalSync'] as bool? ?? false,
      supportsPush: json['supportsPush'] as bool? ?? false,
    );
  }

  final String providerKey;
  final String displayName;
  final String authType;
  final bool supportsRead;
  final bool supportsWrite;
  final bool supportsCalendarList;
  final bool supportsIncrementalSync;
  final bool supportsPush;
}

class ExternalCalendarConnection {
  const ExternalCalendarConnection({
    required this.id,
    required this.providerKey,
    required this.displayName,
    required this.connectionStatus,
    required this.accessMode,
    required this.sourceOfTruthPolicy,
    this.externalAccountEmail,
    this.lastConnectedAt,
    this.lastVerifiedAt,
    this.revokedAt,
  });

  factory ExternalCalendarConnection.fromJson(Map<String, dynamic> json) {
    return ExternalCalendarConnection(
      id: json['id'] as String? ?? '',
      providerKey: json['providerKey'] as String? ?? '',
      displayName: json['displayName'] as String? ?? '',
      externalAccountEmail: json['externalAccountEmail'] as String?,
      connectionStatus: json['connectionStatus'] as String? ?? '',
      accessMode: json['accessMode'] as String? ?? '',
      sourceOfTruthPolicy: json['sourceOfTruthPolicy'] as String? ?? '',
      lastConnectedAt: json['lastConnectedAt'] as String?,
      lastVerifiedAt: json['lastVerifiedAt'] as String?,
      revokedAt: json['revokedAt'] as String?,
    );
  }

  final String id;
  final String providerKey;
  final String displayName;
  final String? externalAccountEmail;
  final String connectionStatus;
  final String accessMode;
  final String sourceOfTruthPolicy;
  final String? lastConnectedAt;
  final String? lastVerifiedAt;
  final String? revokedAt;

  bool get isActive => connectionStatus == 'active';
  bool get isGoogle => providerKey == 'google_calendar';
}

class ExternalCalendarPrivacySettings {
  const ExternalCalendarPrivacySettings({
    required this.showTitle,
    required this.showLocation,
    required this.showDescription,
    required this.showAttendees,
    required this.showOrganizer,
    required this.privateEventMode,
  });

  factory ExternalCalendarPrivacySettings.fromJson(Map<String, dynamic> json) {
    return ExternalCalendarPrivacySettings(
      showTitle: json['showTitle'] as bool? ?? true,
      showLocation: json['showLocation'] as bool? ?? true,
      showDescription: json['showDescription'] as bool? ?? false,
      showAttendees: json['showAttendees'] as bool? ?? false,
      showOrganizer: json['showOrganizer'] as bool? ?? false,
      privateEventMode:
          json['privateEventMode'] as String? ?? 'busy_only',
    );
  }

  static const defaults = ExternalCalendarPrivacySettings(
    showTitle: true,
    showLocation: true,
    showDescription: false,
    showAttendees: false,
    showOrganizer: false,
    privateEventMode: 'busy_only',
  );

  final bool showTitle;
  final bool showLocation;
  final bool showDescription;
  final bool showAttendees;
  final bool showOrganizer;
  final String privateEventMode;

  Map<String, dynamic> toJson() => {
    'showTitle': showTitle,
    'showLocation': showLocation,
    'showDescription': showDescription,
    'showAttendees': showAttendees,
    'showOrganizer': showOrganizer,
    'privateEventMode': privateEventMode,
  };
}

class ExternalCalendar {
  const ExternalCalendar({
    required this.id,
    required this.providerKey,
    required this.externalCalendarId,
    required this.displayName,
    required this.providerDisplayName,
    required this.syncEnabled,
    required this.visibilityStatus,
    required this.accessMode,
    required this.sourceOfTruthPolicy,
    required this.privacySettings,
    required this.syncStatus,
    this.color,
    this.timeZone,
    this.accessRole,
    this.lastSyncedAt,
  });

  factory ExternalCalendar.fromJson(Map<String, dynamic> json) {
    final privacyJson = json['privacySettings'];
    final privacy = privacyJson is Map<String, dynamic>
        ? ExternalCalendarPrivacySettings.fromJson(privacyJson)
        : ExternalCalendarPrivacySettings.defaults;

    return ExternalCalendar(
      id: json['id'] as String? ?? '',
      providerKey: json['providerKey'] as String? ?? '',
      externalCalendarId: json['externalCalendarId'] as String? ?? '',
      displayName: json['displayName'] as String? ?? '',
      providerDisplayName: json['providerDisplayName'] as String? ?? '',
      color: json['color'] as String?,
      timeZone: json['timeZone'] as String?,
      accessRole: json['accessRole'] as String?,
      syncEnabled: json['syncEnabled'] as bool? ?? false,
      visibilityStatus: json['visibilityStatus'] as String? ?? '',
      accessMode: json['accessMode'] as String? ?? '',
      sourceOfTruthPolicy: json['sourceOfTruthPolicy'] as String? ?? '',
      privacySettings: privacy,
      syncStatus: json['syncStatus'] as String? ?? '',
      lastSyncedAt: json['lastSyncedAt'] as String?,
    );
  }

  final String id;
  final String providerKey;
  final String externalCalendarId;
  final String displayName;
  final String providerDisplayName;
  final String? color;
  final String? timeZone;
  final String? accessRole;
  final bool syncEnabled;
  final String visibilityStatus;
  final String accessMode;
  final String sourceOfTruthPolicy;
  final ExternalCalendarPrivacySettings privacySettings;
  final String syncStatus;
  final String? lastSyncedAt;
}

class ExternalCalendarSyncResult {
  const ExternalCalendarSyncResult({
    required this.status,
    required this.mode,
    required this.eventCount,
    required this.deletedCount,
    required this.nextSyncAvailable,
  });

  factory ExternalCalendarSyncResult.fromJson(Map<String, dynamic> json) {
    return ExternalCalendarSyncResult(
      status: json['status'] as String? ?? '',
      mode: json['mode'] as String? ?? '',
      eventCount: json['eventCount'] as int? ?? 0,
      deletedCount: json['deletedCount'] as int? ?? 0,
      nextSyncAvailable: json['nextSyncAvailable'] as bool? ?? false,
    );
  }

  final String status;
  final String mode;
  final int eventCount;
  final int deletedCount;
  final bool nextSyncAvailable;

  bool get isSuccess => status == 'ok' || status == 'success';
}

import 'dart:convert';

enum SyncRunMode { pull, push, twoWay }

enum SyncRunResult { success, partial, failed, abortedBySafety }

enum SnapshotTrustStatus { remote, local, unknown }

enum SyncBindingResultStatus { success, partial, failed, abortedBySafety }

enum SyncErrorCode {
  networkUnavailable,
  authExpired,
  remoteCalendarMissing,
  permissionDenied,
  parseOrServerResponse,
  localProviderFailure,
  dbOrMappingConflict,
  safetyStop,
  unknown,
}

class SyncChangeCounts {
  int created;
  int updated;
  int deleted;

  SyncChangeCounts({this.created = 0, this.updated = 0, this.deleted = 0});

  Map<String, dynamic> toJson() => {
        'created': created,
        'updated': updated,
        'deleted': deleted,
      };

  factory SyncChangeCounts.fromJson(Map<String, dynamic> json) => SyncChangeCounts(
        created: (json['created'] as num?)?.toInt() ?? 0,
        updated: (json['updated'] as num?)?.toInt() ?? 0,
        deleted: (json['deleted'] as num?)?.toInt() ?? 0,
      );
}

class SyncBindingRunRecord {
  String bindingIdentifier;
  String accountIdentifier;
  SnapshotTrustStatus snapshotTrustStatus;
  bool safetyGateTriggered;
  SyncBindingResultStatus resultStatus;
  SyncChangeCounts localCounts;
  SyncChangeCounts remoteCounts;
  SyncErrorCode? errorCode;
  String? errorMessage;
  String? technicalDetail;
  DateTime? startedAt;
  DateTime? endedAt;

  SyncBindingRunRecord({
    required this.bindingIdentifier,
    required this.accountIdentifier,
    this.snapshotTrustStatus = SnapshotTrustStatus.unknown,
    this.safetyGateTriggered = false,
    this.resultStatus = SyncBindingResultStatus.success,
    SyncChangeCounts? localCounts,
    SyncChangeCounts? remoteCounts,
    this.errorCode,
    this.errorMessage,
    this.technicalDetail,
    this.startedAt,
    this.endedAt,
  })  : localCounts = localCounts ?? SyncChangeCounts(),
        remoteCounts = remoteCounts ?? SyncChangeCounts();

  Map<String, dynamic> toJson() => {
        'bindingIdentifier': bindingIdentifier,
        'accountIdentifier': accountIdentifier,
        'snapshotTrustStatus': snapshotTrustStatus.name,
        'safetyGateTriggered': safetyGateTriggered,
        'resultStatus': resultStatus.name,
        'localCounts': localCounts.toJson(),
        'remoteCounts': remoteCounts.toJson(),
        'errorCode': errorCode?.name,
        'errorMessage': errorMessage,
        'technicalDetail': technicalDetail,
        'startedAt': startedAt?.toIso8601String(),
        'endedAt': endedAt?.toIso8601String(),
      };

  factory SyncBindingRunRecord.fromJson(Map<String, dynamic> json) => SyncBindingRunRecord(
        bindingIdentifier: (json['bindingIdentifier'] ?? '').toString(),
        accountIdentifier: (json['accountIdentifier'] ?? '').toString(),
        snapshotTrustStatus: SnapshotTrustStatus.values.firstWhere(
          (e) => e.name == json['snapshotTrustStatus'],
          orElse: () => SnapshotTrustStatus.unknown,
        ),
        safetyGateTriggered: json['safetyGateTriggered'] == true,
        resultStatus: SyncBindingResultStatus.values.firstWhere(
          (e) => e.name == json['resultStatus'],
          orElse: () => SyncBindingResultStatus.success,
        ),
        localCounts: SyncChangeCounts.fromJson((json['localCounts'] as Map?)?.cast<String, dynamic>() ?? {}),
        remoteCounts: SyncChangeCounts.fromJson((json['remoteCounts'] as Map?)?.cast<String, dynamic>() ?? {}),
        errorCode: SyncErrorCode.values.where((e) => e.name == json['errorCode']).cast<SyncErrorCode?>().firstOrNull,
        errorMessage: json['errorMessage']?.toString(),
        technicalDetail: json['technicalDetail']?.toString(),
        startedAt: json['startedAt'] != null ? DateTime.tryParse(json['startedAt'].toString()) : null,
        endedAt: json['endedAt'] != null ? DateTime.tryParse(json['endedAt'].toString()) : null,
      );
}

class SyncRunRecord {
  String runId;
  DateTime startTime;
  DateTime? endTime;
  int? durationMs;
  SyncRunMode mode;
  String appVersion;
  String deviceIdentifier;
  SyncRunResult result;
  List<SyncBindingRunRecord> bindings;

  SyncRunRecord({
    required this.runId,
    required this.startTime,
    this.endTime,
    this.durationMs,
    required this.mode,
    required this.appVersion,
    required this.deviceIdentifier,
    this.result = SyncRunResult.success,
    List<SyncBindingRunRecord>? bindings,
  }) : bindings = bindings ?? [];

  Map<String, dynamic> toJson() => {
        'runId': runId,
        'startTime': startTime.toIso8601String(),
        'endTime': endTime?.toIso8601String(),
        'durationMs': durationMs,
        'mode': mode.name,
        'appVersion': appVersion,
        'deviceIdentifier': deviceIdentifier,
        'result': result.name,
        'bindings': bindings.map((b) => b.toJson()).toList(),
      };

  String toJsonString() => const JsonEncoder.withIndent('  ').convert(toJson());

  factory SyncRunRecord.fromJson(Map<String, dynamic> json) => SyncRunRecord(
        runId: (json['runId'] ?? '').toString(),
        startTime: DateTime.tryParse((json['startTime'] ?? '').toString()) ?? DateTime.fromMillisecondsSinceEpoch(0),
        endTime: json['endTime'] != null ? DateTime.tryParse(json['endTime'].toString()) : null,
        durationMs: (json['durationMs'] as num?)?.toInt(),
        mode: SyncRunMode.values.firstWhere((e) => e.name == json['mode'], orElse: () => SyncRunMode.twoWay),
        appVersion: (json['appVersion'] ?? 'unknown').toString(),
        deviceIdentifier: (json['deviceIdentifier'] ?? 'unknown-device').toString(),
        result: SyncRunResult.values.firstWhere((e) => e.name == json['result'], orElse: () => SyncRunResult.failed),
        bindings: ((json['bindings'] as List?) ?? [])
            .whereType<Map>()
            .map((e) => SyncBindingRunRecord.fromJson(e.cast<String, dynamic>()))
            .toList(),
      );
}

extension<T> on Iterable<T> {
  T? get firstOrNull => isEmpty ? null : first;
}

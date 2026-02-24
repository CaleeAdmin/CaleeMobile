import 'package:package_info_plus/package_info_plus.dart';
import 'package:uuid/uuid.dart';

import '../common/app_constant.dart';
import '../common/utils/mmkv_utils.dart';
import '../data/sync_run_store.dart';
import '../entity/SyncContext.dart';
import '../entity/sync_run_record.dart';
import 'SyncEnum.dart';
import 'sync_completed_event_bus.dart';
import 'sync_run_telemetry.dart';

class SyncRunRecorder implements SyncRunTelemetry {
  SyncRunRecorder({SyncRunStore? store}) : _store = store ?? SyncRunStore();

  final SyncRunStore _store;
  final Map<String, SyncBindingRunRecord> _bindings = {};
  SyncRunRecord? _run;

  SyncRunRecord? get currentRun => _run;
  bool get hasSafetyAbort => _bindings.values.any((b) => b.resultStatus == SyncBindingResultStatus.abortedBySafety);

  Future<void> startRun({required SyncRunMode mode, required SyncRunTrigger trigger}) async {
    _bindings.clear();
    final packageInfo = await PackageInfo.fromPlatform();
    final runId = const Uuid().v4();
    final deviceId = _getDeviceId();
    _run = SyncRunRecord(
      runId: runId,
      startTime: DateTime.now(),
      mode: mode,
      appVersion: packageInfo.version,
      deviceIdentifier: deviceId,
      result: SyncRunResult.success,
      trigger: trigger,
    );
  }

  Future<void> finalizeAndPersist(SyncRunResult result) async {
    final run = _run;
    if (run == null) return;
    run.endTime = DateTime.now();
    run.durationMs = run.endTime!.difference(run.startTime).inMilliseconds;
    run.result = result;

    for (final binding in _bindings.values) {
      binding.endedAt ??= run.endTime;
    }
    run.bindings
      ..clear()
      ..addAll(_bindings.values);
    await _store.persistCompletedRun(run);
    SyncCompletedEventBus.publish(
      SyncCompletedEvent(
        runId: run.runId,
        completedAt: run.endTime ?? DateTime.now(),
      ),
    );
  }

  @override
  void onBindingStart(SyncContext ctx) {
    final key = _bindingKey(ctx);
    _bindings.putIfAbsent(
      key,
      () => SyncBindingRunRecord(
        bindingIdentifier: '${ctx.remotePath} <-> ${ctx.localCalendarId}',
        accountIdentifier: _redact(ctx.accountName),
        startedAt: DateTime.now(),
      ),
    );
  }

  @override
  void onBindingEnd({
    required SyncContext ctx,
    required SyncBindingResultStatus status,
    required SnapshotTrustStatus snapshotTrustStatus,
    required bool safetyTriggered,
    SyncErrorCode? errorCode,
    String? errorMessage,
    String? technicalDetail,
  }) {
    final b = _bindings[_bindingKey(ctx)];
    if (b == null) return;
    b.resultStatus = status;
    b.snapshotTrustStatus = snapshotTrustStatus;
    b.safetyGateTriggered = safetyTriggered;
    b.errorCode = errorCode;
    b.errorMessage = errorMessage;
    b.technicalDetail = technicalDetail;
    b.endedAt = DateTime.now();
  }

  @override
  void onOperation({required SyncContext ctx, required SyncOperationTarget target, required SyncOperationType type}) {
    final b = _bindings[_bindingKey(ctx)];
    if (b == null) return;
    final counts = target == SyncOperationTarget.local ? b.localCounts : b.remoteCounts;
    switch (type) {
      case SyncOperationType.created:
        counts.created++;
        break;
      case SyncOperationType.updated:
        counts.updated++;
        break;
      case SyncOperationType.deleted:
        counts.deleted++;
        break;
    }
  }

  @override
  void onError({required SyncContext ctx, required SyncErrorCode code, required String message, String? technicalDetail}) {
    final b = _bindings[_bindingKey(ctx)];
    if (b == null) return;
    b.errorCode = code;
    b.errorMessage = message;
    b.technicalDetail = technicalDetail;
    if (b.resultStatus == SyncBindingResultStatus.success) {
      b.resultStatus = SyncBindingResultStatus.failed;
    }
  }

  @override
  void onSafetyTriggered({required SyncContext ctx, String? detail}) {
    final b = _bindings[_bindingKey(ctx)];
    if (b == null) return;
    b.safetyGateTriggered = true;
    b.resultStatus = SyncBindingResultStatus.abortedBySafety;
    b.errorCode = SyncErrorCode.safetyStop;
    b.errorMessage = 'Safety gate blocked destructive operations';
    b.technicalDetail = detail;
  }

  String _bindingKey(SyncContext ctx) => '${ctx.remoteCollectionId}:${ctx.localCalendarId}';

  String _redact(String account) {
    if (account.length <= 2) return '**';
    return '${account.substring(0, 2)}***';
  }

  String _getDeviceId() {
    const key = 'sync_device_identifier';
    String? id = MMKVUtils.instance.getString(key);
    if (id == null || id.isEmpty) {
      id = 'dev-${const Uuid().v4().split('-').first}';
      MMKVUtils.instance.setString(key, id);
    }
    return id;
  }
}

SyncErrorCode mapSyncErrorCode(Object error) {
  final raw = error.toString().toLowerCase();
  if (raw.contains('timeout') || raw.contains('socket') || raw.contains('network')) {
    return SyncErrorCode.networkUnavailable;
  }
  if (raw.contains('401') || raw.contains('403') || raw.contains('auth')) {
    return SyncErrorCode.authExpired;
  }
  if (raw.contains('not found') || raw.contains('404') || raw.contains('calendar')) {
    return SyncErrorCode.remoteCalendarMissing;
  }
  if (raw.contains('permission')) {
    return SyncErrorCode.permissionDenied;
  }
  if (raw.contains('parse') || raw.contains('xml') || raw.contains('json') || raw.contains('status code')) {
    return SyncErrorCode.parseOrServerResponse;
  }
  if (raw.contains('sqlite') || raw.contains('constraint') || raw.contains('mapping')) {
    return SyncErrorCode.dbOrMappingConflict;
  }
  if (raw.contains('provider') || raw.contains('calendar api')) {
    return SyncErrorCode.localProviderFailure;
  }
  return SyncErrorCode.unknown;
}

SyncRunMode mapRunModeFromAction(SyncAction action) {
  switch (action) {
    case SyncAction.fullSyncPull:
      return SyncRunMode.pull;
    case SyncAction.fullSyncPush:
      return SyncRunMode.push;
    case SyncAction.fullSyncBidi:
      return SyncRunMode.twoWay;
  }
}

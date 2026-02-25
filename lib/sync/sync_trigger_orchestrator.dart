import 'dart:async';

import 'package:caleesync/common/app_constant.dart';
import 'package:caleesync/common/utils/mmkv_utils.dart';
import 'package:flutter/widgets.dart';
import 'package:get/get.dart';

import '../data/sync_run_store.dart';
import '../entity/SyncSummary.dart';
import '../entity/sync_run_record.dart';
import 'background_sync_scheduler.dart';

enum SyncTriggerType {
  manual,
  autoForeground,
  force,
}

class SyncTriggerOrchestrator extends GetxService with WidgetsBindingObserver {
  bool _appActive = true;
  Timer? _autoDebounceTimer;

  SyncTriggerOrchestrator({
    SyncRunStore? runStore,
    Future<void> Function({required String reason, bool expedited})? scheduleOneOff,
    Future<BackgroundSyncStatus> Function()? loadStatus,
    Duration foregroundDebounce = const Duration(seconds: 2),
    Duration pollInterval = const Duration(milliseconds: 500),
    Duration waitTimeout = const Duration(minutes: 3),
    bool Function()? autoSyncEnabledReader,
  })  : _runStore = runStore ?? SyncRunStore(),
        _scheduleOneOff = scheduleOneOff ?? BackgroundSyncScheduler.scheduleOneOff,
        _loadStatus = loadStatus ?? BackgroundSyncScheduler.getStatus,
        _autoSyncEnabledReader = autoSyncEnabledReader,
        _foregroundDebounce = foregroundDebounce,
        _pollInterval = pollInterval,
        _waitTimeout = waitTimeout;

  final SyncRunStore _runStore;
  final Future<void> Function({required String reason, bool expedited}) _scheduleOneOff;
  final Future<BackgroundSyncStatus> Function() _loadStatus;
  final bool Function()? _autoSyncEnabledReader;

  final Duration _foregroundDebounce;
  final Duration _pollInterval;
  final Duration _waitTimeout;

  @override
  void onInit() {
    super.onInit();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void onClose() {
    WidgetsBinding.instance.removeObserver(this);
    _autoDebounceTimer?.cancel();
    super.onClose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _appActive = state == AppLifecycleState.resumed;
  }

  Future<SyncSummary> triggerManual({Function(SyncSummary)? onProgress}) {
    return _scheduleRun(SyncTriggerType.manual, onProgress: onProgress);
  }

  Future<SyncSummary> triggerForce(int remoteCollectionId, {Function(SyncSummary)? onProgress}) {
    return _scheduleRun(SyncTriggerType.force, onProgress: onProgress, reason: 'force:$remoteCollectionId', expedited: true);
  }

  void notifyMeaningfulForegroundChange() {
    final bool autoSyncEnabled = _autoSyncEnabledReader?.call() ?? (MMKVUtils.instance.getBool(AppConstant.autoSyncEnabledKey, defaultValue: true) ?? true);
    if (!autoSyncEnabled || !_appActive) {
      return;
    }
    _autoDebounceTimer?.cancel();
    _autoDebounceTimer = Timer(_foregroundDebounce, () {
      _scheduleRun(SyncTriggerType.autoForeground);
    });
  }

  Future<SyncSummary> _scheduleRun(
    SyncTriggerType trigger, {
    Function(SyncSummary)? onProgress,
    String? reason,
    bool expedited = false,
  }) async {
    final String? baselineRunId = await _loadLatestRunId();
    final String triggerReason = reason ?? _mapReason(trigger);
    await _scheduleOneOff(reason: triggerReason, expedited: expedited);
    final SyncSummary summary = await _awaitRunCompletion(baselineRunId: baselineRunId);
    onProgress?.call(summary);
    return summary;
  }

  Future<String?> _loadLatestRunId() async {
    final runs = await _runStore.loadRuns(limit: 1);
    if (runs.isEmpty) return null;
    return runs.first.runId;
  }

  Future<SyncSummary> _awaitRunCompletion({required String? baselineRunId}) async {
    final DateTime deadline = DateTime.now().add(_waitTimeout);
    while (DateTime.now().isBefore(deadline)) {
      final status = await _loadStatus();
      final runs = await _runStore.loadRuns(limit: 1);
      if (runs.isNotEmpty) {
        final latest = runs.first;
        final bool isNewRun = baselineRunId == null || latest.runId != baselineRunId;
        if (isNewRun && latest.endTime != null && !status.workerRunning) {
          return _toSummary(latest);
        }
      }
      await Future.delayed(_pollInterval);
    }
    return SyncSummary();
  }

  SyncSummary _toSummary(SyncRunRecord run) {
    final summary = SyncSummary();
    summary.total = run.bindings.length;
    for (final binding in run.bindings) {
      switch (binding.resultStatus) {
        case SyncBindingResultStatus.success:
          summary.success++;
          summary.successLog.add(binding.bindingIdentifier);
          break;
        case SyncBindingResultStatus.partial:
        case SyncBindingResultStatus.failed:
        case SyncBindingResultStatus.abortedBySafety:
          summary.failed++;
          summary.errorLog.add(binding.errorMessage ?? binding.resultStatus.name);
          break;
      }
    }
    return summary;
  }

  String _mapReason(SyncTriggerType trigger) {
    return switch (trigger) {
      SyncTriggerType.manual => 'manual',
      SyncTriggerType.autoForeground => 'autoForeground',
      SyncTriggerType.force => 'force',
    };
  }
}

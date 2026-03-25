import 'dart:async';
import 'dart:io';

import 'package:caleesync/common/app_constant.dart';
import 'package:caleesync/common/utils/mmkv_utils.dart';
import 'package:flutter/widgets.dart';
import 'package:get/get.dart';

import '../data/sync_run_store.dart';
import '../core/platform/pigeon/background_sync_api.g.dart';
import '../entity/SyncSummary.dart';
import '../entity/sync_run_record.dart';
import 'SyncEngine.dart';
import 'background_sync_scheduler.dart';

enum SyncTriggerType {
  manual,
  autoForeground,
  force,
}

class SyncTriggerOrchestrator extends GetxService with WidgetsBindingObserver {
  bool _appActive = true;
  Timer? _autoDebounceTimer;

  final SyncRunStore _runStore = SyncRunStore();

  static const Duration _foregroundDebounce = Duration(seconds: 2);
  static const Duration _pollInterval = Duration(milliseconds: 500);
  static const Duration _waitTimeout = Duration(minutes: 3);

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
    if (Platform.isIOS) {
      return;
    }
    final bool autoSyncEnabled = MMKVUtils.instance.getBool(AppConstant.autoSyncEnabledKey, defaultValue: true) ?? true;
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
    if (_shouldRunInline(trigger)) {
      final SyncSummary? summary = await SyncEngine().executeFullSync(
        onProgress: onProgress,
        trigger: SyncRunTrigger.manual,
        waitForTurn: true,
      );
      return summary ?? SyncSummary();
    }

    final String? baselineRunId = await _loadLatestRunId();
    final String triggerReason = reason ?? _mapReason(trigger);
    final bool isManualOrForce = trigger == SyncTriggerType.manual || trigger == SyncTriggerType.force;
    await BackgroundSyncScheduler.scheduleOneOff(
      reason: triggerReason,
      expedited: expedited,
      policy: isManualOrForce ? OneOffEnqueuePolicy.replace : OneOffEnqueuePolicy.keep,
    );
    final SyncSummary summary = await _awaitRunCompletion(baselineRunId: baselineRunId);
    onProgress?.call(summary);
    return summary;
  }

  bool _shouldRunInline(SyncTriggerType trigger) {
    return Platform.isIOS && _appActive && trigger == SyncTriggerType.manual;
  }

  Future<String?> _loadLatestRunId() async {
    final runs = await _runStore.loadRuns(limit: 1);
    if (runs.isEmpty) return null;
    return runs.first.runId;
  }

  Future<SyncSummary> _awaitRunCompletion({required String? baselineRunId}) async {
    final DateTime deadline = DateTime.now().add(_waitTimeout);
    while (DateTime.now().isBefore(deadline)) {
      final status = await BackgroundSyncScheduler.getStatus();
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

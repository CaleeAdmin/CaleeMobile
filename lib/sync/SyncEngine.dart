import 'dart:async';

import 'package:caleesync/common/app_constant.dart';
import 'package:caleesync/common/utils/mmkv_utils.dart';
import 'package:caleesync/data/sync_repository.dart';
import 'package:flutter/cupertino.dart';

import '../entity/SyncSummary.dart';
import '../entity/sync_run_record.dart';
import '../services/calee_auth_service.dart';
import '../services/calee_server_service.dart';
import 'force_sync_registry.dart';
import 'sync_item_executor.dart';
import 'sync_item_planner.dart';
import 'sync_run_recorder.dart';

class SyncEngine {
  SyncEngine({
    SyncRepository? repo,
    CaleeServerService? serverService,
    CaleeAuthService? authService,
    SyncItemPlanner? planner,
    SyncItemExecutor? executor,
    SyncRunRecorder? runRecorder,
  })  : _repo = repo ?? SyncRepository(),
        _serverService = serverService ?? CaleeServerService(),
        _authService = authService ?? CaleeAuthService(serverBaseUrl: AppConstant.caleeServer),
        _planner = planner ?? SyncItemPlanner(),
        _executor = executor ?? SyncItemExecutor(),
        _runRecorder = runRecorder ?? SyncRunRecorder();

  final SyncRepository _repo;
  final CaleeServerService _serverService;
  final CaleeAuthService _authService;
  final SyncItemPlanner _planner;
  final SyncItemExecutor _executor;
  final SyncRunRecorder _runRecorder;

  static bool _syncInProgress = false;
  static Completer<void>? _syncRelease;

  static bool get isSyncInProgress => _syncInProgress;

  static void requestForceSyncForCollection(int remoteCollectionId) {
    ForceSyncRegistry.requestForceSyncForCollection(remoteCollectionId);
  }

  Future<SyncSummary?> executeFullSync({
    Function(SyncSummary)? onProgress,
    SyncRunTrigger trigger = SyncRunTrigger.manual,
    bool waitForTurn = true,
  }) async {
    final bool lockAcquired = await _acquireSyncTurn(waitForTurn: waitForTurn);
    if (!lockAcquired) {
      return null;
    }

    try {
      final summary = SyncSummary(telemetry: _runRecorder);
      final String? loginName = MMKVUtils.instance.getString(AppConstant.loginNameKey);
      if (loginName == null) return summary;

      await _repo.scanLocalCalendars(loginName);
      final List<Map<String, dynamic>> remoteCalendars = await _serverService.scanRemoteCalendars(
        serverUrl: _authService.normalizedUrl,
        userId: loginName,
      );

      final int enabledBindings = await _repo.countEnabledCalendarBindings(loginName);
      final syncItems = await _planner.generateSyncItems(loginName, remoteCalendars);
      debugPrint('====generateSyncItems===$syncItems');

      final mode = syncItems.isEmpty ? SyncRunMode.twoWay : mapRunModeFromAction(syncItems.first.action);
      await _runRecorder.startRun(mode: mode, trigger: trigger);

      summary.reset(syncItems.length);
      if (syncItems.isEmpty) {
        final skippedResult = enabledBindings <= 0
            ? SyncRunResult.skippedNoEnabledSources
            : SyncRunResult.skippedNoChanges;
        await _runRecorder.finalizeAndPersist(skippedResult);
        return summary;
      }

      for (final syncItem in syncItems) {
        summary.processing++;
        onProgress?.call(summary);

        try {
          _runRecorder.onBindingStart(syncItem);
          await _executor.execute(syncItem, summary);
        } finally {
          if (summary.processing > 0) {
            summary.processing--;
          }
          onProgress?.call(summary);
        }
      }

      final hasSafetyAbort = _runRecorder.hasSafetyAbort;
      final SyncRunResult result;
      if (summary.failed > 0 && summary.success > 0) {
        result = SyncRunResult.partial;
      } else if (summary.failed > 0) {
        result = SyncRunResult.failed;
      } else if (hasSafetyAbort) {
        result = SyncRunResult.abortedBySafety;
      } else {
        result = SyncRunResult.success;
      }
      await _runRecorder.finalizeAndPersist(result);

      return summary;
    } finally {
      _releaseSyncTurn();
    }
  }

  static Future<bool> _acquireSyncTurn({required bool waitForTurn}) async {
    while (_syncInProgress) {
      if (!waitForTurn) {
        return false;
      }
      final currentRelease = _syncRelease;
      if (currentRelease != null) {
        await currentRelease.future;
      } else {
        await Future<void>.delayed(const Duration(milliseconds: 50));
      }
    }
    _syncInProgress = true;
    _syncRelease = Completer<void>();
    return true;
  }

  static void _releaseSyncTurn() {
    _syncInProgress = false;
    _syncRelease?.complete();
    _syncRelease = null;
  }
}

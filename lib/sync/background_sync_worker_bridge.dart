import 'dart:async';
import 'dart:io';
import 'dart:ui';

import 'package:caleesync/common/app_constant.dart';
import 'package:caleesync/common/utils/mmkv_utils.dart';
import 'package:caleesync/core/platform/pigeon/background_sync_api.g.dart';
import 'package:caleesync/data/database_helper.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';

import 'SyncEngine.dart';
import '../entity/sync_run_record.dart';

/// 与 iOS `CaleeSyncPeriodicWorker.CONTRACT_VERSION` 保持一致的协议版本号。
/// 如果修改了 Pigeon 定义或 Background Sync 的数据结构，需要同时更新
/// Dart 和 iOS 里的版本号。
const int kBackgroundSyncContractVersion = 1;

class BackgroundSyncWorkerBridge implements BackgroundSyncRunnerApi {
  static Future<void>? _initFuture;
  static Object? _initFailure;
  static final BackgroundSyncRunnerHostApi _runnerHostApi = BackgroundSyncRunnerHostApi();
  static bool _readyDelivered = false;
  static Completer<void>? _runStartedCompleter;
  static Completer<void>? _runFinishedCompleter;
  static bool _backgroundCycleActive = false;

  static const Duration _initTimeout = Duration(seconds: 12);
  static const Duration _readyNotifyWindow = Duration(seconds: 20);
  static const Duration _readyNotifyRetryDelay = Duration(milliseconds: 350);
  static const Duration _runStartTimeout = Duration(seconds: 20);
  static const Duration _backgroundSyncBudget = Duration(seconds: 150);
  @visibleForTesting
  static Duration runStartTimeoutForTest = _runStartTimeout;
  @visibleForTesting
  static Future<void>? runInProgressBarrierForTest;

  static Future<void> start() async {
    WidgetsFlutterBinding.ensureInitialized();
    DartPluginRegistrant.ensureInitialized();
    _prepareBackgroundCycle();
    BackgroundSyncRunnerApi.setUp(BackgroundSyncWorkerBridge());

    try {
      await _notifyReadyWithRetry();
      if (!_readyDelivered) {
        return;
      }
      await _runStartedCompleter!.future.timeout(runStartTimeoutForTest);
      await _runFinishedCompleter!.future;
    } on TimeoutException {
      _finishBackgroundCycle();
    } catch (_) {
      _finishBackgroundCycle();
      rethrow;
    } finally {
      _finishBackgroundCycle();
    }
  }

  @visibleForTesting
  static void resetForTest() {
    _initFuture = null;
    _initFailure = null;
    _readyDelivered = false;
    _runStartedCompleter = null;
    _runFinishedCompleter = null;
    _backgroundCycleActive = false;
    runStartTimeoutForTest = _runStartTimeout;
    runInProgressBarrierForTest = null;
  }

  static void _prepareBackgroundCycle() {
    _readyDelivered = false;
    _runStartedCompleter = Completer<void>();
    _runFinishedCompleter = Completer<void>();
    _backgroundCycleActive = true;
  }

  static void _finishBackgroundCycle() {
    if (_backgroundCycleActive) {
      if (!(_runStartedCompleter?.isCompleted ?? true)) {
        _runStartedCompleter!.complete();
      }
      if (!(_runFinishedCompleter?.isCompleted ?? true)) {
        _runFinishedCompleter!.complete();
      }
    }
    _backgroundCycleActive = false;
  }

  static Future<bool> _notifyReadyWithRetry() async {
    final DateTime deadline = DateTime.now().add(_readyNotifyWindow);
    while (true) {
      try {
        await _runnerHostApi.notifyBackgroundIsolateReady(kBackgroundSyncContractVersion);
        _readyDelivered = true;
        return true;
      } catch (_) {
        if (DateTime.now().isAfter(deadline)) {
          return false;
        }
        await Future<void>.delayed(_readyNotifyRetryDelay);
      }
    }
  }

  static Future<void> _ensureInitFuture() {
    return _initFuture ??= (() async {
      try {
        await _heavyInit();
        _initFailure = null;
      } catch (e) {
        _initFailure = e;
        rethrow;
      }
    })();
  }

  static Future<void> _heavyInit() async {
    await MMKVUtils.instance.init();
    await DatabaseHelper.instance.init();
  }

  @override
  Future<bool> pingBackgroundIsolate() async {
    return true;
  }

  @override
  Future<BackgroundRunResult> runBackgroundSync(BackgroundRunRequest request) async {
    final String trigger = request.trigger;
    if (!(_runStartedCompleter?.isCompleted ?? true)) {
      _runStartedCompleter!.complete();
    }

    if (runInProgressBarrierForTest != null) {
      await runInProgressBarrierForTest;
    }

    try {
      try {
        if (request.contractVersion != kBackgroundSyncContractVersion) {
          return BackgroundRunResult(
            outcome: BackgroundRunOutcome.failure,
            reason: "contract_mismatch",
            gateReason: BackgroundGateReason.unknown,
            error: "expected=${kBackgroundSyncContractVersion}, actual=${request.contractVersion}",
            contractVersion: kBackgroundSyncContractVersion,
          );
        }
        try {
          final Future<void> initFuture = _ensureInitFuture();
          await initFuture.timeout(_initTimeout);
        } on TimeoutException {
          return BackgroundRunResult(
            outcome: BackgroundRunOutcome.retry,
            reason: 'init_not_ready',
            gateReason: BackgroundGateReason.environmentBlocked,
            error: 'background_init_timeout',
            contractVersion: kBackgroundSyncContractVersion,
          );
        } catch (e) {
          return BackgroundRunResult(
            outcome: BackgroundRunOutcome.failure,
            reason: 'background_init_failed',
            gateReason: BackgroundGateReason.environmentBlocked,
            error: _initFailure?.toString() ?? e.toString(),
            contractVersion: kBackgroundSyncContractVersion,
          );
        }

        final String? loginName = MMKVUtils.instance.getString(AppConstant.loginNameKey);
        if (loginName == null || loginName.isEmpty) {
          return BackgroundRunResult(outcome: BackgroundRunOutcome.failure, reason: 'no_account', gateReason: BackgroundGateReason.authInvalid, error: 'missing_login_name', contractVersion: kBackgroundSyncContractVersion);
        }

        if (SyncEngine.isSyncInProgress) {
          return BackgroundRunResult(
            outcome: BackgroundRunOutcome.success,
            reason: 'already_syncing',
            gateReason: BackgroundGateReason.none,
            contractVersion: kBackgroundSyncContractVersion,
          );
        }

        try {
          final summary = await SyncEngine()
              .executeFullSync(
                trigger: _mapTrigger(trigger),
                waitForTurn: false,
              )
              .timeout(_backgroundSyncBudget);
          if (summary == null) {
            return BackgroundRunResult(
              outcome: BackgroundRunOutcome.success,
              reason: 'already_syncing',
              gateReason: BackgroundGateReason.none,
              contractVersion: kBackgroundSyncContractVersion,
            );
          }
          if (summary.failed == 0) {
            return BackgroundRunResult(outcome: BackgroundRunOutcome.success, reason: trigger, gateReason: BackgroundGateReason.none, contractVersion: kBackgroundSyncContractVersion);
          }
          final String details = summary.errorLog.join(';').toLowerCase();
          if (_isGate(details)) {
            return BackgroundRunResult(outcome: BackgroundRunOutcome.gated, reason: 'gated', gateReason: _classifyGate(details), error: details.isEmpty ? null : details, contractVersion: kBackgroundSyncContractVersion);
          }
          if (_isTransient(details)) {
            return BackgroundRunResult(outcome: BackgroundRunOutcome.retry, reason: details.isEmpty ? 'transient' : details, gateReason: BackgroundGateReason.none, error: details, contractVersion: kBackgroundSyncContractVersion);
          }
          return BackgroundRunResult(outcome: BackgroundRunOutcome.failure, reason: details.isEmpty ? 'sync_failed' : details, gateReason: BackgroundGateReason.none, error: details, contractVersion: kBackgroundSyncContractVersion);
        } on TimeoutException {
          return BackgroundRunResult(
            outcome: BackgroundRunOutcome.retry,
            reason: 'sync_execution_timeout',
            gateReason: BackgroundGateReason.none,
            error: 'background_sync_budget_exceeded',
            contractVersion: kBackgroundSyncContractVersion,
          );
        } on SocketException catch (e) {
          return BackgroundRunResult(outcome: BackgroundRunOutcome.retry, reason: 'socket_exception', gateReason: BackgroundGateReason.noNetwork, error: e.message, contractVersion: kBackgroundSyncContractVersion);
        } on TimeoutException catch (e) {
          return BackgroundRunResult(outcome: BackgroundRunOutcome.retry, reason: 'timeout', gateReason: BackgroundGateReason.none, error: e.message ?? 'timeout', contractVersion: kBackgroundSyncContractVersion);
        } catch (e) {
          final reason = e.toString().toLowerCase();
          if (_isGate(reason)) {
            return BackgroundRunResult(outcome: BackgroundRunOutcome.gated, reason: 'gated_exception', gateReason: _classifyGate(reason), error: reason, contractVersion: kBackgroundSyncContractVersion);
          }
          if (_isTransient(reason)) {
            return BackgroundRunResult(outcome: BackgroundRunOutcome.retry, reason: 'transient_exception', gateReason: BackgroundGateReason.none, error: reason, contractVersion: kBackgroundSyncContractVersion);
          }
          return BackgroundRunResult(outcome: BackgroundRunOutcome.failure, reason: 'exception', gateReason: BackgroundGateReason.none, error: reason, contractVersion: kBackgroundSyncContractVersion);
        }
      } catch (e) {
        return BackgroundRunResult(
          outcome: BackgroundRunOutcome.retry,
          reason: 'runner_exception',
          gateReason: BackgroundGateReason.unknown,
          error: e.toString(),
          contractVersion: kBackgroundSyncContractVersion,
        );
      }
    } finally {
      if (!(_runFinishedCompleter?.isCompleted ?? true)) {
        _runFinishedCompleter!.complete();
      }
    }
  }

  static SyncRunTrigger _mapTrigger(String trigger) {
    final normalized = trigger.toLowerCase();
    if (normalized.contains('watchdog')) return SyncRunTrigger.periodic;
    if (normalized.contains('periodic')) return SyncRunTrigger.periodic;
    if (normalized.contains('force')) return SyncRunTrigger.force;
    if (normalized.contains('auto')) return SyncRunTrigger.autoForeground;
    return SyncRunTrigger.manual;
  }

  static bool _isGate(String message) {
    return message.contains('no_network') ||
        message.contains('environment_blocked') ||
        message.contains('auth_invalid') ||
        message.contains('binding_invalid') ||
        message.contains('repair_required');
  }

  static BackgroundGateReason _classifyGate(String message) {
    if (message.contains('no_network') || message.contains('network')) return BackgroundGateReason.noNetwork;
    if (message.contains('auth_invalid') || message.contains('no_account')) return BackgroundGateReason.authInvalid;
    if (message.contains('binding_invalid')) return BackgroundGateReason.bindingInvalid;
    if (message.contains('repair_required')) return BackgroundGateReason.repairRequired;
    if (message.contains('environment_blocked')) return BackgroundGateReason.environmentBlocked;
    if (message.contains('local_calendar_missing')) return BackgroundGateReason.localCalendarMissing;
    return BackgroundGateReason.unknown;
  }

  static bool _isTransient(String message) {
    return message.contains('timeout') ||
        message.contains('socket') ||
        message.contains('network') ||
        message.contains('temporar') ||
        message.contains(' 5');
  }
}

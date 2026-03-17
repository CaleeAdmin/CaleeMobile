import 'dart:async';
import 'dart:io';
import 'dart:ui';

import 'package:caleesync/common/app_constant.dart';
import 'package:caleesync/common/utils/mmkv_utils.dart';
import 'package:caleesync/core/platform/pigeon/background_sync_api.g.dart';
import 'package:caleesync/data/database_helper.dart';
import 'package:flutter/widgets.dart';

import 'SyncEngine.dart';
import '../entity/sync_run_record.dart';

/// 与 iOS `CaleeSyncPeriodicWorker.CONTRACT_VERSION` 保持一致的协议版本号。
/// 如果修改了 Pigeon 定义或 Background Sync 的数据结构，需要同时更新
/// Dart 和 iOS 里的版本号。
const int kBackgroundSyncContractVersion = 1;

class BackgroundSyncWorkerBridge implements BackgroundSyncRunnerApi {
  static Future<void>? _initFuture;
  static final BackgroundSyncRunnerHostApi _runnerHostApi = BackgroundSyncRunnerHostApi();
  static const Duration _initTimeout = Duration(seconds: 12);
  static const Duration _readyNotifyWindow = Duration(seconds: 14);
  static const Duration _readyNotifyRetryDelay = Duration(milliseconds: 350);

  static Future<void> start() async {
    WidgetsFlutterBinding.ensureInitialized();
    DartPluginRegistrant.ensureInitialized();
    BackgroundSyncRunnerApi.setUp(BackgroundSyncWorkerBridge());
    unawaited(_notifyReadyWithRetry());
    _initFuture ??= _heavyInit();
  }

  static Future<void> _notifyReadyWithRetry() async {
    final DateTime deadline = DateTime.now().add(_readyNotifyWindow);
    while (true) {
      try {
        await _runnerHostApi.notifyBackgroundIsolateReady(kBackgroundSyncContractVersion);
        return;
      } catch (_) {
        if (DateTime.now().isAfter(deadline)) {
          return;
        }
        await Future<void>.delayed(_readyNotifyRetryDelay);
      }
    }
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
      final Future<void> initFuture = _initFuture ?? (_initFuture = _heavyInit());
      await initFuture.timeout(_initTimeout);
    } on TimeoutException {
      return BackgroundRunResult(
        outcome: BackgroundRunOutcome.retry,
        reason: 'init_not_ready',
        gateReason: BackgroundGateReason.environmentBlocked,
        error: 'background_init_timeout',
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
      final summary = await SyncEngine().executeFullSync(
        trigger: _mapTrigger(trigger),
        waitForTurn: false,
      );
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
  }

  static SyncRunTrigger _mapTrigger(String trigger) {
    final normalized = trigger.toLowerCase();
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

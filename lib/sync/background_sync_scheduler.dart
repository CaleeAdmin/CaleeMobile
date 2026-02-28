import '../common/app_constant.dart';
import '../common/utils/mmkv_utils.dart';
import '../core/platform/pigeon/background_sync_api.g.dart';

class BackgroundSyncStatus {
  const BackgroundSyncStatus({
    required this.periodicEnabled,
    required this.periodicConfigured,
    this.lastRunAt,
    this.lastResult,
    this.lastReason,
    this.lastGate,
    this.lastError,
    this.nextScheduledAt,
    this.workerRunning = false,
    this.intervalMinutes,
    this.periodicWorkState,
    this.oneOffWorkState,
    this.lastFailureStage,
    this.lastFailureElapsedMs,
    this.lastFailureStep,
  });

  final bool periodicEnabled;
  final bool periodicConfigured;
  final DateTime? lastRunAt;
  final BackgroundRunOutcome? lastResult;
  final String? lastReason;
  final BackgroundGateReason? lastGate;
  final String? lastError;
  final DateTime? nextScheduledAt;
  final bool workerRunning;
  final int? intervalMinutes;
  final String? periodicWorkState;
  final String? oneOffWorkState;
  final String? lastFailureStage;
  final int? lastFailureElapsedMs;
  final String? lastFailureStep;

  factory BackgroundSyncStatus.fromDto(BackgroundStatusDto dto) {
    DateTime? parse(int? ms) => ms == null ? null : DateTime.fromMillisecondsSinceEpoch(ms);
    return BackgroundSyncStatus(
      periodicEnabled: dto.periodicEnabled,
      periodicConfigured: dto.periodicEnabled || (MMKVUtils.instance.getBool(AppConstant.periodicSyncEnabledKey, defaultValue: false) ?? false),
      lastRunAt: parse(dto.lastRunAtMs),
      lastResult: dto.lastOutcome,
      lastReason: dto.lastReason,
      lastGate: dto.lastGateReason,
      lastError: dto.lastError,
      nextScheduledAt: parse(dto.nextScheduledAtMs),
      workerRunning: dto.workerRunning,
      intervalMinutes: dto.intervalMinutes,
      periodicWorkState: dto.periodicWorkState,
      oneOffWorkState: dto.oneOffWorkState,
      lastFailureStage: dto.lastFailureStage,
      lastFailureElapsedMs: dto.lastFailureElapsedMs,
      lastFailureStep: dto.lastFailureStep,
    );
  }
}

class BackgroundSyncScheduler {
  static final BackgroundSyncControlApi _api = BackgroundSyncControlApi();

  static Future<void> setPeriodicEnabled(bool enabled) async {
    MMKVUtils.instance.setBool(AppConstant.periodicSyncEnabledKey, enabled);
    if (enabled) {
      final int interval = MMKVUtils.instance.getInt(AppConstant.syncIntervalCalendarKey) ?? 15;
      await _api.schedulePeriodic(interval);
      return;
    }
    await _api.cancelPeriodic();
  }

  static Future<void> scheduleOneOff({
    required String reason,
    bool expedited = false,
    OneOffEnqueuePolicy policy = OneOffEnqueuePolicy.keep,
  }) {
    return _api.enqueueOneOff(reason, expedited, policy);
  }

  static Future<void> selfHealPeriodicIfNeeded() async {
    final status = await getStatus();
    final bool enabledByMmkv = MMKVUtils.instance.getBool(AppConstant.periodicSyncEnabledKey, defaultValue: false) ?? false;
    if (!status.periodicEnabled && !enabledByMmkv) {
      return;
    }
    final int interval = (MMKVUtils.instance.getInt(AppConstant.syncIntervalCalendarKey) ?? status.intervalMinutes ?? 15)
        .clamp(15, 24 * 60)
        .toInt();
    await _api.ensurePeriodicScheduled(interval);
    await _api.enqueueOneOff('repair_scheduler', false, OneOffEnqueuePolicy.replace);
  }

  static Future<BackgroundSyncStatus> getStatus() async {
    final dto = await _api.getBackgroundStatus();
    return BackgroundSyncStatus.fromDto(dto);
  }
}

import 'package:flutter/services.dart';

import '../common/app_constant.dart';
import '../common/utils/mmkv_utils.dart';

class BackgroundSyncStatus {
  const BackgroundSyncStatus({
    required this.periodicEnabled,
    required this.periodicConfigured,
    this.lastRunAt,
    this.lastResult,
    this.lastReason,
    this.nextScheduledAt,
    this.workerRunning = false,
    this.intervalMinutes,
  });

  final bool periodicEnabled;
  final bool periodicConfigured;
  final DateTime? lastRunAt;
  final String? lastResult;
  final String? lastReason;
  final DateTime? nextScheduledAt;
  final bool workerRunning;
  final int? intervalMinutes;

  factory BackgroundSyncStatus.fromMap(Map<dynamic, dynamic> map) {
    DateTime? _parse(dynamic v) => v is int ? DateTime.fromMillisecondsSinceEpoch(v) : null;
    return BackgroundSyncStatus(
      periodicEnabled: map['periodicEnabled'] == true,
      periodicConfigured: MMKVUtils.instance.getBool(AppConstant.periodicSyncEnabledKey, defaultValue: false) ?? false,
      lastRunAt: _parse(map['lastRunAtMs']),
      lastResult: map['lastResult']?.toString(),
      lastReason: map['lastReason']?.toString(),
      nextScheduledAt: _parse(map['nextScheduledAtMs']),
      workerRunning: map['workerRunning'] == true,
      intervalMinutes: (map['intervalMinutes'] as num?)?.toInt(),
    );
  }
}

class BackgroundSyncScheduler {
  static const MethodChannel _channel = MethodChannel('caleesync/background_sync');
  static const String _periodicWork = 'CaleeSyncPeriodicWorker';
  static const String _oneTimeWork = 'CaleeSyncOneTimeWorker';

  static Future<void> setPeriodicEnabled(bool enabled) async {
    MMKVUtils.instance.setBool(AppConstant.periodicSyncEnabledKey, enabled);
    if (enabled) {
      final int interval = MMKVUtils.instance.getInt(AppConstant.syncIntervalCalendarKey) ?? 15;
      await _channel.invokeMethod('schedulePeriodic', {'intervalMinutes': interval});
      return;
    }
    await _channel.invokeMethod('cancelPeriodic');
  }

  static Future<void> scheduleOneOff({required String reason, bool expedited = false}) {
    return _channel.invokeMethod('enqueueOneOff', {
      'reason': reason,
      'expedited': expedited,
      'uniqueName': _oneTimeWork,
    });
  }

  static Future<void> selfHealPeriodicIfNeeded() async {
    final bool enabled = MMKVUtils.instance.getBool(AppConstant.periodicSyncEnabledKey, defaultValue: false) ?? false;
    if (!enabled) {
      return;
    }
    final int interval = MMKVUtils.instance.getInt(AppConstant.syncIntervalCalendarKey) ?? 15;
    await _channel.invokeMethod('ensurePeriodicScheduled', {
      'intervalMinutes': interval,
      'uniqueName': _periodicWork,
    });
  }

  static Future<BackgroundSyncStatus> getStatus() async {
    final map = await _channel.invokeMethod<Map<dynamic, dynamic>>('getBackgroundStatus');
    return BackgroundSyncStatus.fromMap(map ?? const {});
  }
}

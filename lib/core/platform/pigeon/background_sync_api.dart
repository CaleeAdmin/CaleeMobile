import 'package:pigeon/pigeon.dart';

@ConfigurePigeon(PigeonOptions(
  dartOut: 'lib/core/platform/pigeon/background_sync_api.g.dart',
  dartOptions: DartOptions(),
  kotlinOut: 'android/app/src/main/kotlin/com/viso/caleesync/BackgroundSyncApi.g.kt',
  kotlinOptions: KotlinOptions(
    package: 'com.viso.caleesync',
  ),
  swiftOut: 'ios/Runner/BackgroundSyncApi.g.swift',
  swiftOptions: SwiftOptions(),
))
enum BackgroundRunOutcome {
  success,
  retry,
  failure,
  gated,
}

enum BackgroundGateReason {
  none,
  noNetwork,
  authInvalid,
  bindingInvalid,
  repairRequired,
  environmentBlocked,
  localCalendarMissing,
  unknown,
}

class BackgroundRunRequest {
  String trigger;
  int contractVersion;

  BackgroundRunRequest({
    required this.trigger,
    required this.contractVersion,
  });
}

class BackgroundRunResult {
  BackgroundRunOutcome outcome;
  String reason;
  BackgroundGateReason gateReason;
  String? error;
  int contractVersion;

  BackgroundRunResult({
    required this.outcome,
    required this.reason,
    required this.gateReason,
    this.error,
    required this.contractVersion,
  });
}

class BackgroundStatusDto {
  bool periodicEnabled;
  int? lastRunAtMs;
  BackgroundRunOutcome? lastOutcome;
  String? lastReason;
  BackgroundGateReason? lastGateReason;
  String? lastError;
  String? lastStage;
  int? lastStageAtMs;
  int? nextScheduledAtMs;
  bool workerRunning;
  int intervalMinutes;
  int contractVersion;

  BackgroundStatusDto({
    required this.periodicEnabled,
    this.lastRunAtMs,
    this.lastOutcome,
    this.lastReason,
    this.lastGateReason,
    this.lastError,
    this.lastStage,
    this.lastStageAtMs,
    this.nextScheduledAtMs,
    required this.workerRunning,
    required this.intervalMinutes,
    required this.contractVersion,
  });
}

@HostApi()
abstract class BackgroundSyncControlApi {
  @async
  void schedulePeriodic(int intervalMinutes);

  @async
  void cancelPeriodic();

  @async
  void ensurePeriodicScheduled(int intervalMinutes);

  @async
  void enqueueOneOff(String reason, bool expedited);

  @async
  BackgroundStatusDto getBackgroundStatus();
}

@HostApi()
abstract class BackgroundSyncRunnerHostApi {
  @async
  void notifyBackgroundIsolateReady(int contractVersion);
}

@FlutterApi()
abstract class BackgroundSyncRunnerApi {
  @async
  BackgroundRunResult runBackgroundSync(BackgroundRunRequest request);
}

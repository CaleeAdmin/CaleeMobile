import '../sync/sync_run_telemetry.dart';

enum SyncOutcomeStatus {
  completedNormally,
  safetyGateBlockedDeletions,
  persistentOverrideEnabled,
}

class SyncSummary {
  SyncSummary({this.telemetry});

  int total = 0;
  int success = 0;
  int failed = 0;
  int processing = 0;
  bool continuationQueued = false;
  final SyncRunTelemetry? telemetry;

  List<String> successLog = [];
  List<String> errorLog = [];

  final Map<int, SyncOutcomeStatus> bindingOutcomes = {};

  void recordBindingOutcome(int bindingId, SyncOutcomeStatus status) {
    if (bindingId <= 0) return;
    bindingOutcomes[bindingId] = status;
  }

  void reset(int count) {
    total = count;
    success = 0;
    failed = 0;
    processing = 0;
    continuationQueued = false;
    successLog.clear();
    errorLog.clear();
    bindingOutcomes.clear();
  }
}

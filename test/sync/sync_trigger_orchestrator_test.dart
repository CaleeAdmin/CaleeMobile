import 'package:caleesync/data/sync_run_store.dart';
import 'package:caleesync/entity/sync_run_record.dart';
import 'package:caleesync/sync/background_sync_scheduler.dart';
import 'package:caleesync/sync/sync_trigger_orchestrator.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

class _FakeRunStore extends SyncRunStore {
  List<SyncRunRecord> runs = [];

  @override
  Future<List<SyncRunRecord>> loadRuns({int? limit}) async {
    if (limit == null) return runs;
    return runs.take(limit).toList();
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('manual and force triggers schedule one-off with correct reason/expedited', () async {
    final calls = <Map<String, dynamic>>[];
    final runStore = _FakeRunStore();
    final orchestrator = SyncTriggerOrchestrator(
      runStore: runStore,
      scheduleOneOff: ({required reason, expedited = false}) async {
        calls.add({'reason': reason, 'expedited': expedited});
        runStore.runs = [
          SyncRunRecord(
            runId: 'run-1',
            startTime: DateTime.now(),
            endTime: DateTime.now(),
            mode: SyncRunMode.twoWay,
            appVersion: 't',
            deviceIdentifier: 'd',
          )
        ];
      },
      loadStatus: () async => const BackgroundSyncStatus(periodicEnabled: false, periodicConfigured: false, workerRunning: false),
      pollInterval: Duration.zero,
      waitTimeout: const Duration(milliseconds: 100),
      autoSyncEnabledReader: () => true,
    );

    await orchestrator.triggerManual();
    await orchestrator.triggerForce(42);

    expect(calls[0], {'reason': 'manual', 'expedited': false});
    expect(calls[1], {'reason': 'force:42', 'expedited': true});
  });

  test('auto-foreground debounces and lifecycle gates', () async {
    int scheduleCount = 0;
    final orchestrator = SyncTriggerOrchestrator(
      runStore: _FakeRunStore(),
      scheduleOneOff: ({required reason, expedited = false}) async {
        scheduleCount++;
      },
      loadStatus: () async => const BackgroundSyncStatus(periodicEnabled: false, periodicConfigured: false),
      foregroundDebounce: const Duration(milliseconds: 20),
      pollInterval: Duration.zero,
      waitTimeout: const Duration(milliseconds: 20),
      autoSyncEnabledReader: () => true,
    );

    orchestrator.didChangeAppLifecycleState(AppLifecycleState.paused);
    orchestrator.notifyMeaningfulForegroundChange();
    await Future<void>.delayed(const Duration(milliseconds: 40));
    expect(scheduleCount, 0);

    orchestrator.didChangeAppLifecycleState(AppLifecycleState.resumed);
    orchestrator.notifyMeaningfulForegroundChange();
    orchestrator.notifyMeaningfulForegroundChange();
    orchestrator.notifyMeaningfulForegroundChange();
    await Future<void>.delayed(const Duration(milliseconds: 60));
    expect(scheduleCount, 1);
  });

  test('await completion timeout returns empty summary', () async {
    final orchestrator = SyncTriggerOrchestrator(
      runStore: _FakeRunStore(),
      scheduleOneOff: ({required reason, expedited = false}) async {},
      loadStatus: () async => const BackgroundSyncStatus(periodicEnabled: false, periodicConfigured: false, workerRunning: true),
      pollInterval: const Duration(milliseconds: 10),
      waitTimeout: const Duration(milliseconds: 35),
      autoSyncEnabledReader: () => true,
    );

    final summary = await orchestrator.triggerManual();
    expect(summary.total, 0);
    expect(summary.success, 0);
    expect(summary.failed, 0);
  });
}

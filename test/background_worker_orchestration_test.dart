import 'package:caleesync/core/platform/pigeon/background_sync_api.g.dart';
import 'package:caleesync/sync/background_sync_scheduler.dart';
import 'package:caleesync/sync/background_sync_worker_bridge.dart';
import 'package:caleesync/sync/sync_completed_event_bus.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('BackgroundSyncWorkerBridge', () {
    test('returns contract mismatch failure before init/sync execution', () async {
      final bridge = BackgroundSyncWorkerBridge();

      final result = await bridge.runBackgroundSync(
        BackgroundRunRequest(trigger: 'periodic', contractVersion: -1),
      );

      expect(result.outcome, BackgroundRunOutcome.failure);
      expect(result.reason, 'contract_mismatch');
      expect(result.gateReason, BackgroundGateReason.unknown);
      expect(result.error, contains('expected='));
      expect(result.error, contains('actual=-1'));
      expect(result.contractVersion, kBackgroundSyncContractVersion);
    });
  });

  group('BackgroundSyncStatus.fromDto', () {
    test('maps dto fields into domain status', () {
      final dto = BackgroundStatusDto(
        periodicEnabled: true,
        lastRunAtMs: 1700000000000,
        lastOutcome: BackgroundRunOutcome.retry,
        lastReason: 'timeout',
        lastGateReason: BackgroundGateReason.noNetwork,
        lastError: 'socket timeout',
        lastStage: null,
        lastStageAtMs: null,
        nextScheduledAtMs: 1700000300000,
        workerRunning: true,
        intervalMinutes: 30,
        contractVersion: kBackgroundSyncContractVersion,
      );

      final status = BackgroundSyncStatus.fromDto(dto);

      expect(status.periodicEnabled, isTrue);
      expect(status.periodicConfigured, isTrue);
      expect(status.lastRunAt, DateTime.fromMillisecondsSinceEpoch(1700000000000));
      expect(status.lastResult, BackgroundRunOutcome.retry);
      expect(status.lastReason, 'timeout');
      expect(status.lastGate, BackgroundGateReason.noNetwork);
      expect(status.lastError, 'socket timeout');
      expect(status.nextScheduledAt, DateTime.fromMillisecondsSinceEpoch(1700000300000));
      expect(status.workerRunning, isTrue);
      expect(status.intervalMinutes, 30);
    });
  });

  group('SyncCompletedEventBus', () {
    test('publishes events to stream subscribers', () async {
      final expected = SyncCompletedEvent(
        runId: 'run-stream-1',
        completedAt: DateTime.parse('2025-01-01T00:00:00Z'),
      );

      final future = SyncCompletedEventBus.stream.first;
      SyncCompletedEventBus.publish(expected);
      final actual = await future;

      expect(actual.runId, expected.runId);
      expect(actual.completedAt, expected.completedAt);
    });
  });
}

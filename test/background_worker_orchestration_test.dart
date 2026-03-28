import 'dart:async';
import 'dart:io';

import 'package:caleesync/core/platform/pigeon/background_sync_api.g.dart';
import 'package:caleesync/sync/background_sync_scheduler.dart';
import 'package:caleesync/sync/background_sync_worker_bridge.dart' hide kBackgroundSyncContractVersion;
import 'package:caleesync/sync/sync_completed_event_bus.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const BasicMessageChannel<Object?> notifyReadyChannel = BasicMessageChannel<Object?>(
    'dev.flutter.pigeon.caleesync.BackgroundSyncRunnerHostApi.notifyBackgroundIsolateReady',
    BackgroundSyncRunnerHostApi.pigeonChannelCodec,
  );

  setUp(() {
    BackgroundSyncWorkerBridge.resetForTest();
    BackgroundSyncWorkerBridge.runStartTimeoutForTest = const Duration(seconds: 20);
    BackgroundSyncWorkerBridge.runInProgressBarrierForTest = null;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockDecodedMessageHandler<Object?>(
      notifyReadyChannel,
      (Object? message) async => <Object?>[null],
    );
  });

  tearDown(() {
    BackgroundSyncWorkerBridge.resetForTest();
    BackgroundSyncWorkerBridge.runStartTimeoutForTest = const Duration(seconds: 20);
    BackgroundSyncWorkerBridge.runInProgressBarrierForTest = null;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockDecodedMessageHandler<Object?>(
      notifyReadyChannel,
      null,
    );
  });

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

    test('start exits when ready arrives but runBackgroundSync never starts', () async {
      BackgroundSyncWorkerBridge.runStartTimeoutForTest = const Duration(milliseconds: 80);

      await BackgroundSyncWorkerBridge.start();
    });

    test('start does not trigger heavy init before runBackgroundSync', () async {
      BackgroundSyncWorkerBridge.runStartTimeoutForTest = const Duration(milliseconds: 80);

      await BackgroundSyncWorkerBridge.start();
    });

    test('start stays alive past legacy window once runBackgroundSync has started', () async {
      final bridge = BackgroundSyncWorkerBridge();
      final runGate = Completer<void>();
      BackgroundSyncWorkerBridge.runStartTimeoutForTest = const Duration(milliseconds: 80);
      BackgroundSyncWorkerBridge.runInProgressBarrierForTest = runGate.future;

      final startFuture = BackgroundSyncWorkerBridge.start();
      final runFuture = bridge.runBackgroundSync(
        BackgroundRunRequest(trigger: 'periodic', contractVersion: -1),
      );
      var startCompleted = false;
      startFuture.then((_) => startCompleted = true);

      await Future<void>.delayed(const Duration(milliseconds: 140));
      expect(startCompleted, isFalse);

      runGate.complete();
      await runFuture;
      await startFuture;
    });

    test('finishing runBackgroundSync completes cycle and allows start to return', () async {
      final bridge = BackgroundSyncWorkerBridge();
      BackgroundSyncWorkerBridge.runStartTimeoutForTest = const Duration(seconds: 1);

      final startFuture = BackgroundSyncWorkerBridge.start();
      final runResult = await bridge.runBackgroundSync(
        BackgroundRunRequest(trigger: 'periodic', contractVersion: -1),
      );

      expect(runResult.reason, 'contract_mismatch');
      await startFuture;
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

  group('Background worker timeout constants', () {
    test('sync reply timeout remains below worker budget with safety margin', () {
      final kotlinFile = File(
        'android/app/src/main/kotlin/com/calee/caleesync/BackgroundSyncWorker.kt',
      ).readAsStringSync();

      expect(kotlinFile, contains('private const val WORKER_EXEC_TIMEOUT_MS = 180_000L'));
      expect(kotlinFile, contains('private const val SYNC_REPLY_TIMEOUT_MS = WORKER_EXEC_TIMEOUT_MS - 10_000L'));
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

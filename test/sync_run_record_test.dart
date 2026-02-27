import 'package:caleesync/entity/sync_run_record.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('SyncRunRecord serialization', () {
    test('round-trips run record with nested binding', () {
      final record = SyncRunRecord(
        runId: 'run-001',
        startTime: DateTime.parse('2025-01-01T10:00:00Z'),
        endTime: DateTime.parse('2025-01-01T10:00:10Z'),
        durationMs: 10000,
        mode: SyncRunMode.twoWay,
        appVersion: '1.0.0',
        deviceIdentifier: 'device-123',
        trigger: SyncRunTrigger.periodic,
        result: SyncRunResult.partial,
        bindings: [
          SyncBindingRunRecord(
            bindingIdentifier: 'binding-a',
            accountIdentifier: 'account-a',
            snapshotTrustStatus: SnapshotTrustStatus.remote,
            safetyGateTriggered: true,
            resultStatus: SyncBindingResultStatus.partial,
            localCounts: SyncChangeCounts(created: 1, updated: 2, deleted: 3),
            remoteCounts: SyncChangeCounts(created: 4, updated: 5, deleted: 6),
            errorCode: SyncErrorCode.permissionDenied,
            errorMessage: 'Permission required',
            technicalDetail: 'calendar permission denied',
            startedAt: DateTime.parse('2025-01-01T10:00:01Z'),
            endedAt: DateTime.parse('2025-01-01T10:00:09Z'),
          ),
        ],
      );

      final deserialized = SyncRunRecord.fromJson(record.toJson());

      expect(deserialized.runId, record.runId);
      expect(deserialized.mode, SyncRunMode.twoWay);
      expect(deserialized.result, SyncRunResult.partial);
      expect(deserialized.trigger, SyncRunTrigger.periodic);
      expect(deserialized.bindings, hasLength(1));

      final binding = deserialized.bindings.first;
      expect(binding.bindingIdentifier, 'binding-a');
      expect(binding.snapshotTrustStatus, SnapshotTrustStatus.remote);
      expect(binding.localCounts.created, 1);
      expect(binding.remoteCounts.deleted, 6);
      expect(binding.errorCode, SyncErrorCode.permissionDenied);
      expect(binding.errorMessage, 'Permission required');
    });

    test('falls back to safe defaults for invalid enum values', () {
      final deserialized = SyncRunRecord.fromJson({
        'runId': 'run-invalid',
        'startTime': 'not-a-date',
        'mode': 'invalid-mode',
        'result': 'invalid-result',
        'trigger': 'invalid-trigger',
        'bindings': [
          {
            'bindingIdentifier': 'binding-b',
            'accountIdentifier': 'account-b',
            'snapshotTrustStatus': 'invalid',
            'resultStatus': 'invalid',
            'errorCode': 'invalid',
          }
        ],
      });

      expect(deserialized.startTime, DateTime.fromMillisecondsSinceEpoch(0));
      expect(deserialized.mode, SyncRunMode.twoWay);
      expect(deserialized.result, SyncRunResult.failed);
      expect(deserialized.trigger, SyncRunTrigger.manual);
      expect(deserialized.bindings.first.snapshotTrustStatus, SnapshotTrustStatus.unknown);
      expect(deserialized.bindings.first.resultStatus, SyncBindingResultStatus.success);
      expect(deserialized.bindings.first.errorCode, isNull);
    });
  });
}

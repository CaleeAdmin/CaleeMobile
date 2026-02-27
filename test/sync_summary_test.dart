import 'package:caleesync/entity/SyncSummary.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('SyncSummary', () {
    test('recordBindingOutcome ignores invalid binding ids', () {
      final summary = SyncSummary();

      summary.recordBindingOutcome(0, SyncOutcomeStatus.completedNormally);
      summary.recordBindingOutcome(-1, SyncOutcomeStatus.completedNormally);

      expect(summary.bindingOutcomes, isEmpty);
    });

    test('recordBindingOutcome stores valid binding ids', () {
      final summary = SyncSummary();

      summary.recordBindingOutcome(10, SyncOutcomeStatus.safetyGateBlockedDeletions);

      expect(summary.bindingOutcomes[10], SyncOutcomeStatus.safetyGateBlockedDeletions);
    });

    test('reset clears counters and logs', () {
      final summary = SyncSummary();
      summary.total = 5;
      summary.success = 3;
      summary.failed = 2;
      summary.processing = 1;
      summary.successLog.add('ok');
      summary.errorLog.add('err');
      summary.recordBindingOutcome(22, SyncOutcomeStatus.persistentOverrideEnabled);

      summary.reset(7);

      expect(summary.total, 7);
      expect(summary.success, 0);
      expect(summary.failed, 0);
      expect(summary.processing, 0);
      expect(summary.successLog, isEmpty);
      expect(summary.errorLog, isEmpty);
      expect(summary.bindingOutcomes, isEmpty);
    });
  });
}

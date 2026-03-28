import 'package:caleesync/entity/SyncContext.dart';
import 'package:caleesync/entity/SyncSummary.dart';
import 'package:caleesync/sync/strategy/SyncStrategy.dart';
import 'package:flutter_test/flutter_test.dart';

class _ChunkingStrategyProbe extends SyncStrategy {
  @override
  Future<void> execute(SyncContext ctx, SyncSummary summary) async {}
}

void main() {
  group('_selectPlanBatch', () {
    test('never splits plans and stops before exceeding budget', () {
      final probe = _ChunkingStrategyProbe();

      final selected = probe.selectPlanBatchSizesForTest(
        <int>[40, 30, 60],
        maxOperations: 100,
      );

      expect(selected, <int>[0, 1]);
    });

    test('includes first oversized plan', () {
      final probe = _ChunkingStrategyProbe();

      final selected = probe.selectPlanBatchSizesForTest(
        <int>[130, 10, 10],
        maxOperations: 120,
      );

      expect(selected, <int>[0]);
    });

    test('returns full list for small plan list', () {
      final probe = _ChunkingStrategyProbe();

      final selected = probe.selectPlanBatchSizesForTest(
        <int>[20, 20, 20],
        maxOperations: 120,
      );

      expect(selected, <int>[0, 1, 2]);
    });
  });
}

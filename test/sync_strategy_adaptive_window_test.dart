import 'package:caleesync/sync/strategy/SyncStrategy.dart';
import 'package:caleesync/entity/SyncContext.dart';
import 'package:caleesync/entity/SyncSummary.dart';
import 'package:flutter_test/flutter_test.dart';


class _TestSyncStrategy extends SyncStrategy {
  @override
  Future<void> execute(SyncContext ctx, SyncSummary summary) async {}
}

void main() {
  group('SyncStrategy adaptive local fetch window', () {

    test('uses fallback window when no usable timestamps exist', () {
      final now = DateTime.utc(2026, 1, 1);
      final strategy = _TestSyncStrategy();
      final window = strategy.computeAdaptiveLocalFetchWindow(
        remoteEvents: const [],
        mappedRecords: const [],
        now: now,
      );

      final expectedStart = now.subtract(const Duration(days: 365 * 2)).millisecondsSinceEpoch;
      final expectedEnd = now.add(const Duration(days: 365 * 3)).millisecondsSinceEpoch;
      expect(window.rangeStartMs, expectedStart);
      expect(window.rangeEndMs, expectedEnd);
    });

    test('builds from remote and mapped ranges with padding', () {
      final strategy = _TestSyncStrategy();
      final window = strategy.computeAdaptiveLocalFetchWindow(
        remoteEvents: [
          {'dtstart': DateTime.utc(2020, 1, 10).millisecondsSinceEpoch},
          {'dtend': DateTime.utc(2020, 2, 10).millisecondsSinceEpoch},
        ],
        mappedRecords: [
          {'dtstart': DateTime.utc(2020, 3, 1).millisecondsSinceEpoch},
          {'dtend': DateTime.utc(2020, 3, 20).millisecondsSinceEpoch},
        ],
      );

      final minTs = DateTime.utc(2020, 1, 10).millisecondsSinceEpoch;
      final maxTs = DateTime.utc(2020, 3, 20).millisecondsSinceEpoch;
      expect(window.rangeStartMs, minTs - const Duration(days: 30).inMilliseconds);
      expect(window.rangeEndMs, maxTs + const Duration(days: 30).inMilliseconds);
    });

    test('clamps very large spans', () {
      final strategy = _TestSyncStrategy();
      final window = strategy.computeAdaptiveLocalFetchWindow(
        remoteEvents: [
          {'dtstart': DateTime.utc(2000, 1, 1).millisecondsSinceEpoch},
        ],
        mappedRecords: [
          {'dtend': DateTime.utc(2050, 1, 1).millisecondsSinceEpoch},
        ],
      );

      final span = window.rangeEndMs - window.rangeStartMs;
      expect(span <= const Duration(days: 365 * 8).inMilliseconds, isTrue);
    });
  });
}

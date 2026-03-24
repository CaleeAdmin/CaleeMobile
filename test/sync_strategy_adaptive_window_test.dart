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
      final now = DateTime.utc(2026, 1, 1);
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
        now: now,
      );

      final historicalMinTs = DateTime.utc(2020, 1, 10).millisecondsSinceEpoch;
      final historicalMaxTs = DateTime.utc(2020, 3, 20).millisecondsSinceEpoch;
      final historicalStart = historicalMinTs - const Duration(days: 30).inMilliseconds;
      final historicalEnd = historicalMaxTs + const Duration(days: 30).inMilliseconds;
      final liveStart = now.subtract(const Duration(days: 365)).millisecondsSinceEpoch;
      final liveEnd = now.add(const Duration(days: 730)).millisecondsSinceEpoch;

      expect(window.rangeStartMs, historicalStart < liveStart ? historicalStart : liveStart);
      expect(window.rangeEndMs, historicalEnd > liveEnd ? historicalEnd : liveEnd);
    });

    test('clamps very large spans', () {
      final now = DateTime.utc(2026, 1, 1);
      final strategy = _TestSyncStrategy();
      final window = strategy.computeAdaptiveLocalFetchWindow(
        remoteEvents: [
          {'dtstart': DateTime.utc(2000, 1, 1).millisecondsSinceEpoch},
        ],
        mappedRecords: [
          {'dtend': DateTime.utc(2050, 1, 1).millisecondsSinceEpoch},
        ],
        now: now,
      );

      final span = window.rangeEndMs - window.rangeStartMs;
      expect(span <= const Duration(days: 365 * 8).inMilliseconds, isTrue);
      expect(window.rangeStartMs <= now.subtract(const Duration(days: 365)).millisecondsSinceEpoch, isTrue);
      expect(window.rangeEndMs >= now.add(const Duration(days: 730)).millisecondsSinceEpoch, isTrue);
    });

    test('long history cannot exclude present or future live window events', () {
      final now = DateTime.utc(2026, 3, 24);
      final strategy = _TestSyncStrategy();
      final window = strategy.computeAdaptiveLocalFetchWindow(
        remoteEvents: [
          {
            'dtstart': DateTime.utc(2012, 1, 1).millisecondsSinceEpoch,
            'dtend': DateTime.utc(2012, 1, 2).millisecondsSinceEpoch,
          },
          {
            'dtstart': DateTime.utc(2027, 12, 1).millisecondsSinceEpoch,
            'dtend': DateTime.utc(2027, 12, 2).millisecondsSinceEpoch,
          },
        ],
        mappedRecords: [
          {
            'dtstart': DateTime.utc(2013, 6, 1).millisecondsSinceEpoch,
            'dtend': DateTime.utc(2013, 6, 2).millisecondsSinceEpoch,
          },
          {
            'dtstart': DateTime.utc(2026, 2, 1).millisecondsSinceEpoch,
            'dtend': DateTime.utc(2026, 2, 2).millisecondsSinceEpoch,
          },
        ],
        now: now,
      );

      final nowMs = now.millisecondsSinceEpoch;
      final liveStartMs = now.subtract(const Duration(days: 365)).millisecondsSinceEpoch;
      final liveEndMs = now.add(const Duration(days: 730)).millisecondsSinceEpoch;
      final localOnlyEventMs = DateTime.utc(2026, 3, 24).millisecondsSinceEpoch;

      expect(window.rangeStartMs <= nowMs, isTrue);
      expect(window.rangeEndMs >= nowMs, isTrue);
      expect(window.rangeStartMs <= localOnlyEventMs, isTrue);
      expect(window.rangeEndMs >= localOnlyEventMs, isTrue);
      expect(window.rangeStartMs <= liveStartMs, isTrue);
      expect(window.rangeEndMs >= liveEndMs, isTrue);
    });

    test('preserves live window even when historical window is clamped away from now', () {
      final now = DateTime.utc(2026, 3, 24);
      final strategy = _TestSyncStrategy();
      final window = strategy.computeAdaptiveLocalFetchWindow(
        remoteEvents: [
          {'dtstart': DateTime.utc(1900, 1, 1).millisecondsSinceEpoch},
          {'dtend': DateTime.utc(1910, 1, 1).millisecondsSinceEpoch},
        ],
        mappedRecords: const [],
        now: now,
      );

      final liveStartMs = now.subtract(const Duration(days: 365)).millisecondsSinceEpoch;
      final liveEndMs = now.add(const Duration(days: 730)).millisecondsSinceEpoch;

      expect(window.rangeStartMs <= liveStartMs, isTrue);
      expect(window.rangeEndMs >= liveEndMs, isTrue);
      expect(window.rangeStartMs <= now.millisecondsSinceEpoch, isTrue);
      expect(window.rangeEndMs >= now.millisecondsSinceEpoch, isTrue);
    });
  });
}

import 'package:caleesync/sync/strategy/SyncStrategy.dart';
import 'package:caleesync/entity/SyncContext.dart';
import 'package:caleesync/entity/SyncSummary.dart';
import 'package:flutter_test/flutter_test.dart';

class _TestSyncStrategy extends SyncStrategy {
  @override
  Future<void> execute(SyncContext ctx, SyncSummary summary) async {}
}

void main() {
  group('Delete inference completeness gate', () {
    test('disables delete inference when mapped local ids are missing from system scan', () {
      final strategy = _TestSyncStrategy();
      const snapshot = LocalEventsSnapshot(
        events: [],
        rangeStartMs: 100,
        rangeEndMs: 200,
        rangedSystemIds: {'local-1'},
        snapshotCoverageComplete: true,
        canInferDeletesFromLocalAbsence: true,
      );
      const window = AdaptiveLocalFetchWindow(
        rangeStartMs: 100,
        rangeEndMs: 200,
        wasClamped: false,
      );

      final assessment = strategy.assessDeleteInferenceAuthority(
        localSnapshot: snapshot,
        mappedRecords: const [
          {
            'remote_uid': 'uid-1',
            'local_item_id': 'local-1',
            'dtstart': 120,
            'dtend': 150,
          },
          {
            'remote_uid': 'uid-2',
            'local_item_id': 'local-2',
            'dtstart': 130,
            'dtend': 160,
          },
        ],
        window: window,
      );

      expect(assessment.canDeleteRemoteFromMissingLocal, isFalse);
      expect(assessment.disableReasons.contains('mapped_ids_missing_from_system_scan'), isTrue);
      expect(assessment.mappedInWindowLocalIds.length, 2);
      expect(assessment.missingMappedLocalIds, {'local-2'});
    });

    test('flags mapped history outside clamped window for per-uid delete gating', () {
      final strategy = _TestSyncStrategy();
      const snapshot = LocalEventsSnapshot(
        events: [],
        rangeStartMs: 100,
        rangeEndMs: 200,
        rangedSystemIds: {'local-in-window'},
        snapshotCoverageComplete: true,
        canInferDeletesFromLocalAbsence: true,
      );
      const window = AdaptiveLocalFetchWindow(
        rangeStartMs: 100,
        rangeEndMs: 200,
        wasClamped: true,
      );

      final assessment = strategy.assessDeleteInferenceAuthority(
        localSnapshot: snapshot,
        mappedRecords: const [
          {
            'remote_uid': 'uid-in-window',
            'local_item_id': 'local-in-window',
            'dtstart': 110,
            'dtend': 120,
          },
          {
            'remote_uid': 'uid-history',
            'local_item_id': 'local-history',
            'dtstart': 10,
            'dtend': 20,
          },
        ],
        window: window,
      );

      expect(assessment.canDeleteRemoteFromMissingLocal, isTrue);
      expect(assessment.disableReasons.contains('window_clamped'), isTrue);
      expect(assessment.mappedOutsideWindowUids, {'uid-history'});
    });

    test('keeps delete inference enabled for complete window coverage', () {
      final strategy = _TestSyncStrategy();
      const snapshot = LocalEventsSnapshot(
        events: [],
        rangeStartMs: 100,
        rangeEndMs: 200,
        rangedSystemIds: {'local-1', 'local-2'},
        snapshotCoverageComplete: true,
        canInferDeletesFromLocalAbsence: true,
      );
      const window = AdaptiveLocalFetchWindow(
        rangeStartMs: 100,
        rangeEndMs: 200,
        wasClamped: false,
      );

      final assessment = strategy.assessDeleteInferenceAuthority(
        localSnapshot: snapshot,
        mappedRecords: const [
          {
            'remote_uid': 'uid-1',
            'local_item_id': 'local-1',
            'dtstart': 120,
            'dtend': 150,
          },
          {
            'remote_uid': 'uid-2',
            'local_item_id': 'local-2',
            'dtstart': 130,
            'dtend': 160,
          },
        ],
        window: window,
      );

      expect(assessment.canDeleteRemoteFromMissingLocal, isTrue);
      expect(assessment.disableReasons, isEmpty);
      expect(assessment.missingMappedLocalIds, isEmpty);
      expect(assessment.mappedOutsideWindowUids, isEmpty);
    });
  });
}

import 'package:calee_mobile/data/models/calendar_reminder_manifest.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('CalendarReminderManifestEntry', () {
    test('round-trips with a fingerprint', () {
      const entry = CalendarReminderManifestEntry(
        notificationId: 42,
        fingerprint: 'abc123',
      );
      final restored = CalendarReminderManifestEntry.tryFromJson(
        entry.toJson(),
      );
      expect(restored, isNotNull);
      expect(restored!.notificationId, 42);
      expect(restored.fingerprint, 'abc123');
    });

    test('omits the fingerprint key when null', () {
      const entry = CalendarReminderManifestEntry(
        notificationId: 7,
        fingerprint: null,
      );
      expect(entry.toJson().containsKey('fp'), isFalse);
      final restored = CalendarReminderManifestEntry.tryFromJson(
        entry.toJson(),
      );
      expect(restored!.fingerprint, isNull);
    });

    test('tryFromJson returns null without a usable id', () {
      expect(CalendarReminderManifestEntry.tryFromJson({'fp': 'x'}), isNull);
      expect(
        CalendarReminderManifestEntry.tryFromJson({'id': 'not-int'}),
        isNull,
      );
    });
  });

  group('CalendarReminderManifest — current (v2) schema', () {
    test('round-trips entries through JSON', () {
      final manifest = CalendarReminderManifest(
        version: CalendarReminderManifest.currentVersion,
        entries: const [
          CalendarReminderManifestEntry(notificationId: 1, fingerprint: 'aa'),
          CalendarReminderManifestEntry(notificationId: 2, fingerprint: null),
        ],
        lastReconciledAt: DateTime.utc(2026, 7, 4, 12),
      );

      final restored = CalendarReminderManifest.fromJson(manifest.toJson());

      expect(restored.version, CalendarReminderManifest.currentVersion);
      expect(restored.scheduledIds, [1, 2]);
      expect(restored.entryFor(1)!.fingerprint, 'aa');
      expect(restored.entryFor(2)!.fingerprint, isNull);
      expect(restored.lastReconciledAt, DateTime.utc(2026, 7, 4, 12));
    });

    test('empty manifest has no entries and reports the current version', () {
      expect(CalendarReminderManifest.empty.entries, isEmpty);
      expect(CalendarReminderManifest.empty.scheduledIds, isEmpty);
      expect(CalendarReminderManifest.empty.isEmpty, isTrue);
      expect(
        CalendarReminderManifest.empty.version,
        CalendarReminderManifest.currentVersion,
      );
    });

    test('the persisted version is always the current version', () {
      final json = CalendarReminderManifest.fromIds([1, 2, 3]).toJson();
      expect(json['version'], CalendarReminderManifest.currentVersion);
    });

    test('omits lastReconciledAt from JSON when null', () {
      final json = CalendarReminderManifest.empty.toJson();
      expect(json.containsKey('lastReconciledAt'), isFalse);
    });

    test('skips malformed entries without inventing ownership', () {
      final restored = CalendarReminderManifest.fromJson({
        'version': 2,
        'entries': [
          {'id': 10, 'fp': 'a'},
          {'fp': 'no-id'},
          'garbage',
          {'id': 11},
        ],
      });
      expect(restored.scheduledIds, [10, 11]);
    });
  });

  group('CalendarReminderManifest — legacy (v1) migration', () {
    test('preserves ownership of all legacy IDs (never treated as empty)', () {
      final restored = CalendarReminderManifest.fromJson({
        'version': 1,
        'ids': [1, 2, 3],
      });

      expect(restored.scheduledIds, [1, 2, 3]);
      // Migrated entries carry no fingerprint yet, so reconciliation will
      // re-schedule each still-desired one once to gain a fingerprint.
      for (final entry in restored.entries) {
        expect(entry.fingerprint, isNull);
      }
      // In-memory the manifest is already upgraded to the current version, so
      // the next persist writes the v2 schema.
      expect(restored.version, CalendarReminderManifest.currentVersion);
    });

    test(
      'a legacy manifest with a garbage ids field is empty, not a crash',
      () {
        expect(
          CalendarReminderManifest.fromJson({
            'version': 1,
            'ids': 'not-a-list',
          }).scheduledIds,
          isEmpty,
        );
      },
    );
  });

  group('CalendarReminderManifest — unknown/newer version', () {
    test('conservatively recovers parseable IDs rather than discarding', () {
      // A future build may store a schema we do not fully understand; we must
      // still retain ownership of any IDs we can parse so nothing is orphaned.
      final restored = CalendarReminderManifest.fromJson({
        'version': 999,
        'ids': [1, 2, 3],
      });
      expect(restored.scheduledIds, containsAll(<int>[1, 2, 3]));
    });

    test('recovers IDs from a future entries-style schema too', () {
      final restored = CalendarReminderManifest.fromJson({
        'version': 999,
        'entries': [
          {'id': 5, 'fp': 'future'},
          {'id': 6},
        ],
      });
      expect(restored.scheduledIds, containsAll(<int>[5, 6]));
    });

    test('unparseable unknown-version data collapses to empty safely', () {
      final restored = CalendarReminderManifest.fromJson({'version': 999});
      expect(restored.scheduledIds, isEmpty);
    });
  });
}

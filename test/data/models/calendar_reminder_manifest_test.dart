import 'package:calee_mobile/data/models/calendar_reminder_manifest.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('CalendarReminderManifest', () {
    test('round-trips through JSON', () {
      final manifest = CalendarReminderManifest(
        version: CalendarReminderManifest.currentVersion,
        scheduledIds: [1, 2, 3],
        lastReconciledAt: DateTime.utc(2026, 7, 4, 12),
      );

      final restored = CalendarReminderManifest.fromJson(manifest.toJson());

      expect(restored.version, CalendarReminderManifest.currentVersion);
      expect(restored.scheduledIds, [1, 2, 3]);
      expect(restored.lastReconciledAt, DateTime.utc(2026, 7, 4, 12));
    });

    test('empty manifest has no scheduled ids', () {
      expect(CalendarReminderManifest.empty.scheduledIds, isEmpty);
      expect(
        CalendarReminderManifest.empty.version,
        CalendarReminderManifest.currentVersion,
      );
    });

    test('an unknown version is treated as empty (safe reset)', () {
      final restored = CalendarReminderManifest.fromJson({
        'version': 999,
        'ids': [1, 2, 3],
      });

      expect(restored.scheduledIds, isEmpty);
      expect(restored.version, CalendarReminderManifest.currentVersion);
    });

    test('tolerates a missing/garbage ids field', () {
      expect(
        CalendarReminderManifest.fromJson({
          'version': CalendarReminderManifest.currentVersion,
        }).scheduledIds,
        isEmpty,
      );
      expect(
        CalendarReminderManifest.fromJson({
          'version': CalendarReminderManifest.currentVersion,
          'ids': 'not-a-list',
        }).scheduledIds,
        isEmpty,
      );
    });

    test('omits lastReconciledAt from JSON when null', () {
      final json = CalendarReminderManifest.empty.toJson();
      expect(json.containsKey('lastReconciledAt'), isFalse);
    });
  });
}

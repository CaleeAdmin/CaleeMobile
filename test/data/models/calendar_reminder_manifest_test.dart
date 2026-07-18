import 'package:calee_mobile/data/models/calendar_reminder_manifest.dart';
import 'package:flutter_test/flutter_test.dart';

// 64-char lowercase-hex, SHA-256-shaped digests used for v4 (current-schema)
// fixtures. v4 trusts a fingerprint/owner only when it matches this format.
final _fp1 = 'a1' * 32;
final _fp2 = 'b2' * 32;
final _owner1 = 'c3' * 32;
final _owner2 = 'd4' * 32;

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

  group('CalendarReminderManifest — current (v4) schema', () {
    test('round-trips entries through JSON', () {
      final manifest = CalendarReminderManifest(
        version: CalendarReminderManifest.currentVersion,
        entries: [
          CalendarReminderManifestEntry(notificationId: 1, fingerprint: _fp1),
          const CalendarReminderManifestEntry(
            notificationId: 2,
            fingerprint: null,
          ),
        ],
        lastReconciledAt: DateTime.utc(2026, 7, 4, 12),
      );

      final restored = CalendarReminderManifest.fromJson(manifest.toJson());

      expect(restored.version, CalendarReminderManifest.currentVersion);
      expect(restored.scheduledIds, [1, 2]);
      expect(restored.entryFor(1)!.fingerprint, _fp1);
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

  group('CalendarReminderManifestEntry — owner + copyWith', () {
    test('round-trips an owner key through JSON', () {
      const entry = CalendarReminderManifestEntry(
        notificationId: 5,
        fingerprint: 'fp',
        ownerKey: 'ownerA',
      );
      final restored = CalendarReminderManifestEntry.tryFromJson(
        entry.toJson(),
      );
      expect(restored!.notificationId, 5);
      expect(restored.fingerprint, 'fp');
      expect(restored.ownerKey, 'ownerA');
    });

    test('omits the owner key from JSON when null', () {
      const entry = CalendarReminderManifestEntry(
        notificationId: 5,
        fingerprint: 'fp',
      );
      expect(entry.toJson().containsKey('owner'), isFalse);
      expect(
        CalendarReminderManifestEntry.tryFromJson(entry.toJson())!.ownerKey,
        isNull,
      );
    });

    test('copyWith can explicitly clear the fingerprint and owner', () {
      const entry = CalendarReminderManifestEntry(
        notificationId: 5,
        fingerprint: 'fp',
        ownerKey: 'ownerA',
      );
      final clearedFp = entry.copyWith(clearFingerprint: true);
      expect(clearedFp.fingerprint, isNull);
      expect(clearedFp.ownerKey, 'ownerA', reason: 'owner untouched');

      final clearedOwner = entry.copyWith(clearOwnerKey: true);
      expect(clearedOwner.ownerKey, isNull);
      expect(clearedOwner.fingerprint, 'fp', reason: 'fingerprint untouched');

      final replaced = entry.copyWith(fingerprint: 'fp2', ownerKey: 'ownerB');
      expect(replaced.fingerprint, 'fp2');
      expect(replaced.ownerKey, 'ownerB');
    });
  });

  group('CalendarReminderManifest — v4 schema and legacy migration', () {
    test('round-trips v4 entries with SHA-256 owners through JSON', () {
      final manifest = CalendarReminderManifest(
        version: CalendarReminderManifest.currentVersion,
        entries: [
          CalendarReminderManifestEntry(
            notificationId: 1,
            fingerprint: _fp1,
            ownerKey: _owner1,
          ),
        ],
      );
      final restored = CalendarReminderManifest.parse(manifest.toJson());
      expect(restored.status, CalendarReminderManifestLoadStatus.loaded);
      expect(restored.manifest.entryFor(1)!.ownerKey, _owner1);
      expect(restored.manifest.entryFor(1)!.fingerprint, _fp1);
      expect(manifest.toJson()['version'], 4);
    });

    test('v1 migration yields null fingerprint and null owner', () {
      final result = CalendarReminderManifest.parse({
        'version': 1,
        'ids': [1, 2],
      });
      expect(result.status, CalendarReminderManifestLoadStatus.recovered);
      for (final entry in result.manifest.entries) {
        expect(entry.fingerprint, isNull);
        expect(entry.ownerKey, isNull);
      }
    });

    test('v2 migration retains IDs but drops the now-untrusted FNV '
        'fingerprints', () {
      final result = CalendarReminderManifest.parse({
        'version': 2,
        'entries': [
          {'id': 1, 'fp': 'aa'},
        ],
      });
      expect(result.status, CalendarReminderManifestLoadStatus.recovered);
      expect(result.manifest.scheduledIds, [1]);
      expect(
        result.manifest.entryFor(1)!.fingerprint,
        isNull,
        reason: 'a v2 (FNV) fingerprint is not trusted as a v4 SHA-256 digest',
      );
      expect(result.manifest.entryFor(1)!.ownerKey, isNull);
    });

    test('v3 migration retains IDs but drops the now-untrusted FNV owner and '
        'fingerprint', () {
      final result = CalendarReminderManifest.parse({
        'version': 3,
        'entries': [
          {'id': 1, 'fp': 'fnv-fp', 'owner': 'fnv-owner'},
        ],
      });
      expect(result.status, CalendarReminderManifestLoadStatus.recovered);
      expect(result.manifest.scheduledIds, [1]);
      expect(
        result.manifest.entryFor(1)!.fingerprint,
        isNull,
        reason: 'v3 FNV fingerprints are not trusted as v4 values',
      );
      expect(
        result.manifest.entryFor(1)!.ownerKey,
        isNull,
        reason: 'v3 FNV owner keys are not trusted as v4 values',
      );
    });
  });

  group('CalendarReminderManifest.parse — status classification', () {
    test('absent when the decoded value is null', () {
      final result = CalendarReminderManifest.parse(null);
      expect(result.status, CalendarReminderManifestLoadStatus.absent);
      expect(result.manifest.isEmpty, isTrue);
    });

    test('corrupt when the top-level value is not an object', () {
      expect(
        CalendarReminderManifest.parse('a string').status,
        CalendarReminderManifestLoadStatus.corrupt,
      );
      expect(
        CalendarReminderManifest.parse([1, 2, 3]).status,
        CalendarReminderManifestLoadStatus.corrupt,
      );
    });

    test('loaded for a valid (even empty) current-schema manifest', () {
      expect(
        CalendarReminderManifest.parse({'version': 4, 'entries': []}).status,
        CalendarReminderManifestLoadStatus.loaded,
      );
    });

    test('corrupt when a current-version value has no entries list', () {
      // Our writer always emits an entries list; its absence means malformed.
      final result = CalendarReminderManifest.parse({
        'version': 4,
        'entries': 'garbage',
      });
      expect(result.status, CalendarReminderManifestLoadStatus.corrupt);
    });

    test('recovered preserves valid IDs from partially malformed data', () {
      final result = CalendarReminderManifest.parse({
        'version': 2,
        'entries': [
          {'id': 10, 'fp': 'a'},
          {'fp': 'no-id'},
          'garbage',
          {'id': 11},
        ],
      });
      expect(result.status, CalendarReminderManifestLoadStatus.recovered);
      expect(result.manifest.scheduledIds, [10, 11]);
    });
  });

  group('CalendarReminderManifest.parse — safe field parsing', () {
    test('a string version does not crash and recovers IDs', () {
      final result = CalendarReminderManifest.parse({
        'version': 'not-a-number',
        'ids': [1, 2],
      });
      expect(result.manifest.scheduledIds, [1, 2]);
    });

    test('a floating-point version does not crash', () {
      // 4.0 coerces to the current version; a non-whole float is unknown.
      expect(
        CalendarReminderManifest.parse({'version': 4.0, 'entries': []}).status,
        CalendarReminderManifestLoadStatus.loaded,
      );
      expect(
        () => CalendarReminderManifest.parse({
          'version': 4.5,
          'ids': [1],
        }),
        returnsNormally,
      );
    });

    test('negative and out-of-range IDs are rejected (v4)', () {
      final result = CalendarReminderManifest.parse({
        'version': 4,
        'entries': [
          {'id': -1},
          {'id': 0x80000000},
          {'id': 42},
        ],
      });
      expect(result.manifest.scheduledIds, [42]);
      // Some records were dropped, so it is recovered rather than cleanly
      // loaded.
      expect(result.status, CalendarReminderManifestLoadStatus.recovered);
    });

    test('a v4 list whose every entry is invalid is corrupt, not empty', () {
      final result = CalendarReminderManifest.parse({
        'version': 4,
        'entries': [
          {'fp': _fp1, 'owner': _owner1},
          {'id': 'nope'},
        ],
      });
      expect(result.manifest.scheduledIds, isEmpty);
      expect(
        result.status,
        CalendarReminderManifestLoadStatus.corrupt,
        reason: 'filtered malformed data must never look like a clean manifest',
      );
    });

    test(
      'duplicate IDs are deduplicated deterministically (v4, recovered)',
      () {
        final result = CalendarReminderManifest.parse({
          'version': 4,
          'entries': [
            {'id': 7, 'fp': _fp1},
            {'id': 7, 'fp': _fp2},
          ],
        });
        expect(result.manifest.scheduledIds, [7]);
        expect(
          result.manifest.entryFor(7)!.fingerprint,
          _fp1,
          reason: 'the first occurrence wins',
        );
        expect(result.status, CalendarReminderManifestLoadStatus.recovered);
      },
    );

    test('a v4 entry with a non-hex fingerprint/owner drops those digests', () {
      final result = CalendarReminderManifest.parse({
        'version': 4,
        'entries': [
          {'id': 5, 'fp': 'not-hex', 'owner': 'ALSO-NOT-HEX'},
        ],
      });
      final entry = result.manifest.entryFor(5)!;
      expect(entry.notificationId, 5);
      expect(
        entry.fingerprint,
        isNull,
        reason: 'a non-SHA-256-format fingerprint is not trusted',
      );
      expect(entry.ownerKey, isNull);
    });

    test('a v4 list with valid and invalid entries is recovered', () {
      final result = CalendarReminderManifest.parse({
        'version': 4,
        'entries': [
          {'id': 10, 'fp': _fp1, 'owner': _owner1},
          'garbage',
          {'id': 11},
        ],
      });
      expect(result.status, CalendarReminderManifestLoadStatus.recovered);
      expect(result.manifest.scheduledIds, [10, 11]);
      expect(result.manifest.entryFor(10)!.ownerKey, _owner1);
    });

    test('a clean v4 list is loaded, not recovered', () {
      final result = CalendarReminderManifest.parse({
        'version': 4,
        'entries': [
          {'id': 10, 'fp': _fp1, 'owner': _owner1},
          {'id': 11, 'fp': _fp2, 'owner': _owner2},
        ],
      });
      expect(result.status, CalendarReminderManifestLoadStatus.loaded);
      expect(result.manifest.scheduledIds, [10, 11]);
    });

    test('unknown-version fingerprints and owners are cleared', () {
      final result = CalendarReminderManifest.parse({
        'version': 999,
        'entries': [
          {'id': 5, 'fp': 'future-fp', 'owner': 'future-owner'},
        ],
      });
      expect(result.status, CalendarReminderManifestLoadStatus.recovered);
      final entry = result.manifest.entryFor(5)!;
      expect(
        entry.fingerprint,
        isNull,
        reason: 'future fingerprints untrusted',
      );
      expect(
        entry.ownerKey,
        isNull,
        reason: 'future owners treated as unknown',
      );
    });
  });
}

import 'package:calee_mobile/data/models/calendar_reminder_manifest.dart';
import 'package:flutter_test/flutter_test.dart';

// Well-formed current-scheme (v4) owner tokens: the `v4:` tag + 64 hex chars.
// Used wherever the parser must retain/compare an owner in the current schema.
final String _ownerA = 'v4:${'a' * 64}';
final String _ownerB = 'v4:${'b' * 64}';

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

  group('CalendarReminderManifest — v4 schema and migration', () {
    test('round-trips v4 entries with cryptographic owners through JSON', () {
      final manifest = CalendarReminderManifest(
        version: CalendarReminderManifest.currentVersion,
        entries: [
          CalendarReminderManifestEntry(
            notificationId: 1,
            fingerprint: 'aa',
            ownerKey: _ownerA,
          ),
        ],
      );
      final restored = CalendarReminderManifest.parse(manifest.toJson());
      expect(restored.status, CalendarReminderManifestLoadStatus.loaded);
      expect(restored.manifest.entryFor(1)!.ownerKey, _ownerA);
      expect(manifest.toJson()['version'], 4);
    });

    test('v3 legacy migration drops FNV owner keys (re-owned), keeps fp', () {
      // A v3 entry carried a non-cryptographic FNV owner key (16 hex). On load
      // it must be dropped (never interpreted as a v4 key) so the entry is
      // re-owned by the current account on the next reconciliation.
      final result = CalendarReminderManifest.parse({
        'version': 3,
        'entries': [
          {'id': 1, 'fp': 'aa', 'owner': '0123456789abcdef'},
        ],
      });
      expect(result.status, CalendarReminderManifestLoadStatus.recovered);
      expect(result.manifest.entryFor(1)!.fingerprint, 'aa');
      expect(
        result.manifest.entryFor(1)!.ownerKey,
        isNull,
        reason: 'a legacy FNV owner is never interpreted as a v4 owner key',
      );
    });

    test('a present-but-non-v4 owner in the current schema is dropped '
        '(recovered), never trusted', () {
      final result = CalendarReminderManifest.parse({
        'version': CalendarReminderManifest.currentVersion,
        'entries': [
          {'id': 1, 'fp': 'aa', 'owner': 'ownerA'}, // wrong algorithm/format
        ],
      });
      expect(result.status, CalendarReminderManifestLoadStatus.recovered);
      expect(result.manifest.entryFor(1)!.ownerKey, isNull);
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

    test('v2 migration keeps fingerprints but has null owners', () {
      final result = CalendarReminderManifest.parse({
        'version': 2,
        'entries': [
          {'id': 1, 'fp': 'aa'},
        ],
      });
      expect(result.status, CalendarReminderManifestLoadStatus.recovered);
      expect(result.manifest.entryFor(1)!.fingerprint, 'aa');
      expect(
        result.manifest.entryFor(1)!.ownerKey,
        isNull,
        reason: 'a v2 entry carries no owner and must not be assumed current',
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
        CalendarReminderManifest.parse({
          'version': CalendarReminderManifest.currentVersion,
          'entries': [],
        }).status,
        CalendarReminderManifestLoadStatus.loaded,
      );
    });

    test('corrupt when a current-version value has no entries list', () {
      // Our writer always emits an entries list; its absence means malformed.
      final result = CalendarReminderManifest.parse({
        'version': CalendarReminderManifest.currentVersion,
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
      // 3.0 coerces to the current version; a non-whole float is unknown.
      expect(
        CalendarReminderManifest.parse({'version': 4.0, 'entries': []}).status,
        CalendarReminderManifestLoadStatus.loaded,
      );
      expect(
        () => CalendarReminderManifest.parse({
          'version': 3.5,
          'ids': [1],
        }),
        returnsNormally,
      );
    });

    test('negative and out-of-range IDs are rejected', () {
      final result = CalendarReminderManifest.parse({
        'version': CalendarReminderManifest.currentVersion,
        'entries': [
          {'id': -1},
          {'id': 0x80000000},
          {'id': 42},
        ],
      });
      expect(result.manifest.scheduledIds, [42]);
    });

    test('a malformed entry does not invent an ID', () {
      final result = CalendarReminderManifest.parse({
        'version': CalendarReminderManifest.currentVersion,
        'entries': [
          {'fp': 'x', 'owner': 'y'},
          {'id': 'nope'},
        ],
      });
      expect(result.manifest.scheduledIds, isEmpty);
    });

    test('current-schema duplicate IDs with conflicting fingerprints are '
        'corrupt (not first-entry-wins)', () {
      // Priority 4: an ambiguous ownership record must not be silently resolved
      // by keeping the first entry and dropping a conflicting duplicate.
      final result = CalendarReminderManifest.parse({
        'version': CalendarReminderManifest.currentVersion,
        'entries': [
          {'id': 7, 'fp': 'first'},
          {'id': 7, 'fp': 'second'},
        ],
      });
      expect(result.status, CalendarReminderManifestLoadStatus.corrupt);
      expect(result.manifest.isEmpty, isTrue);
    });

    test(
      'current-schema duplicate IDs with conflicting owners are corrupt',
      () {
        final result = CalendarReminderManifest.parse({
          'version': CalendarReminderManifest.currentVersion,
          'entries': [
            {'id': 7, 'fp': 'same', 'owner': _ownerA},
            {'id': 7, 'fp': 'same', 'owner': _ownerB},
          ],
        });
        expect(result.status, CalendarReminderManifestLoadStatus.corrupt);
      },
    );

    test('current-schema exact-duplicate IDs collapse and report recovered', () {
      // Identical duplicates carry no ownership conflict, so they are collapsed
      // — but that is a repair, so the load is `recovered`, never `loaded`.
      final result = CalendarReminderManifest.parse({
        'version': CalendarReminderManifest.currentVersion,
        'entries': [
          {'id': 7, 'fp': 'same', 'owner': _ownerA},
          {'id': 7, 'fp': 'same', 'owner': _ownerA},
        ],
      });
      expect(result.status, CalendarReminderManifestLoadStatus.recovered);
      expect(result.manifest.scheduledIds, [7]);
      expect(result.manifest.entryFor(7)!.fingerprint, 'same');
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

  group(
    'CalendarReminderManifest.parse — current-schema conservatism (P4)',
    () {
      test(
        'empty current-schema entries is a valid loaded (empty) manifest',
        () {
          final result = CalendarReminderManifest.parse({
            'version': CalendarReminderManifest.currentVersion,
            'entries': <dynamic>[],
          });
          expect(result.status, CalendarReminderManifestLoadStatus.loaded);
          expect(result.manifest.isEmpty, isTrue);
        },
      );

      test('all-valid current-schema entries load fully', () {
        final result = CalendarReminderManifest.parse({
          'version': CalendarReminderManifest.currentVersion,
          'entries': [
            {'id': 1, 'fp': 'a', 'owner': _ownerA},
            {'id': 2, 'fp': 'b', 'owner': _ownerA},
          ],
        });
        expect(result.status, CalendarReminderManifestLoadStatus.loaded);
        expect(result.manifest.scheduledIds, [1, 2]);
      });

      test('a mix of valid and malformed current-schema entries is RECOVERED, '
          'not reported as fully loaded', () {
        final result = CalendarReminderManifest.parse({
          'version': CalendarReminderManifest.currentVersion,
          'entries': [
            {'id': 1, 'fp': 'a', 'owner': _ownerA},
            {'fp': 'no-id'}, // dropped: no usable ID
            'garbage', // dropped: not a map
            {'id': 2},
          ],
        });
        expect(
          result.status,
          CalendarReminderManifestLoadStatus.recovered,
          reason: 'dropped entries must not be hidden behind a loaded status',
        );
        expect(result.manifest.scheduledIds, [1, 2]);
      });

      test(
        'a non-empty current-schema list with zero valid entries is CORRUPT',
        () {
          final result = CalendarReminderManifest.parse({
            'version': CalendarReminderManifest.currentVersion,
            'entries': [
              {'fp': 'x', 'owner': 'y'}, // no id
              {'id': 'nope'}, // bad id
            ],
          });
          expect(result.status, CalendarReminderManifestLoadStatus.corrupt);
          expect(
            result.manifest.isEmpty,
            isTrue,
            reason:
                'a corrupt manifest is never used as a trusted empty record',
          );
        },
      );

      test(
        'an oversized/malformed owner digest is dropped to null and reported '
        'as recovered (never a silent trusted null owner)',
        () {
          final oversized = 'z' * 200; // exceeds the persisted-digest bound
          final result = CalendarReminderManifest.parse({
            'version': CalendarReminderManifest.currentVersion,
            'entries': [
              {'id': 1, 'fp': 'a', 'owner': oversized},
            ],
          });
          expect(result.status, CalendarReminderManifestLoadStatus.recovered);
          final entry = result.manifest.entryFor(1)!;
          expect(entry.fingerprint, 'a');
          expect(
            entry.ownerKey,
            isNull,
            reason:
                'a malformed owner is dropped; recovered status is the signal',
          );
        },
      );

      test(
        'an oversized/malformed fingerprint is dropped and reported recovered',
        () {
          final result = CalendarReminderManifest.parse({
            'version': CalendarReminderManifest.currentVersion,
            'entries': [
              {'id': 1, 'fp': 'y' * 200, 'owner': _ownerA},
            ],
          });
          expect(result.status, CalendarReminderManifestLoadStatus.recovered);
          final entry = result.manifest.entryFor(1)!;
          expect(entry.fingerprint, isNull);
          expect(entry.ownerKey, _ownerA);
        },
      );
    },
  );
}

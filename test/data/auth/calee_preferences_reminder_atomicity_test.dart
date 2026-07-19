// Tests for the transactional, serialized reminder-preference record and its
// migration from the legacy multi-key format. A fake [ReminderPreferenceStore]
// is injected so failed and delayed writes can be exercised deterministically,
// without touching real SharedPreferences.

import 'dart:async';
import 'dart:convert';

import 'package:calee_mobile/data/auth/calee_preferences.dart';
import 'package:calee_mobile/features/notifications/calendar_notification_candidates.dart';
import 'package:flutter_test/flutter_test.dart';

const _v2Key = 'calee_pref_calendar_reminder_settings_v2';
const _legacyGlobalKey = 'calee_pref_calendar_reminders_enabled';
const _legacyMarkerKey = 'calee_pref_calendar_reminders_enabled_migrated';
String _legacyScopedKey(String owner) =>
    'calee_pref_calendar_reminders_enabled_$owner';

/// In-memory [ReminderPreferenceStore] with hooks to force write failures and
/// to block a write until released, so atomicity and concurrency can be driven.
class _FakeStore implements ReminderPreferenceStore {
  final Map<String, String> strings = {};
  final Map<String, bool> bools = {};

  bool failWrites = false;
  int writeCount = 0;
  int removeCount = 0;
  Completer<void>? _blockWrites;

  /// Blocks every subsequent write until [releaseWrites] is called.
  void blockWrites() => _blockWrites = Completer<void>();
  void releaseWrites() {
    _blockWrites?.complete();
    _blockWrites = null;
  }

  @override
  Future<String?> readString(String key) async => strings[key];

  @override
  Future<bool?> readBool(String key) async => bools[key];

  @override
  Future<bool> writeString(String key, String value) async {
    writeCount++;
    final block = _blockWrites;
    if (block != null) await block.future;
    if (failWrites) return false;
    strings[key] = value;
    return true;
  }

  @override
  Future<bool> remove(String key) async {
    removeCount++;
    strings.remove(key);
    bools.remove(key);
    return true;
  }

  @override
  Future<Set<String>> keys() async => {...strings.keys, ...bools.keys};

  CalendarReminderPreferenceRecord? get record {
    final raw = strings[_v2Key];
    return raw == null
        ? null
        : CalendarReminderPreferenceRecord.fromJson(jsonDecode(raw));
  }
}

void main() {
  final ownerA = reminderOwnerKey('acct-A');
  final ownerB = reminderOwnerKey('acct-B');

  group('atomic storage', () {
    test('a failed record write leaves the old value intact', () async {
      final store = _FakeStore();
      final prefs = CaleePreferences(reminderStore: store);
      await prefs.saveCalendarRemindersEnabled(ownerKey: ownerA, enabled: true);

      store.failWrites = true;
      await expectLater(
        prefs.saveCalendarRemindersEnabled(ownerKey: ownerA, enabled: false),
        throwsA(isA<CalendarReminderPreferenceStorageException>()),
      );

      store.failWrites = false;
      final result = await prefs.loadCalendarRemindersEnabledResult(
        ownerKey: ownerA,
      );
      expect(result.status, CalendarReminderPreferenceLoadStatus.loaded);
      expect(
        result.enabled,
        isTrue,
        reason: 'old value survives a failed save',
      );
    });

    test('a failed enable does not appear enabled after reload', () async {
      final store = _FakeStore()..failWrites = true;
      final prefs = CaleePreferences(reminderStore: store);

      await expectLater(
        prefs.saveCalendarRemindersEnabled(ownerKey: ownerA, enabled: true),
        throwsA(isA<CalendarReminderPreferenceStorageException>()),
      );

      store.failWrites = false;
      final result = await prefs.loadCalendarRemindersEnabledResult(
        ownerKey: ownerA,
      );
      expect(
        result.status,
        CalendarReminderPreferenceLoadStatus.absent,
        reason: 'a failed enable never persisted',
      );
    });

    test('a failed disable does not appear disabled after reload', () async {
      final store = _FakeStore();
      final prefs = CaleePreferences(reminderStore: store);
      await prefs.saveCalendarRemindersEnabled(ownerKey: ownerA, enabled: true);

      store.failWrites = true;
      await expectLater(
        prefs.saveCalendarRemindersEnabled(ownerKey: ownerA, enabled: false),
        throwsA(isA<CalendarReminderPreferenceStorageException>()),
      );

      store.failWrites = false;
      final result = await prefs.loadCalendarRemindersEnabledResult(
        ownerKey: ownerA,
      );
      expect(result.enabled, isTrue, reason: 'a failed disable stays enabled');
    });

    test(
      'a successful save commits its requested value without error',
      () async {
        final store = _FakeStore();
        final prefs = CaleePreferences(reminderStore: store);
        await expectLater(
          prefs.saveCalendarRemindersEnabled(ownerKey: ownerA, enabled: true),
          completes,
        );
        expect(store.record!.valuesByOwner[ownerA], isTrue);
      },
    );

    test('account A and account B remain independent', () async {
      final store = _FakeStore();
      final prefs = CaleePreferences(reminderStore: store);
      await prefs.saveCalendarRemindersEnabled(ownerKey: ownerA, enabled: true);
      await prefs.saveCalendarRemindersEnabled(
        ownerKey: ownerB,
        enabled: false,
      );

      expect(
        (await prefs.loadCalendarRemindersEnabledResult(
          ownerKey: ownerA,
        )).enabled,
        isTrue,
      );
      expect(
        (await prefs.loadCalendarRemindersEnabledResult(
          ownerKey: ownerB,
        )).enabled,
        isFalse,
      );
    });

    test('concurrent A/B saves retain both values', () async {
      final store = _FakeStore();
      final prefs = CaleePreferences(reminderStore: store);

      // Fire both without awaiting so they race; the serialization boundary must
      // apply them one at a time so neither update is lost.
      final a = prefs.saveCalendarRemindersEnabled(
        ownerKey: ownerA,
        enabled: true,
      );
      final b = prefs.saveCalendarRemindersEnabled(
        ownerKey: ownerB,
        enabled: true,
      );
      await Future.wait([a, b]);

      final record = store.record!;
      expect(record.valuesByOwner[ownerA], isTrue);
      expect(record.valuesByOwner[ownerB], isTrue);
    });

    test(
      'a failed operation does not poison the serialization queue',
      () async {
        final store = _FakeStore()..failWrites = true;
        final prefs = CaleePreferences(reminderStore: store);

        await expectLater(
          prefs.saveCalendarRemindersEnabled(ownerKey: ownerA, enabled: true),
          throwsA(isA<CalendarReminderPreferenceStorageException>()),
        );

        // A later operation must still run and complete.
        store.failWrites = false;
        await expectLater(
          prefs.saveCalendarRemindersEnabled(ownerKey: ownerB, enabled: true),
          completes,
        );
        expect(
          (await prefs.loadCalendarRemindersEnabledResult(
            ownerKey: ownerB,
          )).enabled,
          isTrue,
        );
      },
    );

    test(
      'every queued future completes even when writes are delayed',
      () async {
        final store = _FakeStore()..blockWrites();
        final prefs = CaleePreferences(reminderStore: store);

        final a = prefs.saveCalendarRemindersEnabled(
          ownerKey: ownerA,
          enabled: true,
        );
        final b = prefs.saveCalendarRemindersEnabled(
          ownerKey: ownerB,
          enabled: true,
        );
        store.releaseWrites();
        await expectLater(Future.wait([a, b]), completes);
      },
    );
  });

  group('corrupt/unsupported record', () {
    test('malformed JSON yields unavailable, never a default false', () async {
      final store = _FakeStore()..strings[_v2Key] = 'not-json{';
      final prefs = CaleePreferences(reminderStore: store);
      final result = await prefs.loadCalendarRemindersEnabledResult(
        ownerKey: ownerA,
      );
      expect(result.status, CalendarReminderPreferenceLoadStatus.unavailable);
      expect(result.enabled, isNull);
    });

    test('an unsupported record version yields unavailable', () async {
      final store = _FakeStore()
        ..strings[_v2Key] = jsonEncode({
          'version': 999,
          'legacyClaimConsumed': false,
          'values': {ownerA: true},
        });
      final prefs = CaleePreferences(reminderStore: store);
      final result = await prefs.loadCalendarRemindersEnabledResult(
        ownerKey: ownerA,
      );
      expect(result.status, CalendarReminderPreferenceLoadStatus.unavailable);
    });
  });

  group('legacy-format migration', () {
    test(
      'one account claims a legacy global once; a second does not',
      () async {
        final store = _FakeStore()..bools[_legacyGlobalKey] = true;
        final prefs = CaleePreferences(reminderStore: store);

        expect(
          (await prefs.loadCalendarRemindersEnabledResult(
            ownerKey: ownerA,
          )).enabled,
          isTrue,
        );
        expect(
          (await prefs.loadCalendarRemindersEnabledResult(
            ownerKey: ownerB,
          )).status,
          CalendarReminderPreferenceLoadStatus.absent,
        );
      },
    );

    test(
      'concurrent first loads by two accounts yield exactly one claimant',
      () async {
        final store = _FakeStore()..bools[_legacyGlobalKey] = true;
        final prefs = CaleePreferences(reminderStore: store);

        final results = await Future.wait([
          prefs.loadCalendarRemindersEnabledResult(ownerKey: ownerA),
          prefs.loadCalendarRemindersEnabledResult(ownerKey: ownerB),
        ]);
        final claimants = results.where((r) => r.enabled == true).length;
        expect(
          claimants,
          1,
          reason: 'only one account may inherit the legacy value',
        );
      },
    );

    test('a scoped value with a missing marker is recovered safely', () async {
      final store = _FakeStore()..bools[_legacyScopedKey(ownerA)] = true;
      final prefs = CaleePreferences(reminderStore: store);

      expect(
        (await prefs.loadCalendarRemindersEnabledResult(
          ownerKey: ownerA,
        )).enabled,
        isTrue,
        reason: 'the existing scoped value is preserved',
      );
      // A single scoped value conservatively consumes the legacy claim, so a new
      // account cannot inherit anything.
      expect(
        (await prefs.loadCalendarRemindersEnabledResult(
          ownerKey: ownerB,
        )).status,
        CalendarReminderPreferenceLoadStatus.absent,
      );
    });

    test('a marker with a missing scoped value migrates as consumed', () async {
      final store = _FakeStore()..strings[_legacyMarkerKey] = ownerA;
      final prefs = CaleePreferences(reminderStore: store);

      final a = await prefs.loadCalendarRemindersEnabledResult(
        ownerKey: ownerA,
      );
      expect(a.status, CalendarReminderPreferenceLoadStatus.absent);
      expect(store.record!.legacyClaimConsumed, isTrue);
      expect(store.record!.legacyClaimOwner, ownerA);
    });

    test(
      'multiple scoped values with no marker do not let a new account inherit',
      () async {
        final store = _FakeStore()
          ..bools[_legacyScopedKey(ownerA)] = true
          ..bools[_legacyScopedKey(ownerB)] = false;
        final prefs = CaleePreferences(reminderStore: store);

        expect(
          (await prefs.loadCalendarRemindersEnabledResult(
            ownerKey: ownerA,
          )).enabled,
          isTrue,
        );
        expect(
          (await prefs.loadCalendarRemindersEnabledResult(
            ownerKey: ownerB,
          )).enabled,
          isFalse,
        );
        final ownerC = reminderOwnerKey('acct-C');
        expect(
          (await prefs.loadCalendarRemindersEnabledResult(
            ownerKey: ownerC,
          )).status,
          CalendarReminderPreferenceLoadStatus.absent,
        );
      },
    );

    test('a failed migration commit leaves every old key intact', () async {
      final store = _FakeStore()
        ..bools[_legacyGlobalKey] = true
        ..strings[_legacyMarkerKey] = ownerA
        ..failWrites = true;
      final prefs = CaleePreferences(reminderStore: store);

      final result = await prefs.loadCalendarRemindersEnabledResult(
        ownerKey: ownerA,
      );
      expect(result.status, CalendarReminderPreferenceLoadStatus.unavailable);
      expect(
        store.bools[_legacyGlobalKey],
        isTrue,
        reason: 'old key untouched',
      );
      expect(store.strings[_legacyMarkerKey], ownerA);
      expect(store.strings[_v2Key], isNull, reason: 'no v2 record committed');
    });

    test('a successful migration removes old keys best-effort', () async {
      final store = _FakeStore()
        ..bools[_legacyGlobalKey] = true
        ..strings[_legacyMarkerKey] = ownerA;
      final prefs = CaleePreferences(reminderStore: store);

      await prefs.loadCalendarRemindersEnabledResult(ownerKey: ownerA);
      expect(store.strings[_v2Key], isNotNull);
      expect(store.bools.containsKey(_legacyGlobalKey), isFalse);
      expect(store.strings.containsKey(_legacyMarkerKey), isFalse);
    });

    test('no raw account ID appears in the committed record or keys', () async {
      const rawId = 'raw-secret-123';
      final owner = reminderOwnerKey(rawId);
      final store = _FakeStore()..bools[_legacyGlobalKey] = true;
      final prefs = CaleePreferences(reminderStore: store);

      await prefs.saveCalendarRemindersEnabled(ownerKey: owner, enabled: true);
      for (final entry in store.strings.entries) {
        expect(entry.key, isNot(contains(rawId)));
        expect(entry.value, isNot(contains(rawId)));
      }
    });
  });
}

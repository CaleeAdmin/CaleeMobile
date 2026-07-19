// Tests for the account-scoped calendar-reminder-enabled preference and its
// one-time legacy-global migration.

import 'dart:convert';

import 'package:calee_mobile/data/auth/calee_preferences.dart';
import 'package:calee_mobile/features/notifications/calendar_notification_candidates.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final ownerA = reminderOwnerKey('acct-A');
  final ownerB = reminderOwnerKey('acct-B');

  setUp(() {
    SharedPreferences.setMockInitialValues({
      'calee_pref_migrated_to_shared_prefs': true,
    });
  });

  test('a new account defaults to off', () async {
    final prefs = CaleePreferences();
    expect(await prefs.loadCalendarRemindersEnabled(ownerKey: ownerA), isFalse);
  });

  test('two accounts keep independent values', () async {
    final prefs = CaleePreferences();
    await prefs.saveCalendarRemindersEnabled(ownerKey: ownerA, enabled: true);
    await prefs.saveCalendarRemindersEnabled(ownerKey: ownerB, enabled: false);

    expect(await prefs.loadCalendarRemindersEnabled(ownerKey: ownerA), isTrue);
    expect(await prefs.loadCalendarRemindersEnabled(ownerKey: ownerB), isFalse);
  });

  test('disabling one account never affects the other', () async {
    final prefs = CaleePreferences();
    await prefs.saveCalendarRemindersEnabled(ownerKey: ownerA, enabled: true);
    await prefs.saveCalendarRemindersEnabled(ownerKey: ownerB, enabled: true);

    // Permission denial (or a manual toggle) disables the current account only.
    await prefs.saveCalendarRemindersEnabled(ownerKey: ownerA, enabled: false);

    expect(await prefs.loadCalendarRemindersEnabled(ownerKey: ownerA), isFalse);
    expect(await prefs.loadCalendarRemindersEnabled(ownerKey: ownerB), isTrue);
  });

  test('signing out preserves the ended account preference', () async {
    final prefs = CaleePreferences();
    await prefs.saveCalendarRemindersEnabled(ownerKey: ownerA, enabled: true);

    // Sign-out does not clear A's key; a later sign-in reads the saved value.
    expect(await prefs.loadCalendarRemindersEnabled(ownerKey: ownerA), isTrue);
  });

  test('raw account IDs never appear in preference keys', () async {
    const rawId = 'super-secret-account-id';
    final prefs = CaleePreferences();
    await prefs.saveCalendarRemindersEnabled(
      ownerKey: reminderOwnerKey(rawId),
      enabled: true,
    );

    final sp = await SharedPreferences.getInstance();
    for (final key in sp.getKeys()) {
      expect(
        key.contains(rawId),
        isFalse,
        reason: 'no reminder key may embed the raw account ID',
      );
    }
  });

  group('structured load result (Fix 2)', () {
    test('a new account is absent (not a failure)', () async {
      final prefs = CaleePreferences();
      final result = await prefs.loadCalendarRemindersEnabledResult(
        ownerKey: ownerA,
      );
      expect(result.status, CalendarReminderPreferenceLoadStatus.absent);
      expect(result.enabled, isNull);
    });

    test('a saved value is loaded with its actual boolean', () async {
      final prefs = CaleePreferences();
      await prefs.saveCalendarRemindersEnabled(ownerKey: ownerA, enabled: true);
      await prefs.saveCalendarRemindersEnabled(
        ownerKey: ownerB,
        enabled: false,
      );

      final a = await prefs.loadCalendarRemindersEnabledResult(
        ownerKey: ownerA,
      );
      final b = await prefs.loadCalendarRemindersEnabledResult(
        ownerKey: ownerB,
      );
      expect(a.status, CalendarReminderPreferenceLoadStatus.loaded);
      expect(a.enabled, isTrue);
      expect(b.status, CalendarReminderPreferenceLoadStatus.loaded);
      expect(b.enabled, isFalse);
    });

    test(
      'the null-owner legacy path is absent when nothing is stored',
      () async {
        final prefs = CaleePreferences();
        final result = await prefs.loadCalendarRemindersEnabledResult();
        expect(result.status, CalendarReminderPreferenceLoadStatus.absent);
      },
    );
  });

  group('legacy global migration', () {
    setUp(() {
      SharedPreferences.setMockInitialValues({
        'calee_pref_migrated_to_shared_prefs': true,
        // Existing user had reminders on under the old device-global key.
        'calee_pref_calendar_reminders_enabled': true,
      });
    });

    test('claims the legacy value once for the migrating account', () async {
      final prefs = CaleePreferences();
      // First account to read inherits the legacy value.
      expect(
        await prefs.loadCalendarRemindersEnabled(ownerKey: ownerA),
        isTrue,
      );
      // A different, later account does NOT inherit the legacy `true`.
      expect(
        await prefs.loadCalendarRemindersEnabled(ownerKey: ownerB),
        isFalse,
        reason: 'the legacy value must not propagate to every later account',
      );
    });

    test('a save also consumes the one-time migration', () async {
      final prefs = CaleePreferences();
      // A signs in and explicitly turns reminders off (consuming migration).
      await prefs.saveCalendarRemindersEnabled(
        ownerKey: ownerA,
        enabled: false,
      );

      expect(
        await prefs.loadCalendarRemindersEnabled(ownerKey: ownerA),
        isFalse,
      );
      expect(
        await prefs.loadCalendarRemindersEnabled(ownerKey: ownerB),
        isFalse,
        reason: 'B still must not inherit the stale legacy value',
      );
    });

    test(
      'the migrated record records the claiming owner key, no raw ID',
      () async {
        const rawId = 'raw-account-42';
        final owner = reminderOwnerKey(rawId);
        final prefs = CaleePreferences();
        await prefs.loadCalendarRemindersEnabled(ownerKey: owner);

        final sp = await SharedPreferences.getInstance();
        final raw = sp.getString('calee_pref_calendar_reminder_settings_v2');
        expect(raw, isNotNull, reason: 'the migration commits the v2 record');
        final record = CalendarReminderPreferenceRecord.fromJson(
          jsonDecode(raw!),
        );
        expect(record, isNotNull);
        expect(
          record!.legacyClaimConsumed,
          isTrue,
          reason: 'the claim is consumed by the migrating account',
        );
        expect(
          record.legacyClaimOwner,
          owner,
          reason: 'the record records the claiming owner key',
        );
        // No raw account ID may appear anywhere in storage.
        for (final key in sp.getKeys()) {
          expect(key, isNot(contains(rawId)));
          final value = sp.get(key);
          if (value is String) expect(value, isNot(contains(rawId)));
        }
      },
    );

    test(
      'the account-agnostic (null owner) path reads the legacy value',
      () async {
        final prefs = CaleePreferences();
        expect(await prefs.loadCalendarRemindersEnabled(), isTrue);
      },
    );

    test('structured result: migrating account is loaded(true), a later '
        'account is absent', () async {
      final prefs = CaleePreferences();
      final a = await prefs.loadCalendarRemindersEnabledResult(
        ownerKey: ownerA,
      );
      expect(a.status, CalendarReminderPreferenceLoadStatus.loaded);
      expect(a.enabled, isTrue, reason: 'A inherits the legacy value once');

      final b = await prefs.loadCalendarRemindersEnabledResult(
        ownerKey: ownerB,
      );
      expect(
        b.status,
        CalendarReminderPreferenceLoadStatus.absent,
        reason: 'a later account does not inherit; absent is not a failure',
      );
      expect(b.enabled, isNull);
    });

    test(
      'structured result: the null-owner legacy path is loaded(true)',
      () async {
        final prefs = CaleePreferences();
        final result = await prefs.loadCalendarRemindersEnabledResult();
        expect(result.status, CalendarReminderPreferenceLoadStatus.loaded);
        expect(result.enabled, isTrue);
      },
    );
  });

  group('observable save (Fix 3)', () {
    test('a successful save does not throw', () async {
      final prefs = CaleePreferences();
      await expectLater(
        prefs.saveCalendarRemindersEnabled(ownerKey: ownerA, enabled: true),
        completes,
      );
      expect(
        await prefs.loadCalendarRemindersEnabled(ownerKey: ownerA),
        isTrue,
      );
    });
  });
}

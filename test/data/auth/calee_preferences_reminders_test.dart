// Tests for the account-scoped calendar-reminder-enabled preference and its
// one-time legacy-global migration.

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

    test('the migration marker stores only the owner key, no raw ID', () async {
      const rawId = 'raw-account-42';
      final owner = reminderOwnerKey(rawId);
      final prefs = CaleePreferences();
      await prefs.loadCalendarRemindersEnabled(ownerKey: owner);

      final sp = await SharedPreferences.getInstance();
      final marker = sp.getString(
        'calee_pref_calendar_reminders_enabled_migrated',
      );
      expect(
        marker,
        owner,
        reason: 'the marker records the claiming owner key',
      );
      expect(marker, isNot(contains(rawId)));
    });

    test(
      'the account-agnostic (null owner) path reads the legacy value',
      () async {
        final prefs = CaleePreferences();
        expect(await prefs.loadCalendarRemindersEnabled(), isTrue);
      },
    );
  });
}

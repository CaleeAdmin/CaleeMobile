// Tests for the targeted, account-scoped cleanup a COMPLETED deletion runs
// (#556).
//
// The obligation cuts both ways: the deleted account's local state must go,
// and everything that is not the deleted account's must survive untouched.
// Guest/local calendar subscriptions are the case #556 calls out by name.

import 'dart:convert';

import 'package:calee_mobile/data/auth/calee_preferences.dart';
import 'package:calee_mobile/features/account_deletion/account_deletion_account_cleanup.dart';
import 'package:calee_mobile/features/notifications/calendar_notification_candidates.dart';
import 'package:calee_mobile/features/notifications/local_calendar_notification_service.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _deletedAccountId = 'acct_deleted';
const _otherAccountId = 'acct_other';

/// Records the owner-scoped disable call without touching the notification
/// plugin. The subclass is deliberately narrow: only the one method the
/// cleanup uses is replaced.
class _RecordingNotificationService extends LocalCalendarNotificationService {
  _RecordingNotificationService() : super.forTest();

  final List<String> disabledOwnerKeys = <String>[];
  final List<bool> includeLegacyFlags = <bool>[];
  final List<int> individuallyCancelledIds = <int>[];

  @override
  Future<CalendarReminderDisableResult> disableCalendarReminders({
    required String ownerKey,
    bool includeLegacyOwnerless = false,
  }) async {
    disabledOwnerKeys.add(ownerKey);
    includeLegacyFlags.add(includeLegacyOwnerless);
    return const CalendarReminderDisableResult(
      cancelledCount: 3,
      failedCount: 0,
      manifestPersisted: true,
    );
  }

  /// The service exposes no global cancel at all; this records the per-ID
  /// cancels the manifest-driven path uses, so a cleanup that reached past the
  /// owner-scoped seam would be visible here.
  @override
  Future<void> cancelNotification(int id) async =>
      individuallyCancelledIds.add(id);
}

/// The device as it stands before a deletion completes: two accounts, a Guest
/// calendar subscription, and unrelated device preferences.
Map<String, Object> _seededPreferences() => <String, Object>{
  'calee_pref_migrated_to_shared_prefs': true,
  // Account-owned Hub identifiers and display preferences.
  'calee_pref_first_day_of_week': 'monday',
  'calee_pref_time_format': 'h24',
  'calee_pref_default_calendar_id': 'cal_owned_by_deleted_account',
  'calee_pref_default_task_list_id': 'tasks_owned_by_deleted_account',
  // Per-account onboarding, for BOTH accounts on this shared device.
  'calee_calendar_onboarding_status_$_deletedAccountId': 'completed',
  'calee_calendar_onboarding_status_$_otherAccountId': 'completed',
  // Guest/device-local data. Must survive.
  'local_calendar_subscriptions_v1': '[{"id":"s1","url":"https://x/y.ics"}]',
  // Someone else's unrelated preference. Must survive.
  'some_other_feature_setting': 'keep me',
};

void main() {
  // These are plain `test()` cases, so the binding SharedPreferences and the
  // secure-storage channel need is not implicit.
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues(_seededPreferences());
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.it_nomads.com/flutter_secure_storage'),
          (call) async => <String, String>{},
        );
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.it_nomads.com/flutter_secure_storage'),
          null,
        );
  });

  /// Seeds a reminder-enabled row for both accounts, so the removal of one can
  /// be shown not to disturb the other.
  Future<void> seedReminderPreferences(CaleePreferences preferences) async {
    await preferences.saveCalendarRemindersEnabled(
      ownerKey: reminderOwnerKey(_deletedAccountId),
      enabled: true,
    );
    await preferences.saveCalendarRemindersEnabled(
      ownerKey: reminderOwnerKey(_otherAccountId),
      enabled: true,
    );
  }

  group('LocalAccountDeletionCleanup', () {
    test('removes the deleted account state and nothing else', () async {
      final preferences = CaleePreferences();
      await seedReminderPreferences(preferences);
      final notifications = _RecordingNotificationService();

      final report = await LocalAccountDeletionCleanup(
        preferences: preferences,
        notificationService: notifications,
      ).clearAccountState(_deletedAccountId);

      final prefs = await SharedPreferences.getInstance();
      await prefs.reload();

      // Gone: this account's Hub-owned preferences and onboarding.
      expect(prefs.getString('calee_pref_first_day_of_week'), isNull);
      expect(prefs.getString('calee_pref_time_format'), isNull);
      expect(prefs.getString('calee_pref_default_calendar_id'), isNull);
      expect(prefs.getString('calee_pref_default_task_list_id'), isNull);
      expect(
        prefs.getString('calee_calendar_onboarding_status_$_deletedAccountId'),
        isNull,
      );

      // Kept: everything that is not this account's.
      expect(
        prefs.getString('calee_calendar_onboarding_status_$_otherAccountId'),
        'completed',
        reason: 'a shared device keeps the other account intact',
      );
      expect(
        prefs.getString('local_calendar_subscriptions_v1'),
        isNotNull,
        reason: 'Guest/local calendar subscriptions must survive',
      );
      expect(prefs.getString('some_other_feature_setting'), 'keep me');
      expect(prefs.getBool('calee_pref_migrated_to_shared_prefs'), isTrue);

      expect(report.accountScopedPreferencesCleared, isTrue);
      expect(report.onboardingStatusCleared, isTrue);
      expect(report.remindersCancelled, 3);
    });

    test('cancels reminders owner-scoped, never globally', () async {
      final notifications = _RecordingNotificationService();

      await LocalAccountDeletionCleanup(
        preferences: CaleePreferences(),
        notificationService: notifications,
      ).clearAccountState(_deletedAccountId);

      expect(notifications.disabledOwnerKeys, [
        reminderOwnerKey(_deletedAccountId),
      ]);
      expect(notifications.includeLegacyFlags, [true]);
      expect(
        notifications.individuallyCancelledIds,
        isEmpty,
        reason:
            'cleanup goes through the owner-scoped seam, never around it — '
            'the service exposes no global cancel to reach for',
      );
      expect(
        notifications.disabledOwnerKeys.single,
        isNot(contains(_deletedAccountId)),
        reason: 'the owner key is a digest, never the raw account id',
      );
    });

    test('forgets only the deleted account reminder preference row', () async {
      final preferences = CaleePreferences();
      await seedReminderPreferences(preferences);

      await LocalAccountDeletionCleanup(
        preferences: preferences,
        notificationService: _RecordingNotificationService(),
      ).clearAccountState(_deletedAccountId);

      final prefs = await SharedPreferences.getInstance();
      await prefs.reload();
      final record =
          jsonDecode(
                prefs.getString('calee_pref_calendar_reminder_settings_v2')!,
              )
              as Map<String, dynamic>;
      final values = record['values'] as Map<String, dynamic>;

      expect(values.containsKey(reminderOwnerKey(_deletedAccountId)), isFalse);
      expect(
        values[reminderOwnerKey(_otherAccountId)],
        isTrue,
        reason: 'removing one row must not reset the record',
      );
    });

    test('never clears the whole preference store', () async {
      final before = (await SharedPreferences.getInstance()).getKeys().length;

      await LocalAccountDeletionCleanup(
        preferences: CaleePreferences(),
        notificationService: _RecordingNotificationService(),
      ).clearAccountState(_deletedAccountId);

      final prefs = await SharedPreferences.getInstance();
      await prefs.reload();
      expect(
        prefs.getKeys(),
        isNotEmpty,
        reason: 'a global wipe is exactly what #556 forbids',
      );
      expect(prefs.getKeys().length, lessThan(before));
    });
  });

  group('AccountDeletionCleanupTargetStore', () {
    test('round-trips the account awaiting cleanup', () async {
      const store = AccountDeletionCleanupTargetStore();

      expect(await store.load(), isNull);
      await store.remember(_deletedAccountId);
      expect(await store.load(), _deletedAccountId);

      await store.clear();
      expect(await store.load(), isNull);
    });

    test('stores the account id and nothing more', () async {
      const store = AccountDeletionCleanupTargetStore();
      await store.remember(_deletedAccountId);

      final prefs = await SharedPreferences.getInstance();
      await prefs.reload();
      expect(
        prefs.getString(AccountDeletionCleanupTargetStore.cleanupTargetKey),
        _deletedAccountId,
      );
    });

    test('ignores a blank account id', () async {
      const store = AccountDeletionCleanupTargetStore();
      await store.remember('   ');
      expect(await store.load(), isNull);
    });

    test('clearing removes only its own key', () async {
      const store = AccountDeletionCleanupTargetStore();
      await store.remember(_deletedAccountId);

      await store.clear();

      final prefs = await SharedPreferences.getInstance();
      await prefs.reload();
      expect(prefs.getString('local_calendar_subscriptions_v1'), isNotNull);
      expect(prefs.getString('some_other_feature_setting'), 'keep me');
    });
  });
}

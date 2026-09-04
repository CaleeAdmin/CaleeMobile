import 'package:shared_preferences/shared_preferences.dart';

import '../../data/auth/calee_preferences.dart';
import '../notifications/calendar_notification_candidates.dart';
import '../notifications/local_calendar_notification_service.dart';

/// Targeted, account-scoped local cleanup for a COMPLETED deletion (#556).
///
/// THE RULE THIS FILE EXISTS TO ENFORCE: nothing here is global. There is no
/// `SharedPreferences.clear()`, no `FlutterSecureStorage.deleteAll()`, no
/// `cancelAll()` on the notification plugin, and no prefix sweep over
/// per-account keys. Every removal names either one key this account owns or
/// one owner-scoped row.
///
/// WHAT SURVIVES, deliberately:
///  * Guest/local calendar subscriptions (`local_calendar_subscriptions_v1`),
///    which belong to the device and to a person who may never have had a
///    Calee account at all;
///  * every other account's reminder preference row and onboarding status on a
///    shared device;
///  * the shared-preferences migration marker, and every unrelated device
///    preference this app or another feature has written.
///
/// WHEN IT RUNS: only after the Hub's own state string is exactly `completed`.
/// A deletion that is merely accepted, quiescing, deleting or restored must
/// never reach this code -- the ordinary session ends at acceptance through
/// [SessionController], which is a different and reversible thing.

/// Remembers WHICH account a completed deletion must clean up after.
///
/// The account id has to outlive the bootstrap. Deletion is asynchronous: the
/// customer's ordinary session ends the moment the Hub accepts, and completion
/// may not be observed until days later, in a process that has never held a
/// bootstrap. Without this the completion path could only fall back to a
/// device-wide wipe, which is exactly what #556 forbids.
///
/// STORES ONE OPAQUE HUB IDENTIFIER AND NOTHING ELSE. No email, no display
/// name, no token, and -- emphatically -- no recovery secret: this is ordinary
/// SharedPreferences, not the secure store, and the account id is already
/// present there today inside the per-account onboarding key name.
class AccountDeletionCleanupTargetStore {
  const AccountDeletionCleanupTargetStore();

  /// The ONE key this store owns.
  static const String cleanupTargetKey =
      'calee_account_deletion_cleanup_target_v1';

  /// Records the account whose deletion has been accepted.
  ///
  /// Best-effort: a failure here does not make the deletion less real, and must
  /// not stop the request from being submitted or the session from ending. The
  /// consequence of losing it is a stale local cache, never a wrong deletion.
  Future<void> remember(String accountId) async {
    final trimmed = accountId.trim();
    if (trimmed.isEmpty) return;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(cleanupTargetKey, trimmed);
    } catch (_) {
      // Best-effort; see the doc comment.
    }
  }

  /// The account awaiting cleanup, or null when there is none.
  Future<String?> load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final value = prefs.getString(cleanupTargetKey);
      if (value == null || value.trim().isEmpty) return null;
      return value.trim();
    } catch (_) {
      return null;
    }
  }

  /// Removes the target key, and nothing else.
  Future<void> clear() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(cleanupTargetKey);
    } catch (_) {
      // Best-effort; see the doc comment.
    }
  }
}

/// What one cleanup run actually did. Log-safe: counts and flags only, never a
/// key name carrying an account id and never any stored value.
class AccountDeletionCleanupReport {
  const AccountDeletionCleanupReport({
    required this.accountScopedPreferencesCleared,
    required this.onboardingStatusCleared,
    required this.reminderPreferenceCleared,
    required this.remindersCancelled,
  });

  static const AccountDeletionCleanupReport none = AccountDeletionCleanupReport(
    accountScopedPreferencesCleared: false,
    onboardingStatusCleared: false,
    reminderPreferenceCleared: false,
    remindersCancelled: 0,
  );

  final bool accountScopedPreferencesCleared;
  final bool onboardingStatusCleared;
  final bool reminderPreferenceCleared;
  final int remindersCancelled;

  @override
  String toString() =>
      'AccountDeletionCleanupReport(preferences: '
      '$accountScopedPreferencesCleared, onboarding: $onboardingStatusCleared, '
      'reminderPreference: $reminderPreferenceCleared, '
      'remindersCancelled: $remindersCancelled)';
}

/// Runs the account-scoped cleanup. Injected as an interface so the controller
/// can be tested without SharedPreferences or the notification plugin.
abstract class AccountDeletionAccountCleanup {
  /// Removes the local state owned by [accountId]. Never throws: terminal
  /// handling must still tell the customer the truth even if a cache resists
  /// removal.
  Future<AccountDeletionCleanupReport> clearAccountState(String accountId);
}

/// The shipped implementation.
class LocalAccountDeletionCleanup implements AccountDeletionAccountCleanup {
  LocalAccountDeletionCleanup({
    CaleePreferences? preferences,
    LocalCalendarNotificationService? notificationService,
  }) : _preferences = preferences ?? CaleePreferences(),
       _notificationService =
           notificationService ?? LocalCalendarNotificationService.instance;

  final CaleePreferences _preferences;
  final LocalCalendarNotificationService _notificationService;

  @override
  Future<AccountDeletionCleanupReport> clearAccountState(
    String accountId,
  ) async {
    // Every step is independently best-effort. One failing cache must not stop
    // the others from being cleaned, and none of them may fail the completion
    // screen the customer is reading.
    var preferencesCleared = false;
    var onboardingCleared = false;
    var reminderPreferenceCleared = false;
    var remindersCancelled = 0;

    try {
      await _preferences.clearAccountOwnedPreferences();
      preferencesCleared = true;
    } catch (_) {
      // Reported as not-cleared; see above.
    }

    try {
      await _preferences.clearCalendarOnboardingStatus(accountId);
      onboardingCleared = true;
    } catch (_) {
      // Reported as not-cleared; see above.
    }

    // Reminder cleanup is OWNER-SCOPED, using the same privacy-safe digest the
    // reminder session uses, so a shared device keeps every other account's
    // scheduled notifications. `includeLegacyOwnerless` matches what sign-out
    // already does, so a departing account's pre-migration reminders do not
    // linger either.
    final ownerKey = tryReminderOwnerKey(accountId);
    if (ownerKey != null) {
      try {
        final result = await _notificationService.disableCalendarReminders(
          ownerKey: ownerKey,
          includeLegacyOwnerless: true,
        );
        remindersCancelled = result.cancelledCount;
      } catch (_) {
        // Reported as zero cancellations; see above.
      }

      try {
        await _preferences.forgetCalendarRemindersForOwner(ownerKey);
        reminderPreferenceCleared = true;
      } catch (_) {
        // Reported as not-cleared; see above.
      }
    }

    return AccountDeletionCleanupReport(
      accountScopedPreferencesCleared: preferencesCleared,
      onboardingStatusCleared: onboardingCleared,
      reminderPreferenceCleared: reminderPreferenceCleared,
      remindersCancelled: remindersCancelled,
    );
  }
}

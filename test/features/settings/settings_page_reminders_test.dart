// Widget tests for the calendar-reminders toggle in SettingsPage.
//
// Verifies the two permission-flow fixes:
//   1. Permission granted  → setting becomes enabled, calendar callback fires.
//   2. Permission denied   → setting stays disabled, callback not called,
//                            SnackBar is shown.
//
// LocalCalendarNotificationService.testOverride is used to inject a fake
// without hitting flutter_local_notifications platform channels.

import 'package:calee_mobile/data/api/calee_hub_client.dart';
import 'package:calee_mobile/data/auth/calee_preferences.dart';
import 'package:calee_mobile/data/models/client_bootstrap.dart';
import 'package:calee_mobile/data/models/client_calendar.dart';
import 'package:calee_mobile/data/models/client_preferences.dart';
import 'package:calee_mobile/features/notifications/calendar_reminder_coordinator.dart';
import 'package:calee_mobile/features/notifications/local_calendar_notification_service.dart';
import 'package:calee_mobile/features/settings/settings_page.dart';
import 'package:calee_mobile/ui/calee_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

// ── Fake notification service ─────────────────────────────────────────────────

class _FakeNotificationService extends LocalCalendarNotificationService {
  _FakeNotificationService({required this.permissionGranted}) : super.forTest();

  final bool permissionGranted;
  int disableCount = 0;
  final List<String> disableOwnerKeys = [];

  @override
  Future<void> initialize() async {}

  @override
  Future<bool> requestPermissionIfNeeded() async => permissionGranted;

  @override
  Future<CalendarReminderDisableResult> disableCalendarReminders({
    required String ownerKey,
    bool includeLegacyOwnerless = false,
  }) async {
    disableCount++;
    disableOwnerKeys.add(ownerKey);
    return const CalendarReminderDisableResult(
      cancelledCount: 0,
      failedCount: 0,
      manifestPersisted: true,
    );
  }
}

// ── Recording coordinator ─────────────────────────────────────────────────────

class _RecordingCoordinator extends CalendarReminderCoordinator {
  _RecordingCoordinator() : super(hubClient: _StubHubClient());

  final List<CalendarReminderRefreshReason> reasons = [];

  @override
  Future<CalendarReminderRefreshResult> refresh({
    required String? accessToken,
    required CalendarReminderRefreshReason reason,
    bool force = false,
  }) async {
    reasons.add(reason);
    return CalendarReminderRefreshResult(
      reason: reason,
      status: CalendarReminderRefreshStatus.reconciled,
      completedAt: DateTime(2026),
    );
  }
}

// ── Preferences that fail to persist the reminder toggle ──────────────────────

class _FailingPreferences extends CaleePreferences {
  _FailingPreferences({this.enabledSeed = false});

  /// The value [loadCalendarRemindersEnabled] returns, so a test can start the
  /// switch on (to exercise the failed-disable path) or off.
  final bool enabledSeed;
  int saveAttempts = 0;

  @override
  Future<bool> loadCalendarRemindersEnabled({String? ownerKey}) async =>
      enabledSeed;

  @override
  Future<CalendarReminderPreferenceLoadResult>
  loadCalendarRemindersEnabledResult({String? ownerKey}) async =>
      CalendarReminderPreferenceLoadResult.loaded(enabledSeed);

  @override
  Future<void> saveCalendarRemindersEnabled({
    String? ownerKey,
    required bool enabled,
  }) async {
    saveAttempts++;
    throw const CalendarReminderPreferenceStorageException('save');
  }
}

// ── Preferences whose reminder read is unavailable ────────────────────────────

class _UnavailablePreferences extends CaleePreferences {
  @override
  Future<bool> loadCalendarRemindersEnabled({String? ownerKey}) async => false;

  @override
  Future<CalendarReminderPreferenceLoadResult>
  loadCalendarRemindersEnabledResult({String? ownerKey}) async =>
      const CalendarReminderPreferenceLoadResult.unavailable('io');
}

// ── Stub hub client ───────────────────────────────────────────────────────────

class _StubHubClient extends CaleeHubClient {
  _StubHubClient() : super(baseUri: Uri.parse('http://localhost'));

  @override
  Future<ClientCalendarList> calendars({required String accessToken}) async =>
      const ClientCalendarList(calendars: []);

  // Hub preferences are unavailable in these tests; SettingsRepository must
  // fall back to the local cache without surfacing a page-level error.
  @override
  Future<ClientPreferences> preferences({required String accessToken}) async {
    throw const CaleeHubException(statusCode: 500, message: 'Server error');
  }
}

// ── Helpers ───────────────────────────────────────────────────────────────────

ClientBootstrap _bootstrap() => ClientBootstrap(
  account: const ClientAccount(
    id: 'u1',
    displayName: 'Test User',
    primaryEmail: 'test@example.com',
    timeZone: 'Australia/Perth',
    status: 'active',
  ),
  services: const [],
  contexts: const ClientContexts(households: [], organisations: []),
  availableContexts: const [],
  capabilities: const {},
);

Widget _wrap({
  required bool permissionGranted,
  VoidCallback? onNavigateToCalendar,
  CalendarReminderCoordinator? coordinator,
  CaleePreferences? preferencesOverride,
  LocalCalendarNotificationService? notificationService,
}) {
  LocalCalendarNotificationService.testOverride =
      notificationService ??
      _FakeNotificationService(permissionGranted: permissionGranted);
  return MaterialApp(
    theme: CaleeTheme.buildThemeData(),
    home: Scaffold(
      body: SettingsPage(
        hubClient: _StubHubClient(),
        accessToken: 'tok',
        bootstrap: _bootstrap(),
        onSignOut: () {},
        reminderCoordinator: coordinator,
        onNavigateToCalendar: onNavigateToCalendar,
        preferencesOverride: preferencesOverride,
      ),
    ),
  );
}

// ── Tests ─────────────────────────────────────────────────────────────────────

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({
      'calee_pref_migrated_to_shared_prefs': true,
    });
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.it_nomads.com/flutter_secure_storage'),
          (call) async => <String, String>{},
        );
  });

  tearDown(() {
    LocalCalendarNotificationService.testOverride = null;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.it_nomads.com/flutter_secure_storage'),
          null,
        );
  });

  testWidgets(
    'enabling reminders with permission granted: setting is enabled and '
    'calendar callback is called',
    (tester) async {
      var navigated = false;
      await tester.pumpWidget(
        _wrap(
          permissionGranted: true,
          onNavigateToCalendar: () => navigated = true,
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.byType(Switch));
      await tester.pumpAndSettle();

      final sw = tester.widget<Switch>(find.byType(Switch));
      expect(sw.value, isTrue, reason: 'reminders toggle should be on');
      expect(navigated, isTrue, reason: 'calendar tab callback should fire');
    },
  );

  testWidgets(
    'enabling reminders forces a remindersEnabled coordinator refresh',
    (tester) async {
      final coordinator = _RecordingCoordinator();
      await tester.pumpWidget(
        _wrap(permissionGranted: true, coordinator: coordinator),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.byType(Switch));
      await tester.pumpAndSettle();

      expect(coordinator.reasons, [
        CalendarReminderRefreshReason.remindersEnabled,
      ]);
    },
  );

  testWidgets(
    'enabling reminders with permission denied: setting stays disabled, '
    'callback not called, and SnackBar is shown',
    (tester) async {
      var navigated = false;
      await tester.pumpWidget(
        _wrap(
          permissionGranted: false,
          onNavigateToCalendar: () => navigated = true,
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.byType(Switch));
      await tester.pumpAndSettle();

      final sw = tester.widget<Switch>(find.byType(Switch));
      expect(sw.value, isFalse, reason: 'reminders toggle should stay off');
      expect(
        navigated,
        isFalse,
        reason: 'calendar tab callback should not fire',
      );
      expect(
        find.text('Notification permission is needed for calendar reminders.'),
        findsOneWidget,
        reason: 'SnackBar should explain the denial',
      );
    },
  );

  // ── Fix 3: failed persistence gates reconcile/cleanup + rolls the switch back ─

  testWidgets(
    'a failed enable persist rolls the switch back, shows a SnackBar, and does '
    'not reconcile',
    (tester) async {
      final coordinator = _RecordingCoordinator();
      await tester.pumpWidget(
        _wrap(
          permissionGranted: true,
          coordinator: coordinator,
          preferencesOverride: _FailingPreferences(enabledSeed: false),
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.byType(Switch));
      await tester.pumpAndSettle();

      final sw = tester.widget<Switch>(find.byType(Switch));
      expect(
        sw.value,
        isFalse,
        reason: 'the switch rolls back when enabling did not persist',
      );
      expect(
        coordinator.reasons,
        isEmpty,
        reason: 'no reconciliation may run when enabling failed to persist',
      );
      expect(
        find.text("Couldn't save your preference. Please try again."),
        findsOneWidget,
        reason: 'the transient save error is surfaced via a SnackBar',
      );
    },
  );

  testWidgets(
    'a failed disable persist rolls the switch back on, shows a SnackBar, and '
    'does not run cleanup',
    (tester) async {
      final notifs = _FakeNotificationService(permissionGranted: true);
      await tester.pumpWidget(
        _wrap(
          permissionGranted: true,
          notificationService: notifs,
          preferencesOverride: _FailingPreferences(enabledSeed: true),
        ),
      );
      await tester.pumpAndSettle();

      // The switch starts on (loaded value is true).
      expect(tester.widget<Switch>(find.byType(Switch)).value, isTrue);

      // Tap to disable — the persist fails.
      await tester.tap(find.byType(Switch));
      await tester.pumpAndSettle();

      final sw = tester.widget<Switch>(find.byType(Switch));
      expect(
        sw.value,
        isTrue,
        reason: 'the switch stays on when disabling did not persist',
      );
      expect(
        notifs.disableCount,
        0,
        reason: 'no owner cleanup may run when disabling failed to persist',
      );
      expect(
        find.text("Couldn't save your preference. Please try again."),
        findsOneWidget,
      );
    },
  );

  // ── Fix 7: an unavailable read is shown accurately, not as a real "off" ──────

  testWidgets(
    'an unavailable reminder read disables the switch and shows a concise '
    'message without a full-page error',
    (tester) async {
      await tester.pumpWidget(
        _wrap(
          permissionGranted: true,
          preferencesOverride: _UnavailablePreferences(),
        ),
      );
      await tester.pumpAndSettle();

      final sw = tester.widget<Switch>(find.byType(Switch));
      expect(
        sw.onChanged,
        isNull,
        reason: 'the switch is disabled while the value is untrustworthy',
      );
      expect(
        find.text("Couldn't load the reminder setting. Please try again."),
        findsOneWidget,
      );
      // Other Settings sections remain usable (no full-page error state).
      expect(find.byType(Switch), findsOneWidget);
    },
  );
}

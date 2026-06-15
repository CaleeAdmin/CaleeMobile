// Widget tests for CalendarOnboardingPage (Screen 1) and CalendarSourcePickerPage.
//
// Uses SharedPreferences mock and a stub CaleeHubClient to avoid platform-channel
// hangs and real network calls in tests.

import 'package:calee_mobile/data/api/calee_hub_client.dart';
import 'package:calee_mobile/data/models/client_bootstrap.dart';
import 'package:calee_mobile/features/calendar_onboarding/calendar_onboarding_page.dart';
import 'package:calee_mobile/features/calendar_onboarding/calendar_onboarding_status.dart';
import 'package:calee_mobile/ui/calee_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

// ── Stubs ─────────────────────────────────────────────────────────────────────

class _StubHubClient extends CaleeHubClient {
  _StubHubClient() : super(baseUri: Uri.parse('http://localhost'));
}

const _kAccountId = 'test-account-1';

List<ClientService> get _emptyServices => const [];

Widget _wrap({
  required VoidCallback onDismissed,
  VoidCallback? onViewCalendar,
  bool isManual = false,
}) =>
    MaterialApp(
      theme: CaleeTheme.buildThemeData(),
      home: CalendarOnboardingPage(
        hubClient: _StubHubClient(),
        accessToken: 'token',
        services: _emptyServices,
        accountId: _kAccountId,
        onDismissed: onDismissed,
        onViewCalendar: onViewCalendar ?? () {},
        isManual: isManual,
      ),
    );

// ── Setup ──────────────────────────────────────────────────────────────────────

void _setUpSharedPrefs([Map<String, Object>? initial]) {
  SharedPreferences.setMockInitialValues(
    initial ?? {'calee_pref_migrated_to_shared_prefs': true},
  );
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(
        const MethodChannel('plugins.it_nomads.com/flutter_secure_storage'),
        (call) async => <String, String>{},
      );
}

void _tearDownSharedPrefs() {
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(
        const MethodChannel('plugins.it_nomads.com/flutter_secure_storage'),
        null,
      );
}

// ── Tests ──────────────────────────────────────────────────────────────────────

void main() {
  setUp(_setUpSharedPrefs);
  tearDown(_tearDownSharedPrefs);

  group('CalendarOnboardingPage — automatic mode', () {
    testWidgets('shows title and body text', (tester) async {
      await tester.pumpWidget(_wrap(onDismissed: () {}));

      expect(find.text('Your Calee calendar is ready'), findsOneWidget);
      expect(
        find.textContaining('Calee has created a default calendar'),
        findsOneWidget,
      );
    });

    testWidgets('shows required buttons', (tester) async {
      await tester.pumpWidget(_wrap(onDismissed: () {}));

      expect(find.text('Add existing calendars'), findsOneWidget);
      expect(find.text('Remind me later'), findsOneWidget);
      expect(find.text("Don't show this again"), findsOneWidget);
    });

    testWidgets('does not show Not now button', (tester) async {
      await tester.pumpWidget(_wrap(onDismissed: () {}));

      expect(find.text('Not now'), findsNothing);
    });

    testWidgets(
      '"Remind me later" saves remind_later and calls onDismissed',
      (tester) async {
        var dismissed = false;
        _setUpSharedPrefs({'calee_pref_migrated_to_shared_prefs': true});

        await tester.pumpWidget(_wrap(onDismissed: () => dismissed = true));

        await tester.tap(find.text('Remind me later'));
        await tester.pumpAndSettle();

        expect(dismissed, isTrue);

        final prefs = await SharedPreferences.getInstance();
        expect(
          prefs.getString('calee_calendar_onboarding_status_$_kAccountId'),
          CalendarOnboardingStatus.remindLater,
        );
      },
    );

    testWidgets(
      '"Don\'t show this again" saves dismissed_forever and calls onDismissed',
      (tester) async {
        var dismissed = false;
        _setUpSharedPrefs({'calee_pref_migrated_to_shared_prefs': true});

        await tester.pumpWidget(_wrap(onDismissed: () => dismissed = true));

        await tester.tap(find.text("Don't show this again"));
        await tester.pumpAndSettle();

        expect(dismissed, isTrue);

        final prefs = await SharedPreferences.getInstance();
        expect(
          prefs.getString('calee_calendar_onboarding_status_$_kAccountId'),
          CalendarOnboardingStatus.dismissedForever,
        );
      },
    );

    testWidgets(
      '"Add existing calendars" navigates to source picker without changing status',
      (tester) async {
        _setUpSharedPrefs({'calee_pref_migrated_to_shared_prefs': true});

        await tester.pumpWidget(_wrap(onDismissed: () {}));

        await tester.tap(find.text('Add existing calendars'));
        await tester.pumpAndSettle();

        expect(find.text('Where is your calendar?'), findsOneWidget);

        // Status must NOT have been changed yet
        final prefs = await SharedPreferences.getInstance();
        expect(
          prefs.getString('calee_calendar_onboarding_status_$_kAccountId'),
          isNull,
        );
      },
    );

    testWidgets('source picker shows four provider options', (tester) async {
      await tester.pumpWidget(_wrap(onDismissed: () {}));

      await tester.tap(find.text('Add existing calendars'));
      await tester.pumpAndSettle();

      expect(find.text('Google Calendar'), findsOneWidget);
      expect(find.text('Apple / iCloud Calendar'), findsOneWidget);
      expect(find.text('Outlook Calendar'), findsOneWidget);
      expect(find.text('I already have a calendar link'), findsOneWidget);
    });
  });

  group('CalendarOnboardingPage — manual (Settings) mode', () {
    testWidgets('shows Add existing calendars and Not now buttons',
        (tester) async {
      await tester.pumpWidget(_wrap(onDismissed: () {}, isManual: true));

      expect(find.text('Add existing calendars'), findsOneWidget);
      expect(find.text('Not now'), findsOneWidget);
    });

    testWidgets('does not show Remind me later or Don\'t show this again',
        (tester) async {
      await tester.pumpWidget(_wrap(onDismissed: () {}, isManual: true));

      expect(find.text('Remind me later'), findsNothing);
      expect(find.text("Don't show this again"), findsNothing);
    });

    testWidgets('"Not now" calls onDismissed without changing status',
        (tester) async {
      var dismissed = false;
      _setUpSharedPrefs({'calee_pref_migrated_to_shared_prefs': true});

      await tester.pumpWidget(
        _wrap(onDismissed: () => dismissed = true, isManual: true),
      );

      await tester.tap(find.text('Not now'));
      await tester.pumpAndSettle();

      expect(dismissed, isTrue);

      // Status must NOT have been changed
      final prefs = await SharedPreferences.getInstance();
      expect(
        prefs.getString('calee_calendar_onboarding_status_$_kAccountId'),
        isNull,
      );
    });

    testWidgets(
      '"Add existing calendars" navigates to source picker in manual mode',
      (tester) async {
        _setUpSharedPrefs({'calee_pref_migrated_to_shared_prefs': true});

        await tester.pumpWidget(_wrap(onDismissed: () {}, isManual: true));

        await tester.tap(find.text('Add existing calendars'));
        await tester.pumpAndSettle();

        expect(find.text('Where is your calendar?'), findsOneWidget);
      },
    );
  });
}

// Widget tests for the "Add existing calendar" flow copy and routing.
//
// Verifies:
//  - Source picker has exactly four expected options with correct copy.
//  - "Add existing calendar" from Lists & calendars opens the source picker.
//  - Google "Paste the link in Calee" opens a Google-specific link form
//    that does not show "School calendar".
//  - Generic calendar-link form uses "Shared calendar".
//  - Apple guide says "Open the Apple Calendar app."
//  - Outlook guide uses Calendar Share Alias.
//  - Settings uses Calendar Share Alias, not Calendar Sharing Address.
//  - Calendar row subtitle uses Connected calendar, not Linked calendar.

import 'package:calee_mobile/data/api/calee_hub_client.dart';
import 'package:calee_mobile/data/models/client_bootstrap.dart';
import 'package:calee_mobile/data/models/client_calendar.dart';
import 'package:calee_mobile/features/calendar/widgets/calendar_chooser_sheet.dart';
import 'package:calee_mobile/features/calendar_onboarding/calendar_onboarding_page.dart';
import 'package:calee_mobile/features/calendar_onboarding/calendar_source_picker_page.dart';
import 'package:calee_mobile/features/calendar_onboarding/provider_guides/apple_icloud_calendar_guide_page.dart';
import 'package:calee_mobile/features/calendar_onboarding/provider_guides/generic_calendar_link_page.dart';
import 'package:calee_mobile/features/calendar_onboarding/provider_guides/google_calendar_guide_page.dart';
import 'package:calee_mobile/features/calendar_onboarding/provider_guides/outlook_calendar_guide_page.dart';
import 'package:calee_mobile/features/settings/calendar_collections_page.dart';
import 'package:calee_mobile/features/settings/calendar_sharing_address_page.dart';
import 'package:calee_mobile/ui/calee_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

// ── Stubs ──────────────────────────────────────────────────────────────────────

class _StubHubClient extends CaleeHubClient {
  _StubHubClient() : super(baseUri: Uri.parse('http://localhost'));

  @override
  Future<ClientCalendarList> calendars({required String accessToken}) async {
    return const ClientCalendarList(calendars: []);
  }
}

ClientService _sharingService() => const ClientService(
  id: 'svc1',
  displayName: 'Calee',
  serviceType: 'nextcloud_calendar',
  baseUrl: 'http://localhost',
  launchUrl: '',
  accessStatus: 'active',
  calendarCredentialStatus: 'connected',
  source: 'calee',
  capabilities: {'calendarSharingAddress': true},
);

// ── Setup ──────────────────────────────────────────────────────────────────────

void _setUpSharedPrefs() {
  SharedPreferences.setMockInitialValues({
    'calee_pref_migrated_to_shared_prefs': true,
  });
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

// ── Helpers ────────────────────────────────────────────────────────────────────

Widget _wrapOnboarding() => MaterialApp(
  theme: CaleeTheme.buildThemeData(),
  home: CalendarOnboardingPage(
    hubClient: _StubHubClient(),
    accessToken: 'token',
    services: const [],
    accountId: 'acct1',
    onDismissed: () {},
    onViewCalendar: () {},
  ),
);

Widget _wrapSourcePicker() => MaterialApp(
  theme: CaleeTheme.buildThemeData(),
  home: CalendarSourcePickerPage(
    hubClient: _StubHubClient(),
    accessToken: 'token',
    services: const [],
    accountId: 'acct1',
    onDone: () {},
    onViewCalendar: () {},
  ),
);

Widget _wrapGenericLink({bool showExamples = true}) => MaterialApp(
  theme: CaleeTheme.buildThemeData(),
  home: GenericCalendarLinkPage(
    hubClient: _StubHubClient(),
    accessToken: 'token',
    services: const [],
    accountId: 'acct1',
    onDone: () {},
    onViewCalendar: () {},
    showExamples: showExamples,
  ),
);

Widget _wrapGoogleGuide() => MaterialApp(
  theme: CaleeTheme.buildThemeData(),
  home: GoogleCalendarGuidePage(
    hubClient: _StubHubClient(),
    accessToken: 'token',
    services: const [],
    accountId: 'acct1',
    onDone: () {},
    onViewCalendar: () {},
  ),
);

Widget _wrapAppleGuide() => MaterialApp(
  theme: CaleeTheme.buildThemeData(),
  home: AppleIcloudCalendarGuidePage(
    hubClient: _StubHubClient(),
    accessToken: 'token',
    services: const [],
    accountId: 'acct1',
    onDone: () {},
    onViewCalendar: () {},
  ),
);

Widget _wrapOutlookGuide() => MaterialApp(
  theme: CaleeTheme.buildThemeData(),
  home: OutlookCalendarGuidePage(
    hubClient: _StubHubClient(),
    accessToken: 'token',
    services: [_sharingService()],
    accountId: 'acct1',
    onDone: () {},
    onViewCalendar: () {},
  ),
);

Widget _wrapCollections() => MaterialApp(
  theme: CaleeTheme.buildThemeData(),
  home: CalendarCollectionsPage(
    hubClient: _StubHubClient(),
    accessToken: 'token',
    services: const [],
    accountId: 'acct1',
  ),
);

Widget _wrapChooserSheet(List<ClientCalendar> calendars) => MaterialApp(
  theme: CaleeTheme.buildThemeData(),
  home: Scaffold(
    body: CalendarChooserSheet(
      calendars: calendars,
      initialHiddenIds: const {},
      hubClient: _StubHubClient(),
      accessToken: 'token',
      onToggle: (_) {},
      onShowAll: () {},
      onNewCalendar: () {},
      onSubscribeFromLink: () {},
      onCalendarMutated: (_) {},
    ),
  ),
);

// ── Tests ──────────────────────────────────────────────────────────────────────

void main() {
  setUp(_setUpSharedPrefs);
  tearDown(_tearDownSharedPrefs);

  group('CalendarSourcePickerPage — four options', () {
    testWidgets('shows exactly the four expected provider options', (
      tester,
    ) async {
      await tester.pumpWidget(_wrapSourcePicker());

      expect(find.text('Google Calendar'), findsOneWidget);
      expect(find.text('Apple / iCloud Calendar'), findsOneWidget);
      expect(find.text('Outlook Calendar'), findsOneWidget);
      expect(find.text('I already have a calendar link'), findsOneWidget);
    });

    testWidgets('source picker subtitle uses new copy', (tester) async {
      await tester.pumpWidget(_wrapSourcePicker());

      expect(
        find.textContaining('Choose where your existing calendar is'),
        findsOneWidget,
      );
    });
  });

  group('"Add existing calendar" opens source picker', () {
    testWidgets(
      '"Add existing calendars" from onboarding opens source picker',
      (tester) async {
        await tester.pumpWidget(_wrapOnboarding());

        await tester.tap(find.text('Add existing calendars'));
        await tester.pumpAndSettle();

        expect(find.text('Where is your calendar?'), findsOneWidget);
      },
    );

    testWidgets(
      '"Add existing calendar" in collections opens source picker not raw form',
      (tester) async {
        await tester.pumpWidget(_wrapCollections());
        await tester.pump(const Duration(milliseconds: 50));

        await tester.tap(find.byIcon(Icons.add));
        await tester.pumpAndSettle();

        await tester.tap(find.text('Add existing calendar'));
        await tester.pumpAndSettle();

        expect(find.text('Where is your calendar?'), findsOneWidget);
        expect(find.text('Add calendar link'), findsNothing);
      },
    );
  });

  group('Generic calendar-link form copy', () {
    testWidgets('uses "Shared calendar" as name hint', (tester) async {
      await tester.pumpWidget(_wrapGenericLink());

      expect(find.text('Shared calendar'), findsOneWidget);
    });

    testWidgets('shows example text when showExamples is true', (tester) async {
      await tester.pumpWidget(_wrapGenericLink(showExamples: true));

      expect(find.textContaining('school calendar'), findsWidgets);
    });

    testWidgets('hides example text when showExamples is false', (
      tester,
    ) async {
      await tester.pumpWidget(_wrapGenericLink(showExamples: false));

      expect(find.textContaining('Examples:'), findsNothing);
    });

    testWidgets('does not show "School calendar" as main hint', (tester) async {
      await tester.pumpWidget(_wrapGenericLink());

      expect(find.text('School calendar'), findsNothing);
    });
  });

  group('Google guide copy', () {
    testWidgets('main view has "Paste the link in Calee" button', (
      tester,
    ) async {
      await tester.pumpWidget(_wrapGoogleGuide());

      expect(find.text('Paste the link in Calee'), findsOneWidget);
      expect(find.text('I already have the link'), findsNothing);
      expect(find.text('I have the link'), findsNothing);
    });

    testWidgets('"Paste the link in Calee" opens Google-specific form', (
      tester,
    ) async {
      await tester.pumpWidget(_wrapGoogleGuide());

      await tester.tap(find.text('Paste the link in Calee'));
      await tester.pumpAndSettle();

      expect(find.text('Add Google Calendar link'), findsOneWidget);
      expect(find.text('My Google Calendar'), findsOneWidget);
    });

    testWidgets('Google paste-link form does not show "School calendar"', (
      tester,
    ) async {
      await tester.pumpWidget(_wrapGoogleGuide());

      await tester.tap(find.text('Paste the link in Calee'));
      await tester.pumpAndSettle();

      expect(find.text('School calendar'), findsNothing);
      expect(find.textContaining('school calendar'), findsNothing);
    });

    testWidgets('computer view mentions calee.com.au/start', (tester) async {
      await tester.pumpWidget(_wrapGoogleGuide());

      await tester.tap(find.text('Continue on computer'));
      await tester.pumpAndSettle();

      expect(find.textContaining('calee.com.au/start'), findsWidgets);
    });

    testWidgets('computer view has "Copy website address" button', (
      tester,
    ) async {
      await tester.pumpWidget(_wrapGoogleGuide());

      await tester.tap(find.text('Continue on computer'));
      await tester.pumpAndSettle();

      expect(find.text('Copy website address'), findsOneWidget);
    });
  });

  group('Apple / iCloud guide copy', () {
    testWidgets('says "Open the Apple Calendar app."', (tester) async {
      await tester.pumpWidget(_wrapAppleGuide());

      expect(find.text('Open the Apple Calendar app.'), findsOneWidget);
    });

    testWidgets('mentions Public Calendar link', (tester) async {
      await tester.pumpWidget(_wrapAppleGuide());

      expect(find.textContaining('Public Calendar'), findsWidgets);
    });

    testWidgets('uses "My iCloud Calendar" as name hint', (tester) async {
      await tester.pumpWidget(_wrapAppleGuide());

      expect(find.text('My iCloud Calendar'), findsOneWidget);
    });
  });

  group('Outlook guide copy', () {
    testWidgets('page title is "Add Outlook Calendar"', (tester) async {
      await tester.pumpWidget(_wrapOutlookGuide());
      expect(find.text('Add Outlook Calendar'), findsOneWidget);
    });

    testWidgets(
      'Calendar Share Alias wording appears (in error message or alias view)',
      (tester) async {
        await tester.pumpWidget(_wrapOutlookGuide());
        // Allow API call to complete (will fail in test env → error state)
        await tester.pump(const Duration(milliseconds: 100));

        // "Calendar Share Alias" appears either in the error message
        // ("Could not load Calendar Share Alias") or in the alias view.
        expect(find.textContaining('Calendar Share Alias'), findsWidgets);
      },
    );
  });

  group('Settings — Calendar Share Alias page', () {
    testWidgets('page title is "Calendar Share Alias"', (tester) async {
      final page = MaterialApp(
        theme: CaleeTheme.buildThemeData(),
        home: CalendarSharingAddressPage(
          hubClient: _StubHubClient(),
          accessToken: 'token',
          serviceId: 'svc1',
        ),
      );
      await tester.pumpWidget(page);

      expect(find.text('Calendar Share Alias'), findsOneWidget);
      expect(find.text('Calendar Sharing Address'), findsNothing);
    });
  });

  group('Calendar row subtitle — Connected calendar', () {
    testWidgets('subscription calendar shows "Connected calendar" subtitle', (
      tester,
    ) async {
      final subscription = ClientCalendar(
        id: 'cal1',
        name: 'My School Cal',
        serviceId: 'svc1',
        serviceName: 'Calee',
        color: null,
        primaryKind: 'calendar',
        components: const [],
        supportsEvents: true,
        supportsTasks: false,
        supportsChores: false,
        readOnly: true,
        isSubscription: true,
        source: 'test',
        subscriptionUrl: 'https://example.com/calendar.ics',
      );

      await tester.pumpWidget(_wrapChooserSheet([subscription]));

      expect(find.textContaining('Connected calendar'), findsOneWidget);
      expect(find.text('Linked calendar'), findsNothing);
    });
  });
}

// Widget tests for the "Add existing calendar" flow copy and routing.

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

class _StubHubClient extends CaleeHubClient {
  _StubHubClient({this._bootstrap})
    : super(baseUri: Uri.parse('http://localhost'));

  final ClientBootstrap? _bootstrap;

  @override
  Future<ClientBootstrap> bootstrap({required String accessToken}) async {
    return _bootstrap ??
        const ClientBootstrap(
          account: ClientAccount(
            id: '',
            displayName: null,
            primaryEmail: null,
            timeZone: null,
            status: null,
          ),
          services: [],
          contexts: ClientContexts(households: [], organisations: []),
          availableContexts: [],
          capabilities: {},
        );
  }

  @override
  Future<ClientCalendarList> calendars({required String accessToken}) async {
    return const ClientCalendarList(calendars: []);
  }
}

class _StubOAuthHubClient extends CaleeHubClient {
  _StubOAuthHubClient() : super(baseUri: Uri.parse('http://localhost'));

  @override
  Future<ClientCalendarList> calendars({required String accessToken}) async {
    return const ClientCalendarList(calendars: []);
  }

  @override
  Future<String> startExternalCalendarOAuth({
    required String accessToken,
    required String providerKey,
    String accessMode = 'read_only',
  }) async {
    return 'https://accounts.google.com/oauth';
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

ClientBootstrap _bootstrapForGenericLink({
  List<ClientService> services = const [],
  Map<String, dynamic> readiness = const {},
}) => ClientBootstrap(
  account: const ClientAccount(
    id: 'acct1',
    displayName: 'Test',
    primaryEmail: 'test@example.com',
    timeZone: 'UTC',
    status: 'active',
  ),
  services: services,
  contexts: const ClientContexts(households: [], organisations: []),
  availableContexts: const [],
  capabilities: const {},
  readiness: readiness,
);

ClientService _portalService({String calendarCredentialStatus = 'connected'}) =>
    ClientService(
      id: 'portal',
      displayName: 'Portal',
      serviceType: 'nextcloud_portal',
      baseUrl: 'http://localhost',
      launchUrl: '',
      accessStatus: 'active',
      calendarCredentialStatus: calendarCredentialStatus,
      source: 'calee',
      capabilities: const {},
    );

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

Widget _wrapGenericLink({
  bool showExamples = true,
  CaleeHubClient? hubClient,
}) => MaterialApp(
  theme: CaleeTheme.buildThemeData(),
  home: GenericCalendarLinkPage(
    hubClient: hubClient ?? _StubHubClient(),
    accessToken: 'token',
    services: const [],
    accountId: 'acct1',
    onDone: () {},
    onViewCalendar: () {},
    showExamples: showExamples,
  ),
);

Widget _wrapGoogleGuide({
  Future<void> Function(String url)? launchUrl,
  CaleeHubClient? hubClient,
}) => MaterialApp(
  theme: CaleeTheme.buildThemeData(),
  home: GoogleCalendarGuidePage(
    hubClient: hubClient ?? _StubHubClient(),
    accessToken: 'token',
    services: const [],
    accountId: 'acct1',
    onDone: () {},
    onViewCalendar: () {},
    launchUrl: launchUrl,
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

void main() {
  setUp(_setUpSharedPrefs);
  tearDown(_tearDownSharedPrefs);

  testWidgets('source picker shows exactly four provider options', (
    tester,
  ) async {
    await tester.pumpWidget(_wrapSourcePicker());

    expect(find.text('Google Calendar'), findsOneWidget);
    expect(find.text('Apple / iCloud Calendar'), findsOneWidget);
    expect(find.text('Outlook Calendar'), findsOneWidget);
    expect(find.text('I already have a calendar link'), findsOneWidget);
    expect(
      find.textContaining('Choose where your existing calendar is'),
      findsOneWidget,
    );
  });

  testWidgets('onboarding opens source picker', (tester) async {
    await tester.pumpWidget(_wrapOnboarding());

    await tester.tap(find.text('Add existing calendars'));
    await tester.pumpAndSettle();

    expect(find.text('Where is your calendar?'), findsOneWidget);
  });

  testWidgets('collections Add existing calendar opens source picker', (
    tester,
  ) async {
    await tester.pumpWidget(_wrapCollections());
    await tester.pump(const Duration(milliseconds: 50));

    await tester.tap(find.byIcon(Icons.add));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Add existing calendar'));
    await tester.pumpAndSettle();

    expect(find.text('Where is your calendar?'), findsOneWidget);
    expect(find.text('Add calendar link'), findsNothing);
  });

  testWidgets('generic link form uses Shared calendar, not School calendar', (
    tester,
  ) async {
    await tester.pumpWidget(_wrapGenericLink());
    await tester.pumpAndSettle();

    expect(find.text('Shared calendar'), findsOneWidget);
    expect(find.text('School calendar'), findsNothing);
    expect(find.textContaining('school calendar'), findsWidgets);
  });

  testWidgets('generic link accepts connected nextcloud portal service', (
    tester,
  ) async {
    await tester.pumpWidget(
      _wrapGenericLink(
        hubClient: _StubHubClient(
          bootstrap: _bootstrapForGenericLink(services: [_portalService()]),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(
      find.text(
        'No calendar service access found. Please sign out and sign in again.',
      ),
      findsNothing,
    );
    expect(find.text('Calendar name'), findsOneWidget);
    expect(find.text('Calendar link'), findsOneWidget);
    expect(find.text('Add to Calee'), findsOneWidget);
  });

  testWidgets('generic link explains no connected calendar service readiness', (
    tester,
  ) async {
    await tester.pumpWidget(
      _wrapGenericLink(
        hubClient: _StubHubClient(
          bootstrap: _bootstrapForGenericLink(
            readiness: const {
              'calendarServiceReady': false,
              'problem': 'no_connected_calendar_service',
            },
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.enterText(
      find.widgetWithText(TextFormField, 'Calendar name'),
      'Shared',
    );
    await tester.enterText(
      find.widgetWithText(TextFormField, 'Calendar link'),
      'https://example.com/calendar.ics',
    );
    await tester.tap(find.text('Add to Calee'));
    await tester.pumpAndSettle();

    expect(
      find.text(
        'Your account setup is not complete. Please sign out and sign in again.',
      ),
      findsOneWidget,
    );
  });

  testWidgets('generic link explains missing nextcloud portal credential', (
    tester,
  ) async {
    await tester.pumpWidget(
      _wrapGenericLink(
        hubClient: _StubHubClient(
          bootstrap: _bootstrapForGenericLink(
            services: [_portalService(calendarCredentialStatus: 'missing')],
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.enterText(
      find.widgetWithText(TextFormField, 'Calendar name'),
      'Shared',
    );
    await tester.enterText(
      find.widgetWithText(TextFormField, 'Calendar link'),
      'https://example.com/calendar.ics',
    );
    await tester.tap(find.text('Add to Calee'));
    await tester.pumpAndSettle();

    expect(
      find.text(
        'Your calendar service credential is missing. Please sign out and sign in again.',
      ),
      findsOneWidget,
    );
  });

  testWidgets('Google guide shows Connect Google Calendar button', (
    tester,
  ) async {
    await tester.pumpWidget(_wrapGoogleGuide());

    expect(find.text('Connect Google Calendar'), findsOneWidget);
    expect(
      find.textContaining('Calee does not see your Google password'),
      findsOneWidget,
    );
  });

  testWidgets('Google guide exposes Paste calendar link instead fallback', (
    tester,
  ) async {
    await tester.pumpWidget(_wrapGoogleGuide());

    expect(find.text('Paste calendar link instead'), findsOneWidget);
  });

  testWidgets('Google paste-link form is provider-specific', (tester) async {
    await tester.pumpWidget(_wrapGoogleGuide());

    await tester.tap(find.text('Paste calendar link instead'));
    await tester.pumpAndSettle();

    expect(find.text('Add Google Calendar link'), findsOneWidget);
    expect(find.text('My Google Calendar'), findsOneWidget);
    expect(find.text('School calendar'), findsNothing);
    expect(find.textContaining('school calendar'), findsNothing);
  });

  testWidgets(
    'Google Connect button launches OAuth URL via injected launcher',
    (tester) async {
      final launchedUrls = <String>[];

      await tester.pumpWidget(
        _wrapGoogleGuide(
          hubClient: _StubOAuthHubClient(),
          launchUrl: (url) async => launchedUrls.add(url),
        ),
      );

      await tester.tap(find.text('Connect Google Calendar'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      await tester.pumpAndSettle();

      expect(launchedUrls, contains('https://accounts.google.com/oauth'));
      expect(find.text('I finished in browser'), findsOneWidget);
    },
  );

  testWidgets('Apple guide copy is polished', (tester) async {
    await tester.pumpWidget(_wrapAppleGuide());

    expect(find.text('Open the Apple Calendar app.'), findsOneWidget);
    expect(find.textContaining('Public Calendar'), findsWidgets);
    expect(find.text('My iCloud Calendar'), findsOneWidget);
    expect(find.text('webcal://p12-caldav.icloud.com/...'), findsOneWidget);
    expect(find.text('https://example.com/calendar.ics'), findsNothing);
  });

  testWidgets('Outlook guide uses Calendar Share Alias wording', (
    tester,
  ) async {
    await tester.pumpWidget(_wrapOutlookGuide());
    await tester.pump(const Duration(milliseconds: 100));

    expect(find.text('Add Outlook Calendar'), findsOneWidget);
    expect(find.textContaining('Calendar Share Alias'), findsWidgets);
  });

  testWidgets('Settings share page uses Calendar Share Alias wording', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: CaleeTheme.buildThemeData(),
        home: CalendarSharingAddressPage(
          hubClient: _StubHubClient(),
          accessToken: 'token',
          serviceId: 'svc1',
        ),
      ),
    );

    expect(find.text('Calendar Share Alias'), findsOneWidget);
    expect(find.text('Calendar Sharing Address'), findsNothing);
  });

  testWidgets('subscription calendar says Connected calendar', (tester) async {
    final subscription = ClientCalendar(
      id: 'cal1',
      name: 'My Shared Calendar',
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
}

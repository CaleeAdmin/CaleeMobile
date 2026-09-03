// Widget tests for SettingsPage content.
//
// Verifies the "Calendars and lists" management row is present and that the
// retired "Calee displays" row is no longer shown.
//
// SettingsPage loads local preferences via CaleePreferences, which performs a
// one-time migration from FlutterSecureStorage. Setting the migration-done flag
// in mock SharedPreferences (plus stubbing the secure-storage channel) keeps the
// platform channels from hanging the test.

import 'package:calee_mobile/data/api/calee_hub_client.dart';
import 'package:calee_mobile/data/models/client_bootstrap.dart';
import 'package:calee_mobile/data/models/client_calendar.dart';
import 'package:calee_mobile/data/models/client_preferences.dart';
import 'package:calee_mobile/data/models/external_calendar_connection.dart';
import 'package:calee_mobile/features/settings/calendar_collections_page.dart';
import 'package:calee_mobile/features/settings/settings_page.dart';
import 'package:calee_mobile/ui/calee_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _StubHubClient extends CaleeHubClient {
  _StubHubClient() : super(baseUri: Uri.parse('http://localhost'));

  @override
  Future<ClientCalendarList> calendars({required String accessToken}) async {
    return const ClientCalendarList(calendars: []);
  }

  // CalendarCollectionsPage — reached by tapping the "Calendars and lists"
  // row — loads connected external calendar accounts on open. No account is
  // connected in these tests.
  @override
  Future<List<ExternalCalendarConnection>> externalCalendarConnections({
    required String accessToken,
  }) async {
    return const [];
  }

  // Hub preferences are unavailable in these tests; SettingsRepository must
  // fall back to the local cache without surfacing a page-level error.
  @override
  Future<ClientPreferences> preferences({required String accessToken}) async {
    throw const CaleeHubException(statusCode: 500, message: 'Server error');
  }
}

/// Same as [_StubHubClient] but with one active Google Calendar connection, so
/// the Settings → Calendars and lists → Google Calendar management path can be
/// exercised end to end.
class _GoogleConnectedHubClient extends _StubHubClient {
  @override
  Future<List<ExternalCalendarConnection>> externalCalendarConnections({
    required String accessToken,
  }) async {
    return [
      ExternalCalendarConnection.fromJson(const {
        'id': 'conn1',
        'providerKey': 'google_calendar',
        'displayName': 'Google Calendar',
        'externalAccountEmail': 'user@gmail.com',
        'connectionStatus': 'active',
        'accessMode': 'read_only',
        'sourceOfTruthPolicy': 'external',
      }),
    ];
  }

  @override
  Future<List<ExternalCalendar>> externalCalendarsForConnection({
    required String accessToken,
    required String connectionId,
  }) async {
    return const [];
  }
}

class _FailThenSucceedHubClient extends CaleeHubClient {
  _FailThenSucceedHubClient() : super(baseUri: Uri.parse('http://localhost'));

  int callCount = 0;

  @override
  Future<ClientCalendarList> calendars({required String accessToken}) async {
    callCount++;
    if (callCount == 1) {
      throw Exception('network error');
    }
    return const ClientCalendarList(calendars: []);
  }

  @override
  Future<ClientPreferences> preferences({required String accessToken}) async {
    throw const CaleeHubException(statusCode: 500, message: 'Server error');
  }
}

ClientBootstrap _bootstrap() => ClientBootstrap(
  account: const ClientAccount(
    id: 'u1',
    displayName: 'Test User',
    primaryEmail: 'test@example.com',
    timeZone: 'Australia/Perth',
    status: 'active',
  ),
  services: const [],
  // The backend always ensures a default household for every account, so a
  // realistic household/default-user fixture must include one too.
  contexts: const ClientContexts(
    households: [
      ClientContext(
        id: 'hh1',
        type: 'household',
        name: 'My Family',
        role: 'admin',
        status: 'active',
      ),
    ],
    organisations: [],
  ),
  availableContexts: const [],
  capabilities: const {},
);

ClientBootstrap _businessBootstrap() => ClientBootstrap(
  account: const ClientAccount(
    id: 'u2',
    displayName: 'Work User',
    primaryEmail: 'work@example.com',
    timeZone: 'Australia/Perth',
    status: 'active',
  ),
  services: const [],
  contexts: const ClientContexts(
    households: [],
    organisations: [
      ClientContext(
        id: 'org1',
        type: 'organisation',
        name: 'Acme Corp',
        role: 'member',
        status: 'active',
      ),
    ],
  ),
  availableContexts: const [],
  capabilities: const {},
);

Widget _wrap({
  ClientBootstrap? bootstrap,
  CaleeHubClient? hubClient,
  VoidCallback? onNavigateToCalendar,
}) => MaterialApp(
  theme: CaleeTheme.buildThemeData(),
  home: Scaffold(
    body: SettingsPage(
      hubClient: hubClient ?? _StubHubClient(),
      accessToken: 'tok',
      bootstrap: bootstrap ?? _bootstrap(),
      onSignOut: () {},
      onNavigateToCalendar: onNavigateToCalendar,
    ),
  ),
);

// The "Connected services" section renders below the Account/Preferences/
// Manage sections in SettingsPage's ListView. The default 800x600 test
// surface never lays those rows out via the sliver list's cache extent, so
// find.text() finds nothing there even though the widget exists. Widen the
// surface instead of simulating a scroll gesture.
Future<void> _pumpTall(WidgetTester tester, Widget widget) async {
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  tester.view.physicalSize = const Size(800, 2400);
  tester.view.devicePixelRatio = 1.0;
  await tester.pumpWidget(widget);
  await tester.pumpAndSettle();
}

void main() {
  setUp(() {
    // Mark the secure-storage → shared-prefs migration as already done so
    // CaleePreferences.load() never reaches the FlutterSecureStorage channel.
    SharedPreferences.setMockInitialValues({
      'calee_pref_migrated_to_shared_prefs': true,
    });

    // Defensive: stub the secure-storage channel in case it is still hit.
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

  group('Connected services — warning subtitle', () {
    ClientService serviceWith({
      required String accessStatus,
      required String calendarCredentialStatus,
    }) => ClientService(
      id: 'business',
      displayName: 'Calee Business',
      baseUrl: 'https://business.example.com',
      launchUrl: 'https://business.example.com',
      serviceType: 'nextcloud_portal',
      accessStatus: accessStatus,
      calendarCredentialStatus: calendarCredentialStatus,
      source: 'portal',
      capabilities: const {},
    );

    ClientBootstrap bootstrapWith(ClientService service) => ClientBootstrap(
      account: const ClientAccount(
        id: 'u1',
        displayName: 'Test User',
        primaryEmail: 'test@example.com',
        timeZone: 'Australia/Perth',
        status: 'active',
      ),
      services: [service],
      contexts: const ClientContexts(households: [], organisations: []),
      availableContexts: const [],
      capabilities: const {},
    );

    testWidgets(
      'shows "Service access needs attention" when access status is not '
      'connected/active/healthy',
      (tester) async {
        final service = serviceWith(
          accessStatus: 'pending',
          calendarCredentialStatus: 'connected',
        );
        await _pumpTall(tester, _wrap(bootstrap: bootstrapWith(service)));

        expect(find.text('Service access needs attention'), findsOneWidget);
      },
    );

    testWidgets('shows "Calendar app setup needed" when access is active but '
        'calendar credential is missing', (tester) async {
      final service = serviceWith(
        accessStatus: 'active',
        calendarCredentialStatus: 'missing',
      );
      await _pumpTall(tester, _wrap(bootstrap: bootstrapWith(service)));

      expect(find.text('Calendar app setup needed'), findsOneWidget);
    });

    testWidgets(
      'shows "Connected" when access is active and calendar credential is '
      'connected',
      (tester) async {
        final service = serviceWith(
          accessStatus: 'active',
          calendarCredentialStatus: 'connected',
        );
        await _pumpTall(tester, _wrap(bootstrap: bootstrapWith(service)));

        expect(find.text('Connected'), findsOneWidget);
      },
    );
  });

  testWidgets('Settings shows "Calendars and lists" row', (tester) async {
    await tester.pumpWidget(_wrap());
    await tester.pumpAndSettle();

    expect(find.text('Calendars and lists'), findsOneWidget);
    expect(
      find.byKey(const Key('settings_calendar_collections_row')),
      findsOneWidget,
    );
  });

  // The keyed row is the real navigation control, so this proves the contract
  // end to end: tapping it pushes the actual CalendarCollectionsPage. Pumped
  // tall because the row lays out just below the default 600px test surface
  // and a tap there would silently miss.
  testWidgets(
    'settings_calendar_collections_row opens CalendarCollectionsPage',
    (tester) async {
      await _pumpTall(tester, _wrap());

      await tester.tap(
        find.byKey(const Key('settings_calendar_collections_row')),
      );
      await tester.pumpAndSettle();

      expect(find.byType(CalendarCollectionsPage), findsOneWidget);
    },
  );

  // End-to-end through the real rows: Settings → Calendars and lists → Google
  // Calendar → View calendar must ask the host (CaleeHomePage in production)
  // to select the Calendar tab, not merely pop back to the Home route.
  testWidgets(
    'Settings forwards onNavigateToCalendar through Calendars and lists to '
    'the Google management View calendar button',
    (tester) async {
      var navigateToCalendarCount = 0;
      await _pumpTall(
        tester,
        _wrap(
          hubClient: _GoogleConnectedHubClient(),
          onNavigateToCalendar: () => navigateToCalendarCount++,
        ),
      );

      await tester.tap(
        find.byKey(const Key('settings_calendar_collections_row')),
      );
      await tester.pumpAndSettle();
      expect(find.byType(CalendarCollectionsPage), findsOneWidget);

      final connectionRow = find.byKey(
        const Key('calendar_collections_google_calendar_connection_row'),
      );
      await tester.ensureVisible(connectionRow);
      await tester.pumpAndSettle();
      await tester.tap(connectionRow);
      await tester.pumpAndSettle();

      expect(
        find.byKey(const Key('google_calendar_selection_page_root')),
        findsOneWidget,
      );
      expect(navigateToCalendarCount, 0);

      final viewCalendar = find.byKey(
        const Key('google_calendar_view_calendar_button'),
      );
      await tester.ensureVisible(viewCalendar);
      await tester.pumpAndSettle();
      await tester.tap(viewCalendar);
      await tester.pumpAndSettle();

      expect(navigateToCalendarCount, 1);
      expect(
        find.byKey(const Key('google_calendar_selection_page_root')),
        findsNothing,
      );
    },
  );

  testWidgets('Settings shows "Connect a display" row', (tester) async {
    await tester.pumpWidget(_wrap());
    await tester.pumpAndSettle();

    expect(find.text('Connect a display'), findsOneWidget);
    expect(
      find.text('Scan the QR code shown on your Calee display.'),
      findsOneWidget,
    );
  });

  testWidgets('Settings shows "Add existing calendars" row', (tester) async {
    await tester.pumpWidget(_wrap());
    await tester.pumpAndSettle();

    expect(find.text('Add existing calendars'), findsOneWidget);
  });

  testWidgets(
    '"Add existing calendars" opens the calendar source picker directly',
    (tester) async {
      await tester.pumpWidget(_wrap());
      await tester.pumpAndSettle();

      await tester.tap(find.text('Add existing calendars'));
      await tester.pumpAndSettle();

      // Goes straight to the picker — no redundant "Your Calee calendar is
      // ready" splash (with its own "Add existing calendars" button) in
      // between, matching the "Calendars and lists" entry point.
      expect(find.text('Where is your calendar?'), findsOneWidget);
      expect(find.text('Your Calee calendar is ready'), findsNothing);
    },
  );

  group('People row — business/workspace visibility', () {
    testWidgets('Settings shows "People" row for household/default user', (
      tester,
    ) async {
      await tester.pumpWidget(_wrap());
      await tester.pumpAndSettle();

      expect(find.text('People'), findsOneWidget);
    });

    testWidgets('Settings hides "People" row for business/workspace user', (
      tester,
    ) async {
      await tester.pumpWidget(_wrap(bootstrap: _businessBootstrap()));
      await tester.pumpAndSettle();

      expect(find.text('People'), findsNothing);
    });
  });

  group('Preferences load error', () {
    testWidgets('shows a retry state instead of silently falling back to '
        'defaults', (tester) async {
      await tester.pumpWidget(_wrap(hubClient: _FailThenSucceedHubClient()));
      await tester.pumpAndSettle();

      expect(find.text("Couldn't load your preferences."), findsOneWidget);
      expect(find.text('Retry'), findsOneWidget);
      expect(find.text('First day of week'), findsNothing);
    });

    testWidgets('tapping Retry reloads and shows preferences on success', (
      tester,
    ) async {
      final hubClient = _FailThenSucceedHubClient();
      await tester.pumpWidget(_wrap(hubClient: hubClient));
      await tester.pumpAndSettle();

      await tester.tap(find.text('Retry'));
      await tester.pumpAndSettle();

      expect(hubClient.callCount, 2);
      expect(find.text("Couldn't load your preferences."), findsNothing);
      expect(find.text('First day of week'), findsOneWidget);
    });
  });
}

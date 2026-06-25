// Tests for the Google Calendar OAuth return flow:
//
//  1. "I finished in browser" button fetches active connections and navigates
//     to GoogleCalendarSelectionPage.
//  2. CaleeApp deep-link handler processes calee://external-calendar-connected,
//     preferring the connection that matches connectionId when multiple exist.
//  3. Error deep links show a snack bar and do not navigate.

import 'package:calee_mobile/app/calee_app.dart';
import 'package:calee_mobile/data/api/calee_hub_client.dart';
import 'package:calee_mobile/data/auth/session_store.dart';
import 'package:calee_mobile/data/models/client_bootstrap.dart';
import 'package:calee_mobile/data/models/external_calendar_connection.dart';
import 'package:calee_mobile/features/auth/auth_repository.dart';
import 'package:calee_mobile/features/auth/session_controller.dart';
import 'package:calee_mobile/features/calendar_follow/calendar_follow_link_controller.dart';
import 'package:calee_mobile/features/calendar_onboarding/provider_guides/google_calendar_guide_page.dart';
import 'package:calee_mobile/features/calendar_onboarding/provider_guides/google_calendar_selection_page.dart';
import 'package:calee_mobile/features/display_setup/display_activation_controller.dart';
import 'package:calee_mobile/features/display_setup/display_setup_link_controller.dart';
import 'package:calee_mobile/features/display_setup/display_setup_repository.dart';
import 'package:calee_mobile/features/external_calendar/external_calendar_connected_intent.dart';
import 'package:calee_mobile/features/external_calendar/external_calendar_connected_link_controller.dart';
import 'package:calee_mobile/features/local_subscriber/local_calendar_subscription_repository.dart';
import 'package:calee_mobile/ui/calee_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

// ── Helpers ───────────────────────────────────────────────────────────────────────────────

ExternalCalendarConnection _makeConnection({
  required String id,
  String providerKey = 'google_calendar',
  String connectionStatus = 'active',
}) => ExternalCalendarConnection.fromJson({
  'id': id,
  'providerKey': providerKey,
  'displayName': 'Google Calendar',
  'connectionStatus': connectionStatus,
  'accessMode': 'read_only',
  'sourceOfTruthPolicy': 'external',
});

// ── Stub hub clients ───────────────────────────────────────────────────────────────────

class _StubHubClient extends CaleeHubClient {
  _StubHubClient({this._connections = const []})
    : super(baseUri: Uri.parse('http://localhost'));

  final List<ExternalCalendarConnection> _connections;

  String? lastCalledConnectionId;

  @override
  Future<String> startExternalCalendarOAuth({
    required String accessToken,
    required String providerKey,
    String accessMode = 'read_only',
  }) async => 'https://accounts.google.com/oauth';

  @override
  Future<List<ExternalCalendarConnection>> externalCalendarConnections({
    required String accessToken,
  }) async => _connections;

  @override
  Future<List<ExternalCalendar>> externalCalendarsForConnection({
    required String accessToken,
    required String connectionId,
  }) async {
    lastCalledConnectionId = connectionId;
    return [];
  }
}

// ── Fake controllers for CaleeApp tests ────────────────────────────────────────────

class _FakeSessionController extends SessionController {
  _FakeSessionController()
    : super(
        repository: AuthRepository(
          hubClient: CaleeHubClient(),
          sessionStore: SessionStore(),
        ),
      );

  @override
  Future<void> restoreSession() async {}

  void finishRestore({bool signedIn = false}) {
    if (signedIn) {
      accessToken = 'test_token';
      bootstrap = _stubBootstrap();
    } else {
      accessToken = null;
      bootstrap = null;
    }
    isRestoringSession = false;
    notifyListeners();
  }
}

class _FakeDisplaySetupLinkController extends DisplaySetupLinkController {
  @override
  Future<void> init() async {}
}

class _FakeFollowLinkController extends CalendarFollowLinkController {
  @override
  Future<void> init() async {}
}

class _FakeExternalCalendarConnectedLinkController
    extends ExternalCalendarConnectedLinkController {
  @override
  Future<void> init() async {}

  void injectIntent(ExternalCalendarConnectedIntent intent) {
    pendingIntent = intent;
    notifyListeners();
  }
}

ClientBootstrap _stubBootstrap() => const ClientBootstrap(
  account: ClientAccount(
    id: 'u1',
    displayName: 'Test User',
    primaryEmail: 'test@example.com',
    timeZone: 'Australia/Perth',
    status: 'active',
  ),
  services: [],
  contexts: ClientContexts(households: [], organisations: []),
  availableContexts: [],
  capabilities: {},
);

// ── Shared prefs setup ────────────────────────────────────────────────────────────────

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

CaleeAppTestDependencies _makeAppDeps({
  required _StubHubClient hubClient,
  required _FakeSessionController session,
  _FakeExternalCalendarConnectedLinkController? calendarConnected,
}) {
  return CaleeAppTestDependencies(
    hubClient: hubClient,
    sessionController: session,
    displaySetupLinkController: _FakeDisplaySetupLinkController(),
    followLinkController: _FakeFollowLinkController(),
    displayActivationController: DisplayActivationController(
      repository: DisplaySetupRepository(hubClient: hubClient),
    ),
    localSubscriptionRepo: LocalCalendarSubscriptionRepository(),
    externalCalendarConnectedLinkController:
        calendarConnected ?? _FakeExternalCalendarConnectedLinkController(),
  );
}

// ── Tests ──────────────────────────────────────────────────────────────────────────────

void main() {
  group('ExternalCalendarConnectedLinkController.parseUri', () {
    test('success link with connectionId is parsed correctly', () {
      final uri = Uri.parse(
        'calee://external-calendar-connected'
        '?providerKey=google_calendar&connectionId=abc123',
      );
      final intent = ExternalCalendarConnectedLinkController.parseUri(uri);
      expect(intent, isNotNull);
      expect(intent!.providerKey, 'google_calendar');
      expect(intent.connectionId, 'abc123');
      expect(intent.isError, isFalse);
      expect(intent.isGoogle, isTrue);
    });

    test('error link is parsed correctly', () {
      final uri = Uri.parse(
        'calee://external-calendar-connected?status=error&reason=access_denied',
      );
      final intent = ExternalCalendarConnectedLinkController.parseUri(uri);
      expect(intent, isNotNull);
      expect(intent!.isError, isTrue);
      expect(intent.reason, 'access_denied');
      expect(intent.isGoogle, isFalse);
    });

    test('non-calendar calee URI returns null', () {
      final uri = Uri.parse('calee://display-setup?token=abc');
      expect(ExternalCalendarConnectedLinkController.parseUri(uri), isNull);
    });

    test('non-calee scheme returns null', () {
      final uri = Uri.parse('https://example.com/external-calendar-connected');
      expect(ExternalCalendarConnectedLinkController.parseUri(uri), isNull);
    });
  });

  group('GoogleCalendarGuidePage — I finished in browser', () {
    setUp(_setUpSharedPrefs);
    tearDown(_tearDownSharedPrefs);

    testWidgets(
      'tapping "I finished in browser" navigates to GoogleCalendarSelectionPage '
      'when an active Google connection exists',
      (tester) async {
        final connection = _makeConnection(id: 'conn1');
        final hubClient = _StubHubClient(connections: [connection]);
        bool urlLaunched = false;

        await tester.pumpWidget(
          MaterialApp(
            theme: CaleeTheme.buildThemeData(),
            home: GoogleCalendarGuidePage(
              hubClient: hubClient,
              accessToken: 'token',
              services: const [],
              accountId: 'acct1',
              onDone: () {},
              onViewCalendar: () {},
              launchUrl: (url) async {
                urlLaunched = true;
              },
            ),
          ),
        );

        // Advance to the "waiting for browser" view.
        await tester.tap(find.text('Connect Google Calendar'));
        await tester.pumpAndSettle();

        expect(urlLaunched, isTrue);
        expect(find.text('I finished in browser'), findsOneWidget);

        // Tap the fallback button.
        await tester.tap(find.text('I finished in browser'));
        await tester.pumpAndSettle();

        // Should navigate to GoogleCalendarSelectionPage.
        expect(find.byType(GoogleCalendarSelectionPage), findsOneWidget);
      },
    );

    testWidgets('"I finished in browser" shows connection-not-found view '
        'when no active Google connection exists', (tester) async {
      final hubClient = _StubHubClient(connections: []);
      bool urlLaunched = false;

      await tester.pumpWidget(
        MaterialApp(
          theme: CaleeTheme.buildThemeData(),
          home: GoogleCalendarGuidePage(
            hubClient: hubClient,
            accessToken: 'token',
            services: const [],
            accountId: 'acct1',
            onDone: () {},
            onViewCalendar: () {},
            launchUrl: (url) async {
              urlLaunched = true;
            },
          ),
        ),
      );

      await tester.tap(find.text('Connect Google Calendar'));
      await tester.pumpAndSettle();

      expect(urlLaunched, isTrue);

      await tester.tap(find.text('I finished in browser'));
      await tester.pumpAndSettle();

      // Should stay on guide page and show not-found state.
      expect(find.byType(GoogleCalendarSelectionPage), findsNothing);
      expect(find.text('Connection not found yet'), findsOneWidget);
    });
  });

  group('CaleeApp — external-calendar-connected deep link', () {
    setUp(() {
      SharedPreferences.setMockInitialValues({});
    });

    testWidgets(
      'deep link with connectionId navigates to GoogleCalendarSelectionPage '
      'using the matching connection',
      (tester) async {
        final conn1 = _makeConnection(id: 'conn1');
        final conn2 = _makeConnection(id: 'conn2');
        final hubClient = _StubHubClient(connections: [conn1, conn2]);
        final session = _FakeSessionController();
        final linkController = _FakeExternalCalendarConnectedLinkController();

        await tester.pumpWidget(
          CaleeApp.forTesting(
            testDeps: _makeAppDeps(
              hubClient: hubClient,
              session: session,
              calendarConnected: linkController,
            ),
          ),
        );

        session.finishRestore(signedIn: true);
        await tester.pump();

        // Inject deep link referencing conn2.
        linkController.injectIntent(
          const ExternalCalendarConnectedIntent(
            providerKey: 'google_calendar',
            connectionId: 'conn2',
          ),
        );
        await tester.pumpAndSettle();

        // GoogleCalendarSelectionPage should be shown.
        expect(find.byType(GoogleCalendarSelectionPage), findsOneWidget);

        // The selection page fetches calendars for the correct connection.
        expect(hubClient.lastCalledConnectionId, 'conn2');
      },
    );

    testWidgets(
      'deep link without connectionId uses first active Google connection',
      (tester) async {
        final conn1 = _makeConnection(id: 'conn1');
        final hubClient = _StubHubClient(connections: [conn1]);
        final session = _FakeSessionController();
        final linkController = _FakeExternalCalendarConnectedLinkController();

        await tester.pumpWidget(
          CaleeApp.forTesting(
            testDeps: _makeAppDeps(
              hubClient: hubClient,
              session: session,
              calendarConnected: linkController,
            ),
          ),
        );

        session.finishRestore(signedIn: true);
        await tester.pump();

        linkController.injectIntent(
          const ExternalCalendarConnectedIntent(providerKey: 'google_calendar'),
        );
        await tester.pumpAndSettle();

        expect(find.byType(GoogleCalendarSelectionPage), findsOneWidget);
        expect(hubClient.lastCalledConnectionId, 'conn1');
      },
    );

    testWidgets(
      'error deep link shows snack bar and does not navigate to selection page',
      (tester) async {
        final hubClient = _StubHubClient(connections: []);
        final session = _FakeSessionController();
        final linkController = _FakeExternalCalendarConnectedLinkController();

        await tester.pumpWidget(
          CaleeApp.forTesting(
            testDeps: _makeAppDeps(
              hubClient: hubClient,
              session: session,
              calendarConnected: linkController,
            ),
          ),
        );

        session.finishRestore(signedIn: true);
        await tester.pump();

        linkController.injectIntent(
          const ExternalCalendarConnectedIntent(
            status: 'error',
            reason: 'access_denied',
          ),
        );
        // Use bounded pumps: pumpAndSettle times out because the home screen
        // contains an infinite animation (CircularProgressIndicator).
        await tester.pump(); // fire postFrameCallback → show snackbar
        await tester.pump(const Duration(milliseconds: 400)); // snackbar entry

        expect(find.byType(GoogleCalendarSelectionPage), findsNothing);
        expect(
          find.textContaining('Google Calendar was not connected'),
          findsOneWidget,
        );
      },
    );

    testWidgets(
      'connectionId is preferred over first connection when both are active',
      (tester) async {
        // conn1 is first but conn2 matches the connectionId in the deep link.
        final conn1 = _makeConnection(id: 'conn1');
        final conn2 = _makeConnection(id: 'conn2');
        final hubClient = _StubHubClient(connections: [conn1, conn2]);
        final session = _FakeSessionController();
        final linkController = _FakeExternalCalendarConnectedLinkController();

        await tester.pumpWidget(
          CaleeApp.forTesting(
            testDeps: _makeAppDeps(
              hubClient: hubClient,
              session: session,
              calendarConnected: linkController,
            ),
          ),
        );

        session.finishRestore(signedIn: true);
        await tester.pump();

        linkController.injectIntent(
          const ExternalCalendarConnectedIntent(
            providerKey: 'google_calendar',
            connectionId: 'conn2',
          ),
        );
        await tester.pumpAndSettle();

        // conn2 should be selected (verified by which id is used to load calendars).
        expect(hubClient.lastCalledConnectionId, 'conn2');
      },
    );

    testWidgets(
      'deep link received while session is restoring is processed after sign-in',
      (tester) async {
        final conn1 = _makeConnection(id: 'conn1');
        final hubClient = _StubHubClient(connections: [conn1]);
        final session = _FakeSessionController();
        final linkController = _FakeExternalCalendarConnectedLinkController();

        await tester.pumpWidget(
          CaleeApp.forTesting(
            testDeps: _makeAppDeps(
              hubClient: hubClient,
              session: session,
              calendarConnected: linkController,
            ),
          ),
        );

        // Inject intent while session is still restoring.
        linkController.injectIntent(
          const ExternalCalendarConnectedIntent(
            providerKey: 'google_calendar',
            connectionId: 'conn1',
          ),
        );
        await tester.pump();

        // Session restore completes with user signed in.
        session.finishRestore(signedIn: true);
        await tester.pumpAndSettle();

        expect(find.byType(GoogleCalendarSelectionPage), findsOneWidget);
      },
    );

    testWidgets(
      'duplicate deep link does not push a second GoogleCalendarSelectionPage',
      (tester) async {
        final conn1 = _makeConnection(id: 'conn1');
        final hubClient = _StubHubClient(connections: [conn1]);
        final session = _FakeSessionController();
        final linkController = _FakeExternalCalendarConnectedLinkController();

        await tester.pumpWidget(
          CaleeApp.forTesting(
            testDeps: _makeAppDeps(
              hubClient: hubClient,
              session: session,
              calendarConnected: linkController,
            ),
          ),
        );

        session.finishRestore(signedIn: true);
        await tester.pump();

        // Inject the same intent twice in rapid succession.
        linkController.injectIntent(
          const ExternalCalendarConnectedIntent(
            providerKey: 'google_calendar',
            connectionId: 'conn1',
          ),
        );
        await tester.pump();

        linkController.injectIntent(
          const ExternalCalendarConnectedIntent(
            providerKey: 'google_calendar',
            connectionId: 'conn1',
          ),
        );
        await tester.pumpAndSettle();

        // Only one GoogleCalendarSelectionPage should be on the stack.
        expect(find.byType(GoogleCalendarSelectionPage), findsOneWidget);
      },
    );
  });
}

// Widget tests: verifying refreshBootstrap() is called at key lifecycle points.
//
// 1. After display activation succeeds, refreshBootstrap() should be called.
// 2. After a Google OAuth deep link is received and handled, refreshBootstrap()
//    should be called.

import 'package:calee_mobile/app/calee_app.dart';
import 'package:calee_mobile/data/api/calee_hub_client.dart';
import 'package:calee_mobile/data/auth/session_store.dart';
import 'package:calee_mobile/data/models/client_bootstrap.dart';
import 'package:calee_mobile/data/models/external_calendar_connection.dart';
import 'package:calee_mobile/features/auth/auth_repository.dart';
import 'package:calee_mobile/features/auth/session_controller.dart';
import 'package:calee_mobile/features/calendar_follow/calendar_follow_link_controller.dart';
import 'package:calee_mobile/features/calendar_onboarding/provider_guides/google_calendar_selection_page.dart';
import 'package:calee_mobile/features/display_setup/display_activation_controller.dart';
import 'package:calee_mobile/features/display_setup/display_activation_success_page.dart';
import 'package:calee_mobile/features/display_setup/display_setup_intent.dart';
import 'package:calee_mobile/features/display_setup/display_setup_link_controller.dart';
import 'package:calee_mobile/features/display_setup/display_setup_repository.dart';
import 'package:calee_mobile/features/external_calendar/external_calendar_connected_link_controller.dart';
import 'package:calee_mobile/features/local_subscriber/local_calendar_subscription_repository.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

// ── Token ─────────────────────────────────────────────────────────────────────

const _validToken = 'AbCdEfGhIjKlMnOpQrStUvWxYz0123456789_-AB';

// ── Stub bootstrap ────────────────────────────────────────────────────────────

ClientBootstrap _stubBootstrap() => const ClientBootstrap(
  account: ClientAccount(
    id: 'u1',
    displayName: 'Test',
    primaryEmail: 'test@example.com',
    timeZone: 'Australia/Perth',
    status: 'active',
  ),
  services: [],
  contexts: ClientContexts(households: [], organisations: []),
  availableContexts: [],
  capabilities: {},
);

// ── Fake session controller ───────────────────────────────────────────────────

/// SessionController whose [restoreSession] is a no-op so tests drive state
/// directly.
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
      accessToken = 'test_access_token';
      bootstrap = _stubBootstrap();
    } else {
      accessToken = null;
      bootstrap = null;
    }
    isRestoringSession = false;
    notifyListeners();
  }

  /// Simulates a successful sign-in without going through LoginPage UI.
  void simulateSignIn() {
    accessToken = 'test_access_token';
    bootstrap = _stubBootstrap();
    notifyListeners();
  }

  @override
  Future<void> refreshBootstrap() async {
    // Overridden below by _TrackingSessionController.
  }
}

/// Wraps [_FakeSessionController] and counts calls to [refreshBootstrap].
class _TrackingSessionController extends _FakeSessionController {
  int refreshBootstrapCallCount = 0;
  bool refreshBootstrapCompleted = false;

  @override
  Future<void> refreshBootstrap() async {
    refreshBootstrapCallCount++;
    bootstrap = _stubBootstrap();
    refreshBootstrapCompleted = true;
    notifyListeners();
  }
}

// ── Fake link controllers ─────────────────────────────────────────────────────

class _FakeDisplaySetupLinkController extends DisplaySetupLinkController {
  @override
  Future<void> init() async {}

  void injectIntent(String token) {
    pendingIntent = DisplaySetupIntent(
      token: token,
      sourceUri: Uri.parse('calee://native-login/$token'),
    );
    notifyListeners();
  }
}

class _FakeFollowLinkController extends CalendarFollowLinkController {
  @override
  Future<void> init() async {}
}

class _FakeExternalCalendarConnectedLinkController
    extends ExternalCalendarConnectedLinkController {
  @override
  Future<void> init() async {}

  void injectGoogleIntent({String connectionId = 'conn1'}) {
    handleUri(
      Uri.parse(
        'calee://external-calendar-connected'
        '?providerKey=google_calendar'
        '&connectionId=$connectionId'
        '&status=connected',
      ),
    );
  }
}

// ── Fake display activation controller ───────────────────────────────────────

/// A DisplayActivationController that always succeeds without a network call.
class _SucceedingActivationController extends DisplayActivationController {
  _SucceedingActivationController()
    : super(repository: DisplaySetupRepository(hubClient: CaleeHubClient()));

  @override
  Future<bool> activate({
    required String accessToken,
    required String token,
  }) async {
    return true;
  }
}

// ── Fake hub client ───────────────────────────────────────────────────────────

/// CaleeHubClient that stubs network calls used in the OAuth test path:
/// - Returns one active Google connection so refreshBootstrap() is reached.
/// - Returns an empty calendars list to avoid further network calls.
class _FakeHubClient extends CaleeHubClient {
  int resetTransportCallCount = 0;

  @override
  void resetTransport() {
    resetTransportCallCount += 1;
  }

  @override
  Future<List<ExternalCalendarConnection>> externalCalendarConnections({
    required String accessToken,
  }) async {
    return const [
      ExternalCalendarConnection(
        id: 'conn1',
        providerKey: 'google_calendar',
        displayName: 'Google Calendar',
        connectionStatus: 'active',
        accessMode: 'read',
        sourceOfTruthPolicy: 'mirror',
      ),
    ];
  }

  @override
  Future<List<ExternalCalendar>> externalCalendarsForConnection({
    required String accessToken,
    required String connectionId,
  }) async {
    return [];
  }
}

// ── Test dep factory ──────────────────────────────────────────────────────────

CaleeAppTestDependencies _makeDeps({
  required _TrackingSessionController session,
  _FakeDisplaySetupLinkController? displaySetup,
  _FakeExternalCalendarConnectedLinkController? externalCalendar,
  DisplayActivationController? activationController,
  CaleeHubClient? hubClient,
}) {
  final hub = hubClient ?? CaleeHubClient();
  return CaleeAppTestDependencies(
    hubClient: hub,
    sessionController: session,
    displaySetupLinkController:
        displaySetup ?? _FakeDisplaySetupLinkController(),
    followLinkController: _FakeFollowLinkController(),
    displayActivationController:
        activationController ??
        DisplayActivationController(
          repository: DisplaySetupRepository(hubClient: hub),
        ),
    localSubscriptionRepo: LocalCalendarSubscriptionRepository(),
    externalCalendarConnectedLinkController: externalCalendar,
  );
}

// ── Tests ─────────────────────────────────────────────────────────────────────

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  testWidgets(
    'refreshBootstrap is called after display activation succeeds',
    (tester) async {
      final session = _TrackingSessionController();
      final displaySetup = _FakeDisplaySetupLinkController();
      final activation = _SucceedingActivationController();

      await tester.pumpWidget(
        CaleeApp.forTesting(
          testDeps: _makeDeps(
            session: session,
            displaySetup: displaySetup,
            activationController: activation,
          ),
        ),
      );

      // Inject intent while still restoring — CaleeApp will wait for session.
      displaySetup.injectIntent(_validToken);
      await tester.pump();

      // Finish restore as logged-out → landing page is shown.
      session.finishRestore(signedIn: false);
      await tester.pump();

      // Tap "I already have an account" — sets _displaySetupThroughLandingPage=true.
      expect(find.text('Connect this display to Calee'), findsOneWidget);
      await tester.tap(find.text('I already have an account'));
      await tester.pump();

      // Simulate sign-in completing (bypasses the LoginPage form).
      session.simulateSignIn();
      await tester.pump();

      // Wait for activation + bootstrap refresh to complete.
      await tester.pumpAndSettle();

      expect(session.refreshBootstrapCallCount, 1);
      expect(session.refreshBootstrapCompleted, isTrue);
      expect(find.byType(DisplayActivationSuccessPage), findsOneWidget);
    },
  );

  testWidgets('app resume refreshes bootstrap when signed in', (tester) async {
    final session = _TrackingSessionController();
    final hub = _FakeHubClient();

    await tester.pumpWidget(
      CaleeApp.forTesting(
        testDeps: _makeDeps(session: session, hubClient: hub),
      ),
    );

    // Start as signed in.
    session.finishRestore(signedIn: true);
    await tester.pump();

    final countBefore = session.refreshBootstrapCallCount;

    // Pause the app so _transportMayBeStale is set.
    await tester.binding.handleLifecycleMessage('AppLifecycleState.paused');
    await tester.pump();

    // Resume — should trigger refreshBootstrap() because session is signed in.
    await tester.binding.handleLifecycleMessage('AppLifecycleState.resumed');
    await tester.pump();

    expect(
      session.refreshBootstrapCallCount,
      countBefore + 1,
      reason: 'app resume while signed in should refresh bootstrap',
    );
    expect(hub.resetTransportCallCount, 1);
  });

  testWidgets(
    'app resume does not refresh bootstrap when signed out',
    (tester) async {
      final session = _TrackingSessionController();
      final hub = _FakeHubClient();

      await tester.pumpWidget(
        CaleeApp.forTesting(
          testDeps: _makeDeps(session: session, hubClient: hub),
        ),
      );

      session.finishRestore(signedIn: false);
      await tester.pump();

      await tester.binding.handleLifecycleMessage('AppLifecycleState.inactive');
      await tester.pump();
      await tester.binding.handleLifecycleMessage('AppLifecycleState.resumed');
      await tester.pump();

      expect(hub.resetTransportCallCount, 1);
      expect(session.refreshBootstrapCallCount, 0);
    },
  );

  testWidgets(
    'refreshBootstrap is called after Google OAuth deep link is handled',
    (tester) async {
      final session = _TrackingSessionController();
      final externalCalendar = _FakeExternalCalendarConnectedLinkController();
      final hub = _FakeHubClient();

      await tester.pumpWidget(
        CaleeApp.forTesting(
          testDeps: _makeDeps(
            session: session,
            externalCalendar: externalCalendar,
            hubClient: hub,
          ),
        ),
      );

      // Start signed in so the OAuth intent is processed immediately.
      session.finishRestore(signedIn: true);
      await tester.pump();

      // Simulate the Google OAuth deep link arriving.
      externalCalendar.injectGoogleIntent();
      await tester.pump();

      // Wait for async handling (connections fetch + bootstrap refresh).
      await tester.pumpAndSettle();

      expect(session.refreshBootstrapCallCount, 1);
      expect(session.refreshBootstrapCompleted, isTrue);
      expect(find.byType(GoogleCalendarSelectionPage), findsOneWidget);
    },
  );
}

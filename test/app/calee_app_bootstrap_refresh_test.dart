// Widget tests: verifying refreshBootstrap() is called at key lifecycle points.
//
// 1. After display activation succeeds, refreshBootstrap() should be called.
// 2. After a Google OAuth deep link is received and handled, the
//    GoogleCalendarSelectionPage is opened WITHOUT an extra refreshBootstrap()
//    call (the lifecycle resume already handles that).

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
import 'package:flutter/material.dart';
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

const _kActiveGoogleConnection = ExternalCalendarConnection(
  id: 'conn1',
  providerKey: 'google_calendar',
  displayName: 'Google Calendar',
  connectionStatus: 'active',
  accessMode: 'read',
  sourceOfTruthPolicy: 'mirror',
);

/// CaleeHubClient that stubs network calls used in the OAuth test path.
///
/// [connectionsResponses] is a list of responses returned by sequential calls
/// to [externalCalendarConnections]. Each entry is either a
/// `List<ExternalCalendarConnection>` (success) or an [Exception] (thrown).
/// If the call count exceeds the list, the last entry is repeated.
class _FakeHubClient extends CaleeHubClient {
  _FakeHubClient({List<Object>? connectionsResponses})
      : _connectionsResponses =
            connectionsResponses ?? const [[_kActiveGoogleConnection]];

  final List<Object> _connectionsResponses;
  int _connectionsCallCount = 0;
  int resetTransportCallCount = 0;

  @override
  void resetTransport() {
    resetTransportCallCount += 1;
  }

  @override
  Future<List<ExternalCalendarConnection>> externalCalendarConnections({
    required String accessToken,
  }) async {
    final i = _connectionsCallCount++;
    final response = i < _connectionsResponses.length
        ? _connectionsResponses[i]
        : _connectionsResponses.last;
    if (response is Exception) throw response;
    return response as List<ExternalCalendarConnection>;
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

  testWidgets('refreshBootstrap is called after display activation succeeds', (
    tester,
  ) async {
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
  });

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
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    await tester.pump();

    // Resume — should trigger refreshBootstrap() because session is signed in.
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump();

    expect(
      session.refreshBootstrapCallCount,
      countBefore + 1,
      reason: 'app resume while signed in should refresh bootstrap',
    );
    expect(hub.resetTransportCallCount, 1);
  });

  testWidgets('app resume does not refresh bootstrap when signed out', (
    tester,
  ) async {
    final session = _TrackingSessionController();
    final hub = _FakeHubClient();

    await tester.pumpWidget(
      CaleeApp.forTesting(
        testDeps: _makeDeps(session: session, hubClient: hub),
      ),
    );

    session.finishRestore(signedIn: false);
    await tester.pump();

    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    await tester.pump();
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump();

    expect(hub.resetTransportCallCount, 1);
    expect(session.refreshBootstrapCallCount, 0);
  });

  testWidgets(
    'Google OAuth deep link opens GoogleCalendarSelectionPage without extra refreshBootstrap',
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

      final bootstrapCountAfterRestore = session.refreshBootstrapCallCount;

      // Simulate the Google OAuth deep link arriving.
      externalCalendar.injectGoogleIntent();
      await tester.pump();

      // Wait for async handling (connections fetch only — no extra bootstrap).
      await tester.pumpAndSettle();

      // Regression: no extra refreshBootstrap() call should happen inside
      // _openGoogleCalendarSelectionFromDeepLink; the lifecycle resume already
      // handles it, and duplicating it causes a brief disconnected-state flash.
      expect(
        session.refreshBootstrapCallCount,
        bootstrapCountAfterRestore,
        reason: 'no extra refreshBootstrap should occur during OAuth return',
      );

      // GoogleCalendarSelectionPage must still open.
      expect(find.byType(GoogleCalendarSelectionPage), findsOneWidget);

      // Existing signed-in state must be intact.
      expect(session.isSignedIn, isTrue);
      expect(session.bootstrap, isNotNull);
    },
  );

  testWidgets(
    'Google OAuth deep link retries on transient NETWORK_ERROR and opens GoogleCalendarSelectionPage',
    (tester) async {
      final session = _TrackingSessionController();
      final externalCalendar = _FakeExternalCalendarConnectedLinkController();
      // First call throws a transient CaleeHubException; second succeeds.
      final hub = _FakeHubClient(
        connectionsResponses: [
          const CaleeHubException(
            statusCode: 0,
            code: 'NETWORK_ERROR',
            message: 'Check your connection and try again.',
          ),
          const [_kActiveGoogleConnection],
        ],
      );

      await tester.pumpWidget(
        CaleeApp.forTesting(
          testDeps: _makeDeps(
            session: session,
            externalCalendar: externalCalendar,
            hubClient: hub,
          ),
        ),
      );

      session.finishRestore(signedIn: true);
      await tester.pump();

      externalCalendar.injectGoogleIntent();
      await tester.pump();

      // pumpAndSettle handles the retry delay and async operations.
      await tester.pumpAndSettle();

      // GoogleCalendarSelectionPage must open after the retry succeeds.
      expect(find.byType(GoogleCalendarSelectionPage), findsOneWidget);

      // resetTransport must have been called (once before each attempt).
      expect(
        hub.resetTransportCallCount,
        greaterThanOrEqualTo(2),
        reason: 'resetTransport called before each connection attempt',
      );

      // Session state must be intact.
      expect(session.isSignedIn, isTrue);
      expect(session.bootstrap, isNotNull);
    },
  );

  testWidgets(
    'Google OAuth deep link does not retry on non-transient error and shows snackbar',
    (tester) async {
      final session = _TrackingSessionController();
      final externalCalendar = _FakeExternalCalendarConnectedLinkController();
      // 401 is a non-transient error — must not be retried.
      final hub = _FakeHubClient(
        connectionsResponses: [
          const CaleeHubException(
            statusCode: 401,
            code: 'UNAUTHORIZED',
            message: 'Unauthorized',
          ),
          // A second entry that must never be reached.
          const [_kActiveGoogleConnection],
        ],
      );

      await tester.pumpWidget(
        CaleeApp.forTesting(
          testDeps: _makeDeps(
            session: session,
            externalCalendar: externalCalendar,
            hubClient: hub,
          ),
        ),
      );

      session.finishRestore(signedIn: true);
      await tester.pump();

      externalCalendar.injectGoogleIntent();
      await tester.pump(); // drives the 401 error through the async chain
      await tester.pump(); // shows snackbar (post-frame callback fires)

      // Must NOT open GoogleCalendarSelectionPage on a non-transient error.
      expect(find.byType(GoogleCalendarSelectionPage), findsNothing);

      // The friendly snackbar must appear.
      expect(
        find.text('Could not load Google Calendar connection. Please try again.'),
        findsOneWidget,
      );

      // Only one attempt was made (no retries on 401).
      expect(hub.resetTransportCallCount, 1);

      // Session state must be intact — no sign-out or empty-state navigation.
      expect(session.isSignedIn, isTrue);
      expect(session.bootstrap, isNotNull);
    },
  );
}

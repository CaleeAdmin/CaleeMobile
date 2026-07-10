// Widget tests: display-setup QR flow routing after session restore.
//
// Verifies that _onSessionChanged correctly routes to DisplaySetupLandingPage
// when a pending display-setup intent exists and session restore finishes
// with no signed-in session.

import 'dart:async';

import 'package:calee_mobile/app/calee_app.dart';
import 'package:calee_mobile/data/api/calee_hub_client.dart';
import 'package:calee_mobile/data/auth/session_store.dart';
import 'package:calee_mobile/data/models/client_bootstrap.dart';
import 'package:calee_mobile/features/auth/auth_repository.dart';
import 'package:calee_mobile/features/auth/session_controller.dart';
import 'package:calee_mobile/features/calendar_follow/calendar_follow_link_controller.dart';
import 'package:calee_mobile/features/display_setup/display_activation_controller.dart';
import 'package:calee_mobile/features/display_setup/display_activation_success_page.dart';
import 'package:calee_mobile/features/display_setup/display_setup_intent.dart';
import 'package:calee_mobile/features/display_setup/display_setup_link_controller.dart';
import 'package:calee_mobile/features/display_setup/display_setup_repository.dart';
import 'package:calee_mobile/features/local_subscriber/local_calendar_subscription_repository.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

// ── Token ─────────────────────────────────────────────────────────────────────

const _validToken = 'AbCdEfGhIjKlMnOpQrStUvWxYz0123456789_-AB';
const _otherToken = 'ZzYyXxWwVvUuTtSsRrQqPpOoNnMmLlKkJj012345';

// ── Fake controllers ──────────────────────────────────────────────────────────

/// SessionController whose [restoreSession] is a no-op so tests drive state.
class _FakeSessionController extends SessionController {
  _FakeSessionController()
    : super(
        repository: AuthRepository(
          hubClient: CaleeHubClient(),
          sessionStore: SessionStore(),
        ),
      );

  /// No-op — tests set state directly via [finishRestore].
  @override
  Future<void> restoreSession() async {}

  /// Simulates session restore finishing.
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

  int refreshBootstrapCallCount = 0;
  Completer<void>? refreshBootstrapCompleter;

  @override
  Future<void> refreshBootstrap() async {
    refreshBootstrapCallCount += 1;
    final completer = refreshBootstrapCompleter;
    if (completer != null) {
      await completer.future;
    }
    bootstrap = _stubBootstrap();
    notifyListeners();
  }

  /// Re-emits a session notification without changing state — simulates a
  /// bootstrap refresh (or similar) firing while an intent is pending.
  void pokeListeners() => notifyListeners();

  /// Avoids FlutterSecureStorage platform-channel calls in widget tests.
  @override
  Future<void> signOut() async {
    accessToken = null;
    refreshToken = null;
    bootstrap = null;
    notifyListeners();
  }
}

/// DisplaySetupLinkController whose [init] is a no-op.
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

/// DisplaySetupLinkController whose [init] leaves a pending intent set
/// directly (without calling notifyListeners), simulating the real
/// controller resolving getInitialLink with a link already present before
/// CaleeApp's listener could react to a notification. Used to verify
/// CaleeApp's post-init safety net (which re-evaluates pendingIntent once
/// init() completes) still opens the confirmation route.
class _PendingIntentOnInitDisplaySetupLinkController
    extends DisplaySetupLinkController {
  _PendingIntentOnInitDisplaySetupLinkController(this._token);

  final String _token;

  @override
  Future<void> init() async {
    pendingIntent = DisplaySetupIntent(
      token: _token,
      sourceUri: Uri.parse('calee://native-login/$_token'),
    );
  }
}

/// CalendarFollowLinkController whose [init] is a no-op.
class _FakeFollowLinkController extends CalendarFollowLinkController {
  @override
  Future<void> init() async {}
}

class _FakeDisplayActivationController extends DisplayActivationController {
  _FakeDisplayActivationController()
    : super(repository: DisplaySetupRepository(hubClient: CaleeHubClient()));

  @override
  Future<bool> activate({
    required String accessToken,
    required String token,
  }) async {
    isLoading = true;
    notifyListeners();
    isLoading = false;
    notifyListeners();
    return true;
  }
}

// ── Helpers ───────────────────────────────────────────────────────────────────

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

CaleeAppTestDependencies _makeDeps({
  _FakeSessionController? session,
  DisplaySetupLinkController? displaySetup,
  DisplayActivationController? displayActivationController,
}) {
  final hub = CaleeHubClient();
  return CaleeAppTestDependencies(
    hubClient: hub,
    sessionController: session ?? _FakeSessionController(),
    displaySetupLinkController:
        displaySetup ?? _FakeDisplaySetupLinkController(),
    followLinkController: _FakeFollowLinkController(),
    displayActivationController:
        displayActivationController ??
        DisplayActivationController(
          repository: DisplaySetupRepository(hubClient: hub),
        ),
    localSubscriptionRepo: LocalCalendarSubscriptionRepository(),
  );
}

// ── Tests ─────────────────────────────────────────────────────────────────────

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  testWidgets(
    'pending display intent + restore finishes logged out → DisplaySetupLandingPage',
    (tester) async {
      final session = _FakeSessionController();
      final displaySetup = _FakeDisplaySetupLinkController();

      await tester.pumpWidget(
        CaleeApp.forTesting(
          testDeps: _makeDeps(session: session, displaySetup: displaySetup),
        ),
      );

      // Inject the intent while still restoring.
      displaySetup.injectIntent(_validToken);
      await tester.pump();

      // Session restore completes with no session.
      session.finishRestore(signedIn: false);
      await tester.pump();

      expect(find.text('Connect this display to Calee'), findsOneWidget);
      expect(find.text('Create account'), findsOneWidget);
      expect(find.text('I already have an account'), findsOneWidget);
    },
  );

  testWidgets(
    'pending display intent + restore finishes signed in → does NOT show landing page',
    (tester) async {
      final session = _FakeSessionController();
      final displaySetup = _FakeDisplaySetupLinkController();

      await tester.pumpWidget(
        CaleeApp.forTesting(
          testDeps: _makeDeps(session: session, displaySetup: displaySetup),
        ),
      );

      displaySetup.injectIntent(_validToken);
      await tester.pump();

      // Session restore completes with a signed-in session.
      session.finishRestore(signedIn: true);
      await tester.pump();

      expect(find.text('Connect this display to Calee'), findsNothing);
      // Confirmation page is pushed via navigator — landing page must not show.
      expect(find.text('Sign in to Calee'), findsNothing);
    },
  );

  testWidgets(
    'no pending display intent + restore finishes logged out → WelcomePage',
    (tester) async {
      final session = _FakeSessionController();

      await tester.pumpWidget(
        CaleeApp.forTesting(testDeps: _makeDeps(session: session)),
      );

      // Session restore completes with no session, and no display intent.
      session.finishRestore(signedIn: false);
      await tester.pump();

      expect(find.text('Welcome to Calee'), findsOneWidget);
      expect(find.text('Create account'), findsOneWidget);
      expect(find.text('I already have an account'), findsOneWidget);
      expect(find.text('Connect this display to Calee'), findsNothing);
    },
  );

  testWidgets('app resume refreshes bootstrap when signed in', (tester) async {
    final session = _FakeSessionController();

    await tester.pumpWidget(
      CaleeApp.forTesting(testDeps: _makeDeps(session: session)),
    );

    session.finishRestore(signedIn: true);
    await tester.pump();

    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    await tester.pump();
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    expect(session.refreshBootstrapCallCount, 1);
  });

  testWidgets('app resume does not refresh bootstrap when signed out', (
    tester,
  ) async {
    final session = _FakeSessionController();

    await tester.pumpWidget(
      CaleeApp.forTesting(testDeps: _makeDeps(session: session)),
    );

    session.finishRestore(signedIn: false);
    await tester.pump();

    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    await tester.pump();
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    expect(session.refreshBootstrapCallCount, 0);
  });

  testWidgets(
    'successful display activation refreshes bootstrap before success page',
    (tester) async {
      final session = _FakeSessionController();
      final displaySetup = _FakeDisplaySetupLinkController();
      session.refreshBootstrapCompleter = Completer<void>();

      await tester.pumpWidget(
        CaleeApp.forTesting(
          testDeps: _makeDeps(
            session: session,
            displaySetup: displaySetup,
            displayActivationController: _FakeDisplayActivationController(),
          ),
        ),
      );

      displaySetup.injectIntent(_validToken);
      await tester.pump();
      session.finishRestore(signedIn: true);
      await tester.pump();
      await tester.pump();
      await tester.pump();

      expect(
        find.text('Connect this Calee display?', skipOffstage: false),
        findsOneWidget,
      );

      await tester.tap(find.text('Connect display'));
      await tester.pump();
      await tester.pump();

      expect(session.refreshBootstrapCallCount, 1);
      expect(find.byType(DisplayActivationSuccessPage), findsNothing);

      session.refreshBootstrapCompleter!.complete();
      await tester.pump();
      await tester.pump();
      await tester.pump();

      expect(find.byType(DisplayActivationSuccessPage), findsOneWidget);
    },
  );

  testWidgets(
    'display setup landing → Create account preserves pending intent',
    (tester) async {
      final session = _FakeSessionController();
      final displaySetup = _FakeDisplaySetupLinkController();

      await tester.pumpWidget(
        CaleeApp.forTesting(
          testDeps: _makeDeps(session: session, displaySetup: displaySetup),
        ),
      );

      displaySetup.injectIntent(_validToken);
      await tester.pump();
      session.finishRestore(signedIn: false);
      await tester.pump();

      expect(find.text('Connect this display to Calee'), findsOneWidget);

      await tester.tap(find.text('Create account'));
      await tester.pump();

      // Intent must still be pending after tapping Create account.
      expect(displaySetup.pendingIntent, isNotNull);
      expect(displaySetup.pendingIntent!.token, _validToken);
    },
  );

  testWidgets(
    'display setup landing → I already have an account preserves pending intent',
    (tester) async {
      final session = _FakeSessionController();
      final displaySetup = _FakeDisplaySetupLinkController();

      await tester.pumpWidget(
        CaleeApp.forTesting(
          testDeps: _makeDeps(session: session, displaySetup: displaySetup),
        ),
      );

      displaySetup.injectIntent(_validToken);
      await tester.pump();
      session.finishRestore(signedIn: false);
      await tester.pump();

      expect(find.text('Connect this display to Calee'), findsOneWidget);

      await tester.tap(find.text('I already have an account'));
      await tester.pump();

      // Intent must still be pending after tapping sign-in.
      expect(displaySetup.pendingIntent, isNotNull);
      expect(displaySetup.pendingIntent!.token, _validToken);
    },
  );

  // ── Duplicate confirmation-page guards ──────────────────────────────────────

  testWidgets(
    'intent during restore + restore finishes signed in → exactly one confirmation page',
    (tester) async {
      final session = _FakeSessionController();
      final displaySetup = _FakeDisplaySetupLinkController();

      await tester.pumpWidget(
        CaleeApp.forTesting(
          testDeps: _makeDeps(session: session, displaySetup: displaySetup),
        ),
      );

      // Intent arrives while session restore is still running.
      displaySetup.injectIntent(_validToken);
      await tester.pump();

      session.finishRestore(signedIn: true);
      await tester.pump();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));

      expect(
        find.text('Connect this Calee display?', skipOffstage: false),
        findsOneWidget,
      );
    },
  );

  testWidgets(
    'same intent delivered twice in quick succession → exactly one confirmation page',
    (tester) async {
      final session = _FakeSessionController();
      final displaySetup = _FakeDisplaySetupLinkController();

      await tester.pumpWidget(
        CaleeApp.forTesting(
          testDeps: _makeDeps(session: session, displaySetup: displaySetup),
        ),
      );

      session.finishRestore(signedIn: true);
      await tester.pump();

      // injectIntent bypasses the controller's dedup window, so this
      // exercises the app-level navigation guard on its own.
      displaySetup.injectIntent(_validToken);
      displaySetup.injectIntent(_validToken);
      await tester.pump();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));

      expect(
        find.text('Connect this Calee display?', skipOffstage: false),
        findsOneWidget,
      );
    },
  );

  testWidgets(
    'link controller and session controller notify for the same token → one page',
    (tester) async {
      final session = _FakeSessionController();
      final displaySetup = _FakeDisplaySetupLinkController();

      await tester.pumpWidget(
        CaleeApp.forTesting(
          testDeps: _makeDeps(session: session, displaySetup: displaySetup),
        ),
      );

      session.finishRestore(signedIn: true);
      await tester.pump();

      // The link controller notifies, then the session controller notifies
      // for the same still-pending token before the scheduled push runs.
      displaySetup.injectIntent(_validToken);
      session.pokeListeners();
      await tester.pump();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));

      expect(
        find.text('Connect this Calee display?', skipOffstage: false),
        findsOneWidget,
      );
    },
  );

  testWidgets('Cancel closes the page, clears the intent, and later session '
      'notifications do not reopen it', (tester) async {
    final session = _FakeSessionController();
    final displaySetup = _FakeDisplaySetupLinkController();

    await tester.pumpWidget(
      CaleeApp.forTesting(
        testDeps: _makeDeps(session: session, displaySetup: displaySetup),
      ),
    );

    displaySetup.injectIntent(_validToken);
    await tester.pump();
    session.finishRestore(signedIn: true);
    await tester.pump();
    await tester.pump();
    await tester.pump();

    expect(
      find.text('Connect this Calee display?', skipOffstage: false),
      findsOneWidget,
    );

    await tester.tap(find.text('Cancel'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    expect(
      find.text('Connect this Calee display?', skipOffstage: false),
      findsNothing,
    );
    expect(displaySetup.pendingIntent, isNull);

    // A later session notification (e.g. bootstrap refresh) must not
    // resurrect the confirmation page.
    session.pokeListeners();
    await tester.pump();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    expect(
      find.text('Connect this Calee display?', skipOffstage: false),
      findsNothing,
    );
  });

  testWidgets(
    '"Use a different account" keeps the pending token for the signed-out flow',
    (tester) async {
      final session = _FakeSessionController();
      final displaySetup = _FakeDisplaySetupLinkController();

      await tester.pumpWidget(
        CaleeApp.forTesting(
          testDeps: _makeDeps(session: session, displaySetup: displaySetup),
        ),
      );

      displaySetup.injectIntent(_validToken);
      await tester.pump();
      session.finishRestore(signedIn: true);
      await tester.pump();
      await tester.pump();
      await tester.pump();

      expect(
        find.text('Connect this Calee display?', skipOffstage: false),
        findsOneWidget,
      );

      await tester.tap(find.text('Use a different account'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));

      // The tablet token survives the sign-out…
      expect(displaySetup.pendingIntent, isNotNull);
      expect(displaySetup.pendingIntent!.token, _validToken);
      // …and the signed-out display landing page is shown.
      expect(find.text('Connect this display to Calee'), findsOneWidget);
      expect(
        find.text('Connect this Calee display?', skipOffstage: false),
        findsNothing,
      );
    },
  );

  testWidgets(
    'a different token after the first route closed is processed normally',
    (tester) async {
      final session = _FakeSessionController();
      final displaySetup = _FakeDisplaySetupLinkController();

      await tester.pumpWidget(
        CaleeApp.forTesting(
          testDeps: _makeDeps(session: session, displaySetup: displaySetup),
        ),
      );

      displaySetup.injectIntent(_validToken);
      await tester.pump();
      session.finishRestore(signedIn: true);
      await tester.pump();
      await tester.pump();
      await tester.pump();

      expect(
        find.text('Connect this Calee display?', skipOffstage: false),
        findsOneWidget,
      );

      await tester.tap(find.text('Cancel'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(
        find.text('Connect this Calee display?', skipOffstage: false),
        findsNothing,
      );

      displaySetup.injectIntent(_otherToken);
      await tester.pump();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));

      expect(
        find.text('Connect this Calee display?', skipOffstage: false),
        findsOneWidget,
      );
    },
  );

  // ── Route-lifecycle cleanup (implicit dismissal) ────────────────────────────

  /// Opens the signed-in confirmation route for [token] and settles until
  /// exactly one confirmation page is visible.
  Future<void> openConfirmation(
    WidgetTester tester,
    _FakeSessionController session,
    _FakeDisplaySetupLinkController displaySetup,
    String token,
  ) async {
    displaySetup.injectIntent(token);
    await tester.pump();
    session.finishRestore(signedIn: true);
    await tester.pump();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(
      find.text('Connect this Calee display?', skipOffstage: false),
      findsOneWidget,
    );
  }

  testWidgets('system Back clears the pending intent and closes the page', (
    tester,
  ) async {
    final session = _FakeSessionController();
    final displaySetup = _FakeDisplaySetupLinkController();

    await tester.pumpWidget(
      CaleeApp.forTesting(
        testDeps: _makeDeps(session: session, displaySetup: displaySetup),
      ),
    );

    await openConfirmation(tester, session, displaySetup, _validToken);

    // Simulate Android system Back / Navigator.maybePop with no result.
    await tester.binding.handlePopRoute();
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));

    expect(
      find.text('Connect this Calee display?', skipOffstage: false),
      findsNothing,
    );
    expect(displaySetup.pendingIntent, isNull);
  });

  testWidgets(
    'session notification after system Back does not reopen the page',
    (tester) async {
      final session = _FakeSessionController();
      final displaySetup = _FakeDisplaySetupLinkController();

      await tester.pumpWidget(
        CaleeApp.forTesting(
          testDeps: _makeDeps(session: session, displaySetup: displaySetup),
        ),
      );

      await openConfirmation(tester, session, displaySetup, _validToken);

      await tester.binding.handlePopRoute();
      await tester.pump();
      await tester.pump(const Duration(seconds: 1));

      expect(
        find.text('Connect this Calee display?', skipOffstage: false),
        findsNothing,
      );
      expect(displaySetup.pendingIntent, isNull);

      // A later session notification (bootstrap refresh, etc.) must not
      // resurrect the confirmation page.
      session.pokeListeners();
      await tester.pump();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));

      expect(
        find.text('Connect this Calee display?', skipOffstage: false),
        findsNothing,
      );
    },
  );

  testWidgets('Cancel button uses the same route-result cleanup path', (
    tester,
  ) async {
    final session = _FakeSessionController();
    final displaySetup = _FakeDisplaySetupLinkController();

    await tester.pumpWidget(
      CaleeApp.forTesting(
        testDeps: _makeDeps(session: session, displaySetup: displaySetup),
      ),
    );

    await openConfirmation(tester, session, displaySetup, _validToken);

    await tester.tap(find.text('Cancel'));
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));

    expect(
      find.text('Connect this Calee display?', skipOffstage: false),
      findsNothing,
    );
    expect(displaySetup.pendingIntent, isNull);

    session.pokeListeners();
    await tester.pump();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    expect(
      find.text('Connect this Calee display?', skipOffstage: false),
      findsNothing,
    );
  });

  testWidgets(
    '"Use a different account" preserves the token and shows the landing page',
    (tester) async {
      final session = _FakeSessionController();
      final displaySetup = _FakeDisplaySetupLinkController();

      await tester.pumpWidget(
        CaleeApp.forTesting(
          testDeps: _makeDeps(session: session, displaySetup: displaySetup),
        ),
      );

      await openConfirmation(tester, session, displaySetup, _validToken);

      await tester.tap(find.text('Use a different account'));
      await tester.pump();
      await tester.pump(const Duration(seconds: 1));

      expect(displaySetup.pendingIntent, isNotNull);
      expect(displaySetup.pendingIntent!.token, _validToken);
      expect(find.text('Connect this display to Calee'), findsOneWidget);
      expect(
        find.text('Connect this Calee display?', skipOffstage: false),
        findsNothing,
      );
    },
  );

  testWidgets('old-route Back cleanup does not clear a newer pending token', (
    tester,
  ) async {
    final session = _FakeSessionController();
    final displaySetup = _FakeDisplaySetupLinkController();

    await tester.pumpWidget(
      CaleeApp.forTesting(
        testDeps: _makeDeps(session: session, displaySetup: displaySetup),
      ),
    );

    // Route A opens for token A.
    await openConfirmation(tester, session, displaySetup, _validToken);

    // Token B becomes pending while route A is still open.
    displaySetup.pendingIntent = DisplaySetupIntent(
      token: _otherToken,
      sourceUri: Uri.parse('calee://native-login/$_otherToken'),
    );

    // Route A closes through system Back — its cleanup must not touch B.
    await tester.binding.handlePopRoute();
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));

    // Token B survives route A's teardown…
    expect(displaySetup.pendingIntent, isNotNull);
    expect(displaySetup.pendingIntent!.token, _otherToken);

    // …and can open its own confirmation route normally.
    displaySetup.notifyListeners();
    await tester.pump();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    expect(
      find.text('Connect this Calee display?', skipOffstage: false),
      findsOneWidget,
    );
  });

  // ── Post-init safety net ────────────────────────────────────────────────────

  testWidgets(
    'CaleeApp post-init safety net opens exactly one confirmation route when '
    'init() already left a pending intent before notifying',
    (tester) async {
      final session = _FakeSessionController()
        ..accessToken = 'test_access_token'
        ..bootstrap = _stubBootstrap()
        ..isRestoringSession = false;
      final displaySetup = _PendingIntentOnInitDisplaySetupLinkController(
        _validToken,
      );

      await tester.pumpWidget(
        CaleeApp.forTesting(
          testDeps: _makeDeps(session: session, displaySetup: displaySetup),
        ),
      );

      // initState's addListener happened before init() was called, but this
      // fake's init() sets pendingIntent without calling notifyListeners —
      // only CaleeApp's post-init `.then()` safety net re-evaluates it.
      await tester.pump();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));

      expect(
        find.text('Connect this Calee display?', skipOffstage: false),
        findsOneWidget,
      );
    },
  );
}

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

/// CalendarFollowLinkController whose [init] is a no-op.
class _FakeFollowLinkController extends CalendarFollowLinkController {
  @override
  Future<void> init() async {}
}

class _FakeDisplayActivationController extends DisplayActivationController {
  _FakeDisplayActivationController()
    : super(
        repository: DisplaySetupRepository(hubClient: CaleeHubClient()),
      );

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
  _FakeDisplaySetupLinkController? displaySetup,
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

      expect(find.text('Connect this Calee display?'), findsOneWidget);

      await tester.tap(find.text('Connect display'));
      await tester.pump();
      await tester.pump();

      expect(session.refreshBootstrapCallCount, 1);
      expect(find.byType(DisplayActivationSuccessPage), findsNothing);

      session.refreshBootstrapCompleter!.complete();
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
}

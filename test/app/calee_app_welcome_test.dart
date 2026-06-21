// Widget tests: first-run welcome screen and signed-out QR entry flow.

import 'package:calee_mobile/app/calee_app.dart';
import 'package:calee_mobile/data/api/calee_hub_client.dart';
import 'package:calee_mobile/data/auth/session_store.dart';
import 'package:calee_mobile/data/models/client_bootstrap.dart';
import 'package:calee_mobile/features/auth/auth_repository.dart';
import 'package:calee_mobile/features/auth/session_controller.dart';
import 'package:calee_mobile/features/calendar_follow/calendar_follow_link_controller.dart';
import 'package:calee_mobile/features/display_setup/display_activation_controller.dart';
import 'package:calee_mobile/features/display_setup/display_setup_intent.dart';
import 'package:calee_mobile/features/display_setup/display_setup_link_controller.dart';
import 'package:calee_mobile/features/display_setup/display_setup_repository.dart';
import 'package:calee_mobile/features/local_subscriber/local_calendar_subscription_repository.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _validToken = 'AbCdEfGhIjKlMnOpQrStUvWxYz0123456789_-AB';

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
}

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
}) {
  final hub = CaleeHubClient();
  return CaleeAppTestDependencies(
    hubClient: hub,
    sessionController: session ?? _FakeSessionController(),
    displaySetupLinkController:
        displaySetup ?? _FakeDisplaySetupLinkController(),
    followLinkController: _FakeFollowLinkController(),
    displayActivationController: DisplayActivationController(
      repository: DisplaySetupRepository(hubClient: hub),
    ),
    localSubscriptionRepo: LocalCalendarSubscriptionRepository(),
  );
}

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  testWidgets(
    'signed out, no pending intent → WelcomePage shown',
    (tester) async {
      final session = _FakeSessionController();

      await tester.pumpWidget(
        CaleeApp.forTesting(testDeps: _makeDeps(session: session)),
      );
      session.finishRestore(signedIn: false);
      await tester.pump();

      expect(find.text('Welcome to Calee'), findsOneWidget);
      expect(find.text('Create account'), findsOneWidget);
      expect(find.text('I already have an account'), findsOneWidget);
    },
  );

  testWidgets(
    'tap "I already have an account" → LoginPage shown',
    (tester) async {
      final session = _FakeSessionController();

      await tester.pumpWidget(
        CaleeApp.forTesting(testDeps: _makeDeps(session: session)),
      );
      session.finishRestore(signedIn: false);
      await tester.pump();

      await tester.tap(find.text('I already have an account'));
      await tester.pump();

      expect(find.text('Sign in to Calee'), findsOneWidget);
      expect(find.text('Welcome to Calee'), findsNothing);
    },
  );

  testWidgets(
    'tap "Create account" → CreateAccountPage shown',
    (tester) async {
      final session = _FakeSessionController();

      await tester.pumpWidget(
        CaleeApp.forTesting(testDeps: _makeDeps(session: session)),
      );
      session.finishRestore(signedIn: false);
      await tester.pump();

      await tester.tap(find.text('Create account'));
      await tester.pump();

      expect(find.text('Create your Calee account'), findsOneWidget);
      expect(find.text('Welcome to Calee'), findsNothing);
    },
  );

  testWidgets(
    'display QR opened directly (deep link) while signed out → DisplaySetupLandingPage, not WelcomePage',
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

      expect(find.text('Set up your Calee display'), findsOneWidget);
      expect(find.text('Welcome to Calee'), findsNothing);
    },
  );

  testWidgets(
    'Create account does not open signed-out QR scanner',
    (tester) async {
      final session = _FakeSessionController();

      await tester.pumpWidget(
        CaleeApp.forTesting(testDeps: _makeDeps(session: session)),
      );
      session.finishRestore(signedIn: false);
      await tester.pump();

      await tester.tap(find.text('Create account'));
      await tester.pump();

      expect(find.text('Create your Calee account'), findsOneWidget);
      expect(find.text('Scan display QR'), findsNothing);
    },
  );

  testWidgets(
    'signed-in user → home page shown, no WelcomePage',
    (tester) async {
      final session = _FakeSessionController();

      await tester.pumpWidget(
        CaleeApp.forTesting(testDeps: _makeDeps(session: session)),
      );
      session.finishRestore(signedIn: true);
      await tester.pump();

      expect(find.text('Welcome to Calee'), findsNothing);
      expect(find.text('Sign in to Calee'), findsNothing);
    },
  );
}

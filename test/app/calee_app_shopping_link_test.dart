// Widget tests: shopping deep-link routing.
//
// Verifies that a calee://shopping (or hub.calee.com.au/mobile/shopping)
// deep link opens ShoppingPage for a signed-in user, and that a signed-out
// user is asked to sign in first with the pending intent preserved until
// sign-in completes — mirroring the existing display-setup/external-calendar
// deep-link test patterns.

import 'package:calee_mobile/app/calee_app.dart';
import 'package:calee_mobile/data/api/calee_hub_client.dart';
import 'package:calee_mobile/data/auth/session_store.dart';
import 'package:calee_mobile/data/models/client_bootstrap.dart';
import 'package:calee_mobile/data/models/client_shopping_list.dart';
import 'package:calee_mobile/features/auth/auth_repository.dart';
import 'package:calee_mobile/features/auth/session_controller.dart';
import 'package:calee_mobile/features/calendar_follow/calendar_follow_link_controller.dart';
import 'package:calee_mobile/features/display_setup/display_activation_controller.dart';
import 'package:calee_mobile/features/display_setup/display_setup_link_controller.dart';
import 'package:calee_mobile/features/display_setup/display_setup_repository.dart';
import 'package:calee_mobile/features/local_subscriber/local_calendar_subscription_repository.dart';
import 'package:calee_mobile/features/shopping/shopping_link_controller.dart';
import 'package:calee_mobile/features/shopping/shopping_link_intent.dart';
import 'package:calee_mobile/features/shopping/shopping_page.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

// ── Stub hub client ──────────────────────────────────────────────────────────

class _StubHub extends CaleeHubClient {
  _StubHub() : super();

  bool generateCalled = false;
  String? lastLoadFrom;
  String? lastLoadTo;

  static final _list = ClientShoppingList(
    id: 3,
    householdId: 'h1',
    title: 'Shopping list',
    fromDate: '2026-07-06',
    toDate: '2026-07-12',
    status: 'active',
    items: [],
  );

  @override
  Future<ClientShoppingList> currentShoppingList({
    required String accessToken,
    required String from,
    required String to,
  }) async {
    lastLoadFrom = from;
    lastLoadTo = to;
    return _list;
  }

  @override
  Future<ClientShoppingList> generateShoppingList({
    required String accessToken,
    required String from,
    required String to,
    String mode = 'merge',
  }) async {
    generateCalled = true;
    lastLoadFrom = from;
    lastLoadTo = to;
    return _list;
  }
}

// ── Fake controllers ──────────────────────────────────────────────────────────

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

  @override
  Future<void> refreshBootstrap() async {
    bootstrap = _stubBootstrap();
    notifyListeners();
  }
}

class _FakeShoppingLinkController extends ShoppingLinkController {
  @override
  Future<void> init() async {}

  void injectIntent({DateTime? weekStart, Uri? sourceUri}) {
    pendingIntent = ShoppingLinkIntent(
      weekStart: weekStart,
      sourceUri: sourceUri ?? Uri.parse('calee://shopping'),
    );
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

// Mirrors ShoppingController's Monday-alignment so tests can predict the
// "defaults to current week" date without depending on wall-clock timing.
DateTime _mondayOf(DateTime date) {
  final weekday = date.weekday;
  return DateTime(date.year, date.month, date.day - (weekday - 1));
}

String _fmt(DateTime d) =>
    '${d.year.toString().padLeft(4, '0')}-'
    '${d.month.toString().padLeft(2, '0')}-'
    '${d.day.toString().padLeft(2, '0')}';

CaleeAppTestDependencies _makeDeps({
  required _StubHub hub,
  required _FakeSessionController session,
  required _FakeShoppingLinkController shoppingLink,
}) {
  return CaleeAppTestDependencies(
    hubClient: hub,
    sessionController: session,
    displaySetupLinkController: _FakeDisplaySetupLinkController(),
    followLinkController: _FakeFollowLinkController(),
    displayActivationController: DisplayActivationController(
      repository: DisplaySetupRepository(hubClient: hub),
    ),
    localSubscriptionRepo: LocalCalendarSubscriptionRepository(),
    shoppingLinkController: shoppingLink,
  );
}

// ── Tests ─────────────────────────────────────────────────────────────────────

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  testWidgets(
    'signed-in shopping link opens ShoppingPage for the requested week '
    'with autoGenerate=false',
    (tester) async {
      final hub = _StubHub();
      final session = _FakeSessionController();
      final shoppingLink = _FakeShoppingLinkController();

      await tester.pumpWidget(
        CaleeApp.forTesting(
          testDeps: _makeDeps(
            hub: hub,
            session: session,
            shoppingLink: shoppingLink,
          ),
        ),
      );

      session.finishRestore(signedIn: true);
      await tester.pump();

      shoppingLink.injectIntent(weekStart: DateTime(2026, 7, 6));
      await tester.pumpAndSettle();

      expect(find.byType(ShoppingPage), findsOneWidget);
      expect(hub.lastLoadFrom, '2026-07-06');
      expect(hub.generateCalled, isFalse);
      expect(shoppingLink.pendingIntent, isNull);
    },
  );

  testWidgets(
    'shopping link with missing/invalid weekStart defaults to the current '
    'week',
    (tester) async {
      final hub = _StubHub();
      final session = _FakeSessionController();
      final shoppingLink = _FakeShoppingLinkController();

      await tester.pumpWidget(
        CaleeApp.forTesting(
          testDeps: _makeDeps(
            hub: hub,
            session: session,
            shoppingLink: shoppingLink,
          ),
        ),
      );

      session.finishRestore(signedIn: true);
      await tester.pump();

      shoppingLink.injectIntent(weekStart: null);
      await tester.pumpAndSettle();

      expect(find.byType(ShoppingPage), findsOneWidget);
      expect(hub.lastLoadFrom, _fmt(_mondayOf(DateTime.now())));
    },
  );

  testWidgets(
    'pending shopping intent + restore finishes logged out → shows sign-in '
    'prompt, not the ShoppingPage',
    (tester) async {
      final hub = _StubHub();
      final session = _FakeSessionController();
      final shoppingLink = _FakeShoppingLinkController();

      await tester.pumpWidget(
        CaleeApp.forTesting(
          testDeps: _makeDeps(
            hub: hub,
            session: session,
            shoppingLink: shoppingLink,
          ),
        ),
      );

      shoppingLink.injectIntent(weekStart: DateTime(2026, 7, 6));
      await tester.pump();

      session.finishRestore(signedIn: false);
      await tester.pump();

      expect(find.text('Sign in to open your shopping list'), findsOneWidget);
      expect(find.byType(ShoppingPage), findsNothing);
      expect(shoppingLink.pendingIntent, isNotNull);
    },
  );

  testWidgets('pending shopping intent + restore finishes signed in → opens '
      'ShoppingPage directly, skipping the sign-in prompt', (tester) async {
    final hub = _StubHub();
    final session = _FakeSessionController();
    final shoppingLink = _FakeShoppingLinkController();

    await tester.pumpWidget(
      CaleeApp.forTesting(
        testDeps: _makeDeps(
          hub: hub,
          session: session,
          shoppingLink: shoppingLink,
        ),
      ),
    );

    // Inject the intent while still restoring.
    shoppingLink.injectIntent(weekStart: DateTime(2026, 7, 6));
    await tester.pump();

    session.finishRestore(signedIn: true);
    await tester.pumpAndSettle();

    expect(find.text('Sign in to open your shopping list'), findsNothing);
    expect(find.byType(ShoppingPage), findsOneWidget);
    expect(hub.lastLoadFrom, '2026-07-06');
  });

  testWidgets(
    'shopping sign-in prompt → Create account preserves the pending intent',
    (tester) async {
      final hub = _StubHub();
      final session = _FakeSessionController();
      final shoppingLink = _FakeShoppingLinkController();

      await tester.pumpWidget(
        CaleeApp.forTesting(
          testDeps: _makeDeps(
            hub: hub,
            session: session,
            shoppingLink: shoppingLink,
          ),
        ),
      );

      shoppingLink.injectIntent(weekStart: DateTime(2026, 7, 6));
      await tester.pump();
      session.finishRestore(signedIn: false);
      await tester.pump();

      expect(find.text('Sign in to open your shopping list'), findsOneWidget);

      await tester.tap(find.text('Create account'));
      await tester.pump();

      expect(shoppingLink.pendingIntent, isNotNull);
      expect(shoppingLink.pendingIntent!.weekStart, DateTime(2026, 7, 6));
    },
  );

  testWidgets(
    'shopping sign-in prompt → I already have an account preserves the '
    'pending intent',
    (tester) async {
      final hub = _StubHub();
      final session = _FakeSessionController();
      final shoppingLink = _FakeShoppingLinkController();

      await tester.pumpWidget(
        CaleeApp.forTesting(
          testDeps: _makeDeps(
            hub: hub,
            session: session,
            shoppingLink: shoppingLink,
          ),
        ),
      );

      shoppingLink.injectIntent(weekStart: DateTime(2026, 7, 6));
      await tester.pump();
      session.finishRestore(signedIn: false);
      await tester.pump();

      expect(find.text('Sign in to open your shopping list'), findsOneWidget);

      await tester.tap(find.text('I already have an account'));
      await tester.pump();

      expect(shoppingLink.pendingIntent, isNotNull);
      expect(shoppingLink.pendingIntent!.weekStart, DateTime(2026, 7, 6));
    },
  );

  testWidgets(
    'no pending shopping intent + restore finishes logged out → plain '
    'WelcomePage (unchanged default behaviour)',
    (tester) async {
      final hub = _StubHub();
      final session = _FakeSessionController();
      final shoppingLink = _FakeShoppingLinkController();

      await tester.pumpWidget(
        CaleeApp.forTesting(
          testDeps: _makeDeps(
            hub: hub,
            session: session,
            shoppingLink: shoppingLink,
          ),
        ),
      );

      session.finishRestore(signedIn: false);
      await tester.pump();

      expect(find.text('Welcome to Calee'), findsOneWidget);
      expect(find.text('Sign in to open your shopping list'), findsNothing);
    },
  );
}

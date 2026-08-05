// App-level tests: the signed-out local-calendar entry points.
//
// Verifies the commercial model wiring for an installation that already
// follows a calendar locally: the app-bar Sign in opens the existing normal
// LoginPage without touching the phone-only subscriptions, successful
// existing-customer sign-in reuses the Welcome-path completion flow, and the
// inline Calee-for-home promotion is dismissible with the dismissal persisted
// per installation — while the management sheet's permanent discovery row
// stays available.

import 'package:calee_mobile/app/calee_app.dart';
import 'package:calee_mobile/config/calee_links.dart';
import 'package:calee_mobile/data/api/calee_hub_client.dart';
import 'package:calee_mobile/data/auth/session_store.dart';
import 'package:calee_mobile/data/models/client_bootstrap.dart';
import 'package:calee_mobile/features/auth/auth_repository.dart';
import 'package:calee_mobile/features/auth/login_page.dart';
import 'package:calee_mobile/features/auth/session_controller.dart';
import 'package:calee_mobile/features/calendar_follow/calendar_follow_link_controller.dart';
import 'package:calee_mobile/features/display_setup/connect_display_page.dart';
import 'package:calee_mobile/features/display_setup/display_activation_controller.dart';
import 'package:calee_mobile/features/display_setup/display_setup_link_controller.dart';
import 'package:calee_mobile/features/display_setup/display_setup_repository.dart';
import 'package:calee_mobile/features/local_subscriber/local_calendar_subscription_repository.dart';
import 'package:calee_mobile/features/local_subscriber/local_subscriber_calendar_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _calendarUrl = 'https://example.com/school.ics';
const _kDismissedPrefKey = 'local_calendar_inline_home_promo_dismissed_v1';

const _kSignInButton = Key('local_calendar_sign_in_button');
const _kInlinePromo = Key('local_calendar_inline_home_promo');
const _kInlinePromoDismiss = Key('local_calendar_inline_home_promo_dismiss');
const _kSheetPromo = Key('local_calendar_home_promo');

const _kBootstrap = ClientBootstrap(
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

ClientLoginResult _makeLoginResult() => ClientLoginResult(
  accessToken: 'access-token',
  refreshToken: 'refresh-token',
  tokenType: 'Bearer',
  expiresIn: 3600,
  refreshExpiresIn: 86400,
  bootstrap: _kBootstrap,
);

class _FakeSessionController extends SessionController {
  _FakeSessionController()
    : super(
        repository: AuthRepository(
          hubClient: CaleeHubClient(),
          sessionStore: SessionStore(),
        ),
      );

  int completeSignInCalls = 0;

  @override
  Future<void> restoreSession() async {}

  void finishRestore() {
    accessToken = null;
    bootstrap = null;
    isRestoringSession = false;
    notifyListeners();
  }

  @override
  Future<void> completeSignIn(ClientLoginResult result) async {
    completeSignInCalls++;
    accessToken = result.accessToken;
    refreshToken = result.refreshToken;
    bootstrap = result.bootstrap;
    notifyListeners();
  }

  @override
  Future<void> signOut() async {
    accessToken = null;
    refreshToken = null;
    bootstrap = null;
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

CaleeAppTestDependencies _makeDeps({
  required _FakeSessionController session,
  required _FakeFollowLinkController follow,
  required LocalCalendarSubscriptionRepository localRepo,
  Future<bool> Function(Uri url)? launchExternalUrl,
}) {
  final hub = CaleeHubClient();
  return CaleeAppTestDependencies(
    hubClient: hub,
    sessionController: session,
    displaySetupLinkController: _FakeDisplaySetupLinkController(),
    followLinkController: follow,
    displayActivationController: DisplayActivationController(
      repository: DisplaySetupRepository(hubClient: hub),
    ),
    localSubscriptionRepo: localRepo,
    launchExternalUrl: launchExternalUrl ?? (_) async => true,
  );
}

/// Pumps a signed-out app whose repository already holds one locally
/// followed calendar, and settles on [LocalSubscriberCalendarPage].
Future<
  (
    _FakeSessionController,
    _FakeFollowLinkController,
    LocalCalendarSubscriptionRepository,
  )
>
_pumpWithLocalSubscription(
  WidgetTester tester, {
  Future<bool> Function(Uri url)? launchExternalUrl,
}) async {
  final repo = LocalCalendarSubscriptionRepository();
  await repo.add(
    title: 'School Calendar',
    url: _calendarUrl,
    source: 'example.com',
  );

  final session = _FakeSessionController();
  final follow = _FakeFollowLinkController();
  await tester.pumpWidget(
    CaleeApp.forTesting(
      testDeps: _makeDeps(
        session: session,
        follow: follow,
        localRepo: repo,
        launchExternalUrl: launchExternalUrl,
      ),
    ),
  );
  session.finishRestore();
  await tester.pumpAndSettle();

  expect(find.byType(LocalSubscriberCalendarPage), findsOneWidget);
  return (session, follow, repo);
}

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  testWidgets(
    'signed-out installation with a local subscription shows the local '
    'calendar with Sign in and the inline promotion',
    (tester) async {
      await _pumpWithLocalSubscription(tester);

      expect(find.byKey(_kSignInButton), findsOneWidget);
      expect(find.text('Sign in'), findsOneWidget);
      expect(find.byKey(_kInlinePromo), findsOneWidget);
      expect(find.text('See this calendar on a family screen'), findsOneWidget);
      expect(find.text('Discover Calee for your home.'), findsOneWidget);
    },
  );

  testWidgets(
    'Sign in opens the existing LoginPage without touching local state, and '
    'cancel returns to the local calendar',
    (tester) async {
      final launched = <Uri>[];
      final (_, follow, repo) = await _pumpWithLocalSubscription(
        tester,
        launchExternalUrl: (url) async {
          launched.add(url);
          return true;
        },
      );

      await tester.tap(find.byKey(_kSignInButton));
      await tester.pump();

      expect(find.byType(LoginPage), findsOneWidget);
      expect(find.text('Sign in to Calee'), findsOneWidget);

      // Opening login neither deletes nor duplicates the local subscription,
      // creates no follow intent, and never launches the marketing site.
      expect((await repo.list()).length, 1);
      expect(follow.pendingIntent, isNull);
      expect(launched, isEmpty);

      await tester.tap(find.byKey(const Key('login_cancel_button')));
      await tester.pump();

      expect(find.byType(LocalSubscriberCalendarPage), findsOneWidget);
      expect((await repo.list()).length, 1);
    },
  );

  testWidgets(
    'successful existing-customer sign-in uses the normal completion flow '
    'and keeps the phone-only calendars stored',
    (tester) async {
      final (session, follow, repo) = await _pumpWithLocalSubscription(tester);

      await tester.tap(find.byKey(_kSignInButton));
      await tester.pump();
      final loginPage = tester.widget<LoginPage>(find.byType(LoginPage));

      await loginPage.onSignedIn(_makeLoginResult());
      await tester.pump();
      await tester.pump();

      // Same completion as the Welcome-page path: session completed once,
      // not registered as a new account, and — with no pending follow
      // intent — the connect-display step of the signed-in experience.
      expect(session.completeSignInCalls, 1);
      expect(session.isSignedIn, isTrue);
      expect(find.byType(ConnectDisplayPage), findsOneWidget);

      // The inline promotion belongs to the signed-out local-calendar page
      // only; no signed-in page shows it.
      expect(find.byKey(_kInlinePromo), findsNothing);

      // Local subscriptions are not migrated, account-linked, or deleted.
      expect((await repo.list()).length, 1);
      expect(follow.pendingIntent, isNull);

      // Signing out later still leaves the phone-only calendars in place.
      await session.signOut();
      await tester.pump();
      await tester.pump();
      expect(find.byType(LocalSubscriberCalendarPage), findsOneWidget);
      expect((await repo.list()).length, 1);
    },
  );

  testWidgets(
    'dismissing the inline promotion writes the versioned preference, '
    'persists across an app restart, and keeps the sheet discovery row',
    (tester) async {
      final (_, _, repo) = await _pumpWithLocalSubscription(tester);
      expect(find.byKey(_kInlinePromo), findsOneWidget);

      await tester.tap(find.byKey(_kInlinePromoDismiss));
      await tester.pump();

      // Hidden immediately, recorded under the versioned key, and the
      // subscription payload is untouched.
      expect(find.byKey(_kInlinePromo), findsNothing);
      final stored = await SharedPreferences.getInstance();
      expect(stored.getBool(_kDismissedPrefKey), isTrue);
      expect((await repo.list()).length, 1);

      // "Restart": a fresh app instance over the same stored preferences.
      final session = _FakeSessionController();
      final follow = _FakeFollowLinkController();
      await tester.pumpWidget(
        CaleeApp.forTesting(
          testDeps: _makeDeps(
            session: session,
            follow: follow,
            localRepo: repo,
          ),
        ),
      );
      session.finishRestore();
      await tester.pumpAndSettle();

      expect(find.byType(LocalSubscriberCalendarPage), findsOneWidget);
      expect(find.byKey(_kInlinePromo), findsNothing);
      expect((await repo.list()).length, 1);

      // The permanent low-pressure discovery row survives the dismissal.
      await tester.tap(find.byTooltip('Calendars on this phone'));
      await tester.pumpAndSettle();
      expect(find.byKey(_kSheetPromo), findsOneWidget);
      expect(find.text('Calee for your home'), findsOneWidget);
    },
  );

  testWidgets(
    'failed marketing launch from the inline promotion shows the failure '
    'snackbar and retains the signed-out local-calendar state',
    (tester) async {
      final launched = <Uri>[];
      final (_, follow, repo) = await _pumpWithLocalSubscription(
        tester,
        launchExternalUrl: (url) async {
          launched.add(url);
          return false;
        },
      );

      await tester.tap(find.byKey(_kInlinePromo));
      await tester.pump();
      await tester.pump();

      expect(launched, [Uri.parse(kCaleeForHomeUrl)]);
      expect(
        find.text('Could not open Calee for your home. Please try again.'),
        findsOneWidget,
      );
      expect(find.byType(LocalSubscriberCalendarPage), findsOneWidget);
      expect((await repo.list()).length, 1);
      expect(follow.pendingIntent, isNull);
    },
  );
}

// App-level tests: the signed-out public-calendar decision flow.
//
// Verifies the commercial model wiring: the local add stores the subscription
// and only then consumes the pending intent, the existing-customer sign-in
// preserves the intent for the account-backed subscription flow, and opening
// the Calee-for-home marketing page never touches the pending intent.

import 'package:calee_mobile/app/calee_app.dart';
import 'package:calee_mobile/config/calee_links.dart';
import 'package:calee_mobile/data/api/calee_hub_client.dart';
import 'package:calee_mobile/data/auth/session_store.dart';
import 'package:calee_mobile/features/auth/auth_repository.dart';
import 'package:calee_mobile/features/auth/session_controller.dart';
import 'package:calee_mobile/features/calendar_follow/calendar_follow_intent.dart';
import 'package:calee_mobile/features/calendar_follow/calendar_follow_link_controller.dart';
import 'package:calee_mobile/features/calendar_follow/follow_calendar_page.dart';
import 'package:calee_mobile/features/display_setup/display_activation_controller.dart';
import 'package:calee_mobile/features/display_setup/display_setup_link_controller.dart';
import 'package:calee_mobile/features/display_setup/display_setup_repository.dart';
import 'package:calee_mobile/features/local_subscriber/local_calendar_subscription.dart';
import 'package:calee_mobile/features/local_subscriber/local_calendar_subscription_repository.dart';
import 'package:calee_mobile/features/local_subscriber/local_subscriber_calendar_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _calendarUrl = 'https://example.com/school.ics';

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

  void finishRestore() {
    accessToken = null;
    bootstrap = null;
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

  void injectResolvedIntent({String title = 'School Calendar'}) {
    pendingIntent = ResolvedCalendarFollowIntent(
      title: title,
      url: _calendarUrl,
      source: 'example.com',
    );
    notifyListeners();
  }
}

class _ThrowingLocalRepo extends LocalCalendarSubscriptionRepository {
  @override
  Future<LocalCalendarSubscription> add({
    required String title,
    required String url,
    required String source,
  }) async {
    throw Exception('storage failed');
  }
}

CaleeAppTestDependencies _makeDeps({
  required _FakeSessionController session,
  required _FakeFollowLinkController follow,
  LocalCalendarSubscriptionRepository? localRepo,
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
    localSubscriptionRepo: localRepo ?? LocalCalendarSubscriptionRepository(),
    launchExternalUrl: launchExternalUrl ?? (_) async => true,
  );
}

Future<(_FakeSessionController, _FakeFollowLinkController)> _pumpWithIntent(
  WidgetTester tester, {
  LocalCalendarSubscriptionRepository? localRepo,
  Future<bool> Function(Uri url)? launchExternalUrl,
}) async {
  final session = _FakeSessionController();
  final follow = _FakeFollowLinkController();

  await tester.pumpWidget(
    CaleeApp.forTesting(
      testDeps: _makeDeps(
        session: session,
        follow: follow,
        localRepo: localRepo,
        launchExternalUrl: launchExternalUrl,
      ),
    ),
  );
  session.finishRestore();
  follow.injectResolvedIntent();
  await tester.pump();
  await tester.pump();

  expect(find.byType(FollowCalendarPage), findsOneWidget);
  return (session, follow);
}

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  testWidgets('pending intent while signed out shows the decision page', (
    tester,
  ) async {
    await _pumpWithIntent(tester);

    expect(find.text('Add this calendar'), findsOneWidget);
    expect(find.text('School Calendar'), findsOneWidget);
  });

  testWidgets(
    'Add to this phone stores the subscription, clears the intent, and '
    'shows the confirmation snackbar over the local calendar',
    (tester) async {
      final repo = LocalCalendarSubscriptionRepository();
      final (_, follow) = await _pumpWithIntent(tester, localRepo: repo);

      await tester.tap(
        find.byKey(const Key('calendar_follow_add_to_phone_button')),
      );
      await tester.pump();
      await tester.pump();

      expect(await repo.containsUrl(_calendarUrl), isTrue);
      expect(follow.pendingIntent, isNull);

      await tester.pump();
      expect(find.byType(LocalSubscriberCalendarPage), findsOneWidget);
      expect(find.text('Calendar added to this phone'), findsOneWidget);

      // Temporary snackbar, not a permanent banner: entrance animation
      // completes, the display timer elapses, then the exit animation runs.
      await tester.pump(const Duration(seconds: 1));
      await tester.pump(const Duration(seconds: 5));
      await tester.pump(const Duration(seconds: 1));
      expect(find.text('Calendar added to this phone'), findsNothing);
    },
  );

  testWidgets('failed local storage keeps the pending intent', (tester) async {
    final (_, follow) = await _pumpWithIntent(
      tester,
      localRepo: _ThrowingLocalRepo(),
    );

    await tester.tap(
      find.byKey(const Key('calendar_follow_add_to_phone_button')),
    );
    await tester.pump();
    await tester.pump();

    expect(follow.pendingIntent, isNotNull);
    expect(find.byType(FollowCalendarPage), findsOneWidget);
    expect(
      find.text('This calendar could not be added on this phone.'),
      findsOneWidget,
    );
  });

  testWidgets('existing-customer sign-in preserves the pending intent', (
    tester,
  ) async {
    final (_, follow) = await _pumpWithIntent(tester);

    await tester.ensureVisible(
      find.byKey(const Key('calendar_follow_existing_customer_sign_in')),
    );
    await tester.pumpAndSettle();
    await tester.tap(
      find.byKey(const Key('calendar_follow_existing_customer_sign_in')),
    );
    await tester.pump();

    expect(find.text('Sign in to Calee'), findsOneWidget);
    expect(follow.pendingIntent, isNotNull);
  });

  testWidgets(
    'opening the marketing page launches the home URL without consuming '
    'the pending intent',
    (tester) async {
      final launched = <Uri>[];
      final (_, follow) = await _pumpWithIntent(
        tester,
        launchExternalUrl: (url) async {
          launched.add(url);
          return true;
        },
      );

      await tester.tap(find.byKey(const Key('calendar_follow_home_promo')));
      await tester.pump();
      await tester.pump();

      expect(launched, [Uri.parse(kCaleeForHomeUrl)]);
      expect(follow.pendingIntent, isNotNull);
      // The decision page is still available when the user returns.
      expect(find.byType(FollowCalendarPage), findsOneWidget);
    },
  );

  testWidgets(
    'failed marketing launch shows an error and keeps the decision state',
    (tester) async {
      final (_, follow) = await _pumpWithIntent(
        tester,
        launchExternalUrl: (_) async => false,
      );

      await tester.tap(find.byKey(const Key('calendar_follow_home_promo')));
      await tester.pump();
      await tester.pump();

      expect(
        find.text('Could not open Calee for your home. Please try again.'),
        findsOneWidget,
      );
      expect(follow.pendingIntent, isNotNull);
      expect(find.byType(FollowCalendarPage), findsOneWidget);
    },
  );

  testWidgets(
    'failed home launch from the calendars sheet closes the sheet and '
    'shows the snackbar over the calendar page',
    (tester) async {
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
            launchExternalUrl: (_) async => false,
          ),
        ),
      );
      session.finishRestore();
      await tester.pump();
      await tester.pump();
      expect(find.byType(LocalSubscriberCalendarPage), findsOneWidget);

      await tester.tap(find.byTooltip('Calendars on this phone'));
      await tester.pumpAndSettle();
      await tester.ensureVisible(
        find.byKey(const Key('local_calendar_home_promo')),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('local_calendar_home_promo')));
      await tester.pumpAndSettle();

      // The sheet closed before the launch, so the failure snackbar is
      // visible over the calendar page rather than behind the modal.
      expect(find.text('Calendars on this phone'), findsNothing);
      expect(
        find.text('Could not open Calee for your home. Please try again.'),
        findsOneWidget,
      );
      // The promotion never touches local subscriptions.
      expect((await repo.list()).length, 1);
    },
  );

  testWidgets(
    'already-followed calendar offers Open calendar and does not duplicate '
    'the subscription',
    (tester) async {
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
          ),
        ),
      );
      session.finishRestore();
      follow.injectResolvedIntent();
      await tester.pump();
      await tester.pump();

      expect(find.text('Already on this phone'), findsOneWidget);
      expect(
        find.byKey(const Key('calendar_follow_add_to_phone_button')),
        findsNothing,
      );

      await tester.tap(
        find.byKey(const Key('calendar_follow_open_calendar_button')),
      );
      await tester.pump();
      await tester.pump();

      expect(follow.pendingIntent, isNull);
      expect(find.byType(LocalSubscriberCalendarPage), findsOneWidget);
      expect((await repo.list()).length, 1);
    },
  );
}

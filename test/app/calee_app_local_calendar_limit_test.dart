// App-level tests: the sixth-unique-calendar conversion experience.
//
// A signed-out user who already follows the full local allowance and opens a
// link for a new calendar must reach the contextual Calee-for-home promotion
// — never the generic "could not be added" error — and every action on that
// screen must leave the five stored calendars exactly as they were.
//
// Also pins the non-regression case that matters most here: reopening a
// calendar that is *already* followed while at the allowance still goes
// straight to the normal decision page, with no limit message in sight.

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
import 'package:calee_mobile/features/local_subscriber/local_calendar_limit_page.dart';
import 'package:calee_mobile/features/local_subscriber/local_calendar_subscription_repository.dart';
import 'package:calee_mobile/features/local_subscriber/local_subscriber_calendar_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _kAddToPhone = Key('calendar_follow_add_to_phone_button');
const _kLimitPage = Key('local_calendar_limit_page');
const _kSeeCaleeForHome = Key('local_calendar_limit_see_calee_for_home');
const _kManageCalendars = Key('local_calendar_limit_manage_calendars');
const _kDismiss = Key('local_calendar_limit_dismiss');

String _url(int n) => 'https://example.com/cal$n.ics';

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

  void injectResolvedIntent({required String title, required String url}) {
    pendingIntent = ResolvedCalendarFollowIntent(
      title: title,
      url: url,
      source: 'example.com',
    );
    notifyListeners();
  }
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

/// Pumps a signed-out app already at the local allowance, then delivers a
/// follow intent for [intentUrl] and taps through to it.
Future<
  (
    _FakeSessionController,
    _FakeFollowLinkController,
    LocalCalendarSubscriptionRepository,
  )
>
_pumpAtLimitWithIntent(
  WidgetTester tester, {
  required String intentTitle,
  required String intentUrl,
  Future<bool> Function(Uri url)? launchExternalUrl,
}) async {
  // Phone-shaped surface rather than the 800x600 test default, so the whole
  // conversion screen — heading, body, attempted calendar and all three
  // actions — is laid out at once and can be asserted together.
  tester.view.physicalSize = const Size(420, 900);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);

  final repo = LocalCalendarSubscriptionRepository();
  for (var i = 1; i <= kMaxLocalCalendarSubscriptions; i++) {
    await repo.add(title: 'Calendar $i', url: _url(i), source: 'example.com');
  }

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
  follow.injectResolvedIntent(title: intentTitle, url: intentUrl);
  await tester.pump();
  await tester.pump();

  expect(find.byType(FollowCalendarPage), findsOneWidget);
  return (session, follow, repo);
}

/// Drives the sixth-calendar attempt all the way to the limit screen.
Future<
  (
    _FakeSessionController,
    _FakeFollowLinkController,
    LocalCalendarSubscriptionRepository,
  )
>
_pumpToLimitScreen(
  WidgetTester tester, {
  Future<bool> Function(Uri url)? launchExternalUrl,
}) async {
  final result = await _pumpAtLimitWithIntent(
    tester,
    intentTitle: 'Swim Club',
    intentUrl: _url(6),
    launchExternalUrl: launchExternalUrl,
  );

  await tester.tap(find.byKey(_kAddToPhone));
  await tester.pump();
  await tester.pump();

  expect(find.byType(LocalCalendarLimitPage), findsOneWidget);
  return result;
}

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  testWidgets(
    'a sixth unique calendar shows the benefit-led Calee-for-home promotion '
    'instead of an error, and stores nothing',
    (tester) async {
      final (_, _, repo) = await _pumpToLimitScreen(tester);

      expect(find.byKey(_kLimitPage), findsOneWidget);
      expect(find.text('Bring more calendars together'), findsOneWidget);
      expect(
        find.text("You're already following 5 calendars on this phone."),
        findsOneWidget,
      );
      expect(
        find.text(
          "Calee can bring your family's calendars, schedules, tasks and "
          'reminders together on a shared display at home.',
        ),
        findsOneWidget,
      );

      // The attempted calendar keeps its context on the screen.
      expect(find.text('Swim Club'), findsOneWidget);

      // All three actions are offered, benefit first.
      expect(find.text('See Calee for your home'), findsOneWidget);
      expect(find.text('Manage my calendars'), findsOneWidget);
      expect(find.text('Not now'), findsOneWidget);

      // The screen never leads with the unexplained product label, and the
      // generic storage-failure message is not used for this condition.
      expect(find.text('Get Calee Home'), findsNothing);
      expect(
        find.text('This calendar could not be added on this phone.'),
        findsNothing,
      );

      // Non-destructive: still exactly the original five.
      final stored = await repo.list();
      expect(stored.length, 5);
      expect(await repo.containsUrl(_url(6)), isFalse);
    },
  );

  testWidgets(
    'the marketing CTA opens the canonical Calee-for-home URL without '
    'consuming the intent, signing in, or touching local subscriptions',
    (tester) async {
      final launched = <Uri>[];
      final (session, follow, repo) = await _pumpToLimitScreen(
        tester,
        launchExternalUrl: (url) async {
          launched.add(url);
          return true;
        },
      );

      await tester.tap(find.byKey(_kSeeCaleeForHome));
      await tester.pump();
      await tester.pump();

      expect(launched, [Uri.parse(kCaleeForHomeUrl)]);
      expect(follow.pendingIntent, isNotNull);
      expect(session.isSignedIn, isFalse);
      expect((await repo.list()).length, 5);

      // Returning from the browser restores the same screen.
      expect(find.byType(LocalCalendarLimitPage), findsOneWidget);
    },
  );

  testWidgets(
    'Manage my calendars keeps the attempted calendar through the whole '
    'journey: manage, remove one, close, then confirm the add',
    (tester) async {
      final (session, follow, repo) = await _pumpToLimitScreen(tester);

      // ── Manage my calendars → the existing management sheet ──────────────
      await tester.tap(find.byKey(_kManageCalendars));
      await tester.pumpAndSettle();

      expect(find.byType(LocalSubscriberCalendarPage), findsOneWidget);
      expect(
        find.byKey(const Key('local_calendars_sheet_list')),
        findsOneWidget,
      );
      expect(find.text('5 of 5 calendars'), findsOneWidget);

      // The attempted calendar is still live: the pending intent — the single
      // source of truth for what the user was trying to follow — was not
      // consumed by stepping into calendar management.
      expect(follow.pendingIntent, isNotNull);
      expect(follow.pendingIntent!.url, _url(6));
      expect(follow.pendingIntent!.title, 'Swim Club');

      // Navigating here changed nothing on the phone.
      expect((await repo.list()).length, 5);

      // ── Remove one existing calendar ─────────────────────────────────────
      await tester.tap(find.byType(PopupMenuButton<String>).first);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Remove').last);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Remove').last);
      await tester.pumpAndSettle();

      expect((await repo.list()).length, 4);
      // The still-open sheet reflects the freed slot rather than a stale count.
      expect(find.text('4 of 5 calendars'), findsOneWidget);
      // Still nothing auto-added: making room does not follow the calendar.
      expect(await repo.containsUrl(_url(6)), isFalse);

      // ── Close management → back to the original follow flow ──────────────
      await tester.tap(find.byKey(const Key('local_calendars_sheet_close')));
      await tester.pumpAndSettle();

      // The user lands on the decision page for the calendar they originally
      // opened — not on a bare calendar page, and not on a re-shown limit
      // screen. They confirm the add themselves.
      expect(find.byType(FollowCalendarPage), findsOneWidget);
      expect(find.byType(LocalCalendarLimitPage), findsNothing);
      expect(find.text('Add this calendar'), findsOneWidget);
      expect(find.text('Swim Club'), findsOneWidget);
      expect(await repo.containsUrl(_url(6)), isFalse);

      // ── Confirm the add ──────────────────────────────────────────────────
      await tester.tap(find.byKey(_kAddToPhone));
      await tester.pump();
      await tester.pump();

      final stored = await repo.list();
      expect(await repo.containsUrl(_url(6)), isTrue);
      expect(stored.length, 5);
      expect(stored.length, lessThanOrEqualTo(kMaxLocalCalendarSubscriptions));
      // The attempt is complete, so the intent is finally consumed, and no
      // account was ever created.
      expect(follow.pendingIntent, isNull);
      expect(session.isSignedIn, isFalse);
    },
  );

  testWidgets(
    'a newer follow intent arriving during calendar management supersedes '
    'the older attempt and dismisses the sheet',
    (tester) async {
      final (_, follow, repo) = await _pumpToLimitScreen(tester);

      await tester.tap(find.byKey(_kManageCalendars));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const Key('local_calendars_sheet_list')),
        findsOneWidget,
      );

      // A second calendar link arrives mid-management.
      follow.injectResolvedIntent(title: 'Netball Fixtures', url: _url(7));
      await tester.pumpAndSettle();

      // The management session ends and its sheet is torn down rather than
      // being left floating over the new decision page.
      expect(find.byKey(const Key('local_calendars_sheet_list')), findsNothing);
      expect(find.text('Calendars on this phone'), findsNothing);
      expect(find.byType(LocalCalendarLimitPage), findsNothing);

      // The newer attempt owns the flow now.
      expect(find.byType(FollowCalendarPage), findsOneWidget);
      expect(find.text('Netball Fixtures'), findsOneWidget);
      expect(find.text('Swim Club'), findsNothing);
      expect(follow.pendingIntent!.url, _url(7));

      // Superseding is not destructive to what is stored.
      expect((await repo.list()).length, 5);
    },
  );

  testWidgets(
    'Not now dismisses the promotion, preserves all five subscriptions, and '
    'returns to the local calendars',
    (tester) async {
      final (session, follow, repo) = await _pumpToLimitScreen(tester);
      final before = await repo.list();

      await tester.tap(find.byKey(_kDismiss));
      await tester.pumpAndSettle();

      expect(find.byType(LocalCalendarLimitPage), findsNothing);
      expect(find.byType(LocalSubscriberCalendarPage), findsOneWidget);

      // Dismissal is inert: same five calendars, same ids, no sign-in, and
      // the rejected calendar was never stored.
      final after = await repo.list();
      expect(after.length, 5);
      expect(after.map((s) => s.id), before.map((s) => s.id));
      expect(await repo.containsUrl(_url(6)), isFalse);
      expect(session.isSignedIn, isFalse);
      expect(follow.pendingIntent, isNull);
    },
  );

  testWidgets(
    'reopening an already-followed calendar while at the allowance shows the '
    'normal decision page and never the limit promotion',
    (tester) async {
      final (_, follow, repo) = await _pumpAtLimitWithIntent(
        tester,
        intentTitle: 'Calendar 3',
        intentUrl: _url(3),
      );

      // Already followed → the decision page offers Open calendar, not Add.
      expect(find.text('Already on this phone'), findsOneWidget);
      expect(find.byKey(_kAddToPhone), findsNothing);
      expect(find.byType(LocalCalendarLimitPage), findsNothing);
      expect(find.text('Bring more calendars together'), findsNothing);

      await tester.tap(
        find.byKey(const Key('calendar_follow_open_calendar_button')),
      );
      await tester.pump();
      await tester.pump();

      expect(find.byType(LocalSubscriberCalendarPage), findsOneWidget);
      expect(find.byType(LocalCalendarLimitPage), findsNothing);
      expect(follow.pendingIntent, isNull);
      expect((await repo.list()).length, 5);
    },
  );

  testWidgets(
    'a later intent for a different calendar replaces a stale limit screen',
    (tester) async {
      final (_, follow, _) = await _pumpToLimitScreen(tester);
      expect(find.text('Swim Club'), findsOneWidget);

      follow.injectResolvedIntent(title: 'Netball Fixtures', url: _url(7));
      await tester.pump();
      await tester.pump();

      // The new attempt gets its own decision page, not the previous
      // attempt's promotion with a stale calendar name.
      expect(find.byType(LocalCalendarLimitPage), findsNothing);
      expect(find.byType(FollowCalendarPage), findsOneWidget);
      expect(find.text('Netball Fixtures'), findsOneWidget);
    },
  );
}

// The REAL application sign-in transition, for a phone that already follows a
// public Calee calendar (CaleeAdmin/CaleeMobile#566).
//
// event_details_auth_parity_test.dart proves the two share seams agree: given
// the same logical occurrence, LocalSubscriberCalendarPage and CalendarPage
// send byte-identical mint inputs. What it cannot prove is that the real app
// actually gets from one to the other — it swaps the two widgets directly.
//
// This file covers the part that swap skips: CaleeApp's own state machine,
// driven through the REAL SessionController (real AuthRepository, real
// SessionStore over the mocked secure-storage channel), from the signed-out
// local-subscriber screen, through _completeLocalCalendarSignIn, into the
// normal authenticated CaleeHomePage/CalendarPage, and back out again on sign
// out.
//
// Two things this asserts that nothing else does:
//
//  * signing in does not migrate, link or clear the phone-local subscription —
//    the deliberate behaviour #566 says must not change — and signing out
//    returns to it intact;
//  * the same public event still OFFERS Share once the signed-in CalendarPage
//    is the thing rendering it.
//
// What it deliberately does NOT do is drive the mint. CaleeApp constructs
// LocalSubscriberCalendarPage and CalendarPage with production share
// collaborators and exposes no injection point for them, and inventing one so
// a test could reach it would be a production API that exists for the test.
// The mint inputs are owned by event_details_auth_parity_test.dart, at the
// seam where they can be observed honestly. The two layers together are the
// deterministic coverage: this one proves the journey reaches the signed-in
// Share action, that one proves the action mints the same link.

import 'package:calee_mobile/app/calee_app.dart';
import 'package:calee_mobile/app/calee_home_page.dart';
import 'package:calee_mobile/data/api/calee_hub_client.dart';
import 'package:calee_mobile/data/auth/session_store.dart';
import 'package:calee_mobile/data/models/client_bootstrap.dart';
import 'package:calee_mobile/data/models/client_calendar.dart';
import 'package:calee_mobile/features/auth/auth_repository.dart';
import 'package:calee_mobile/features/auth/login_page.dart';
import 'package:calee_mobile/features/auth/session_controller.dart';
import 'package:calee_mobile/features/calendar/calendar_page.dart';
import 'package:calee_mobile/features/calendar/shared/read_only_calendar_view.dart';
import 'package:calee_mobile/features/calendar/widgets/event_details_sheet.dart';
import 'package:calee_mobile/features/calendar_follow/calendar_follow_link_controller.dart';
import 'package:calee_mobile/features/display_setup/display_activation_controller.dart';
import 'package:calee_mobile/features/display_setup/display_setup_link_controller.dart';
import 'package:calee_mobile/features/display_setup/display_setup_repository.dart';
import 'package:calee_mobile/features/local_subscriber/local_calendar_subscription_repository.dart';
import 'package:calee_mobile/features/local_subscriber/local_subscriber_calendar_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

// ── The one public source, followed locally AND visible signed in ──────────

const String _kPublicUrl =
    'https://portal.calee.com.au/remote.php/dav/public-calendars/abcdefgh?export';

/// The verbatim source UID Hub reports for the occurrence.
const String _kUid = 'shared-occurrence-uid@calee.com.au';

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

ClientLoginResult _loginResult() => ClientLoginResult(
  accessToken: 'access-token',
  refreshToken: 'refresh-token',
  tokenType: 'Bearer',
  expiresIn: 3600,
  refreshExpiresIn: 86400,
  bootstrap: _kBootstrap,
);

/// The SAME published calendar, as the signed-in client sees it.
const _publicCalendar = ClientCalendar(
  id: 'portal:lazers',
  serviceId: 'portal',
  serviceName: 'Portal',
  name: 'Lazers (Morley Eagles)',
  components: [],
  primaryKind: 'calendar',
  supportsEvents: true,
  supportsTasks: false,
  supportsChores: false,
  readOnly: true,
  isSubscription: true,
  subscriptionUrl: _kPublicUrl,
  source: 'portal',
);

const _familyCalendar = ClientCalendar(
  id: 'portal:family',
  serviceId: 'portal',
  serviceName: 'Portal',
  name: 'Family',
  components: [],
  primaryKind: 'calendar',
  supportsEvents: true,
  supportsTasks: false,
  supportsChores: false,
  readOnly: false,
  isSubscription: false,
  source: 'nextcloud',
);

DateTime _todayAt(int hour) {
  final now = DateTime.now();
  return DateTime(now.year, now.month, now.day, hour);
}

ClientEvent _publicEvent() => ClientEvent(
  id: 'portal:lazers:composite:1',
  calendarId: 'portal:lazers',
  serviceId: 'portal',
  serviceName: 'Portal',
  title: 'Training',
  startsAt: _todayAt(10).toIso8601String(),
  endsAt: _todayAt(11).toIso8601String(),
  allDay: false,
  source: 'portal',
  recurring: false,
  sourceUid: _kUid,
  readOnly: true,
);

ClientEvent _familyEvent() => ClientEvent(
  id: 'portal:family:composite:1',
  calendarId: 'portal:family',
  serviceId: 'portal',
  serviceName: 'Portal',
  title: 'Dentist',
  startsAt: _todayAt(14).toIso8601String(),
  endsAt: _todayAt(15).toIso8601String(),
  allDay: false,
  source: 'nextcloud',
  recurring: false,
  sourceUid: 'family-uid',
  readOnly: false,
);

/// Serves the signed-in calendar/event payload. Everything else on
/// CaleeHubClient keeps its real (unused) behaviour.
class _StubHub extends CaleeHubClient {
  _StubHub({this.calendarsPayload = const [], this.eventsPayload = const []})
    : super();

  List<ClientCalendar> calendarsPayload;
  List<ClientEvent> eventsPayload;
  int calendarCalls = 0;

  @override
  Future<ClientCalendarList> calendars({required String accessToken}) async {
    calendarCalls++;
    return ClientCalendarList(
      calendars: List<ClientCalendar>.from(calendarsPayload),
    );
  }

  @override
  Future<ClientEventList> events({
    required String accessToken,
    required String from,
    required String to,
  }) async => ClientEventList(
    from: from,
    to: to,
    events: List<ClientEvent>.from(eventsPayload),
  );
}

class _FakeDisplaySetupLinkController extends DisplaySetupLinkController {
  @override
  Future<void> init() async {}
}

class _FakeFollowLinkController extends CalendarFollowLinkController {
  @override
  Future<void> init() async {}
}

/// The REAL SessionController, over the real repository and session store.
///
/// Only [restoreSession] is neutralised, and only so the app settles on the
/// signed-out screen deterministically instead of racing a stored-token read.
/// completeSignIn and signOut — the two transitions under test — are the
/// production implementations, and they really do write and clear the session
/// store through the mocked platform channel.
class _RestoreSuppressedSessionController extends SessionController {
  _RestoreSuppressedSessionController({required super.repository});

  @override
  Future<void> restoreSession() async {
    accessToken = null;
    bootstrap = null;
    isRestoringSession = false;
    notifyListeners();
  }
}

class _Harness {
  _Harness({required this.session, required this.repo, required this.hub});

  final SessionController session;
  final LocalCalendarSubscriptionRepository repo;
  final _StubHub hub;
}

Future<_Harness> _pumpSignedOutWithLocalFollow(
  WidgetTester tester, {
  required _StubHub hub,
}) async {
  final repo = LocalCalendarSubscriptionRepository();
  await repo.add(
    title: 'Lazers (Morley Eagles)',
    url: _kPublicUrl,
    source: 'portal.calee.com.au',
  );

  final session = _RestoreSuppressedSessionController(
    repository: AuthRepository(hubClient: hub, sessionStore: SessionStore()),
  );

  await tester.pumpWidget(
    CaleeApp.forTesting(
      testDeps: CaleeAppTestDependencies(
        hubClient: hub,
        sessionController: session,
        displaySetupLinkController: _FakeDisplaySetupLinkController(),
        followLinkController: _FakeFollowLinkController(),
        displayActivationController: DisplayActivationController(
          repository: DisplaySetupRepository(hubClient: hub),
        ),
        localSubscriptionRepo: repo,
        launchExternalUrl: (_) async => true,
      ),
    ),
  );
  await session.restoreSession();
  await tester.pumpAndSettle();

  return _Harness(session: session, repo: repo, hub: hub);
}

/// Signs in the way the app does: the local-calendar screen's Sign in action
/// opens the normal LoginPage, and a successful login hands its result to
/// CaleeApp's own completion path.
Future<void> _signInFromLocalCalendar(WidgetTester tester) async {
  await tester.tap(find.byKey(const Key('local_calendar_sign_in_button')));
  await tester.pumpAndSettle();
  expect(find.byType(LoginPage), findsOneWidget);

  final loginPage = tester.widget<LoginPage>(find.byType(LoginPage));
  await loginPage.onSignedIn(_loginResult());
  await tester.pumpAndSettle();
}

/// Selects the Calendar tab and the day the fixture events fall on.
Future<void> _openCalendarTabOnEventDay(WidgetTester tester) async {
  await tester.tap(find.byIcon(Icons.calendar_month_outlined).last);
  await tester.pumpAndSettle();
  expect(find.byType(CalendarPage), findsOneWidget);

  final today = _todayAt(10);
  tester
      .widget<ReadOnlyCalendarView>(find.byType(ReadOnlyCalendarView))
      .onSelectDay(DateTime(today.year, today.month, today.day));
  await tester.pumpAndSettle();
}

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({
      'calee_pref_migrated_to_shared_prefs': true,
    });
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.it_nomads.com/flutter_secure_storage'),
          (call) async => <String, String>{},
        );
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.it_nomads.com/flutter_secure_storage'),
          null,
        );
  });

  testWidgets('the real sign-in transition keeps the local follow and still '
      'offers Share for the same public event', (tester) async {
    final hub = _StubHub(
      calendarsPayload: const [_publicCalendar],
      eventsPayload: [_publicEvent()],
    );
    final harness = await _pumpSignedOutWithLocalFollow(tester, hub: hub);

    // 1-2. Signed out, on the local-subscriber screen, following the calendar.
    expect(find.byType(LocalSubscriberCalendarPage), findsOneWidget);
    expect(await harness.repo.list(), hasLength(1));
    expect((await harness.repo.list()).single.url, _kPublicUrl);

    // 3-4. Sign in through the app's own path.
    await _signInFromLocalCalendar(tester);

    // 5. The phone-local subscription was NOT migrated, linked or cleared.
    //    #566 is explicit that signing in must not touch it.
    expect(await harness.repo.list(), hasLength(1));
    expect((await harness.repo.list()).single.url, _kPublicUrl);

    // 6. The normal authenticated experience is what renders now.
    expect(find.byType(CaleeHomePage), findsOneWidget);
    expect(find.byType(LocalSubscriberCalendarPage), findsNothing);

    // 7-8. The same public event, now served by Hub to the signed-in
    //      CalendarPage, opens details and STILL offers Share.
    await _openCalendarTabOnEventDay(tester);
    expect(harness.hub.calendarCalls, greaterThan(0));

    await tester.tap(find.text('Training').first);
    await tester.pumpAndSettle();

    expect(find.byKey(kEventDetailsSheetKey), findsOneWidget);
    expect(
      find.text('Share event'),
      findsOneWidget,
      reason: 'signing in must not remove Share from an already-public event',
    );
    await tester.tapAt(const Offset(20, 20));
    await tester.pumpAndSettle();

    // 9-10. Sign out, and the original local follow is still there and still
    //       usable.
    await harness.session.signOut();
    await tester.pumpAndSettle();

    expect(find.byType(LocalSubscriberCalendarPage), findsOneWidget);
    expect(await harness.repo.list(), hasLength(1));
    expect((await harness.repo.list()).single.url, _kPublicUrl);
    // Read back through a FRESH repository: the follow survives in storage,
    // not merely in the instance the app happens to be holding.
    expect(await LocalCalendarSubscriptionRepository().list(), hasLength(1));
  });

  testWidgets('signing in does not make a private family event shareable', (
    tester,
  ) async {
    // The same transition, for the source that must never gain a public link.
    final hub = _StubHub(
      calendarsPayload: const [_familyCalendar],
      eventsPayload: [_familyEvent()],
    );
    await _pumpSignedOutWithLocalFollow(tester, hub: hub);
    await _signInFromLocalCalendar(tester);
    await _openCalendarTabOnEventDay(tester);

    await tester.tap(find.text('Dentist').first);
    await tester.pumpAndSettle();

    expect(find.byKey(kEventDetailsSheetKey), findsOneWidget);
    expect(find.text('Edit Event'), findsOneWidget);
    expect(find.text('Share event'), findsNothing);
  });

  testWidgets('a public event Hub sends without a source UID is not '
      'shareable after sign-in', (tester) async {
    // The Hub-side half of #566: the calendar is provably public, but the
    // occurrence carries no canonical source identity. Mobile must refuse
    // rather than substitute the composite event id — and the details must
    // still open.
    final hub = _StubHub(
      calendarsPayload: const [_publicCalendar],
      eventsPayload: [
        ClientEvent(
          id: 'portal:lazers:composite:1',
          calendarId: 'portal:lazers',
          serviceId: 'portal',
          serviceName: 'Portal',
          title: 'Training',
          startsAt: _todayAt(10).toIso8601String(),
          endsAt: _todayAt(11).toIso8601String(),
          allDay: false,
          source: 'portal',
          recurring: false,
          sourceUid: null,
          readOnly: true,
        ),
      ],
    );
    await _pumpSignedOutWithLocalFollow(tester, hub: hub);
    await _signInFromLocalCalendar(tester);
    await _openCalendarTabOnEventDay(tester);

    await tester.tap(find.text('Training').first);
    await tester.pumpAndSettle();

    expect(find.byKey(kEventDetailsSheetKey), findsOneWidget);
    expect(find.text('Share event'), findsNothing);
    expect(find.textContaining("Sharing isn't available"), findsOneWidget);
  });
}

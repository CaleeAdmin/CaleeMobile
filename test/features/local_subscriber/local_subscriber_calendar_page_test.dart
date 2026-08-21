import 'dart:async';

import 'package:calee_mobile/features/calendar/shared/read_only_calendar_view.dart';
import 'package:calee_mobile/features/local_subscriber/calee_public_calendar_source.dart';
import 'package:calee_mobile/features/local_subscriber/local_calendar_event.dart';
import 'package:calee_mobile/features/local_subscriber/local_calendar_ics_service.dart';
import 'package:calee_mobile/features/local_subscriber/local_calendar_occurrence_identity.dart';
import 'package:calee_mobile/features/local_subscriber/local_calendar_subscription.dart';
import 'package:calee_mobile/features/local_subscriber/local_calendar_subscription_repository.dart';
import 'package:calee_mobile/features/local_subscriber/local_event_details_sheet.dart';
import 'package:calee_mobile/features/local_subscriber/local_event_link_service.dart';
import 'package:calee_mobile/features/local_subscriber/local_event_share_launcher.dart';
import 'package:calee_mobile/features/local_subscriber/local_subscriber_calendar_page.dart';
import 'package:calee_mobile/features/local_subscriber/local_subscriber_promotion_preferences.dart';
import 'package:calee_mobile/ui/calee_design.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _kInlinePromo = Key('local_calendar_inline_home_promo');
const _kInlinePromoDismiss = Key('local_calendar_inline_home_promo_dismiss');
const _kSignInButton = Key('local_calendar_sign_in_button');
const _kSheetPromo = Key('local_calendar_home_promo');

// ── Stubs ──────────────────────────────────────────────────────────────────────

class _StubIcsService extends LocalCalendarIcsService {
  _StubIcsService(this._events);

  final List<LocalCalendarEvent> _events;

  @override
  Future<List<LocalCalendarEvent>> fetchEvents(
    LocalCalendarSubscription sub,
  ) async => _events;
}

/// Fetch that never completes, freezing the page in its refreshing state.
class _NeverCompletingIcsService extends LocalCalendarIcsService {
  final _completer = Completer<List<LocalCalendarEvent>>();

  @override
  Future<List<LocalCalendarEvent>> fetchEvents(LocalCalendarSubscription sub) =>
      _completer.future;
}

class _FakePromotionPreferences extends LocalSubscriberPromotionPreferences {
  bool dismissed = false;
  int dismissCalls = 0;

  @override
  Future<bool> isInlineHomePromotionDismissed() async => dismissed;

  @override
  Future<void> dismissInlineHomePromotion() async {
    dismissCalls++;
    dismissed = true;
  }
}

// ── Helpers ───────────────────────────────────────────────────────────────────

LocalCalendarSubscription _sub({
  String id = 'sub1',
  String title = 'Test Calendar',
  String url = 'https://example.com/cal.ics',
  String source = 'example.com',
}) => LocalCalendarSubscription(
  id: id,
  title: title,
  url: url,
  source: source,
  createdAt: DateTime(2024, 1, 1),
);

LocalCalendarEvent _event({
  String id = 'e1',
  String subId = 'sub1',
  String title = 'Test Event',
}) {
  final now = DateTime.now();
  return LocalCalendarEvent(
    id: id,
    subscriptionId: subId,
    subscriptionTitle: 'Test Calendar',
    title: title,
    start: DateTime(now.year, now.month, now.day, 10),
    end: DateTime(now.year, now.month, now.day, 11),
    isAllDay: false,
    sourceUrl: 'https://example.com/cal.ics',
  );
}

Widget _buildPage({
  List<LocalCalendarSubscription> subscriptions = const [],
  LocalCalendarIcsService? icsService,
  VoidCallback? onSignIn,
  VoidCallback? onLearnAboutHome,
  void Function(List<LocalCalendarSubscription>)? onSubscriptionsChanged,
  LocalSubscriberPromotionPreferences? promotionPreferences,
  LocalEventLinkService? eventLinkService,
  LocalEventShareLauncher? shareLauncher,
  bool use24h = false,
}) {
  return MaterialApp(
    theme: CaleeTheme.buildThemeData(),
    home: Builder(
      builder: (context) => MediaQuery(
        data: MediaQuery.of(context).copyWith(alwaysUse24HourFormat: use24h),
        child: LocalSubscriberCalendarPage(
          subscriptions: subscriptions,
          repository: LocalCalendarSubscriptionRepository(),
          onSignIn: onSignIn ?? () {},
          onLearnAboutHome: onLearnAboutHome ?? () {},
          onSubscriptionsChanged: onSubscriptionsChanged ?? (_) {},
          icsService: icsService ?? _StubIcsService(const []),
          promotionPreferences: promotionPreferences,
          eventLinkService: eventLinkService,
          shareLauncher: shareLauncher,
        ),
      ),
    ),
  );
}

// ── #558 share fixtures ───────────────────────────────────────────────────────

const _kPublicToken = 'AbC123_-xyz';
const _kPublicCalendarUrl =
    'https://portal.calee.com.au/remote.php/dav/public-calendars/'
    '$_kPublicToken?export';
const _kOneOffUid = 'public-one-off-source-uid';
const _kSeriesUid = 'public-series-source-uid';
const _kMintedLink =
    'https://calembed.calee.com.au/e/1.eyJiIjoicG9ydGFsIn0.c2lnbmF0dXJl';

/// What the DISPLAY parser resolved for a timed occurrence whose source zone
/// this phone had to guess at, and which must therefore never be minted.
const _kDisplayRecurrenceId = '20260818T153000Z';

/// The CANONICAL occurrence identity for that same occurrence.
const _kCanonicalRecurrenceId = '20260818T073000Z';

/// Where a detached occurrence originally sat, which stays its identity even
/// after it is moved.
const _kOriginalRecurrenceId = '20260818T020000Z';

LocalCalendarSubscription _publicSub() => LocalCalendarSubscription(
  id: 'sub1',
  title: 'Public Calendar',
  url: _kPublicCalendarUrl,
  // Deliberately a value that says nothing about publicness: eligibility is
  // decided from the URL, never from this descriptive legacy field.
  source: 'somewhere-else',
  createdAt: DateTime(2024, 1, 1),
);

DateTime _todayAt(int hour, [int minute = 0]) {
  final now = DateTime.now();
  return DateTime(now.year, now.month, now.day, hour, minute);
}

const _kFullDayNames = [
  'Sunday',
  'Monday',
  'Tuesday',
  'Wednesday',
  'Thursday',
  'Friday',
  'Saturday',
];

const _kMonthNames = [
  'January',
  'February',
  'March',
  'April',
  'May',
  'June',
  'July',
  'August',
  'September',
  'October',
  'November',
  'December',
];

String _todayDateLabel() {
  final now = DateTime.now();
  return '${_kFullDayNames[now.weekday % 7]} ${now.day} '
      '${_kMonthNames[now.month - 1]} ${now.year}';
}

LocalCalendarEvent _publicOneOffEvent({
  String id = 'public-one-off',
  String title = 'Public One Off',
  String uid = _kOneOffUid,
  int startHour = 10,
  String canonicalStatus = CanonicalSourceStatus.ok,
}) => LocalCalendarEvent(
  id: id,
  subscriptionId: 'sub1',
  subscriptionTitle: 'Public Calendar',
  title: title,
  start: _todayAt(startHour),
  end: _todayAt(startHour + 1),
  isAllDay: false,
  sourceUrl: _kPublicCalendarUrl,
  uid: uid,
  canonicalStatus: canonicalStatus,
);

/// An all-day occurrence of a series. The canonical identity is deliberately
/// NOT derivable from the displayed date, so a test that sees it arrive at the
/// mint endpoint has proved it was carried through rather than recomputed.
LocalCalendarEvent _publicAllDayRecurringEvent() => LocalCalendarEvent(
  id: 'public-all-day',
  subscriptionId: 'sub1',
  subscriptionTitle: 'Public Calendar',
  title: 'Public All Day',
  start: _todayAt(0),
  isAllDay: true,
  sourceUrl: _kPublicCalendarUrl,
  uid: _kSeriesUid,
  recurring: true,
  recurrenceId: '20260818',
  canonicalRecurrenceId: '20260818',
  canonicalStatus: CanonicalSourceStatus.ok,
);

/// A timed occurrence whose DISPLAY identity and CANONICAL identity disagree —
/// the case the whole canonical layer exists for.
LocalCalendarEvent _publicTimedRecurringEvent() => LocalCalendarEvent(
  id: 'public-timed-series',
  subscriptionId: 'sub1',
  subscriptionTitle: 'Public Calendar',
  title: 'Public Timed Series',
  start: _todayAt(15, 30),
  end: _todayAt(16, 30),
  isAllDay: false,
  sourceUrl: _kPublicCalendarUrl,
  uid: _kSeriesUid,
  recurring: true,
  recurrenceId: _kDisplayRecurrenceId,
  canonicalRecurrenceId: _kCanonicalRecurrenceId,
  canonicalStatus: CanonicalSourceStatus.ok,
);

/// A detached override: shown at its MOVED start, identified by where it
/// originally was.
LocalCalendarEvent _publicDetachedMovedEvent() => LocalCalendarEvent(
  id: 'public-moved',
  subscriptionId: 'sub1',
  subscriptionTitle: 'Public Calendar',
  title: 'Public Moved Occurrence',
  start: _todayAt(18),
  end: _todayAt(19),
  isAllDay: false,
  sourceUrl: _kPublicCalendarUrl,
  uid: _kSeriesUid,
  recurring: true,
  recurrenceId: _kOriginalRecurrenceId,
  canonicalRecurrenceId: _kOriginalRecurrenceId,
  // A moved occurrence can land on a zone no database resolves and still be
  // named by its RECURRENCE-ID, so this status must not gate sharing.
  canonicalStatus: CanonicalSourceStatus.unsupportedTzid,
);

/// A recurring occurrence the canonical layer refuses to name.
LocalCalendarEvent _publicUnmintableRecurringEvent() => LocalCalendarEvent(
  id: 'public-floating-series',
  subscriptionId: 'sub1',
  subscriptionTitle: 'Public Calendar',
  title: 'Public Floating Series',
  start: _todayAt(12),
  end: _todayAt(13),
  isAllDay: false,
  sourceUrl: _kPublicCalendarUrl,
  uid: _kSeriesUid,
  recurring: true,
  // The display parser still placed it; the canonical layer would not.
  recurrenceId: '20260818T040000Z',
  canonicalStatus: CanonicalSourceStatus.floatingWithoutContext,
);

class _FakeEventLinkService implements LocalEventLinkService {
  final List<({String calendarUrl, String uid, String? occurrenceId})> calls =
      [];

  Uri result = Uri.parse(_kMintedLink);
  Object? error;

  /// Holds a mint request open so a test can act while one is in flight.
  Completer<void>? gate;

  @override
  Future<Uri> mint({
    required CaleePublicCalendarSource source,
    required String uid,
    String? occurrenceId,
  }) async {
    calls.add((
      calendarUrl: source.canonicalUrl,
      uid: uid,
      occurrenceId: occurrenceId,
    ));
    final held = gate;
    if (held != null) await held.future;
    final failure = error;
    if (failure != null) throw failure;
    return result;
  }
}

class _FakeShareLauncher implements LocalEventShareLauncher {
  final List<({Uri url, String title, Rect origin})> calls = [];
  Object? error;

  @override
  Future<void> share({
    required Uri url,
    required String title,
    required Rect sharePositionOrigin,
  }) async {
    calls.add((url: url, title: title, origin: sharePositionOrigin));
    final failure = error;
    if (failure != null) throw failure;
  }
}

// ── Tests ─────────────────────────────────────────────────────────────────────

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  group('LocalSubscriberCalendarPage — empty state', () {
    testWidgets('shows empty state when no subscriptions', (tester) async {
      await tester.pumpWidget(_buildPage(subscriptions: []));
      await tester.pumpAndSettle();
      expect(
        find.text('No calendars added on this phone yet.'),
        findsOneWidget,
      );
    });

    testWidgets('does not show calendar view when no subscriptions', (
      tester,
    ) async {
      await tester.pumpWidget(_buildPage(subscriptions: []));
      await tester.pumpAndSettle();
      expect(find.byType(ReadOnlyCalendarView), findsNothing);
    });
  });

  group('LocalSubscriberCalendarPage — calendar view', () {
    testWidgets('shows ReadOnlyCalendarView when subscriptions exist', (
      tester,
    ) async {
      await tester.pumpWidget(_buildPage(subscriptions: [_sub()]));
      await tester.pumpAndSettle();
      expect(find.byType(ReadOnlyCalendarView), findsOneWidget);
    });

    testWidgets('displays Month / Agenda segmented control', (tester) async {
      await tester.pumpWidget(_buildPage(subscriptions: [_sub()]));
      await tester.pumpAndSettle();
      expect(find.text('Month'), findsOneWidget);
      expect(find.text('Agenda'), findsOneWidget);
    });

    testWidgets('switching to Agenda mode does not crash', (tester) async {
      await tester.pumpWidget(_buildPage(subscriptions: [_sub()]));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Agenda'));
      await tester.pumpAndSettle();
      expect(find.byType(ReadOnlyCalendarView), findsOneWidget);
    });

    testWidgets('does not show the old permanent banner or misleading copy', (
      tester,
    ) async {
      await tester.pumpWidget(_buildPage(subscriptions: [_sub()]));
      await tester.pumpAndSettle();
      expect(find.text('Added on this phone only'), findsNothing);
      expect(find.textContaining('Sign in to link'), findsNothing);
      // The calendar itself is unobstructed and visible.
      expect(find.byType(ReadOnlyCalendarView), findsOneWidget);
    });

    testWidgets('never shows migration, transfer, or free-account copy', (
      tester,
    ) async {
      await tester.pumpWidget(_buildPage(subscriptions: [_sub()]));
      await tester.pumpAndSettle();
      for (final forbidden in [
        'Sign in to link',
        'free account',
        'Free Calee account',
        'sync this calendar',
        'Sync this calendar',
        'transfer this calendar',
        'Transfer this calendar',
        'will be transferred',
      ]) {
        expect(
          find.textContaining(forbidden),
          findsNothing,
          reason: 'forbidden copy "$forbidden" must not appear',
        );
      }
    });

    testWidgets('does not show paid-feature navigation in signed-out mode', (
      tester,
    ) async {
      await tester.pumpWidget(_buildPage(subscriptions: [_sub()]));
      await tester.pumpAndSettle();
      expect(find.byType(NavigationBar), findsNothing);
      expect(find.byType(BottomNavigationBar), findsNothing);
      expect(find.text('Tasks'), findsNothing);
      expect(find.text('Chores'), findsNothing);
      expect(find.text('Meals'), findsNothing);
      expect(find.text('Lists'), findsNothing);
    });
  });

  group('LocalSubscriberCalendarPage — no create/edit/delete', () {
    testWidgets('does not show Add event button', (tester) async {
      await tester.pumpWidget(_buildPage(subscriptions: [_sub()]));
      await tester.pumpAndSettle();
      expect(find.byTooltip('Add event'), findsNothing);
      expect(find.widgetWithText(FloatingActionButton, 'Add'), findsNothing);
    });

    testWidgets('does not show Edit event text anywhere', (tester) async {
      await tester.pumpWidget(
        _buildPage(
          subscriptions: [_sub()],
          icsService: _StubIcsService([_event()]),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Edit Event'), findsNothing);
      expect(find.text('Edit event'), findsNothing);
    });

    testWidgets('does not show Delete event text anywhere', (tester) async {
      await tester.pumpWidget(
        _buildPage(
          subscriptions: [_sub()],
          icsService: _StubIcsService([_event()]),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Delete Event'), findsNothing);
      expect(find.text('Delete event'), findsNothing);
    });
  });

  group('LocalSubscriberCalendarPage — refresh', () {
    testWidgets('shows refresh icon button in app bar', (tester) async {
      await tester.pumpWidget(_buildPage(subscriptions: [_sub()]));
      await tester.pumpAndSettle();
      expect(find.byTooltip('Refresh'), findsOneWidget);
    });

    testWidgets('refresh button triggers without crashing', (tester) async {
      await tester.pumpWidget(
        _buildPage(
          subscriptions: [_sub()],
          icsService: _StubIcsService([_event()]),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Refresh'));
      await tester.pumpAndSettle();
      expect(find.byType(LocalSubscriberCalendarPage), findsOneWidget);
    });
  });

  group('LocalSubscriberCalendarPage — sign-in action', () {
    testWidgets('app bar shows Calee title, Refresh, and a visible Sign in', (
      tester,
    ) async {
      await tester.pumpWidget(_buildPage(subscriptions: [_sub()]));
      await tester.pumpAndSettle();

      expect(find.text('Calee'), findsOneWidget);
      expect(find.byTooltip('Refresh'), findsOneWidget);
      expect(find.byKey(_kSignInButton), findsOneWidget);
      expect(find.text('Sign in'), findsOneWidget);
      expect(find.byIcon(Icons.login), findsOneWidget);
      expect(find.byTooltip('Sign in to Calee'), findsOneWidget);
      // An explicit labelled action, not an icon-only avatar control.
      expect(find.byIcon(Icons.account_circle_outlined), findsNothing);
      expect(find.byIcon(Icons.account_circle), findsNothing);
    });

    testWidgets('Sign in meets the 48 dp minimum tap target', (tester) async {
      await tester.pumpWidget(_buildPage(subscriptions: [_sub()]));
      await tester.pumpAndSettle();

      final size = tester.getSize(find.byKey(_kSignInButton));
      expect(size.height, greaterThanOrEqualTo(48));
      expect(size.width, greaterThanOrEqualTo(48));
    });

    testWidgets(
      'tapping Sign in invokes onSignIn exactly once and nothing else',
      (tester) async {
        var signInTaps = 0;
        var learnTaps = 0;
        var subscriptionsChangedCalls = 0;
        await tester.pumpWidget(
          _buildPage(
            subscriptions: [_sub()],
            onSignIn: () => signInTaps++,
            onLearnAboutHome: () => learnTaps++,
            onSubscriptionsChanged: (_) => subscriptionsChangedCalls++,
          ),
        );
        await tester.pumpAndSettle();

        await tester.tap(find.byKey(_kSignInButton));
        await tester.pump();

        expect(signInTaps, 1);
        expect(learnTaps, 0);
        // Signing in never removes or migrates local subscriptions.
        expect(subscriptionsChangedCalls, 0);
        expect(find.byType(ReadOnlyCalendarView), findsOneWidget);
      },
    );
  });

  group('LocalSubscriberCalendarPage — inline home promotion', () {
    testWidgets('shows thumbnail, copy, chevron, and dismiss by default', (
      tester,
    ) async {
      await tester.pumpWidget(_buildPage(subscriptions: [_sub()]));
      await tester.pumpAndSettle();

      final promo = find.byKey(_kInlinePromo);
      expect(promo, findsOneWidget);
      expect(
        find.descendant(
          of: promo,
          matching: find.byKey(const Key('calee_home_product_thumbnail')),
        ),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: promo,
          matching: find.text('See this calendar on a family screen'),
        ),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: promo,
          matching: find.text('Discover Calee for your home.'),
        ),
        findsOneWidget,
      );
      expect(
        find.descendant(of: promo, matching: find.byIcon(Icons.chevron_right)),
        findsOneWidget,
      );
      expect(
        find.descendant(of: promo, matching: find.byKey(_kInlinePromoDismiss)),
        findsOneWidget,
      );
      // Compact discovery only: no pricing, feature list, or sales button.
      expect(find.textContaining('\$'), findsNothing);
      expect(
        find.descendant(of: promo, matching: find.byType(FilledButton)),
        findsNothing,
      );
    });

    testWidgets('is compact by default', (tester) async {
      await tester.pumpWidget(_buildPage(subscriptions: [_sub()]));
      await tester.pumpAndSettle();

      final height = tester.getSize(find.byKey(_kInlinePromo)).height;
      expect(height, greaterThanOrEqualTo(72));
      expect(height, lessThanOrEqualTo(96));
    });

    testWidgets('tapping the body invokes onLearnAboutHome only', (
      tester,
    ) async {
      var learnTaps = 0;
      var signInTaps = 0;
      final prefs = _FakePromotionPreferences();
      await tester.pumpWidget(
        _buildPage(
          subscriptions: [_sub()],
          onSignIn: () => signInTaps++,
          onLearnAboutHome: () => learnTaps++,
          promotionPreferences: prefs,
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(_kInlinePromo));
      await tester.pump();

      expect(learnTaps, 1);
      expect(signInTaps, 0);
      expect(prefs.dismissCalls, 0);
      // Navigating is not dismissing: the strip stays.
      expect(find.byKey(_kInlinePromo), findsOneWidget);
    });

    testWidgets('dismiss hides the promotion without navigating', (
      tester,
    ) async {
      var learnTaps = 0;
      final prefs = _FakePromotionPreferences();
      await tester.pumpWidget(
        _buildPage(
          subscriptions: [_sub()],
          onLearnAboutHome: () => learnTaps++,
          promotionPreferences: prefs,
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(_kInlinePromoDismiss));
      await tester.pumpAndSettle();

      expect(prefs.dismissCalls, 1);
      expect(learnTaps, 0);
      expect(find.byKey(_kInlinePromo), findsNothing);
      expect(find.byType(ReadOnlyCalendarView), findsOneWidget);
    });

    testWidgets('dismissal writes the real versioned preference', (
      tester,
    ) async {
      await tester.pumpWidget(_buildPage(subscriptions: [_sub()]));
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(_kInlinePromoDismiss));
      await tester.pumpAndSettle();

      final stored = await SharedPreferences.getInstance();
      expect(
        stored.getBool('local_calendar_inline_home_promo_dismissed_v1'),
        isTrue,
      );
      // The dismissal never touches the subscription payload.
      expect(stored.getString('local_calendar_subscriptions_v1'), isNull);
    });

    testWidgets(
      'saved dismissal keeps the promotion hidden and the sheet row intact',
      (tester) async {
        SharedPreferences.setMockInitialValues({
          'local_calendar_inline_home_promo_dismissed_v1': true,
        });
        await tester.pumpWidget(_buildPage(subscriptions: [_sub()]));
        await tester.pumpAndSettle();

        expect(find.byKey(_kInlinePromo), findsNothing);
        expect(find.byType(ReadOnlyCalendarView), findsOneWidget);

        // The permanent low-pressure discovery row in the management sheet
        // is unaffected by dismissing the inline strip.
        await tester.tap(find.byTooltip('Calendars on this phone'));
        await tester.pumpAndSettle();
        expect(find.byKey(_kSheetPromo), findsOneWidget);
        expect(find.text('Calee for your home'), findsOneWidget);
      },
    );

    testWidgets(
      'body and dismiss expose separate button semantics; image is decorative',
      (tester) async {
        final handle = tester.ensureSemantics();
        await tester.pumpWidget(_buildPage(subscriptions: [_sub()]));
        await tester.pumpAndSettle();

        final bodyNode = tester.getSemantics(
          find.descendant(
            of: find.byKey(_kInlinePromo),
            matching: find.text('See this calendar on a family screen'),
          ),
        );
        expect(bodyNode, isSemantics(isButton: true, hasTapAction: true));
        expect(
          bodyNode.label,
          contains('See this calendar on a family screen'),
        );
        expect(bodyNode.label, contains('Discover Calee for your home.'));

        expect(
          tester.getSemantics(find.byKey(_kInlinePromoDismiss)),
          isSemantics(isButton: true, hasTapAction: true, tooltip: 'Dismiss'),
        );

        // The product image stays excluded from semantics as decorative.
        expect(bodyNode.label, isNot(contains('calee_home_white_tablet')));
        handle.dispose();
      },
    );
  });

  group('LocalSubscriberCalendarPage — responsive and loading', () {
    testWidgets('renders without exceptions at 320 logical pixels wide', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(320, 568);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      await tester.pumpWidget(_buildPage(subscriptions: [_sub()]));
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
      expect(find.text('Sign in').hitTestable(), findsOneWidget);
      expect(find.byKey(_kInlinePromo), findsOneWidget);
      expect(find.byType(ReadOnlyCalendarView), findsOneWidget);
    });

    testWidgets('renders without exceptions at 2.0 text scale', (tester) async {
      tester.view.physicalSize = const Size(360, 640);
      tester.view.devicePixelRatio = 1.0;
      tester.platformDispatcher.textScaleFactorTestValue = 2.0;
      addTearDown(tester.view.reset);
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);

      await tester.pumpWidget(_buildPage(subscriptions: [_sub()]));
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
      expect(find.text('Sign in'), findsOneWidget);
      expect(find.text('See this calendar on a family screen'), findsOneWidget);
      expect(find.byType(ReadOnlyCalendarView), findsOneWidget);
    });

    testWidgets('Sign in stays visible while calendars are refreshing', (
      tester,
    ) async {
      await tester.pumpWidget(
        _buildPage(
          subscriptions: [_sub()],
          icsService: _NeverCompletingIcsService(),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));

      // The refresh slot shows the progress indicator while loading…
      expect(
        find.descendant(
          of: find.byType(AppBar),
          matching: find.byType(CircularProgressIndicator),
        ),
        findsOneWidget,
      );
      // …and the Sign in action remains visible and tappable.
      expect(find.byKey(_kSignInButton).hitTestable(), findsOneWidget);
      expect(find.text('Sign in'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('many local calendars still render with the promotion', (
      tester,
    ) async {
      final subs = [
        for (var i = 1; i <= 8; i++) _sub(id: 'sub$i', title: 'Calendar $i'),
      ];
      await tester.pumpWidget(_buildPage(subscriptions: subs));
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
      expect(find.byKey(_kInlinePromo), findsOneWidget);
      expect(find.byType(ReadOnlyCalendarView), findsOneWidget);
    });
  });

  group('LocalSubscriberCalendarPage — calendars sheet', () {
    testWidgets('shows Calendars icon button when subscriptions exist', (
      tester,
    ) async {
      await tester.pumpWidget(_buildPage(subscriptions: [_sub()]));
      await tester.pumpAndSettle();
      expect(find.byTooltip('Calendars on this phone'), findsOneWidget);
    });

    testWidgets('opening calendars sheet shows subscription name', (
      tester,
    ) async {
      await tester.pumpWidget(
        _buildPage(subscriptions: [_sub(title: 'My Soccer Calendar')]),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Calendars on this phone'));
      await tester.pumpAndSettle();
      expect(find.text('My Soccer Calendar'), findsOneWidget);
    });

    testWidgets('calendars sheet shows Refresh and Remove options', (
      tester,
    ) async {
      await tester.pumpWidget(_buildPage(subscriptions: [_sub()]));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Calendars on this phone'));
      await tester.pumpAndSettle();

      // Open the popup menu for the subscription tile
      await tester.tap(find.byType(PopupMenuButton<String>).first);
      await tester.pumpAndSettle();

      expect(find.text('Refresh'), findsOneWidget);
      expect(find.text('Remove'), findsOneWidget);
    });

    testWidgets('removing a subscription via the sheet still works', (
      tester,
    ) async {
      var reportedSubscriptions = <LocalCalendarSubscription>[];
      await tester.pumpWidget(
        _buildPage(
          subscriptions: [_sub(title: 'Removable Calendar')],
          onSubscriptionsChanged: (updated) => reportedSubscriptions = updated,
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Calendars on this phone'));
      await tester.pumpAndSettle();

      await tester.tap(find.byType(PopupMenuButton<String>).first);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Remove'));
      await tester.pumpAndSettle();

      expect(find.text('Remove calendar'), findsOneWidget);
      await tester.tap(find.widgetWithText(TextButton, 'Remove'));
      await tester.pumpAndSettle();

      expect(reportedSubscriptions, isEmpty);
    });

    testWidgets('sheet shows the Calee-for-home discovery row', (tester) async {
      await tester.pumpWidget(_buildPage(subscriptions: [_sub()]));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Calendars on this phone'));
      await tester.pumpAndSettle();

      expect(
        find.byKey(const Key('local_calendar_home_promo')),
        findsOneWidget,
      );
      expect(find.text('Calee for your home'), findsOneWidget);
      expect(
        find.text('One shared screen for the whole family'),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: find.byKey(const Key('local_calendar_home_promo')),
          matching: find.byIcon(Icons.chevron_right),
        ),
        findsOneWidget,
      );
      // The approved white-framed product thumbnail leads the row.
      expect(
        find.descendant(
          of: find.byKey(const Key('local_calendar_home_promo')),
          matching: find.byKey(const Key('calee_home_product_thumbnail')),
        ),
        findsOneWidget,
      );
    });

    testWidgets(
      'tapping the Calee-for-home row dismisses the sheet, then invokes '
      'the callback exactly once',
      (tester) async {
        var learnAboutHomeTaps = 0;
        await tester.pumpWidget(
          _buildPage(
            subscriptions: [_sub()],
            onLearnAboutHome: () => learnAboutHomeTaps++,
          ),
        );
        await tester.pumpAndSettle();
        await tester.tap(find.byTooltip('Calendars on this phone'));
        await tester.pumpAndSettle();
        expect(find.text('Calendars on this phone'), findsOneWidget);

        await tester.tap(find.byKey(const Key('local_calendar_home_promo')));
        await tester.pumpAndSettle();

        expect(learnAboutHomeTaps, 1);
        // The modal sheet is gone and the calendar page is visible again.
        expect(find.byType(BottomSheet), findsNothing);
        expect(find.text('Calendars on this phone'), findsNothing);
        expect(find.byType(ReadOnlyCalendarView), findsOneWidget);
      },
    );

    testWidgets(
      'sheet scrolls without overflow for many calendars at 2.0 text scale',
      (tester) async {
        tester.view.physicalSize = const Size(360, 640);
        tester.view.devicePixelRatio = 1.0;
        tester.platformDispatcher.textScaleFactorTestValue = 2.0;
        addTearDown(tester.view.reset);
        addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);

        final subs = [
          for (var i = 1; i <= 12; i++)
            _sub(id: 'sub$i', title: 'Calendar Number $i'),
        ];
        await tester.pumpWidget(_buildPage(subscriptions: subs));
        await tester.pumpAndSettle();
        await tester.tap(
          find.byTooltip('Calendars on this phone'),
          warnIfMissed: false,
        );
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        expect(find.text('Calendars on this phone'), findsOneWidget);

        // First and last calendar rows and the Home promotion are all
        // reachable by scrolling the sheet's list.
        final sheetScrollable = find.descendant(
          of: find.byKey(const Key('local_calendars_sheet_list')),
          matching: find.byType(Scrollable),
        );
        final promo = find.byKey(const Key('local_calendar_home_promo'));

        expect(find.text('Calendar Number 1').hitTestable(), findsOneWidget);

        await tester.scrollUntilVisible(
          find.text('Calendar Number 12'),
          200,
          scrollable: sheetScrollable,
        );
        await tester.ensureVisible(find.text('Calendar Number 12'));
        await tester.pumpAndSettle();
        expect(find.text('Calendar Number 12').hitTestable(), findsOneWidget);

        await tester.scrollUntilVisible(
          promo,
          200,
          scrollable: sheetScrollable,
        );
        await tester.ensureVisible(promo);
        await tester.pumpAndSettle();
        expect(promo.hitTestable(), findsOneWidget);
        expect(tester.takeException(), isNull);

        // Scrolling back up keeps the first row reachable too.
        await tester.scrollUntilVisible(
          find.text('Calendar Number 1'),
          -200,
          scrollable: sheetScrollable,
        );
        await tester.ensureVisible(find.text('Calendar Number 1'));
        await tester.pumpAndSettle();
        expect(find.text('Calendar Number 1').hitTestable(), findsOneWidget);
        expect(tester.takeException(), isNull);
      },
    );

    testWidgets('sheet discovery row is not shown in the calendar body', (
      tester,
    ) async {
      await tester.pumpWidget(_buildPage(subscriptions: [_sub()]));
      await tester.pumpAndSettle();

      // The sheet's discovery row lives only inside the management sheet;
      // the calendar body carries the separate dismissible inline strip.
      expect(find.byKey(_kSheetPromo), findsNothing);
      expect(find.text('Calee for your home'), findsNothing);
      expect(find.byKey(_kInlinePromo), findsOneWidget);
    });
  });

  group('LocalSubscriberCalendarPage — events in calendar', () {
    testWidgets('fetched events are displayed in month grid', (tester) async {
      final now = DateTime.now();
      final eventToday = LocalCalendarEvent(
        id: 'today-evt',
        subscriptionId: 'sub1',
        subscriptionTitle: 'Test Calendar',
        title: 'Today Event',
        start: DateTime(now.year, now.month, now.day, 9),
        end: DateTime(now.year, now.month, now.day, 10),
        isAllDay: false,
        sourceUrl: 'https://example.com/cal.ics',
      );
      await tester.pumpWidget(
        _buildPage(
          subscriptions: [_sub()],
          icsService: _StubIcsService([eventToday]),
        ),
      );
      await tester.pumpAndSettle();

      // The event title should appear in the day agenda panel beneath the grid
      expect(find.text('Today Event'), findsOneWidget);
    });
  });

  // ── Event details + signed-out sharing (CaleeAdmin/CaleeMobile#558) ────────

  group('LocalSubscriberCalendarPage — event details', () {
    testWidgets('tapping an event row opens the details sheet', (tester) async {
      await tester.pumpWidget(
        _buildPage(
          subscriptions: [_publicSub()],
          icsService: _StubIcsService([_publicOneOffEvent()]),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.byKey(kLocalEventDetailsSheetKey), findsNothing);

      await tester.tap(find.text('Public One Off'));
      await tester.pumpAndSettle();

      expect(find.byKey(kLocalEventDetailsSheetKey), findsOneWidget);
    });

    testWidgets('shows title, date, time and calendar name', (tester) async {
      await tester.pumpWidget(
        _buildPage(
          subscriptions: [_publicSub()],
          icsService: _StubIcsService([_publicOneOffEvent()]),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Public One Off'));
      await tester.pumpAndSettle();

      final sheet = find.byKey(kLocalEventDetailsSheetKey);
      expect(
        find.descendant(of: sheet, matching: find.text('Public One Off')),
        findsOneWidget,
      );
      expect(
        find.descendant(of: sheet, matching: find.text(_todayDateLabel())),
        findsOneWidget,
      );
      expect(
        find.descendant(of: sheet, matching: find.text('10 AM–11 AM')),
        findsOneWidget,
      );
      expect(
        find.descendant(of: sheet, matching: find.text('Public Calendar')),
        findsOneWidget,
      );
    });

    testWidgets('renders 24-hour times when the device asks for them', (
      tester,
    ) async {
      await tester.pumpWidget(
        _buildPage(
          subscriptions: [_publicSub()],
          icsService: _StubIcsService([_publicOneOffEvent()]),
          use24h: true,
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Public One Off'));
      await tester.pumpAndSettle();

      // The row behind the sheet shows the same label, so scope the check.
      expect(
        find.descendant(
          of: find.byKey(kLocalEventDetailsSheetKey),
          matching: find.text('10:00–11:00'),
        ),
        findsOneWidget,
      );
    });

    testWidgets('an all-day event shows "All day" instead of a time', (
      tester,
    ) async {
      await tester.pumpWidget(
        _buildPage(
          subscriptions: [_publicSub()],
          icsService: _StubIcsService([_publicAllDayRecurringEvent()]),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Public All Day'));
      await tester.pumpAndSettle();

      expect(
        find.descendant(
          of: find.byKey(kLocalEventDetailsSheetKey),
          matching: find.text('All day'),
        ),
        findsOneWidget,
      );
    });

    testWidgets('never shows Edit, Delete, the UID, or the source URL', (
      tester,
    ) async {
      await tester.pumpWidget(
        _buildPage(
          subscriptions: [_publicSub()],
          icsService: _StubIcsService([_publicOneOffEvent()]),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Public One Off'));
      await tester.pumpAndSettle();

      expect(find.text('Edit'), findsNothing);
      expect(find.text('Edit event'), findsNothing);
      expect(find.text('Delete'), findsNothing);
      expect(find.text('Delete event'), findsNothing);
      for (final secret in [
        _kOneOffUid,
        _kPublicToken,
        _kPublicCalendarUrl,
        'remote.php',
        'public-calendars',
        'portal.calee.com.au',
      ]) {
        expect(
          find.textContaining(secret),
          findsNothing,
          reason: 'details must never expose "$secret"',
        );
      }
    });

    testWidgets('the sign-in action is untouched by opening details', (
      tester,
    ) async {
      var signInTaps = 0;
      var subscriptionsChanged = 0;
      await tester.pumpWidget(
        _buildPage(
          subscriptions: [_publicSub()],
          icsService: _StubIcsService([_publicOneOffEvent()]),
          onSignIn: () => signInTaps++,
          onSubscriptionsChanged: (_) => subscriptionsChanged++,
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Public One Off'));
      await tester.pumpAndSettle();

      expect(signInTaps, 0);
      expect(subscriptionsChanged, 0);
      expect(find.byKey(_kSignInButton), findsOneWidget);
    });

    testWidgets(
      'an unsupported external subscription opens details with no Share',
      (tester) async {
        final mint = _FakeEventLinkService();
        await tester.pumpWidget(
          _buildPage(
            // Ordinary external HTTPS .ics — exactly what V1 does not share.
            subscriptions: [_sub()],
            icsService: _StubIcsService([_event(title: 'External Event')]),
            eventLinkService: mint,
          ),
        );
        await tester.pumpAndSettle();
        await tester.tap(find.text('External Event'));
        await tester.pumpAndSettle();

        expect(find.byKey(kLocalEventDetailsSheetKey), findsOneWidget);
        expect(find.byKey(kLocalEventShareButtonKey), findsNothing);
        expect(find.text('Share event'), findsNothing);
        // Not even the "this event" wording: sharing is not offered for this
        // KIND of calendar, so the sheet says nothing about it at all.
        expect(find.byKey(kLocalEventShareUnavailableKey), findsNothing);
        expect(mint.calls, isEmpty);
      },
    );

    testWidgets('a Google Calendar feed never offers Share', (tester) async {
      final mint = _FakeEventLinkService();
      await tester.pumpWidget(
        _buildPage(
          subscriptions: [
            _sub(
              url:
                  'https://calendar.google.com/calendar/ical/x/public/basic.ics',
            ),
          ],
          icsService: _StubIcsService([
            // A perfectly canonical identity on a source that is not ours.
            _publicOneOffEvent(title: 'Google Event'),
          ]),
          eventLinkService: mint,
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Google Event'));
      await tester.pumpAndSettle();

      expect(find.byKey(kLocalEventDetailsSheetKey), findsOneWidget);
      expect(find.byKey(kLocalEventShareButtonKey), findsNothing);
      expect(mint.calls, isEmpty);
    });
  });

  group('LocalSubscriberCalendarPage — share event', () {
    testWidgets('a public one-off mints from calendar + UID only', (
      tester,
    ) async {
      final mint = _FakeEventLinkService();
      final launcher = _FakeShareLauncher();

      await tester.pumpWidget(
        _buildPage(
          subscriptions: [_publicSub()],
          icsService: _StubIcsService([_publicOneOffEvent()]),
          eventLinkService: mint,
          shareLauncher: launcher,
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Public One Off'));
      await tester.pumpAndSettle();

      expect(find.byKey(kLocalEventShareButtonKey), findsOneWidget);

      await tester.tap(find.byKey(kLocalEventShareButtonKey));
      await tester.pumpAndSettle();

      expect(mint.calls, hasLength(1));
      expect(mint.calls.single.calendarUrl, _kPublicCalendarUrl);
      expect(mint.calls.single.uid, _kOneOffUid);
      expect(mint.calls.single.occurrenceId, isNull);

      expect(launcher.calls, hasLength(1));
      // Byte-identical to what the mint endpoint returned.
      expect(launcher.calls.single.url.toString(), _kMintedLink);
      expect(launcher.calls.single.title, 'Public One Off');
    });

    testWidgets('an all-day recurrence sends the canonical Ymd identity', (
      tester,
    ) async {
      final mint = _FakeEventLinkService();
      final launcher = _FakeShareLauncher();

      await tester.pumpWidget(
        _buildPage(
          subscriptions: [_publicSub()],
          icsService: _StubIcsService([_publicAllDayRecurringEvent()]),
          eventLinkService: mint,
          shareLauncher: launcher,
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Public All Day'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(kLocalEventShareButtonKey));
      await tester.pumpAndSettle();

      expect(mint.calls.single.uid, _kSeriesUid);
      expect(mint.calls.single.occurrenceId, '20260818');
      expect(launcher.calls, hasLength(1));
    });

    testWidgets(
      'a timed recurrence sends the CANONICAL identity, not the display one',
      (tester) async {
        final mint = _FakeEventLinkService();

        await tester.pumpWidget(
          _buildPage(
            subscriptions: [_publicSub()],
            icsService: _StubIcsService([_publicTimedRecurringEvent()]),
            eventLinkService: mint,
            shareLauncher: _FakeShareLauncher(),
          ),
        );
        await tester.pumpAndSettle();
        await tester.tap(find.text('Public Timed Series'));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(kLocalEventShareButtonKey));
        await tester.pumpAndSettle();

        expect(mint.calls.single.occurrenceId, '20260818T073000Z');
        // The display recurrence id is a local best effort and must never be
        // substituted for the canonical one.
        expect(mint.calls.single.occurrenceId, isNot(_kDisplayRecurrenceId));
      },
    );

    testWidgets(
      'a detached moved occurrence keeps its ORIGINAL recurrence identity',
      (tester) async {
        final mint = _FakeEventLinkService();
        final moved = _publicDetachedMovedEvent();

        await tester.pumpWidget(
          _buildPage(
            subscriptions: [_publicSub()],
            icsService: _StubIcsService([moved]),
            eventLinkService: mint,
            shareLauncher: _FakeShareLauncher(),
          ),
        );
        await tester.pumpAndSettle();

        // Visible at its MOVED start...
        await tester.tap(find.text('Public Moved Occurrence'));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(kLocalEventShareButtonKey));
        await tester.pumpAndSettle();

        // ...and still named by where it originally was.
        expect(mint.calls.single.occurrenceId, _kOriginalRecurrenceId);
        expect(mint.calls.single.uid, _kSeriesUid);
      },
    );

    testWidgets('the UID "0" is shareable and sent exactly', (tester) async {
      final mint = _FakeEventLinkService();

      await tester.pumpWidget(
        _buildPage(
          subscriptions: [_publicSub()],
          icsService: _StubIcsService([
            _publicOneOffEvent(title: 'Zero Uid Event', uid: '0'),
          ]),
          eventLinkService: mint,
          shareLauncher: _FakeShareLauncher(),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Zero Uid Event'));
      await tester.pumpAndSettle();

      expect(find.byKey(kLocalEventShareButtonKey), findsOneWidget);
      await tester.tap(find.byKey(kLocalEventShareButtonKey));
      await tester.pumpAndSettle();

      expect(mint.calls.single.uid, '0');
    });

    testWidgets('boundary whitespace in a UID is preserved exactly', (
      tester,
    ) async {
      final mint = _FakeEventLinkService();

      await tester.pumpWidget(
        _buildPage(
          subscriptions: [_publicSub()],
          icsService: _StubIcsService([
            _publicOneOffEvent(
              title: 'Padded Uid Event',
              uid: '  padded-uid  ',
            ),
          ]),
          eventLinkService: mint,
          shareLauncher: _FakeShareLauncher(),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Padded Uid Event'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(kLocalEventShareButtonKey));
      await tester.pumpAndSettle();

      expect(mint.calls.single.uid, '  padded-uid  ');
    });

    testWidgets(
      'a recurring occurrence with no canonical identity is not shareable',
      (tester) async {
        final mint = _FakeEventLinkService();

        await tester.pumpWidget(
          _buildPage(
            subscriptions: [_publicSub()],
            icsService: _StubIcsService([_publicUnmintableRecurringEvent()]),
            eventLinkService: mint,
            shareLauncher: _FakeShareLauncher(),
          ),
        );
        await tester.pumpAndSettle();
        await tester.tap(find.text('Public Floating Series'));
        await tester.pumpAndSettle();

        // Details still open, and no invented link.
        expect(find.byKey(kLocalEventDetailsSheetKey), findsOneWidget);
        expect(find.byKey(kLocalEventShareButtonKey), findsNothing);
        expect(find.byKey(kLocalEventShareUnavailableKey), findsOneWidget);
        expect(mint.calls, isEmpty);
      },
    );

    testWidgets('a one-off whose DTSTART is unplaceable is STILL shareable', (
      tester,
    ) async {
      // Regression guard for the CaleeAdmin/CaleeMobile#561 correction: a
      // one-off's identity is calendar + exact UID, so an unresolvable
      // DTSTART timezone does not make it unshareable.
      final mint = _FakeEventLinkService();

      await tester.pumpWidget(
        _buildPage(
          subscriptions: [_publicSub()],
          icsService: _StubIcsService([
            _publicOneOffEvent(
              title: 'Unplaceable One Off',
              uid: 'unplaceable-one-off-uid',
              canonicalStatus: CanonicalSourceStatus.unsupportedTzid,
            ),
          ]),
          eventLinkService: mint,
          shareLauncher: _FakeShareLauncher(),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Unplaceable One Off'));
      await tester.pumpAndSettle();

      expect(find.byKey(kLocalEventShareButtonKey), findsOneWidget);
      await tester.tap(find.byKey(kLocalEventShareButtonKey));
      await tester.pumpAndSettle();

      expect(mint.calls.single.uid, 'unplaceable-one-off-uid');
      expect(mint.calls.single.occurrenceId, isNull);
    });

    testWidgets('each row mints its OWN source UID, never a neighbour\'s', (
      tester,
    ) async {
      // The two rows carry source UIDs that differ only in boundary
      // whitespace — precisely the pair the non-normative local UI id is
      // known to be able to collapse together. The tap seam maps a row back
      // to its source by OBJECT IDENTITY rather than by that id, so each row
      // still mints its own event.
      final mint = _FakeEventLinkService();

      await tester.pumpWidget(
        _buildPage(
          subscriptions: [_publicSub()],
          icsService: _StubIcsService([
            _publicOneOffEvent(
              id: 'row-a',
              title: 'Row A',
              uid: ' shared-uid ',
              startHour: 9,
            ),
            _publicOneOffEvent(
              id: 'row-b',
              title: 'Row B',
              uid: 'shared-uid',
              startHour: 11,
            ),
          ]),
          eventLinkService: mint,
          shareLauncher: _FakeShareLauncher(),
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.text('Row A'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(kLocalEventShareButtonKey));
      await tester.pumpAndSettle();
      // Dismiss the sheet before opening the other row's.
      await tester.tapAt(const Offset(400, 20));
      await tester.pumpAndSettle();

      await tester.tap(find.text('Row B'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(kLocalEventShareButtonKey));
      await tester.pumpAndSettle();

      expect(mint.calls, hasLength(2));
      expect(mint.calls[0].uid, ' shared-uid ');
      expect(mint.calls[1].uid, 'shared-uid');
    });

    testWidgets('sharing never signs in or touches local subscriptions', (
      tester,
    ) async {
      var signInTaps = 0;
      var subscriptionsChanged = 0;
      final launcher = _FakeShareLauncher();

      await tester.pumpWidget(
        _buildPage(
          subscriptions: [_publicSub()],
          icsService: _StubIcsService([_publicOneOffEvent()]),
          eventLinkService: _FakeEventLinkService(),
          shareLauncher: launcher,
          onSignIn: () => signInTaps++,
          onSubscriptionsChanged: (_) => subscriptionsChanged++,
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Public One Off'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(kLocalEventShareButtonKey));
      await tester.pumpAndSettle();

      expect(launcher.calls, hasLength(1));
      expect(signInTaps, 0);
      expect(subscriptionsChanged, 0);
      // The followed calendar is still exactly as local as it was.
      final stored = await LocalCalendarSubscriptionRepository().list();
      expect(stored, isEmpty);
    });

    testWidgets('anchors the iPad share popover to the tapped button', (
      tester,
    ) async {
      final launcher = _FakeShareLauncher();

      await tester.pumpWidget(
        _buildPage(
          subscriptions: [_publicSub()],
          icsService: _StubIcsService([_publicOneOffEvent()]),
          eventLinkService: _FakeEventLinkService(),
          shareLauncher: launcher,
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Public One Off'));
      await tester.pumpAndSettle();

      final anchorRect = tester.getRect(find.byKey(kLocalEventShareAnchorKey));
      await tester.tap(find.byKey(kLocalEventShareButtonKey));
      await tester.pumpAndSettle();

      final origin = launcher.calls.single.origin;
      expect(origin, anchorRect);
      // Not the centre-of-screen fallback.
      final screen = tester.view.physicalSize / tester.view.devicePixelRatio;
      expect(
        origin,
        isNot(
          Rect.fromCenter(
            center: Offset(screen.width / 2, screen.height / 2),
            width: 1,
            height: 1,
          ),
        ),
      );
      // UIKit rejects a degenerate or off-screen popover anchor outright.
      expect(origin.width, greaterThan(0));
      expect(origin.height, greaterThan(0));
      expect(origin.isFinite, isTrue);
    });
  });

  group('LocalSubscriberCalendarPage — share failures', () {
    Future<void> openShareableEvent(
      WidgetTester tester, {
      required LocalEventLinkService mint,
      required LocalEventShareLauncher launcher,
    }) async {
      await tester.pumpWidget(
        _buildPage(
          subscriptions: [_publicSub()],
          icsService: _StubIcsService([_publicOneOffEvent()]),
          eventLinkService: mint,
          shareLauncher: launcher,
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Public One Off'));
      await tester.pumpAndSettle();
    }

    testWidgets('a mint failure shows a friendly message and never shares', (
      tester,
    ) async {
      final mint = _FakeEventLinkService()
        ..error = const LocalEventLinkException();
      final launcher = _FakeShareLauncher();

      await openShareableEvent(tester, mint: mint, launcher: launcher);
      await tester.tap(find.byKey(kLocalEventShareButtonKey));
      await tester.pumpAndSettle();

      expect(find.byKey(kLocalEventShareErrorKey), findsOneWidget);
      expect(find.text(kLocalEventShareFailureMessage), findsOneWidget);
      expect(launcher.calls, isEmpty);
      // The sheet stays open and the button is usable again.
      expect(find.byKey(kLocalEventDetailsSheetKey), findsOneWidget);
      expect(
        tester
            .widget<FilledButton>(find.byKey(kLocalEventShareButtonKey))
            .onPressed,
        isNotNull,
      );
    });

    testWidgets('the failure message leaks no status, code, or URI', (
      tester,
    ) async {
      final mint = _FakeEventLinkService()
        ..error = Exception('503 invalid_source https://portal.calee.com.au');
      await openShareableEvent(
        tester,
        mint: mint,
        launcher: _FakeShareLauncher(),
      );
      await tester.tap(find.byKey(kLocalEventShareButtonKey));
      await tester.pumpAndSettle();

      expect(find.text(kLocalEventShareFailureMessage), findsOneWidget);
      for (final leak in [
        '503',
        'invalid_source',
        'unavailable',
        'portal.calee.com.au',
        _kPublicToken,
        _kOneOffUid,
      ]) {
        expect(
          find.textContaining(leak),
          findsNothing,
          reason: 'failure UI must not leak "$leak"',
        );
      }
    });

    testWidgets('a retry after a failure mints again', (tester) async {
      final mint = _FakeEventLinkService()
        ..error = const LocalEventLinkException();
      final launcher = _FakeShareLauncher();

      await openShareableEvent(tester, mint: mint, launcher: launcher);
      await tester.tap(find.byKey(kLocalEventShareButtonKey));
      await tester.pumpAndSettle();
      expect(find.byKey(kLocalEventShareErrorKey), findsOneWidget);

      mint.error = null;
      await tester.tap(find.byKey(kLocalEventShareButtonKey));
      await tester.pumpAndSettle();

      expect(mint.calls, hasLength(2));
      expect(launcher.calls, hasLength(1));
      expect(find.byKey(kLocalEventShareErrorKey), findsNothing);
    });

    testWidgets('a throwing share launcher is reported, not crashed', (
      tester,
    ) async {
      final launcher = _FakeShareLauncher()
        ..error = Exception('no share sheet');

      await openShareableEvent(
        tester,
        mint: _FakeEventLinkService(),
        launcher: launcher,
      );
      await tester.tap(find.byKey(kLocalEventShareButtonKey));
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
      expect(find.text(kLocalEventShareFailureMessage), findsOneWidget);
      expect(find.byKey(kLocalEventDetailsSheetKey), findsOneWidget);
    });

    testWidgets('a dismissed share sheet is not an error', (tester) async {
      // The production launcher returns normally when the user cancels, so a
      // cancellation reaches the page as an ordinary completion.
      final launcher = _FakeShareLauncher();
      await openShareableEvent(
        tester,
        mint: _FakeEventLinkService(),
        launcher: launcher,
      );
      await tester.tap(find.byKey(kLocalEventShareButtonKey));
      await tester.pumpAndSettle();

      expect(find.byKey(kLocalEventShareErrorKey), findsNothing);
      expect(find.textContaining('failed'), findsNothing);
      expect(find.textContaining('Failed'), findsNothing);
    });

    testWidgets('a rapid double tap mints once and shares once', (
      tester,
    ) async {
      final gate = Completer<void>();
      final mint = _FakeEventLinkService()..gate = gate;
      final launcher = _FakeShareLauncher();

      await openShareableEvent(tester, mint: mint, launcher: launcher);

      // Both taps land before any frame can rebuild the button as disabled.
      await tester.tap(find.byKey(kLocalEventShareButtonKey));
      await tester.tap(find.byKey(kLocalEventShareButtonKey));
      await tester.pump();

      // The in-flight state is visible while the request is outstanding.
      expect(find.byKey(kLocalEventShareSpinnerKey), findsOneWidget);
      expect(
        tester
            .widget<FilledButton>(find.byKey(kLocalEventShareButtonKey))
            .onPressed,
        isNull,
      );

      gate.complete();
      await tester.pumpAndSettle();

      expect(mint.calls, hasLength(1));
      expect(launcher.calls, hasLength(1));
    });

    testWidgets(
      'closing the sheet mid-mint shares nothing and does not crash',
      (tester) async {
        final gate = Completer<void>();
        final mint = _FakeEventLinkService()..gate = gate;
        final launcher = _FakeShareLauncher();

        await openShareableEvent(tester, mint: mint, launcher: launcher);
        await tester.tap(find.byKey(kLocalEventShareButtonKey));
        await tester.pump();

        // Dismiss the sheet by tapping the modal barrier above it.
        await tester.tapAt(const Offset(400, 20));
        await tester.pumpAndSettle();
        expect(find.byKey(kLocalEventDetailsSheetKey), findsNothing);

        gate.complete();
        await tester.pumpAndSettle();

        expect(mint.calls, hasLength(1));
        expect(launcher.calls, isEmpty);
        expect(tester.takeException(), isNull);
        // No stale snackbar over whatever page is showing now.
        expect(find.text(kLocalEventShareFailureMessage), findsNothing);
      },
    );
  });
}

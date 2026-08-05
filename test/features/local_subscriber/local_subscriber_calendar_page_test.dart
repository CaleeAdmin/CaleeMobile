import 'dart:async';

import 'package:calee_mobile/features/calendar/shared/read_only_calendar_view.dart';
import 'package:calee_mobile/features/local_subscriber/local_calendar_event.dart';
import 'package:calee_mobile/features/local_subscriber/local_calendar_ics_service.dart';
import 'package:calee_mobile/features/local_subscriber/local_calendar_subscription.dart';
import 'package:calee_mobile/features/local_subscriber/local_calendar_subscription_repository.dart';
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
}) => LocalCalendarSubscription(
  id: id,
  title: title,
  url: 'https://example.com/cal.ics',
  source: 'example.com',
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
}) {
  return MaterialApp(
    theme: CaleeTheme.buildThemeData(),
    home: LocalSubscriberCalendarPage(
      subscriptions: subscriptions,
      repository: LocalCalendarSubscriptionRepository(),
      onSignIn: onSignIn ?? () {},
      onLearnAboutHome: onLearnAboutHome ?? () {},
      onSubscriptionsChanged: onSubscriptionsChanged ?? (_) {},
      icsService: icsService ?? _StubIcsService(const []),
      promotionPreferences: promotionPreferences,
    ),
  );
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
}

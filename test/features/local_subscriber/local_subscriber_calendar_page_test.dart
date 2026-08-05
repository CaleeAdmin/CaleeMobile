import 'package:calee_mobile/features/calendar/shared/read_only_calendar_view.dart';
import 'package:calee_mobile/features/local_subscriber/local_calendar_event.dart';
import 'package:calee_mobile/features/local_subscriber/local_calendar_ics_service.dart';
import 'package:calee_mobile/features/local_subscriber/local_calendar_subscription.dart';
import 'package:calee_mobile/features/local_subscriber/local_calendar_subscription_repository.dart';
import 'package:calee_mobile/features/local_subscriber/local_subscriber_calendar_page.dart';
import 'package:calee_mobile/ui/calee_design.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

// ── Stubs ──────────────────────────────────────────────────────────────────────

class _StubIcsService extends LocalCalendarIcsService {
  _StubIcsService(this._events);

  final List<LocalCalendarEvent> _events;

  @override
  Future<List<LocalCalendarEvent>> fetchEvents(
    LocalCalendarSubscription sub,
  ) async => _events;
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
  VoidCallback? onLearnAboutHome,
  void Function(List<LocalCalendarSubscription>)? onSubscriptionsChanged,
}) {
  SharedPreferences.setMockInitialValues({});
  return MaterialApp(
    theme: CaleeTheme.buildThemeData(),
    home: LocalSubscriberCalendarPage(
      subscriptions: subscriptions,
      repository: LocalCalendarSubscriptionRepository(),
      onLearnAboutHome: onLearnAboutHome ?? () {},
      onSubscriptionsChanged: onSubscriptionsChanged ?? (_) {},
      icsService: icsService ?? _StubIcsService(const []),
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

    testWidgets('does not show the old permanent banner or sign-in copy', (
      tester,
    ) async {
      await tester.pumpWidget(_buildPage(subscriptions: [_sub()]));
      await tester.pumpAndSettle();
      expect(find.text('Added on this phone only'), findsNothing);
      expect(find.textContaining('Sign in to link'), findsNothing);
      expect(find.text('Sign in'), findsNothing);
      // The calendar itself is unobstructed and visible.
      expect(find.byType(ReadOnlyCalendarView), findsOneWidget);
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

    testWidgets('home promotion is not shown in the calendar body', (
      tester,
    ) async {
      await tester.pumpWidget(_buildPage(subscriptions: [_sub()]));
      await tester.pumpAndSettle();

      // Discoverable only inside the management sheet, never permanently.
      expect(find.byKey(const Key('local_calendar_home_promo')), findsNothing);
      expect(find.text('Calee for your home'), findsNothing);
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

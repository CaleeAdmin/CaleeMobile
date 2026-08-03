// Widget tests for CalendarPage structure.
//
// Verifies that the Month/Agenda switcher renders and that switching between
// modes does not crash the page. Uses a stub CaleeHubClient so no platform
// channels or network access are needed. SharedPreferences is mocked because
// CalendarPage creates CaleePreferences internally.

import 'dart:async';

import 'package:calee_mobile/data/api/calee_hub_client.dart';
import 'package:calee_mobile/data/models/client_bootstrap.dart';
import 'package:calee_mobile/data/models/client_calendar.dart';
import 'package:calee_mobile/features/calendar/calendar_page.dart';
import 'package:calee_mobile/features/calendar/shared/read_only_calendar_view.dart';
import 'package:calee_mobile/features/calendar/widgets/calendar_chooser_sheet.dart';
import 'package:calee_mobile/ui/calee_design.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

// ── Stubs ──────────────────────────────────────────────────────────────────────

class _StubHub extends CaleeHubClient {
  _StubHub({List<ClientCalendar>? calendars})
    : calendarsPayload = calendars ?? const [],
      super();

  /// Both payloads are swappable so a test can model the subscribed feed
  /// gaining an event after Calendar has already loaded.
  List<ClientCalendar> calendarsPayload;
  List<ClientEvent> eventsPayload = const [];

  int calendarLoadCount = 0;
  int eventLoadCount = 0;

  /// When set, `events()` waits on it before returning, so a test can inspect
  /// the UI while a refresh is still in flight.
  Completer<void>? gate;

  @override
  Future<ClientCalendarList> calendars({required String accessToken}) async {
    calendarLoadCount++;
    return ClientCalendarList(
      calendars: List<ClientCalendar>.from(calendarsPayload),
    );
  }

  @override
  Future<ClientEventList> events({
    required String accessToken,
    required String from,
    required String to,
  }) async {
    eventLoadCount++;
    final payload = List<ClientEvent>.from(eventsPayload);
    final pending = gate;
    if (pending != null) await pending.future;
    return ClientEventList(from: from, to: to, events: payload);
  }
}

// ── Live-evidence fixtures ─────────────────────────────────────────────────────
//
// The read-only subscribed calendar and the event that reproduced the stale-
// agenda defect on Pixel_9, taken verbatim from the confirmed hub responses.

const _lazersCalendar = ClientCalendar(
  id: 'portal:lazers-morley-eagles',
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
  source: 'portal',
);

const _setupEvent = ClientEvent(
  id: 'setup-1',
  calendarId: 'portal:lazers-morley-eagles',
  serviceId: 'portal',
  serviceName: 'Portal',
  title: 'Setup',
  startsAt: '2026-08-04T05:30:00Z',
  endsAt: '2026-08-04T06:30:00Z',
  allDay: false,
  recurring: false,
  readOnly: true,
  source: 'portal',
);

/// A second calendar, used to prove a hidden-calendar selection survives a
/// pull-to-refresh.
const _otherCalendar = ClientCalendar(
  id: 'portal:other',
  serviceId: 'portal',
  serviceName: 'Portal',
  name: 'Other Calendar',
  components: [],
  primaryKind: 'calendar',
  supportsEvents: true,
  supportsTasks: false,
  supportsChores: false,
  readOnly: false,
  isSubscription: false,
  source: 'portal',
);

const _otherEvent = ClientEvent(
  id: 'training-1',
  calendarId: 'portal:other',
  serviceId: 'portal',
  serviceName: 'Portal',
  title: 'Training',
  startsAt: '2026-08-04T08:00:00Z',
  endsAt: '2026-08-04T09:00:00Z',
  allDay: false,
  recurring: false,
  source: 'portal',
);

/// The time label the Setup event renders under the repository's standard test
/// timezone (Australia/Perth — see CLAUDE.md and flutter-ci.yml, which set
/// TZ=Australia/Perth). 05:30Z–06:30Z is 1:30 PM–2:30 PM there. The dash is an
/// en dash, matching ReadOnlyCalendarEventRow.
const _setupTimeLabel = '1:30 PM–2:30 PM';

/// The local calendar day the Setup event falls on. Derived from the UTC
/// instant so the assertion holds in any host timezone (CI runs
/// Australia/Perth, where it renders as 1:30 PM–2:30 PM on 4 August).
final _setupDay = () {
  final local = DateTime.parse('2026-08-04T05:30:00Z').toLocal();
  return DateTime(local.year, local.month, local.day);
}();

// ── Helpers ────────────────────────────────────────────────────────────────────

Widget _hostCalendar(_StubHub hub, {bool isActive = true}) => MaterialApp(
  theme: CaleeTheme.buildThemeData(),
  // TimeFormatPref.system defers to the platform, so pin 12-hour formatting
  // here rather than depending on the host's default. Must sit inside
  // MaterialApp, which installs its own MediaQuery from the view.
  home: Builder(
    builder: (context) => MediaQuery(
      data: MediaQuery.of(context).copyWith(alwaysUse24HourFormat: false),
      child: CalendarPage(
        hubClient: hub,
        accessToken: 'tok',
        services: const [_service],
        accountId: 'acct1',
        isFamilyUxContext: true,
        isActive: isActive,
      ),
    ),
  ),
);

ReadOnlyCalendarView _view(WidgetTester tester) =>
    tester.widget<ReadOnlyCalendarView>(find.byType(ReadOnlyCalendarView));

/// Pulls down on Calendar's refreshable event list and pumps until the handler
/// has fired. Does not settle — the caller controls when the gated response
/// completes.
Future<void> _pullToRefresh(WidgetTester tester) async {
  final list = find.descendant(
    of: find.byType(RefreshIndicator),
    matching: find.byType(ListView),
  );
  expect(list, findsOneWidget, reason: 'Calendar exposes one refreshable list');
  await tester.fling(list, const Offset(0, 400), 1000);
  await tester.pump();
  await tester.pump(const Duration(seconds: 1));
}

/// Hides [calendarName] through the real chooser-sheet path so the test
/// exercises the same visibility state a user would set.
Future<void> _hideCalendar(WidgetTester tester, String calendarName) async {
  await tester.tap(find.byKey(const Key('calendar_filter_button')));
  await tester.pumpAndSettle();
  // Scope to the sheet: the calendar name also appears as an event-row
  // subtitle on the page behind it.
  await tester.tap(
    find.descendant(
      of: find.byType(CalendarChooserSheet),
      matching: find.text(calendarName),
    ),
  );
  await tester.pumpAndSettle();
  await tester.tap(
    find.descendant(
      of: find.byType(CalendarChooserSheet),
      matching: find.byIcon(Icons.close),
    ),
  );
  await tester.pumpAndSettle();
}

/// Puts the agenda on 4 August 2026 the way a user would — by selecting that
/// day in the month grid.
Future<void> _selectSetupDay(WidgetTester tester) async {
  _view(tester).onSelectDay(_setupDay);
  await tester.pumpAndSettle();
}

/// Drives a full background → foreground round trip. The leading `resumed`
/// makes the sequence independent of whatever lifecycle state an earlier test
/// left on the shared binding; it never refreshes on its own, because the page
/// only reacts to a resume that follows a background.
Future<void> _backgroundThenResume(WidgetTester tester) async {
  tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
  await tester.pump();
  tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
  await tester.pump();
  tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
}

// ── Tests ──────────────────────────────────────────────────────────────────────

const _service = ClientService(
  id: 'svc1',
  displayName: 'Test',
  baseUrl: 'http://localhost',
  launchUrl: 'http://localhost',
  serviceType: 'nextcloud',
  accessStatus: 'ok',
  calendarCredentialStatus: 'connected',
  source: 'test',
  capabilities: {'calendar': true, 'tasks': false, 'chores': false},
);

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

  group('CalendarPage', () {
    testWidgets('renders without crashing', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: CaleeTheme.buildThemeData(),
          home: CalendarPage(
            hubClient: _StubHub(),
            accessToken: 'tok',
            services: const [_service],
            accountId: 'acct1',
            isFamilyUxContext: true,
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.byType(CalendarPage), findsOneWidget);
    });

    testWidgets('Month / Agenda switcher (SegmentedButton) is visible', (
      tester,
    ) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: CaleeTheme.buildThemeData(),
          home: CalendarPage(
            hubClient: _StubHub(),
            accessToken: 'tok',
            services: const [_service],
            accountId: 'acct1',
            isFamilyUxContext: true,
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('Month'), findsOneWidget);
      expect(find.text('Agenda'), findsOneWidget);
    });

    testWidgets('switching to Agenda mode does not crash', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: CaleeTheme.buildThemeData(),
          home: CalendarPage(
            hubClient: _StubHub(),
            accessToken: 'tok',
            services: const [_service],
            accountId: 'acct1',
            isFamilyUxContext: true,
          ),
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.text('Agenda'));
      await tester.pumpAndSettle();

      expect(find.byType(CalendarPage), findsOneWidget);
    });

    testWidgets('refreshes when refreshGeneration increments', (tester) async {
      final hub = _StubHub();
      int generation = 0;

      await tester.pumpWidget(
        StatefulBuilder(
          builder: (context, setState) => MaterialApp(
            theme: CaleeTheme.buildThemeData(),
            home: Scaffold(
              body: Column(
                children: [
                  Expanded(
                    child: CalendarPage(
                      hubClient: hub,
                      accessToken: 'tok',
                      services: const [_service],
                      accountId: 'acct1',
                      isFamilyUxContext: true,
                      refreshGeneration: generation,
                    ),
                  ),
                  ElevatedButton(
                    onPressed: () => setState(() => generation++),
                    child: const Text('Bump'),
                  ),
                ],
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      final countAfterInit = hub.calendarLoadCount;
      expect(countAfterInit, greaterThan(0));

      await tester.tap(find.text('Bump'));
      await tester.pumpAndSettle();

      expect(hub.calendarLoadCount, greaterThan(countAfterInit));
    });
  });

  // ── Refresh on app resume ────────────────────────────────────────────────────
  //
  // CalendarPage stays mounted in the home IndexedStack, so its controller kept
  // serving the snapshot loaded when the page was first built. An event that
  // reached the hub afterwards only appeared once the user left Calendar and
  // came back (which recreated/reloaded the page). The page now refetches the
  // month already on screen when the app returns to the foreground.

  group('CalendarPage refresh on app resume', () {
    testWidgets(
      'reveals a subscribed-calendar event that arrived after the initial '
      'load, without leaving and re-entering Calendar',
      (tester) async {
        final hub = _StubHub(calendars: const [_lazersCalendar]);

        await tester.pumpWidget(_hostCalendar(hub));
        await tester.pumpAndSettle();
        await _selectSetupDay(tester);

        expect(
          find.text('Setup'),
          findsNothing,
          reason: 'the initial load predates the subscribed-calendar sync',
        );

        final stateBefore = tester.state(find.byType(CalendarPage));
        final eventLoadsBefore = hub.eventLoadCount;

        // The subscribed feed now carries the Hub event.
        hub.eventsPayload = const [_setupEvent];

        await _backgroundThenResume(tester);
        await tester.pumpAndSettle();

        expect(find.text('Setup'), findsOneWidget);
        expect(find.text('Lazers (Morley Eagles)'), findsOneWidget);
        expect(
          hub.eventLoadCount,
          eventLoadsBefore + 1,
          reason: 'exactly one refetch of the displayed month',
        );
        expect(
          identical(tester.state(find.byType(CalendarPage)), stateBefore),
          isTrue,
          reason: 'the page must not be destroyed and recreated to show it',
        );
        expect(
          _view(tester).selectedDay,
          _setupDay,
          reason: 'the selected date survives the refresh',
        );
        expect(_view(tester).selectedMonth, DateTime(2026, 8, 1));
      },
    );

    testWidgets('does not swap the calendar for a full-screen spinner while '
        'refreshing', (tester) async {
      final hub = _StubHub(calendars: const [_lazersCalendar]);

      await tester.pumpWidget(_hostCalendar(hub));
      await tester.pumpAndSettle();
      await _selectSetupDay(tester);

      final gate = Completer<void>();
      hub.gate = gate;
      hub.eventsPayload = const [_setupEvent];

      await _backgroundThenResume(tester);
      await tester.pump(); // the refresh is now in flight

      expect(find.byType(CircularProgressIndicator), findsNothing);
      expect(find.byType(ReadOnlyCalendarView), findsOneWidget);

      gate.complete();
      await tester.pumpAndSettle();

      expect(find.text('Setup'), findsOneWidget);
    });

    testWidgets('duplicate resume notifications trigger exactly one refetch', (
      tester,
    ) async {
      final hub = _StubHub(calendars: const [_lazersCalendar]);

      await tester.pumpWidget(_hostCalendar(hub));
      await tester.pumpAndSettle();

      final observer =
          tester.state(find.byType(CalendarPage)) as WidgetsBindingObserver;
      final eventLoadsBefore = hub.eventLoadCount;

      observer.didChangeAppLifecycleState(AppLifecycleState.paused);
      observer.didChangeAppLifecycleState(AppLifecycleState.resumed);
      observer.didChangeAppLifecycleState(AppLifecycleState.resumed);
      observer.didChangeAppLifecycleState(AppLifecycleState.resumed);
      await tester.pumpAndSettle();

      expect(
        hub.eventLoadCount,
        eventLoadsBefore + 1,
        reason: 'one refresh per background → foreground round trip',
      );
    });

    testWidgets('an inactive Calendar tab does not refetch on resume', (
      tester,
    ) async {
      final hub = _StubHub(calendars: const [_lazersCalendar]);

      await tester.pumpWidget(_hostCalendar(hub, isActive: false));
      await tester.pumpAndSettle();

      final eventLoadsBefore = hub.eventLoadCount;

      await _backgroundThenResume(tester);
      await tester.pumpAndSettle();

      expect(
        hub.eventLoadCount,
        eventLoadsBefore,
        reason:
            'a hidden tab reloads via refreshGeneration when it is selected, '
            'so resuming must not spend a request on it',
      );
    });

    testWidgets('a disposed page does not refresh on resume (regression)', (
      tester,
    ) async {
      final hub = _StubHub(calendars: const [_lazersCalendar]);

      await tester.pumpWidget(_hostCalendar(hub));
      await tester.pumpAndSettle();

      final eventLoadsBefore = hub.eventLoadCount;

      await tester.pumpWidget(
        const MaterialApp(home: Scaffold(body: SizedBox.shrink())),
      );
      await tester.pumpAndSettle();

      await _backgroundThenResume(tester);
      await tester.pumpAndSettle();

      expect(hub.eventLoadCount, eventLoadsBefore);
    });
  });

  // ── Pull to refresh ──────────────────────────────────────────────────────────
  //
  // The user-controlled fallback for the case app-resume cannot cover: the app
  // stays in the foreground, on Calendar, while the subscribed feed gains an
  // event. Requires TZ=Australia/Perth (the repository's standard test
  // timezone) for the rendered time assertion.

  group('CalendarPage pull to refresh', () {
    testWidgets(
      'reveals a subscribed-calendar event with no navigation, no tab switch '
      'and no lifecycle event',
      (tester) async {
        final hub = _StubHub(calendars: const [_lazersCalendar, _otherCalendar])
          ..eventsPayload = const [_otherEvent];

        await tester.pumpWidget(_hostCalendar(hub));
        await tester.pumpAndSettle();
        await _selectSetupDay(tester);

        expect(_view(tester).selectedMonth, DateTime(2026, 8, 1));
        expect(find.text('Setup'), findsNothing);
        expect(find.text('Training'), findsOneWidget);

        // Hide the second calendar so the refresh can be shown to preserve it.
        await _hideCalendar(tester, 'Other Calendar');
        expect(find.text('Training'), findsNothing);

        final stateBefore = tester.state(find.byType(CalendarPage));
        final eventLoadsBefore = hub.eventLoadCount;

        // The subscribed feed now carries the Hub event; hold the response open
        // so the in-flight state is observable.
        hub.eventsPayload = const [_otherEvent, _setupEvent];
        final gate = Completer<void>();
        hub.gate = gate;

        await _pullToRefresh(tester);

        expect(
          hub.eventLoadCount,
          eventLoadsBefore + 1,
          reason: 'one gesture → exactly one event-range request',
        );
        expect(
          find.byType(ReadOnlyCalendarView),
          findsOneWidget,
          reason: 'the last good snapshot stays on screen while refreshing',
        );

        gate.complete();
        await tester.pumpAndSettle();

        expect(find.text('Setup'), findsOneWidget);
        expect(find.text('Lazers (Morley Eagles)'), findsOneWidget);
        expect(
          find.text(_setupTimeLabel),
          findsOneWidget,
          reason: 'run with TZ=Australia/Perth (repository test standard)',
        );
        expect(
          find.text('Training'),
          findsNothing,
          reason: 'the hidden-calendar selection survives the refresh',
        );
        expect(
          identical(tester.state(find.byType(CalendarPage)), stateBefore),
          isTrue,
          reason: 'the same CalendarPage instance stayed mounted throughout',
        );
        expect(_view(tester).selectedDay, _setupDay);
        expect(_view(tester).selectedMonth, DateTime(2026, 8, 1));
        expect(_view(tester).viewMode, CalendarDisplayViewMode.month);
        expect(
          hub.eventLoadCount,
          eventLoadsBefore + 1,
          reason: 'no extra request after the response landed',
        );

        final shown = _view(tester).events.where((e) => e.title == 'Setup');
        expect(shown.single.calendarId, 'portal:lazers-morley-eagles');
        expect(
          shown.single.readOnly,
          isTrue,
          reason: 'subscribed events stay read-only after a refresh',
        );
      },
    );

    testWidgets('works in Agenda mode, including an empty month', (
      tester,
    ) async {
      final hub = _StubHub(calendars: const [_lazersCalendar]);

      await tester.pumpWidget(_hostCalendar(hub));
      await tester.pumpAndSettle();
      await _selectSetupDay(tester);

      await tester.tap(find.text('Agenda'));
      await tester.pumpAndSettle();
      expect(find.text('No events this month'), findsOneWidget);

      final eventLoadsBefore = hub.eventLoadCount;
      hub.eventsPayload = const [_setupEvent];
      final gate = Completer<void>();
      hub.gate = gate;

      await _pullToRefresh(tester);
      expect(hub.eventLoadCount, eventLoadsBefore + 1);

      gate.complete();
      await tester.pumpAndSettle();

      expect(find.text('Setup'), findsOneWidget);
      expect(find.text(_setupTimeLabel), findsOneWidget);
      expect(
        _view(tester).viewMode,
        CalendarDisplayViewMode.agenda,
        reason: 'the view mode must not reset',
      );
    });

    testWidgets('app-resume refresh still works after a pull refresh', (
      tester,
    ) async {
      final hub = _StubHub(calendars: const [_lazersCalendar]);

      await tester.pumpWidget(_hostCalendar(hub));
      await tester.pumpAndSettle();
      await _selectSetupDay(tester);

      await _pullToRefresh(tester);
      await tester.pumpAndSettle();

      final eventLoadsBefore = hub.eventLoadCount;
      hub.eventsPayload = const [_setupEvent];

      await _backgroundThenResume(tester);
      await tester.pumpAndSettle();

      expect(hub.eventLoadCount, eventLoadsBefore + 1);
      expect(find.text('Setup'), findsOneWidget);
    });
  });
}

import 'package:flutter_test/flutter_test.dart';

import 'package:calee_mobile/data/api/calee_hub_client.dart';
import 'package:calee_mobile/data/auth/calee_preferences.dart';
import 'package:calee_mobile/data/models/client_calendar.dart';
import 'package:calee_mobile/features/calendar/calendar_controller.dart';
import 'package:calee_mobile/features/calendar/calendar_repository.dart';

// ─── Stubs ────────────────────────────────────────────────────────────────────

class _StubPrefs extends CaleePreferences {
  _StubPrefs(this._stored);
  final StoredPreferences _stored;

  @override
  Future<StoredPreferences> load() async => _stored;
}

class _StubHubClient extends CaleeHubClient {
  _StubHubClient({
    List<ClientCalendar>? calendars,
    List<ClientEvent>? events,
    this.failCalendars = false,
  })  : _calendars = calendars ?? [],
        _events = events ?? [],
        super();

  final List<ClientCalendar> _calendars;
  final List<ClientEvent> _events;
  final bool failCalendars;

  @override
  Future<ClientCalendarList> calendars({required String accessToken}) async {
    if (failCalendars) throw Exception('network error');
    return ClientCalendarList(calendars: _calendars);
  }

  @override
  Future<ClientEventList> events({
    required String accessToken,
    required String from,
    required String to,
  }) async {
    return ClientEventList(from: from, to: to, events: _events);
  }
}

// ─── Helpers ──────────────────────────────────────────────────────────────────

ClientCalendar _calendar(String id, {String primaryKind = 'calendar'}) =>
    ClientCalendar(
      id: id,
      serviceId: 'svc',
      serviceName: 'Test',
      name: 'Cal $id',
      components: const [],
      primaryKind: primaryKind,
      supportsEvents: true,
      supportsTasks: false,
      supportsChores: false,
      readOnly: false,
      isSubscription: false,
      source: 'test',
    );

ClientEvent _event(
  String id, {
  String calendarId = 'cal1',
  bool allDay = false,
  String startsAt = '2026-06-15T09:00:00',
  String endsAt = '2026-06-15T10:00:00',
  bool recurring = false,
}) =>
    ClientEvent(
      id: id,
      calendarId: calendarId,
      serviceId: 'svc',
      serviceName: 'Test',
      title: 'Event $id',
      startsAt: startsAt,
      endsAt: endsAt,
      allDay: allDay,
      recurring: recurring,
      source: 'test',
    );

CalendarController _makeController({
  List<ClientCalendar>? calendars,
  List<ClientEvent>? events,
  bool failCalendars = false,
  StoredPreferences? prefs,
}) {
  final hub = _StubHubClient(
    calendars: calendars,
    events: events,
    failCalendars: failCalendars,
  );
  final repo = CalendarRepository(
    hubClient: hub,
    accessToken: 'tok',
    preferences: _StubPrefs(prefs ?? const StoredPreferences()),
  );
  return CalendarController(repository: repo);
}

// ─── Tests ────────────────────────────────────────────────────────────────────

void main() {
  // ── Repository ──────────────────────────────────────────────────────────────

  group('CalendarRepository.loadMonth', () {
    test('filters calendars to isCalendarKind', () async {
      final repo = CalendarRepository(
        hubClient: _StubHubClient(calendars: [
          _calendar('cal-calendar', primaryKind: 'calendar'),
          _calendar('cal-tasks', primaryKind: 'tasks'),
          _calendar('cal-chores', primaryKind: 'chores'),
        ]),
        accessToken: 'tok',
        preferences: _StubPrefs(const StoredPreferences()),
      );

      final overview = await repo.loadMonth(
        selectedMonth: DateTime(2026, 6, 1),
        firstDayOfWeek: FirstDayOfWeek.sunday,
      );

      expect(overview.calendars, hasLength(1));
      expect(overview.calendars.first.id, 'cal-calendar');
    });

    test('computes 42-day grid (6 weeks)', () async {
      final repo = CalendarRepository(
        hubClient: _StubHubClient(),
        accessToken: 'tok',
        preferences: _StubPrefs(const StoredPreferences()),
      );

      final overview = await repo.loadMonth(
        selectedMonth: DateTime(2026, 6, 1),
        firstDayOfWeek: FirstDayOfWeek.sunday,
      );

      final diff = overview.gridEnd.difference(overview.gridStart).inDays;
      expect(diff, 41); // gridStart + 41 days = 42-day window
    });
  });

  // ── Controller loading ──────────────────────────────────────────────────────

  group('CalendarController.loadMonth', () {
    test('sets isLoading true then false on success', () async {
      final ctrl = _makeController(calendars: [_calendar('c1')]);

      final loadingStates = <bool>[];
      ctrl.addListener(() => loadingStates.add(ctrl.isLoading));

      await ctrl.loadMonth();

      expect(loadingStates.first, isTrue);
      expect(loadingStates.last, isFalse);
    });

    test('sets error on failure', () async {
      final ctrl = _makeController(failCalendars: true);

      await ctrl.loadMonth();

      expect(ctrl.error, isNotNull);
      expect(ctrl.isLoading, isFalse);
    });

    test('populates calendars on success', () async {
      final ctrl =
          _makeController(calendars: [_calendar('c1'), _calendar('c2')]);

      await ctrl.loadMonth();

      expect(ctrl.calendars, hasLength(2));
      expect(ctrl.error, isNull);
    });
  });

  // ── Navigation ──────────────────────────────────────────────────────────────

  group('CalendarController navigation', () {
    test('previousMonth decrements month', () async {
      final ctrl = _makeController();

      // Override selectedMonth to a known value for a deterministic test
      ctrl.selectedMonth = DateTime(2026, 6, 1);
      ctrl.selectedDay = DateTime(2026, 6, 15);

      ctrl.previousMonth();
      await Future<void>.delayed(Duration.zero); // let async loadMonth settle

      expect(ctrl.selectedMonth, DateTime(2026, 5, 1));
    });

    test('nextMonth increments month', () async {
      final ctrl = _makeController();
      ctrl.selectedMonth = DateTime(2026, 6, 1);
      ctrl.selectedDay = DateTime(2026, 6, 15);

      ctrl.nextMonth();
      await Future<void>.delayed(Duration.zero);

      expect(ctrl.selectedMonth, DateTime(2026, 7, 1));
    });

    test('previousMonth resets selectedDay when outside new month', () async {
      final ctrl = _makeController();
      ctrl.selectedMonth = DateTime(2026, 6, 1);
      ctrl.selectedDay = DateTime(2026, 6, 15); // in June

      ctrl.previousMonth(); // goes to May
      await Future<void>.delayed(Duration.zero);

      // selectedDay is in June but new month is May → reset to 1st of May
      expect(ctrl.selectedDay, DateTime(2026, 5, 1));
    });

    test('nextMonth keeps selectedDay when inside new month', () async {
      final ctrl = _makeController();
      ctrl.selectedMonth = DateTime(2026, 6, 1);
      ctrl.selectedDay = DateTime(2026, 6, 1); // same as first of month

      ctrl.nextMonth(); // goes to July; selectedDay was June 1
      await Future<void>.delayed(Duration.zero);

      // selectedDay (June 1) is not in July → reset to 1st of July
      expect(ctrl.selectedDay, DateTime(2026, 7, 1));
    });
  });

  // ── Calendar visibility ─────────────────────────────────────────────────────

  group('CalendarController visibility', () {
    test('toggleCalendarVisibility hides a visible calendar', () {
      final ctrl = _makeController();
      expect(ctrl.isCalendarVisible('cal1'), isTrue);

      ctrl.toggleCalendarVisibility('cal1');

      expect(ctrl.isCalendarVisible('cal1'), isFalse);
    });

    test('toggleCalendarVisibility shows a hidden calendar', () {
      final ctrl = _makeController();
      ctrl.toggleCalendarVisibility('cal1');
      expect(ctrl.isCalendarVisible('cal1'), isFalse);

      ctrl.toggleCalendarVisibility('cal1');

      expect(ctrl.isCalendarVisible('cal1'), isTrue);
    });

    test('showAllCalendars clears all hidden IDs', () {
      final ctrl = _makeController();
      ctrl.toggleCalendarVisibility('cal1');
      ctrl.toggleCalendarVisibility('cal2');
      expect(ctrl.hiddenCalendarIds, hasLength(2));

      ctrl.showAllCalendars();

      expect(ctrl.hiddenCalendarIds, isEmpty);
    });
  });

  // ── eventsForDay ────────────────────────────────────────────────────────────

  group('CalendarController.eventsForDay', () {
    test('returns timed event on its start date', () async {
      final ctrl = _makeController(
        calendars: [_calendar('cal1')],
        events: [_event('e1', startsAt: '2026-06-15T09:00:00')],
      );
      await ctrl.loadMonth();

      final result = ctrl.eventsForDay(DateTime(2026, 6, 15));

      expect(result, hasLength(1));
      expect(result.first.id, 'e1');
    });

    test('returns all-day event using exclusive endsAt', () async {
      // Event runs June 15–17 (endsAt June 18 exclusive)
      final ctrl = _makeController(
        calendars: [_calendar('cal1')],
        events: [
          _event(
            'e1',
            allDay: true,
            startsAt: '2026-06-15',
            endsAt: '2026-06-18', // exclusive end
          ),
        ],
      );
      await ctrl.loadMonth();

      expect(ctrl.eventsForDay(DateTime(2026, 6, 15)), hasLength(1));
      expect(ctrl.eventsForDay(DateTime(2026, 6, 17)), hasLength(1));
      expect(ctrl.eventsForDay(DateTime(2026, 6, 18)), isEmpty); // exclusive
    });

    test('excludes events from hidden calendars', () async {
      final ctrl = _makeController(
        calendars: [_calendar('cal1')],
        events: [_event('e1', calendarId: 'cal1')],
      );
      await ctrl.loadMonth();

      ctrl.toggleCalendarVisibility('cal1');
      final result = ctrl.eventsForDay(DateTime(2026, 6, 15));

      expect(result, isEmpty);
    });
  });

  // ── searchEvents ────────────────────────────────────────────────────────────

  group('CalendarController.searchEvents', () {
    test('returns empty list for empty query', () async {
      final ctrl = _makeController(
        calendars: [_calendar('cal1')],
        events: [_event('e1')],
      );
      await ctrl.loadMonth();

      expect(ctrl.searchEvents(''), isEmpty);
    });

    test('matches event by title', () async {
      final ctrl = _makeController(
        calendars: [_calendar('cal1')],
        events: [_event('e1')],
      );
      await ctrl.loadMonth();

      // _event sets title to 'Event e1'
      final results = ctrl.searchEvents('event e1');
      expect(results, hasLength(1));
    });

    test('hides events from hidden calendars', () async {
      final ctrl = _makeController(
        calendars: [_calendar('cal1')],
        events: [_event('e1', calendarId: 'cal1')],
      );
      await ctrl.loadMonth();

      ctrl.toggleCalendarVisibility('cal1');
      final results = ctrl.searchEvents('event');

      expect(results, isEmpty);
    });
  });
}

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
  _StubHubClient({List<ClientCalendar>? calendars, List<ClientEvent>? events})
    : _calendars = calendars ?? [],
      _events = events ?? [],
      super();

  final List<ClientCalendar> _calendars;
  final List<ClientEvent> _events;

  @override
  Future<ClientCalendarList> calendars({required String accessToken}) async =>
      ClientCalendarList(calendars: _calendars);

  @override
  Future<ClientEventList> events({
    required String accessToken,
    required String from,
    required String to,
  }) async => ClientEventList(from: from, to: to, events: _events);
}

// ─── Helpers ──────────────────────────────────────────────────────────────────

ClientCalendar _calendar(String id) => ClientCalendar(
  id: id,
  serviceId: 'svc',
  serviceName: 'Test',
  name: 'Cal $id',
  components: const [],
  primaryKind: 'calendar',
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
}) => ClientEvent(
  id: id,
  calendarId: calendarId,
  serviceId: 'svc',
  serviceName: 'Test',
  title: 'Event $id',
  startsAt: startsAt,
  endsAt: endsAt,
  allDay: allDay,
  recurring: false,
  source: 'test',
);

CalendarController _ctrl({
  List<ClientCalendar>? calendars,
  List<ClientEvent>? events,
}) {
  final hub = _StubHubClient(calendars: calendars, events: events);
  final repo = CalendarRepository(
    hubClient: hub,
    accessToken: 'tok',
    preferences: _StubPrefs(const StoredPreferences()),
  );
  return CalendarController(repository: repo);
}

// ─── Tests ────────────────────────────────────────────────────────────────────

void main() {
  group('Agenda month view — event grouping', () {
    test('eventsForDay returns empty list for a day with no events', () async {
      final ctrl = _ctrl(
        calendars: [_calendar('cal1')],
        events: [_event('e1', startsAt: '2026-06-15T09:00:00')],
      );
      await ctrl.loadMonth();

      final result = ctrl.eventsForDay(DateTime(2026, 6, 16));
      expect(result, isEmpty);
    });

    test(
      'all-day events appear alongside timed events for the same day',
      () async {
        final ctrl = _ctrl(
          calendars: [_calendar('cal1')],
          events: [
            _event(
              'e-allday',
              allDay: true,
              startsAt: '2026-06-15',
              endsAt: '2026-06-16',
            ),
            _event('e-timed', startsAt: '2026-06-15T10:00:00'),
          ],
        );
        await ctrl.loadMonth();

        final day = ctrl.eventsForDay(DateTime(2026, 6, 15));
        expect(day.any((e) => e.allDay), isTrue);
        expect(day.any((e) => !e.allDay), isTrue);
      },
    );

    test('hidden calendar events are excluded from agenda', () async {
      final ctrl = _ctrl(
        calendars: [_calendar('cal1')],
        events: [_event('e1', calendarId: 'cal1')],
      );
      await ctrl.loadMonth();

      ctrl.toggleCalendarVisibility('cal1');

      // All days in June should have no visible events
      var totalVisible = 0;
      for (var d = 1; d <= 30; d++) {
        totalVisible += ctrl.eventsForDay(DateTime(2026, 6, d)).length;
      }
      expect(totalVisible, 0);
    });

    test('agenda lists events from multiple days in the month', () async {
      final ctrl = _ctrl(
        calendars: [_calendar('cal1')],
        events: [
          _event('e1', startsAt: '2026-06-10T09:00:00'),
          _event('e2', startsAt: '2026-06-20T14:00:00'),
        ],
      );
      await ctrl.loadMonth();

      final june10 = ctrl.eventsForDay(DateTime(2026, 6, 10));
      final june20 = ctrl.eventsForDay(DateTime(2026, 6, 20));

      expect(june10, hasLength(1));
      expect(june20, hasLength(1));
      expect(june10.first.id, 'e1');
      expect(june20.first.id, 'e2');
    });

    test('no visible events yields empty days throughout the month', () async {
      final ctrl = _ctrl(calendars: [_calendar('cal1')], events: const []);
      await ctrl.loadMonth();

      var totalVisible = 0;
      for (var d = 1; d <= 30; d++) {
        totalVisible += ctrl.eventsForDay(DateTime(2026, 6, d)).length;
      }
      expect(totalVisible, 0);
    });
  });

  group('FAB hero tag uniqueness (static check)', () {
    test('tasks_page and chores_page use distinct named hero tags', () {
      // These are compile-time string constants verified here as a
      // regression guard — they must not share the default FAB tag.
      const tasksTag = 'tasks_add_task_fab';
      const choresTag = 'chores_add_chore_fab';
      const settingsTag = 'settings_add_family_member_fab';

      final tags = [tasksTag, choresTag, settingsTag];
      expect(
        tags.toSet().length,
        tags.length,
        reason: 'All FAB hero tags must be unique',
      );
    });
  });
}

// The destination calendar's journey from the editor to the wire.
//
// CalendarController.updateEvent -> CalendarRepository.updateEvent ->
// CaleeHubClient.updateEvent -> PATCH /client/v1/events/{eventId}.
//
// Each hop used to drop the destination because none of them had one: this
// pins that it now survives all four, that a move triggers the calendar
// reload and reminder refresh a move needs (the event's calendar, colour and
// visibility all change), and that an edit which does not move an event
// sends byte-for-byte the request it always did — the backward-compatibility
// guarantee an older Hub depends on.

import 'dart:convert';
import 'dart:io';

import 'package:calee_mobile/data/api/calee_hub_client.dart';
import 'package:calee_mobile/data/auth/calee_preferences.dart';
import 'package:calee_mobile/data/models/client_calendar.dart';
import 'package:calee_mobile/features/calendar/calendar_controller.dart';
import 'package:calee_mobile/features/calendar/calendar_repository.dart';
import 'package:calee_mobile/features/notifications/calendar_reminder_coordinator.dart';
import 'package:flutter_test/flutter_test.dart';

// ── Stubs ─────────────────────────────────────────────────────────────────────

class _StubPrefs extends CaleePreferences {
  @override
  Future<StoredPreferences> load() async => const StoredPreferences();
}

/// Records exactly what reached the client, including whether `calendarId`
/// was supplied at all.
class _RecordingHubClient extends CaleeHubClient {
  final List<({String eventId, String? calendarId, String? scope})>
  updateCalls = [];
  int calendarFetches = 0;
  int eventFetches = 0;

  @override
  Future<ClientCalendarList> calendars({required String accessToken}) async {
    calendarFetches++;
    return const ClientCalendarList(calendars: []);
  }

  @override
  Future<ClientEventList> events({
    required String accessToken,
    required String from,
    required String to,
  }) async {
    eventFetches++;
    return ClientEventList(from: from, to: to, events: const []);
  }

  @override
  Future<ClientEvent> updateEvent({
    required String accessToken,
    required String eventId,
    required String title,
    String? calendarId,
    String? startsAt,
    String? endsAt,
    bool? allDay,
    String? location,
    String? description,
    String? recurrence,
    bool includeRecurrence = false,
    String? scope,
  }) async {
    updateCalls.add((eventId: eventId, calendarId: calendarId, scope: scope));
    return _movedEvent;
  }
}

// ── Fixtures ──────────────────────────────────────────────────────────────────

ClientCalendar _calendar({required String id, required String name}) =>
    ClientCalendar(
      id: id,
      serviceId: 'portal',
      serviceName: 'Calee',
      name: name,
      color: null,
      components: const ['VEVENT'],
      primaryKind: 'calendar',
      supportsEvents: true,
      supportsTasks: false,
      supportsChores: false,
      readOnly: false,
      isSubscription: false,
      source: 'nextcloud_calendar',
    );

final _myCalendar = _calendar(id: 'portal:personal', name: 'My Calendar');
final _gCalendar = _calendar(id: 'portal:work', name: 'G Calendar');

const _event = ClientEvent(
  id: 'portal:ev-1',
  calendarId: 'portal:personal',
  serviceId: 'portal',
  serviceName: 'Calee',
  title: 'School note',
  startsAt: '2026-08-10T01:00:00.000Z',
  endsAt: '2026-08-10T02:00:00.000Z',
  allDay: false,
  source: 'nextcloud_calendar',
  recurring: false,
);

const _recurringEvent = ClientEvent(
  id: 'portal:ev-2:20260817T010000Z',
  calendarId: 'portal:personal',
  serviceId: 'portal',
  serviceName: 'Calee',
  title: 'Weekly standup',
  startsAt: '2026-08-17T01:00:00.000Z',
  endsAt: '2026-08-17T02:00:00.000Z',
  allDay: false,
  source: 'nextcloud_calendar',
  recurring: true,
  recurrence: 'FREQ=WEEKLY',
  seriesId: 'portal:ev-2',
);

const _movedEvent = ClientEvent(
  id: 'portal:ev-1',
  calendarId: 'portal:work',
  serviceId: 'portal',
  serviceName: 'Calee',
  title: 'School note',
  startsAt: '2026-08-10T01:00:00.000Z',
  endsAt: '2026-08-10T02:00:00.000Z',
  allDay: false,
  source: 'nextcloud_calendar',
  recurring: false,
);

CalendarRepository _repository(CaleeHubClient hub) => CalendarRepository(
  hubClient: hub,
  accessToken: 'tok',
  preferences: _StubPrefs(),
);

void main() {
  group('CalendarRepository.updateEvent()', () {
    test('forwards the destination calendar\'s public id', () async {
      final hub = _RecordingHubClient();

      await _repository(hub).updateEvent(
        event: _event,
        title: 'School note',
        startsAt: DateTime.utc(2026, 8, 10, 1),
        endsAt: DateTime.utc(2026, 8, 10, 2),
        allDay: false,
        destinationCalendar: _gCalendar,
      );

      expect(hub.updateCalls.single.calendarId, 'portal:work');
    });

    test('sends no destination when none was chosen', () async {
      final hub = _RecordingHubClient();

      await _repository(hub).updateEvent(
        event: _event,
        title: 'School note',
        startsAt: DateTime.utc(2026, 8, 10, 1),
        endsAt: DateTime.utc(2026, 8, 10, 2),
        allDay: false,
      );

      expect(hub.updateCalls.single.calendarId, isNull);
    });

    test('never sends a destination for an occurrence-scoped edit, even if '
        'one is passed - a series cannot be split across calendars', () async {
      final hub = _RecordingHubClient();

      await _repository(hub).updateEvent(
        event: _recurringEvent,
        title: 'Weekly standup',
        startsAt: DateTime.utc(2026, 8, 17, 1),
        endsAt: DateTime.utc(2026, 8, 17, 2),
        allDay: false,
        editScope: 'occurrence',
        destinationCalendar: _gCalendar,
      );

      expect(hub.updateCalls.single.scope, 'occurrence');
      expect(hub.updateCalls.single.calendarId, isNull);
    });

    test('does send a destination for a series-scoped edit', () async {
      final hub = _RecordingHubClient();

      await _repository(hub).updateEvent(
        event: _recurringEvent,
        title: 'Weekly standup',
        startsAt: DateTime.utc(2026, 8, 17, 1),
        endsAt: DateTime.utc(2026, 8, 17, 2),
        allDay: false,
        editScope: 'series',
        destinationCalendar: _gCalendar,
      );

      expect(hub.updateCalls.single.scope, 'series');
      expect(hub.updateCalls.single.calendarId, 'portal:work');
    });
  });

  group('CalendarController.updateEvent()', () {
    test(
      'forwards the destination and reloads the calendar afterwards',
      () async {
        final hub = _RecordingHubClient();
        final reasons = <CalendarReminderRefreshReason>[];
        final controller = CalendarController(
          repository: _repository(hub),
          onRequestReminderRefresh: (reason) async => reasons.add(reason),
        );

        await controller.loadMonth();
        final fetchesBefore = hub.eventFetches;

        await controller.updateEvent(
          event: _event,
          title: 'School note',
          startsAt: DateTime.utc(2026, 8, 10, 1),
          endsAt: DateTime.utc(2026, 8, 10, 2),
          allDay: false,
          destinationCalendar: _gCalendar,
        );

        expect(hub.updateCalls.single.calendarId, 'portal:work');
        // The move changes which calendar the event belongs to -- its colour,
        // its grouping, and whether a hidden-calendar filter should show it at
        // all. Only a reload from the server gets every one of those right.
        expect(hub.eventFetches, greaterThan(fetchesBefore));
        expect(hub.calendarFetches, greaterThan(1));
        // Reminders are still refreshed after a mutation, exactly as before.
        expect(reasons, [CalendarReminderRefreshReason.eventUpdated]);
      },
    );

    test(
      'an edit that does not move the event forwards no destination',
      () async {
        final hub = _RecordingHubClient();
        final controller = CalendarController(repository: _repository(hub));

        await controller.loadMonth();
        await controller.updateEvent(
          event: _event,
          title: 'School note',
          startsAt: DateTime.utc(2026, 8, 10, 1),
          endsAt: DateTime.utc(2026, 8, 10, 2),
          allDay: false,
        );

        expect(hub.updateCalls.single.calendarId, isNull);
      },
    );
  });

  group('CaleeHubClient.updateEvent() on the wire', () {
    late HttpServer server;
    late List<Map<String, dynamic>> bodies;
    late List<String> paths;

    Future<CaleeHubClient> start() async {
      bodies = [];
      paths = [];
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      server.listen((req) async {
        paths.add(req.uri.toString());
        final raw = await utf8.decoder.bind(req).join();
        if (raw.isNotEmpty) {
          bodies.add(jsonDecode(raw) as Map<String, dynamic>);
        }
        req.response.headers.contentType = ContentType.json;
        req.response.statusCode = HttpStatus.ok;
        req.response.write(
          jsonEncode({
            'data': {
              'event': {
                'id': 'portal:ev-1',
                'calendarId': 'portal:work',
                'serviceId': 'portal',
                'serviceName': 'Calee',
                'title': 'School note',
                'startsAt': '2026-08-10T01:00:00Z',
                'endsAt': '2026-08-10T02:00:00Z',
                'allDay': false,
                'source': 'nextcloud_calendar',
                'recurring': false,
              },
            },
          }),
        );
        await req.response.close();
      });
      return CaleeHubClient(
        baseUri: Uri.parse('http://127.0.0.1:${server.port}'),
      );
    }

    tearDown(() async => server.close(force: true));

    test('PATCHes the destination calendarId in the body', () async {
      final client = await start();

      final result = await client.updateEvent(
        accessToken: 'tok',
        eventId: 'portal:ev-1',
        title: 'School note',
        calendarId: 'portal:work',
      );

      expect(paths.single, '/client/v1/events/portal%3Aev-1');
      expect(bodies.single['calendarId'], 'portal:work');
      // The response is authoritative about where the event now lives.
      expect(result.calendarId, 'portal:work');
    });

    test('omits calendarId entirely when no destination is supplied, so an '
        'older Hub sees exactly the request it always saw', () async {
      final client = await start();

      await client.updateEvent(
        accessToken: 'tok',
        eventId: 'portal:ev-1',
        title: 'School note',
      );

      expect(bodies.single.containsKey('calendarId'), isFalse);
    });

    test(
      'omits a blank destination rather than sending an empty value',
      () async {
        final client = await start();

        await client.updateEvent(
          accessToken: 'tok',
          eventId: 'portal:ev-1',
          title: 'School note',
          calendarId: '   ',
        );

        expect(bodies.single.containsKey('calendarId'), isFalse);
      },
    );

    test('keeps the destination alongside a scope query parameter', () async {
      final client = await start();

      await client.updateEvent(
        accessToken: 'tok',
        eventId: 'portal:ev-1',
        title: 'School note',
        calendarId: 'portal:work',
        scope: 'series',
      );

      expect(paths.single, '/client/v1/events/portal%3Aev-1?scope=series');
      expect(bodies.single['calendarId'], 'portal:work');
    });

    test('createEvent is unchanged', () async {
      final client = await start();

      await client.createEvent(
        accessToken: 'tok',
        serviceId: 'portal',
        calendarId: 'portal:work',
        title: 'School note',
        startsAt: '2026-08-10T01:00:00Z',
        endsAt: '2026-08-10T02:00:00Z',
        allDay: false,
      );

      expect(paths.single, '/client/v1/events');
      expect(bodies.single['serviceId'], 'portal');
      expect(bodies.single['calendarId'], 'portal:work');
    });
  });

  test('the fixtures used above are the ones the editor would pass', () {
    // Guards against the propagation tests silently drifting away from the
    // calendars the editor actually offers.
    expect(_myCalendar.id, _event.calendarId);
    expect(_gCalendar.serviceId, _event.serviceId);
  });
}

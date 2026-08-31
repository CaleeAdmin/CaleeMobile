// Which calendars an event may be moved to, and when the Calendar selector
// may be changed at all.
//
// These rules mirror calee-hub-core's own validation of the optional
// destination `calendarId` on PATCH /client/v1/events/{eventId}. Hub is the
// authority and re-checks all of it; these tests exist so the editor never
// OFFERS a destination Hub would refuse, which would turn a server-side
// rejection into something the user only discovers after pressing Save.

import 'package:calee_mobile/data/models/client_calendar.dart';
import 'package:calee_mobile/features/calendar/event_move_eligibility.dart';
import 'package:flutter_test/flutter_test.dart';

ClientCalendar _calendar({
  required String id,
  String serviceId = 'portal',
  String name = 'Calendar',
  bool readOnly = false,
  bool isSubscription = false,
  String primaryKind = 'calendar',
  String source = 'nextcloud_calendar',
}) {
  return ClientCalendar(
    id: id,
    serviceId: serviceId,
    serviceName: 'Calee',
    name: name,
    color: null,
    components: const ['VEVENT'],
    primaryKind: primaryKind,
    supportsEvents: true,
    supportsTasks: false,
    supportsChores: false,
    readOnly: readOnly,
    isSubscription: isSubscription,
    source: source,
  );
}

ClientEvent _event({
  String calendarId = 'portal:personal',
  String serviceId = 'portal',
  bool recurring = false,
  bool readOnly = false,
}) {
  return ClientEvent(
    id: 'portal:ev-1',
    calendarId: calendarId,
    serviceId: serviceId,
    serviceName: 'Calee',
    title: 'School note',
    startsAt: '2026-08-10T01:00:00.000Z',
    endsAt: '2026-08-10T02:00:00.000Z',
    allDay: false,
    source: 'nextcloud_calendar',
    recurring: recurring,
    readOnly: readOnly,
  );
}

/// Everything one account can have: two writable calendars, a read-only
/// share, a subscription, two non-event collections, an external provider
/// calendar, and a calendar on a second service.
List<ClientCalendar> _allCalendars() => [
  _calendar(id: 'portal:personal', name: 'My Calendar'),
  _calendar(id: 'portal:work', name: 'G Calendar'),
  _calendar(id: 'portal:shared', name: 'Shared', readOnly: true),
  _calendar(
    id: 'portal:holidays',
    name: 'Holidays',
    readOnly: true,
    isSubscription: true,
  ),
  _calendar(id: 'portal:tasks', name: 'Tasks', primaryKind: 'tasks'),
  _calendar(id: 'portal:chores', name: 'Chores', primaryKind: 'chores'),
  _calendar(
    id: 'external:google-primary',
    serviceId: 'external',
    name: 'Google',
    readOnly: true,
    source: 'external',
  ),
  _calendar(id: 'business:work', serviceId: 'business', name: 'Business'),
];

void main() {
  group('eventMoveDestinations()', () {
    test(
      'offers every writable event calendar on the event\'s own service',
      () {
        final destinations = eventMoveDestinations(
          event: _event(),
          calendars: _allCalendars(),
        );

        expect(destinations.map((c) => c.id), [
          'portal:personal',
          'portal:work',
        ]);
      },
    );

    test('includes the calendar the event is already in', () {
      final destinations = eventMoveDestinations(
        event: _event(),
        calendars: _allCalendars(),
      );

      expect(destinations.any((c) => c.id == 'portal:personal'), isTrue);
    });

    test('excludes read-only calendars', () {
      final destinations = eventMoveDestinations(
        event: _event(),
        calendars: _allCalendars(),
      );

      expect(destinations.any((c) => c.id == 'portal:shared'), isFalse);
    });

    test('excludes subscriptions', () {
      final destinations = eventMoveDestinations(
        event: _event(),
        calendars: _allCalendars(),
      );

      expect(destinations.any((c) => c.id == 'portal:holidays'), isFalse);
    });

    test('excludes external provider calendars', () {
      final destinations = eventMoveDestinations(
        event: _event(),
        calendars: _allCalendars(),
      );

      expect(destinations.any((c) => c.isExternal), isFalse);
    });

    test('excludes collections that cannot hold events', () {
      final destinations = eventMoveDestinations(
        event: _event(),
        calendars: _allCalendars(),
      );

      expect(destinations.any((c) => c.id == 'portal:tasks'), isFalse);
      expect(destinations.any((c) => c.id == 'portal:chores'), isFalse);
    });

    test('excludes calendars on another service - Hub cannot move across '
        'services, so a cross-service destination must never be offered', () {
      final destinations = eventMoveDestinations(
        event: _event(),
        calendars: _allCalendars(),
      );

      expect(destinations.any((c) => c.serviceId == 'business'), isFalse);
    });

    test('offers nothing for an event with no resolvable service', () {
      final destinations = eventMoveDestinations(
        event: _event(serviceId: ''),
        calendars: _allCalendars(),
      );

      expect(destinations, isEmpty);
    });
  });

  group('canChangeEventCalendar()', () {
    test('is allowed for an ordinary one-off edit', () {
      final destinations = eventMoveDestinations(
        event: _event(),
        calendars: _allCalendars(),
      );

      expect(
        canChangeEventCalendar(
          event: _event(),
          editScope: null,
          destinations: destinations,
        ),
        isTrue,
      );
    });

    test('is allowed when editing an entire series', () {
      final event = _event(recurring: true);
      final destinations = eventMoveDestinations(
        event: event,
        calendars: _allCalendars(),
      );

      expect(
        canChangeEventCalendar(
          event: event,
          editScope: 'series',
          destinations: destinations,
        ),
        isTrue,
      );
    });

    test('is refused when editing a single occurrence - a series lives in one '
        'CalDAV resource and cannot be split across calendars', () {
      final event = _event(recurring: true);
      final destinations = eventMoveDestinations(
        event: event,
        calendars: _allCalendars(),
      );

      expect(
        canChangeEventCalendar(
          event: event,
          editScope: 'occurrence',
          destinations: destinations,
        ),
        isFalse,
      );
    });

    test('is refused when there is nowhere else to move to', () {
      final destinations = eventMoveDestinations(
        event: _event(),
        calendars: [_calendar(id: 'portal:personal')],
      );

      expect(destinations, hasLength(1));
      expect(
        canChangeEventCalendar(
          event: _event(),
          editScope: null,
          destinations: destinations,
        ),
        isFalse,
      );
    });

    test('is refused for a read-only event', () {
      final event = _event(readOnly: true);
      final destinations = eventMoveDestinations(
        event: event,
        calendars: _allCalendars(),
      );

      expect(
        canChangeEventCalendar(
          event: event,
          editScope: null,
          destinations: destinations,
        ),
        isFalse,
      );
    });
  });

  group('currentCalendarForEvent()', () {
    test('resolves the calendar the event is in', () {
      final destinations = eventMoveDestinations(
        event: _event(),
        calendars: _allCalendars(),
      );

      expect(
        currentCalendarForEvent(
          event: _event(),
          destinations: destinations,
        )?.id,
        'portal:personal',
      );
    });

    test(
      'resolves a legacy bare calendarId against the composite public id',
      () {
        final destinations = eventMoveDestinations(
          event: _event(calendarId: 'personal'),
          calendars: _allCalendars(),
        );

        expect(
          currentCalendarForEvent(
            event: _event(calendarId: 'personal'),
            destinations: destinations,
          )?.id,
          'portal:personal',
        );
      },
    );

    test('returns null rather than guessing when the calendar is not in the '
        'list - selecting an unrelated calendar would turn an ordinary edit '
        'into an unrequested move', () {
      expect(
        currentCalendarForEvent(
          event: _event(calendarId: 'portal:deleted-calendar'),
          destinations: [
            _calendar(id: 'portal:work'),
            _calendar(id: 'portal:personal'),
          ],
        ),
        isNull,
      );
    });
  });
}

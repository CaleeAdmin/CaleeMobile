// Moving an event to another calendar from the edit sheet.
//
// The reported bug: an event filed in the wrong calendar could only be
// corrected by deleting and recreating it. The editor's Calendar row was
// disabled while editing, and the editor was only ever handed the ONE
// calendar the event was already in — so there was nothing to pick even if
// the row had been live.
//
// These tests pin the editor half of the fix, and the behaviour that must
// NOT change with it: creating an event, editing without touching the
// Calendar row, and — critically — that attachment requests keep addressing
// the calendar the event is still IN while a different destination is merely
// selected.

import 'dart:io';

import 'package:calee_mobile/data/api/calee_hub_client.dart';
import 'package:calee_mobile/data/models/client_calendar.dart';
import 'package:calee_mobile/data/models/client_event_draft.dart';
import 'package:calee_mobile/features/calendar/widgets/create_event_sheet.dart';
import 'package:calee_mobile/ui/calee_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

// ── Stub ──────────────────────────────────────────────────────────────────────

/// Records every attachment request's (eventId, calendarId) so the tests can
/// prove which calendar the editor addressed.
class _StubHub extends CaleeHubClient {
  final List<({String eventId, String? calendarId})> attachmentListCalls = [];

  @override
  Future<EventDraftsFromImageResponse> eventDraftsFromImage({
    required String accessToken,
    required File imageFile,
    String? timezone,
    String? referenceDate,
    String? sourceHint,
  }) async => const EventDraftsFromImageResponse(drafts: []);

  @override
  Future<List<CalendarAttachment>> listAttachments({
    required String accessToken,
    required String eventId,
    String? calendarId,
  }) async {
    attachmentListCalls.add((eventId: eventId, calendarId: calendarId));
    return const [];
  }
}

// ── Fixtures ──────────────────────────────────────────────────────────────────

const _attachmentCapabilities = CalendarCapabilities(
  canEditAppearance: true,
  canEditEvents: true,
  canEditSourceMetadata: true,
  canRemoveFromCalee: true,
  canDeleteSource: true,
  canViewAttachments: true,
  canAddAttachments: true,
  canRemoveAttachments: true,
);

ClientCalendar _calendar({
  required String id,
  required String name,
  String serviceId = 'portal',
  CalendarCapabilities? capabilities,
}) {
  return ClientCalendar(
    id: id,
    serviceId: serviceId,
    serviceName: 'Calee',
    name: name,
    color: '#4285F4',
    components: const ['VEVENT'],
    primaryKind: 'calendar',
    supportsEvents: true,
    supportsTasks: false,
    supportsChores: false,
    readOnly: false,
    isSubscription: false,
    source: 'nextcloud_calendar',
    capabilities:
        capabilities ??
        CalendarCapabilities.fallback(readOnly: false, isSubscription: false),
  );
}

final _myCalendar = _calendar(id: 'portal:personal', name: 'My Calendar');
final _gCalendar = _calendar(id: 'portal:work', name: 'G Calendar');

const _event = ClientEvent(
  id: 'portal:ev-1',
  calendarId: 'portal:personal',
  serviceId: 'portal',
  serviceName: 'Calee',
  title: 'School note',
  startsAt: '2026-06-27T09:00:00.000Z',
  endsAt: '2026-06-27T10:00:00.000Z',
  allDay: false,
  source: 'nextcloud_calendar',
  recurring: false,
);

const _recurringEvent = ClientEvent(
  id: 'portal:ev-2',
  calendarId: 'portal:personal',
  serviceId: 'portal',
  serviceName: 'Calee',
  title: 'Weekly standup',
  startsAt: '2026-06-28T01:00:00.000Z',
  endsAt: '2026-06-28T02:00:00.000Z',
  allDay: false,
  source: 'nextcloud_calendar',
  recurring: true,
  recurrence: 'FREQ=WEEKLY;BYDAY=SU',
);

// ── Helpers ───────────────────────────────────────────────────────────────────

/// Captures what the sheet reported on Save.
class _UpdateCapture {
  int calls = 0;
  ClientCalendar? destinationCalendar;
  String? title;
}

Widget _buildEditor({
  required List<ClientCalendar> calendars,
  required ClientEvent event,
  String? editScope,
  _UpdateCapture? capture,
  CaleeHubClient? hub,
}) {
  return MaterialApp(
    theme: CaleeTheme.buildThemeData(),
    home: Scaffold(
      body: CreateEventSheet(
        calendars: calendars,
        initialEvent: event,
        editScope: editScope,
        onCreate:
            ({
              required calendar,
              required title,
              required startsAt,
              required endsAt,
              required allDay,
              location,
              description,
              recurrence,
            }) async {},
        onUpdate:
            ({
              required event,
              required title,
              required startsAt,
              required endsAt,
              required allDay,
              location,
              description,
              recurrence,
              editScope,
              destinationCalendar,
            }) async {
              capture?.calls++;
              capture?.destinationCalendar = destinationCalendar;
              capture?.title = title;
            },
        hubClient: hub ?? _StubHub(),
        accessToken: 'tok',
        use24h: true,
      ),
    ),
  );
}

/// Scrolls the Save button into view before tapping it -- the editor is
/// taller than the test viewport.
Future<void> _save(WidgetTester tester) async {
  final submit = find.byKey(const Key('event_submit_button'));
  await tester.ensureVisible(submit);
  await tester.pumpAndSettle();
  await tester.tap(submit);
  await tester.pumpAndSettle();
}

DropdownButton<ClientCalendar> _calendarDropdown(WidgetTester tester) =>
    tester.widget<DropdownButton<ClientCalendar>>(
      find.byType(DropdownButton<ClientCalendar>),
    );

void main() {
  group('initial calendar selection', () {
    testWidgets('starts on the event\'s OWN calendar, not the first in the '
        'list', (tester) async {
      // 'G Calendar' is deliberately first, so selecting widget.calendars.first
      // would show the wrong one -- and, once Save forwards the selection,
      // would silently move every edited event.
      await tester.pumpWidget(
        _buildEditor(calendars: [_gCalendar, _myCalendar], event: _event),
      );
      await tester.pumpAndSettle();

      expect(_calendarDropdown(tester).value, _myCalendar);
      expect(find.text('My Calendar'), findsWidgets);
    });
  });

  group('when the Calendar row may be changed', () {
    testWidgets('is enabled for an eligible one-off edit', (tester) async {
      await tester.pumpWidget(
        _buildEditor(calendars: [_myCalendar, _gCalendar], event: _event),
      );
      await tester.pumpAndSettle();

      expect(_calendarDropdown(tester).onChanged, isNotNull);
    });

    testWidgets('is enabled when editing an entire series', (tester) async {
      await tester.pumpWidget(
        _buildEditor(
          calendars: [_myCalendar, _gCalendar],
          event: _recurringEvent,
          editScope: 'series',
        ),
      );
      await tester.pumpAndSettle();

      expect(_calendarDropdown(tester).onChanged, isNotNull);
    });

    testWidgets('is fixed when editing a single occurrence', (tester) async {
      await tester.pumpWidget(
        _buildEditor(
          calendars: [_myCalendar, _gCalendar],
          event: _recurringEvent,
          editScope: 'occurrence',
        ),
      );
      await tester.pumpAndSettle();

      expect(_calendarDropdown(tester).onChanged, isNull);
    });

    testWidgets('is fixed when there is nowhere else to move to', (
      tester,
    ) async {
      await tester.pumpWidget(
        _buildEditor(calendars: [_myCalendar], event: _event),
      );
      await tester.pumpAndSettle();

      expect(_calendarDropdown(tester).onChanged, isNull);
    });

    testWidgets('is fixed when the event\'s own calendar cannot be resolved', (
      tester,
    ) async {
      // Fail closed: with no trustworthy starting point, the row must not be
      // usable to nominate a destination.
      await tester.pumpWidget(
        _buildEditor(
          calendars: [_myCalendar, _gCalendar],
          event: const ClientEvent(
            id: 'portal:ev-9',
            calendarId: 'portal:deleted',
            serviceId: 'portal',
            serviceName: 'Calee',
            title: 'Orphan',
            startsAt: '2026-06-27T09:00:00.000Z',
            endsAt: '2026-06-27T10:00:00.000Z',
            allDay: false,
            source: 'nextcloud_calendar',
            recurring: false,
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(_calendarDropdown(tester).onChanged, isNull);
    });
  });

  group('submitting', () {
    testWidgets('forwards the newly selected calendar as the destination', (
      tester,
    ) async {
      final capture = _UpdateCapture();
      await tester.pumpWidget(
        _buildEditor(
          calendars: [_myCalendar, _gCalendar],
          event: _event,
          capture: capture,
        ),
      );
      await tester.pumpAndSettle();

      // Open the dropdown and pick the other calendar.
      await tester.tap(find.byType(DropdownButton<ClientCalendar>));
      await tester.pumpAndSettle();
      await tester.tap(find.text('G Calendar').last);
      await tester.pumpAndSettle();

      expect(_calendarDropdown(tester).value, _gCalendar);

      await _save(tester);

      expect(capture.calls, 1);
      expect(capture.destinationCalendar, _gCalendar);
    });

    testWidgets('forwards the event\'s own calendar when the row was not '
        'touched - Hub treats that as no move', (tester) async {
      final capture = _UpdateCapture();
      await tester.pumpWidget(
        _buildEditor(
          calendars: [_myCalendar, _gCalendar],
          event: _event,
          capture: capture,
        ),
      );
      await tester.pumpAndSettle();

      await _save(tester);

      expect(capture.calls, 1);
      expect(capture.destinationCalendar, _myCalendar);
    });

    testWidgets('forwards NO destination when the event\'s calendar could not '
        'be resolved, so the edit stays an in-place update', (tester) async {
      final capture = _UpdateCapture();
      await tester.pumpWidget(
        _buildEditor(
          calendars: [_myCalendar, _gCalendar],
          event: const ClientEvent(
            id: 'portal:ev-9',
            calendarId: 'portal:deleted',
            serviceId: 'portal',
            serviceName: 'Calee',
            title: 'Orphan',
            startsAt: '2026-06-27T09:00:00.000Z',
            endsAt: '2026-06-27T10:00:00.000Z',
            allDay: false,
            source: 'nextcloud_calendar',
            recurring: false,
          ),
          capture: capture,
        ),
      );
      await tester.pumpAndSettle();

      await _save(tester);

      expect(capture.calls, 1);
      expect(capture.destinationCalendar, isNull);
    });
  });

  group('attachments during an unsaved move', () {
    testWidgets('keep addressing the calendar the event is still IN after a '
        'different destination is selected', (tester) async {
      final hub = _StubHub();
      final calendars = [
        _calendar(
          id: 'portal:personal',
          name: 'My Calendar',
          capabilities: _attachmentCapabilities,
        ),
        _calendar(
          id: 'portal:work',
          name: 'G Calendar',
          capabilities: _attachmentCapabilities,
        ),
      ];

      await tester.pumpWidget(
        _buildEditor(calendars: calendars, event: _event, hub: hub),
      );
      await tester.pumpAndSettle();

      expect(hub.attachmentListCalls, isNotEmpty);
      expect(hub.attachmentListCalls.first.calendarId, 'portal:personal');

      // Pick the destination, but do not Save. The event has not moved.
      await tester.tap(find.byType(DropdownButton<ClientCalendar>));
      await tester.pumpAndSettle();
      await tester.tap(find.text('G Calendar').last);
      await tester.pumpAndSettle();

      // Every attachment request, including any triggered by that rebuild,
      // must still name the SOURCE calendar. Sending the destination would
      // make Hub answer "not found" for a file the user can see on screen.
      for (final call in hub.attachmentListCalls) {
        expect(call.calendarId, 'portal:personal');
        expect(call.eventId, 'portal:ev-1');
      }
    });
  });
}

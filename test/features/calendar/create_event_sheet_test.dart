import 'dart:io';

import 'package:calee_mobile/data/api/calee_hub_client.dart';
import 'package:calee_mobile/data/models/client_calendar.dart';
import 'package:calee_mobile/data/models/client_event_draft.dart';
import 'package:calee_mobile/features/calendar/widgets/create_event_sheet.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

// ── Stub ──────────────────────────────────────────────────────────────────────

class _StubHub extends CaleeHubClient {
  @override
  Future<EventDraftsFromImageResponse> eventDraftsFromImage({
    required String accessToken,
    required File imageFile,
    String? timezone,
    String? referenceDate,
    String? sourceHint,
  }) async {
    return const EventDraftsFromImageResponse(drafts: []);
  }
}

// ── Fixtures ──────────────────────────────────────────────────────────────────

const _calendar = ClientCalendar(
  id: 'cal1',
  serviceId: 'svc1',
  serviceName: 'Test Service',
  name: 'Personal',
  color: '#4285F4',
  components: ['VEVENT'],
  primaryKind: 'personal',
  supportsEvents: true,
  supportsTasks: false,
  supportsChores: false,
  readOnly: false,
  isSubscription: false,
  source: 'test',
);

const _existingEvent = ClientEvent(
  id: 'evt1',
  calendarId: 'cal1',
  serviceId: 'svc1',
  serviceName: 'Test Service',
  title: 'Existing Event',
  startsAt: '2026-06-27T09:00:00.000Z',
  endsAt: '2026-06-27T10:00:00.000Z',
  allDay: false,
  source: 'test',
  recurring: false,
);

// ── Tests ──────────────────────────────────────────────────────────────────────

void main() {
  Widget buildSheet({ClientEvent? initialEvent, String? editScope}) {
    return MaterialApp(
      home: Scaffold(
        body: CreateEventSheet(
          calendars: const [_calendar],
          onCreate: ({
            required calendar,
            required title,
            required startsAt,
            required endsAt,
            required allDay,
            location,
            description,
            recurrence,
          }) async {},
          hubClient: _StubHub(),
          accessToken: 'test-token',
          initialEvent: initialEvent,
          editScope: editScope,
        ),
      ),
    );
  }

  group('CreateEventSheet', () {
    testWidgets('opens for manual event creation', (tester) async {
      await tester.pumpWidget(buildSheet());
      expect(find.byType(CreateEventSheet), findsOneWidget);
      expect(find.text('Add event'), findsOneWidget);
    });

    testWidgets('shows Scan image button in create mode', (tester) async {
      await tester.pumpWidget(buildSheet());
      expect(find.text('Scan image'), findsOneWidget);
    });

    testWidgets('does not show Scan image button in edit mode', (tester) async {
      await tester.pumpWidget(
        buildSheet(initialEvent: _existingEvent, editScope: null),
      );
      expect(find.text('Scan image'), findsNothing);
    });

    testWidgets('shows Save Event button in create mode', (tester) async {
      await tester.pumpWidget(buildSheet());
      expect(find.text('Save Event'), findsOneWidget);
    });

    testWidgets('shows update label in edit mode', (tester) async {
      await tester.pumpWidget(
        buildSheet(initialEvent: _existingEvent, editScope: null),
      );
      expect(find.text('Update Event'), findsOneWidget);
    });
  });
}

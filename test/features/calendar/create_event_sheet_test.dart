import 'dart:io';

import 'package:calee_mobile/data/api/calee_hub_client.dart';
import 'package:calee_mobile/data/models/client_calendar.dart';
import 'package:calee_mobile/data/models/client_event_draft.dart';
import 'package:calee_mobile/features/calendar/widgets/create_event_sheet.dart';
import 'package:calee_mobile/ui/calee_theme.dart';
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

// 2026-06-28 is a Sunday.
const _recurringEvent = ClientEvent(
  id: 'evt2',
  calendarId: 'cal1',
  serviceId: 'svc1',
  serviceName: 'Test Service',
  title: 'Recurring Event',
  startsAt: '2026-06-28T01:00:00.000Z',
  endsAt: '2026-06-28T02:00:00.000Z',
  allDay: false,
  source: 'test',
  recurring: true,
  recurrence: 'FREQ=WEEKLY;BYDAY=SU',
);

// ── Helpers ───────────────────────────────────────────────────────────────────

Widget _buildSheet({
  ClientEvent? initialEvent,
  String? editScope,
  DateTime? initialDate,
  void Function(String?)? onRecurrence,
  void Function(String?)? onUpdateRecurrence,
}) {
  return MaterialApp(
    theme: CaleeTheme.buildThemeData(),
    home: Scaffold(
      body: CreateEventSheet(
        calendars: const [_calendar],
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
            }) async {
              onRecurrence?.call(recurrence);
            },
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
            }) async {
              onUpdateRecurrence?.call(recurrence);
            },
        hubClient: _StubHub(),
        accessToken: 'test-token',
        initialEvent: initialEvent,
        editScope: editScope,
        initialDate: initialDate,
      ),
    ),
  );
}

Future<void> _openRepeatPicker(WidgetTester tester) async {
  final repeatRow = find.ancestor(
    of: find.text('Repeat'),
    matching: find.byType(InkWell),
  );
  await tester.tap(repeatRow.first);
  await tester.pumpAndSettle();
}

Future<void> _selectRepeat(WidgetTester tester, String label) async {
  await _openRepeatPicker(tester);
  await tester.tap(find.text(label));
  await tester.pumpAndSettle();
  await tester.tap(find.text('Done'));
  await tester.pumpAndSettle();
}

Future<void> _selectCustomRepeat(
  WidgetTester tester,
  List<String> pillLabels,
) async {
  await _openRepeatPicker(tester);
  await tester.tap(find.text('Custom days'));
  await tester.pumpAndSettle();
  for (final pill in pillLabels) {
    await tester.ensureVisible(find.text(pill));
    await tester.pumpAndSettle();
    await tester.tap(find.text(pill));
    await tester.pumpAndSettle();
  }
  await tester.ensureVisible(find.text('Done'));
  await tester.pumpAndSettle();
  await tester.tap(find.text('Done'));
  await tester.pumpAndSettle();
}

// ── Tests ──────────────────────────────────────────────────────────────────────

void main() {
  group('CreateEventSheet', () {
    testWidgets('opens for manual event creation', (tester) async {
      await tester.pumpWidget(_buildSheet());
      expect(find.byType(CreateEventSheet), findsOneWidget);
      expect(find.text('Add event'), findsOneWidget);
    });

    testWidgets('shows Scan image button in create mode', (tester) async {
      await tester.pumpWidget(_buildSheet());
      expect(find.text('Scan image'), findsOneWidget);
    });

    testWidgets('does not show Scan image button in edit mode', (tester) async {
      await tester.pumpWidget(
        _buildSheet(initialEvent: _existingEvent, editScope: null),
      );
      expect(find.text('Scan image'), findsNothing);
    });

    testWidgets('shows Save Event button in create mode', (tester) async {
      await tester.pumpWidget(_buildSheet());
      expect(find.text('Save Event'), findsOneWidget);
    });

    testWidgets('shows update label in edit mode', (tester) async {
      await tester.pumpWidget(
        _buildSheet(initialEvent: _existingEvent, editScope: null),
      );
      expect(find.text('Update Event'), findsOneWidget);
    });
  });

  group('event recurrence', () {
    testWidgets('create weekdays sends FREQ=WEEKLY;BYDAY=MO,TU,WE,TH,FR', (
      tester,
    ) async {
      String? captured;
      await tester.pumpWidget(_buildSheet(onRecurrence: (r) => captured = r));

      await tester.enterText(find.byType(TextFormField).first, 'Test Event');
      await tester.pumpAndSettle();

      await _selectRepeat(tester, 'Weekdays');

      await tester.ensureVisible(find.text('Save Event'));
      await tester.tap(find.text('Save Event'));
      await tester.pumpAndSettle();

      expect(captured, 'FREQ=WEEKLY;BYDAY=MO,TU,WE,TH,FR');
    });

    // 2026-06-28 is a Sunday.
    testWidgets(
      'create starting Sunday with weekly sends FREQ=WEEKLY;BYDAY=SU',
      (tester) async {
        String? captured;
        await tester.pumpWidget(
          _buildSheet(
            initialDate: DateTime(2026, 6, 28),
            onRecurrence: (r) => captured = r,
          ),
        );

        await tester.enterText(find.byType(TextFormField).first, 'Test Event');
        await tester.pumpAndSettle();

        await _selectRepeat(tester, 'Every Sunday');

        await tester.ensureVisible(find.text('Save Event'));
        await tester.tap(find.text('Save Event'));
        await tester.pumpAndSettle();

        expect(captured, 'FREQ=WEEKLY;BYDAY=SU');
      },
    );

    testWidgets(
      'create starting Sunday with fortnightly sends FREQ=WEEKLY;INTERVAL=2;BYDAY=SU',
      (tester) async {
        String? captured;
        await tester.pumpWidget(
          _buildSheet(
            initialDate: DateTime(2026, 6, 28),
            onRecurrence: (r) => captured = r,
          ),
        );

        await tester.enterText(find.byType(TextFormField).first, 'Test Event');
        await tester.pumpAndSettle();

        await _selectRepeat(tester, 'Every 2 weeks on Sunday');

        await tester.ensureVisible(find.text('Save Event'));
        await tester.tap(find.text('Save Event'));
        await tester.pumpAndSettle();

        expect(captured, 'FREQ=WEEKLY;INTERVAL=2;BYDAY=SU');
      },
    );

    testWidgets('custom Mon/Wed/Fri sends FREQ=WEEKLY;BYDAY=MO,WE,FR', (
      tester,
    ) async {
      String? captured;
      await tester.pumpWidget(_buildSheet(onRecurrence: (r) => captured = r));

      await tester.enterText(find.byType(TextFormField).first, 'Test Event');
      await tester.pumpAndSettle();

      await _selectCustomRepeat(tester, ['Mon', 'Wed', 'Fri']);

      await tester.ensureVisible(find.text('Save Event'));
      await tester.tap(find.text('Save Event'));
      await tester.pumpAndSettle();

      expect(captured, 'FREQ=WEEKLY;BYDAY=MO,WE,FR');
    });

    testWidgets('edit all events can clear recurrence', (tester) async {
      String? captured;
      var called = false;
      await tester.pumpWidget(
        _buildSheet(
          initialEvent: _recurringEvent,
          editScope: 'series',
          onUpdateRecurrence: (r) {
            captured = r;
            called = true;
          },
        ),
      );

      // Repeat picker row is visible for series editing.
      expect(find.text('Repeat'), findsOneWidget);

      await _selectRepeat(tester, 'Does not repeat');

      await tester.ensureVisible(find.text('Update Series'));
      await tester.tap(find.text('Update Series'));
      await tester.pumpAndSettle();

      expect(called, isTrue);
      expect(captured, isNull);
    });

    testWidgets('this event only hides repeat and sends null recurrence', (
      tester,
    ) async {
      String? captured;
      var called = false;
      await tester.pumpWidget(
        _buildSheet(
          initialEvent: _recurringEvent,
          editScope: 'occurrence',
          onUpdateRecurrence: (r) {
            captured = r;
            called = true;
          },
        ),
      );

      // Repeat section is hidden for single-occurrence editing.
      expect(find.text('Repeat'), findsNothing);

      await tester.ensureVisible(find.text('Update Event'));
      await tester.tap(find.text('Update Event'));
      await tester.pumpAndSettle();

      expect(called, isTrue);
      expect(captured, isNull);
    });
  });
}

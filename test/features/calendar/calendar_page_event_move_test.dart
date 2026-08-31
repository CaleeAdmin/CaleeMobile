// The calendar screen hands the editor every calendar an event can be moved
// to.
//
// Before this, editing passed `calendars: [calendar]` -- the ONE calendar the
// event was already in -- so even an enabled Calendar row would have had
// nothing to choose. This drives the real screen: tap the event, tap Edit
// Event, and inspect the editor the page actually built.

import 'package:calee_mobile/data/api/calee_hub_client.dart';
import 'package:calee_mobile/data/models/client_bootstrap.dart';
import 'package:calee_mobile/data/models/client_calendar.dart';
import 'package:calee_mobile/features/calendar/calendar_page.dart';
import 'package:calee_mobile/features/calendar/shared/read_only_calendar_view.dart';
import 'package:calee_mobile/features/calendar/widgets/create_event_sheet.dart';
import 'package:calee_mobile/ui/calee_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

// ── Stub ──────────────────────────────────────────────────────────────────────

class _StubHub extends CaleeHubClient {
  _StubHub({required this.calendarsPayload, required this.eventsPayload})
    : super();

  final List<ClientCalendar> calendarsPayload;
  final List<ClientEvent> eventsPayload;

  @override
  Future<ClientCalendarList> calendars({required String accessToken}) async =>
      ClientCalendarList(calendars: List.of(calendarsPayload));

  @override
  Future<ClientEventList> events({
    required String accessToken,
    required String from,
    required String to,
  }) async =>
      ClientEventList(from: from, to: to, events: List.of(eventsPayload));

  @override
  Future<List<CalendarAttachment>> listAttachments({
    required String accessToken,
    required String eventId,
    String? calendarId,
  }) async => const [];
}

// ── Fixtures ──────────────────────────────────────────────────────────────────

const _service = ClientService(
  id: 'portal',
  displayName: 'Portal',
  baseUrl: 'http://localhost',
  launchUrl: 'http://localhost',
  serviceType: 'nextcloud',
  accessStatus: 'ok',
  calendarCredentialStatus: 'connected',
  source: 'test',
  capabilities: {'calendar': true, 'tasks': false, 'chores': false},
);

ClientCalendar _calendar({
  required String id,
  required String name,
  String serviceId = 'portal',
  bool readOnly = false,
  bool isSubscription = false,
  String primaryKind = 'calendar',
  String source = 'nextcloud',
}) => ClientCalendar(
  id: id,
  serviceId: serviceId,
  serviceName: 'Portal',
  name: name,
  components: const [],
  primaryKind: primaryKind,
  supportsEvents: true,
  supportsTasks: false,
  supportsChores: false,
  readOnly: readOnly,
  isSubscription: isSubscription,
  source: source,
);

final _calendars = [
  _calendar(id: 'portal:family', name: 'My Calendar'),
  _calendar(id: 'portal:work', name: 'G Calendar'),
  _calendar(id: 'portal:shared', name: 'Shared', readOnly: true),
  _calendar(
    id: 'portal:feed',
    name: 'School Feed',
    readOnly: true,
    isSubscription: true,
  ),
  _calendar(
    id: 'external:google-1',
    serviceId: 'external',
    name: 'Work (Google)',
    readOnly: true,
    source: 'external',
  ),
  _calendar(id: 'business:ops', serviceId: 'business', name: 'Ops'),
];

const _schoolNote = ClientEvent(
  id: 'evt-1',
  calendarId: 'portal:family',
  serviceId: 'portal',
  serviceName: 'Portal',
  title: 'School note',
  startsAt: '2026-08-21T13:00:00',
  endsAt: '2026-08-21T14:00:00',
  allDay: false,
  source: 'portal',
  recurring: false,
);

// ── Harness ───────────────────────────────────────────────────────────────────

Future<void> _pumpCalendar(WidgetTester tester, _StubHub hub) async {
  await tester.pumpWidget(
    MaterialApp(
      theme: CaleeTheme.buildThemeData(),
      home: Builder(
        builder: (context) => MediaQuery(
          data: MediaQuery.of(context).copyWith(alwaysUse24HourFormat: true),
          child: CalendarPage(
            hubClient: hub,
            accessToken: 'tok',
            services: const [_service],
            accountId: 'acct1',
            isFamilyUxContext: true,
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

Future<void> _openEditor(WidgetTester tester) async {
  final local = DateTime.parse('2026-08-21T13:00:00').toLocal();
  tester
      .widget<ReadOnlyCalendarView>(find.byType(ReadOnlyCalendarView))
      .onSelectDay(DateTime(local.year, local.month, local.day));
  await tester.pumpAndSettle();

  await tester.tap(find.text('School note').first);
  await tester.pumpAndSettle();

  await tester.tap(find.text('Edit Event'));
  await tester.pumpAndSettle();
}

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

  testWidgets('the editor is given every eligible destination, not just the '
      'calendar the event is in', (tester) async {
    await _pumpCalendar(
      tester,
      _StubHub(
        calendarsPayload: _calendars,
        eventsPayload: const [_schoolNote],
      ),
    );
    await _openEditor(tester);

    final sheet = tester.widget<CreateEventSheet>(
      find.byType(CreateEventSheet),
    );

    expect(sheet.calendars.map((c) => c.id), ['portal:family', 'portal:work']);
  });

  testWidgets('the editor opens on the calendar the event is actually in', (
    tester,
  ) async {
    await _pumpCalendar(
      tester,
      _StubHub(
        calendarsPayload: _calendars,
        eventsPayload: const [_schoolNote],
      ),
    );
    await _openEditor(tester);

    final dropdown = tester.widget<DropdownButton<ClientCalendar>>(
      find.byType(DropdownButton<ClientCalendar>),
    );
    expect(dropdown.value?.id, 'portal:family');
    expect(dropdown.onChanged, isNotNull);
  });

  testWidgets('an event whose only same-service calendar is its own gets that '
      'one calendar and a fixed row', (tester) async {
    await _pumpCalendar(
      tester,
      _StubHub(
        calendarsPayload: [
          _calendar(id: 'portal:family', name: 'My Calendar'),
          _calendar(id: 'portal:shared', name: 'Shared', readOnly: true),
        ],
        eventsPayload: const [_schoolNote],
      ),
    );
    await _openEditor(tester);

    final sheet = tester.widget<CreateEventSheet>(
      find.byType(CreateEventSheet),
    );
    expect(sheet.calendars.map((c) => c.id), ['portal:family']);

    final dropdown = tester.widget<DropdownButton<ClientCalendar>>(
      find.byType(DropdownButton<ClientCalendar>),
    );
    expect(dropdown.onChanged, isNull);
  });
}

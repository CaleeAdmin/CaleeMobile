// The signed-in event-details contract (CaleeAdmin/CaleeMobile#566).
//
// One product invariant runs through every test here:
//
//   tapping ANY calendar event opens details for the EXACT logical event that
//   was tapped, and the actions offered are derived INDEPENDENTLY from that
//   event's own source, permission and publication state.
//
// The tests are deliberately written against the behaviour a user can see —
// the strings on the sheet and the actions on it — rather than against the
// widget that happens to render them. That is what lets them fail on `dev`
// (where a writable tap opens an Edit/Delete action sheet with no details at
// all, and a Google tap opens guidance copy) and pass afterwards without
// being rewritten around the new implementation.
//
// Sharing lifecycle (double tap, mint failure, iPad anchor) is NOT retested
// here: it is owned by calendar_page_signed_in_share_test.dart and must stay
// exactly as green as it already is.

import 'package:calee_mobile/data/api/calee_hub_client.dart';
import 'package:calee_mobile/data/models/client_bootstrap.dart';
import 'package:calee_mobile/data/models/client_calendar.dart';
import 'package:calee_mobile/features/calendar/calendar_page.dart';
import 'package:calee_mobile/features/calendar/shared/read_only_calendar_view.dart';
import 'package:calee_mobile/features/calendar/widgets/create_event_sheet.dart';
import 'package:calee_mobile/features/local_subscriber/calee_public_calendar_source.dart';
import 'package:calee_mobile/features/local_subscriber/local_event_link_service.dart';
import 'package:calee_mobile/features/local_subscriber/local_event_share_launcher.dart';
import 'package:calee_mobile/ui/calee_design.dart';
import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

// ── Stubs ───────────────────────────────────────────────────────────────────

class _StubHub extends CaleeHubClient {
  _StubHub({this.calendarsPayload = const [], this.eventsPayload = const []})
    : super();

  List<ClientCalendar> calendarsPayload;
  List<ClientEvent> eventsPayload;

  @override
  Future<ClientCalendarList> calendars({required String accessToken}) async =>
      ClientCalendarList(
        calendars: List<ClientCalendar>.from(calendarsPayload),
      );

  @override
  Future<ClientEventList> events({
    required String accessToken,
    required String from,
    required String to,
  }) async => ClientEventList(
    from: from,
    to: to,
    events: List<ClientEvent>.from(eventsPayload),
  );
}

class _MintCall {
  const _MintCall({required this.source, required this.uid, this.occurrenceId});

  final CaleePublicCalendarSource source;
  final String uid;
  final String? occurrenceId;
}

class _FakeEventLinkService implements LocalEventLinkService {
  final List<_MintCall> calls = [];

  @override
  Future<Uri> mint({
    required CaleePublicCalendarSource source,
    required String uid,
    String? occurrenceId,
  }) async {
    calls.add(_MintCall(source: source, uid: uid, occurrenceId: occurrenceId));
    return Uri.parse('https://calembed.calee.com.au/e/1.eyJhIjoxfQ.c2ln');
  }
}

class _FakeShareLauncher implements LocalEventShareLauncher {
  final List<Uri> urls = [];

  @override
  Future<void> share({
    required Uri url,
    required String title,
    required Rect sharePositionOrigin,
  }) async {
    urls.add(url);
  }
}

// ── Fixtures ────────────────────────────────────────────────────────────────

const String _kPublicUrl =
    'https://portal.calee.com.au/remote.php/dav/public-calendars/abcdefgh?export';

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

/// Private, writable, not published. Edit/Delete yes, Share never.
const _familyCalendar = ClientCalendar(
  id: 'portal:family',
  serviceId: 'portal',
  serviceName: 'Portal',
  name: 'Family',
  components: [],
  primaryKind: 'calendar',
  supportsEvents: true,
  supportsTasks: false,
  supportsChores: false,
  readOnly: false,
  isSubscription: false,
  source: 'nextcloud',
);

/// Already-public Calee subscription, read-only. Share yes, mutation no.
const _publicReadOnlyCalendar = ClientCalendar(
  id: 'portal:lazers',
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
  subscriptionUrl: _kPublicUrl,
  source: 'portal',
);

/// The combination `dev` cannot express: already-public AND writable.
/// Edit/Delete AND Share must both be offered.
const _publicWritableCalendar = ClientCalendar(
  id: 'portal:club-admin',
  serviceId: 'portal',
  serviceName: 'Portal',
  name: 'Club Admin',
  components: [],
  primaryKind: 'calendar',
  supportsEvents: true,
  supportsTasks: false,
  supportsChores: false,
  readOnly: false,
  isSubscription: true,
  subscriptionUrl: _kPublicUrl,
  source: 'portal',
);

const _googleCalendar = ClientCalendar(
  id: 'external:google-1',
  serviceId: 'external',
  serviceName: 'Google',
  name: 'Work (Google)',
  components: [],
  primaryKind: 'calendar',
  supportsEvents: true,
  supportsTasks: false,
  supportsChores: false,
  readOnly: true,
  isSubscription: false,
  source: 'external',
  providerKey: 'google_calendar',
);

const _privateIcsCalendar = ClientCalendar(
  id: 'portal:private-ics',
  serviceId: 'portal',
  serviceName: 'Portal',
  name: 'School Newsletter',
  components: [],
  primaryKind: 'calendar',
  supportsEvents: true,
  supportsTasks: false,
  supportsChores: false,
  readOnly: true,
  isSubscription: true,
  subscriptionUrl: 'https://school.example.com/private/feed.ics',
  source: 'portal',
);

ClientEvent _event({
  required String calendarId,
  String id = 'evt-1',
  String title = 'Training',
  String? sourceUid = 'event-uid-1',
  String? canonicalRecurrenceId,
  bool recurring = false,
  bool readOnly = true,
  bool allDay = false,
  String startsAt = '2026-08-21T13:00:00',
  String endsAt = '2026-08-21T14:00:00',
  String source = 'portal',
  String serviceId = 'portal',
  String? providerKey,
  String? seriesId,
  String? location,
  String? description,
}) => ClientEvent(
  id: id,
  calendarId: calendarId,
  serviceId: serviceId,
  serviceName: 'Portal',
  title: title,
  startsAt: startsAt,
  endsAt: endsAt,
  allDay: allDay,
  location: location,
  description: description,
  source: source,
  recurring: recurring,
  seriesId: seriesId,
  sourceUid: sourceUid,
  canonicalRecurrenceId: canonicalRecurrenceId,
  providerKey: providerKey,
  readOnly: readOnly,
);

// ── Harness ─────────────────────────────────────────────────────────────────

Future<void> _pumpCalendar(
  WidgetTester tester, {
  required _StubHub hub,
  _FakeEventLinkService? linkService,
  _FakeShareLauncher? shareLauncher,
  bool use24h = true,
  TextScaler textScaler = TextScaler.noScaling,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      theme: CaleeTheme.buildThemeData(),
      home: Builder(
        builder: (context) => MediaQuery(
          data: MediaQuery.of(
            context,
          ).copyWith(alwaysUse24HourFormat: use24h, textScaler: textScaler),
          child: CalendarPage(
            hubClient: hub,
            accessToken: 'tok',
            services: const [_service],
            accountId: 'acct1',
            isFamilyUxContext: true,
            eventLinkService: linkService,
            shareLauncher: shareLauncher,
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

/// Selects the local day [localIso] falls on, so its row is in the agenda.
Future<void> _selectDay(WidgetTester tester, String localIso) async {
  final local = DateTime.parse(localIso).toLocal();
  tester
      .widget<ReadOnlyCalendarView>(find.byType(ReadOnlyCalendarView))
      .onSelectDay(DateTime(local.year, local.month, local.day));
  await tester.pumpAndSettle();
}

Future<void> _tapEvent(WidgetTester tester, String title) async {
  final row = find.text(title);
  expect(row, findsWidgets, reason: 'the "$title" row is on screen');
  await tester.tap(row.first);
  await tester.pumpAndSettle();
}

/// The default day every fixture event above starts on.
Future<void> _selectDefaultDay(WidgetTester tester) =>
    _selectDay(tester, '2026-08-21T13:00:00');

/// True when the details surface is open, decided by a fact ONLY details
/// shows: the full date of the event. An Edit/Delete action sheet and a
/// read-only guidance sheet both show a title and neither shows this.
Matcher get _detailsIsOpen => findsOneWidget;
Finder _detailsDate(String label) => find.text(label);

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

  // ── A. Details open FIRST, for every kind of event ────────────────────────

  group('A — every tap opens details first', () {
    testWidgets('a writable one-off shows full details AND Edit/Delete', (
      tester,
    ) async {
      final hub = _StubHub(
        calendarsPayload: const [_familyCalendar],
        eventsPayload: [
          _event(
            calendarId: 'portal:family',
            title: 'Dentist',
            readOnly: false,
            source: 'nextcloud',
            location: 'Level 2, 14 Main Street',
            description: 'Bring the referral letter.',
          ),
        ],
      );

      await _pumpCalendar(tester, hub: hub);
      await _selectDefaultDay(tester);
      await _tapEvent(tester, 'Dentist');

      // Details, not the bare action sheet: the date, the time, the calendar,
      // the location and the description are all on screen.
      expect(_detailsDate('Friday 21 August 2026'), _detailsIsOpen);
      expect(find.text('13:00–14:00'), findsWidgets);
      expect(find.text('Family'), findsWidgets);
      expect(find.text('Level 2, 14 Main Street'), findsWidgets);
      expect(find.text('Bring the referral letter.'), findsOneWidget);

      // And the actions the user already had.
      expect(find.text('Edit Event'), findsOneWidget);
      expect(find.text('Delete Event'), findsOneWidget);
      // A private family event is not public, whatever else is true of it.
      expect(find.text('Share event'), findsNothing);
    });

    testWidgets('a writable recurring event shows details, then the EXISTING '
        'occurrence/series Edit chooser', (tester) async {
      final hub = _StubHub(
        calendarsPayload: const [_familyCalendar],
        eventsPayload: [
          _event(
            calendarId: 'portal:family',
            title: 'Swimming',
            readOnly: false,
            source: 'nextcloud',
            recurring: true,
            seriesId: 'portal:family:series-1',
          ),
        ],
      );

      await _pumpCalendar(tester, hub: hub);
      await _selectDefaultDay(tester);
      await _tapEvent(tester, 'Swimming');

      expect(_detailsDate('Friday 21 August 2026'), _detailsIsOpen);
      expect(find.text('Edit…'), findsOneWidget);

      await tester.tap(find.text('Edit…'));
      await tester.pumpAndSettle();

      // The existing chooser, unchanged and NOT reimplemented in details.
      expect(find.text('Edit This Event'), findsOneWidget);
      expect(find.text('Edit Entire Series'), findsOneWidget);
    });

    testWidgets('a writable recurring event reaches the EXISTING Delete '
        'occurrence/series chooser', (tester) async {
      final hub = _StubHub(
        calendarsPayload: const [_familyCalendar],
        eventsPayload: [
          _event(
            calendarId: 'portal:family',
            title: 'Swimming',
            readOnly: false,
            source: 'nextcloud',
            recurring: true,
            seriesId: 'portal:family:series-1',
          ),
        ],
      );

      await _pumpCalendar(tester, hub: hub);
      await _selectDefaultDay(tester);
      await _tapEvent(tester, 'Swimming');

      expect(find.text('Delete…'), findsOneWidget);
      await tester.tap(find.text('Delete…'));
      await tester.pumpAndSettle();

      expect(find.text('Delete This Event'), findsOneWidget);
      expect(find.text('Delete Entire Series'), findsOneWidget);
    });
  });

  // ── B. Editability and shareability are INDEPENDENT ───────────────────────

  group('B — the capability matrix', () {
    testWidgets('1. private writable family: details, Edit, Delete, no Share', (
      tester,
    ) async {
      final link = _FakeEventLinkService();
      final hub = _StubHub(
        calendarsPayload: const [_familyCalendar],
        eventsPayload: [
          _event(
            calendarId: 'portal:family',
            title: 'Dentist',
            readOnly: false,
            source: 'nextcloud',
          ),
        ],
      );

      await _pumpCalendar(tester, hub: hub, linkService: link);
      await _selectDefaultDay(tester);
      await _tapEvent(tester, 'Dentist');

      expect(_detailsDate('Friday 21 August 2026'), _detailsIsOpen);
      expect(find.text('Edit Event'), findsOneWidget);
      expect(find.text('Delete Event'), findsOneWidget);
      expect(find.text('Share event'), findsNothing);
      expect(link.calls, isEmpty);
    });

    testWidgets(
      '2. PUBLIC WRITABLE Calee event offers Edit, Delete AND Share',
      (tester) async {
        final link = _FakeEventLinkService();
        final launcher = _FakeShareLauncher();
        final hub = _StubHub(
          calendarsPayload: const [_publicWritableCalendar],
          eventsPayload: [
            _event(
              calendarId: 'portal:club-admin',
              title: 'Committee Meeting',
              readOnly: false,
              source: 'nextcloud',
              sourceUid: 'committee-uid',
            ),
          ],
        );

        await _pumpCalendar(
          tester,
          hub: hub,
          linkService: link,
          shareLauncher: launcher,
        );
        await _selectDefaultDay(tester);
        await _tapEvent(tester, 'Committee Meeting');

        expect(_detailsDate('Friday 21 August 2026'), _detailsIsOpen);
        // Writable AND published: neither capability suppresses the other.
        expect(find.text('Edit Event'), findsOneWidget);
        expect(find.text('Delete Event'), findsOneWidget);
        expect(find.text('Share event'), findsOneWidget);

        await tester.tap(find.text('Share event'));
        await tester.pumpAndSettle();

        expect(link.calls, hasLength(1));
        expect(link.calls.single.source.canonicalUrl, _kPublicUrl);
        expect(link.calls.single.uid, 'committee-uid');
        expect(launcher.urls, hasLength(1));
      },
    );

    testWidgets('3. public read-only subscription: details + Share, no '
        'mutation', (tester) async {
      final link = _FakeEventLinkService();
      final hub = _StubHub(
        calendarsPayload: const [_publicReadOnlyCalendar],
        eventsPayload: [_event(calendarId: 'portal:lazers')],
      );

      await _pumpCalendar(tester, hub: hub, linkService: link);
      await _selectDefaultDay(tester);
      await _tapEvent(tester, 'Training');

      expect(_detailsDate('Friday 21 August 2026'), _detailsIsOpen);
      expect(find.text('Share event'), findsOneWidget);
      expect(find.text('Edit Event'), findsNothing);
      expect(find.text('Delete Event'), findsNothing);
    });

    testWidgets('4. public recurring occurrence with NO canonical recurrence '
        'identity: details, no Share', (tester) async {
      final link = _FakeEventLinkService();
      final hub = _StubHub(
        calendarsPayload: const [_publicReadOnlyCalendar],
        eventsPayload: [
          _event(
            calendarId: 'portal:lazers',
            recurring: true,
            canonicalRecurrenceId: null,
          ),
        ],
      );

      await _pumpCalendar(tester, hub: hub, linkService: link);
      await _selectDefaultDay(tester);
      await _tapEvent(tester, 'Training');

      expect(_detailsDate('Friday 21 August 2026'), _detailsIsOpen);
      expect(find.text('Share event'), findsNothing);
      expect(find.textContaining("Sharing isn't available"), findsOneWidget);
      expect(link.calls, isEmpty);
    });

    testWidgets('5. Google: details, no Edit/Delete/Share', (tester) async {
      final link = _FakeEventLinkService();
      final hub = _StubHub(
        calendarsPayload: const [_googleCalendar],
        eventsPayload: [
          _event(
            calendarId: 'external:google-1',
            source: 'external',
            serviceId: 'external',
            providerKey: 'google_calendar',
            location: 'Meeting Room 3',
          ),
        ],
      );

      await _pumpCalendar(tester, hub: hub, linkService: link);
      await _selectDefaultDay(tester);
      await _tapEvent(tester, 'Training');

      expect(_detailsDate('Friday 21 August 2026'), _detailsIsOpen);
      expect(find.text('Meeting Room 3'), findsWidgets);
      expect(find.text('Edit Event'), findsNothing);
      expect(find.text('Delete Event'), findsNothing);
      expect(find.text('Share event'), findsNothing);
      expect(link.calls, isEmpty);
    });

    testWidgets('6. arbitrary private ICS: details, no Edit/Delete/Share', (
      tester,
    ) async {
      final link = _FakeEventLinkService();
      final hub = _StubHub(
        calendarsPayload: const [_privateIcsCalendar],
        eventsPayload: [_event(calendarId: 'portal:private-ics')],
      );

      await _pumpCalendar(tester, hub: hub, linkService: link);
      await _selectDefaultDay(tester);
      await _tapEvent(tester, 'Training');

      expect(_detailsDate('Friday 21 August 2026'), _detailsIsOpen);
      expect(find.text('Edit Event'), findsNothing);
      expect(find.text('Delete Event'), findsNothing);
      expect(find.text('Share event'), findsNothing);
      expect(link.calls, isEmpty);
    });

    testWidgets('7. unknown calendar mapping: details, and everything else '
        'fails closed', (tester) async {
      final link = _FakeEventLinkService();
      final hub = _StubHub(
        // No calendar row matches the event's calendarId at all.
        calendarsPayload: const [],
        eventsPayload: [
          _event(
            calendarId: 'portal:vanished',
            title: 'Orphan',
            readOnly: false,
          ),
        ],
      );

      await _pumpCalendar(tester, hub: hub, linkService: link);
      await _selectDefaultDay(tester);
      await _tapEvent(tester, 'Orphan');

      // Silently doing nothing is the defect; details still open.
      expect(_detailsDate('Friday 21 August 2026'), _detailsIsOpen);
      expect(find.text('Edit Event'), findsNothing);
      expect(find.text('Delete Event'), findsNothing);
      expect(find.text('Share event'), findsNothing);
      expect(link.calls, isEmpty);
    });
  });

  // ── D. Search resolves to the EXACT event ─────────────────────────────────

  group('D — search parity', () {
    testWidgets('tapping a search result closes Search, selects the date and '
        'opens details for THAT event', (tester) async {
      final hub = _StubHub(
        calendarsPayload: const [_familyCalendar],
        eventsPayload: [
          _event(
            calendarId: 'portal:family',
            title: 'Dentist',
            readOnly: false,
            source: 'nextcloud',
          ),
        ],
      );

      await _pumpCalendar(tester, hub: hub);

      await tester.tap(find.byKey(const Key('calendar_search_button')));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), 'Dentist');
      await tester.pumpAndSettle();

      // The result row inside the Search sheet.
      await tester.tap(find.text('Dentist').last);
      await tester.pumpAndSettle();

      // Search closed…
      expect(find.text('Search Events'), findsNothing);
      // …the day was selected…
      final view = tester.widget<ReadOnlyCalendarView>(
        find.byType(ReadOnlyCalendarView),
      );
      expect(view.selectedDay, DateTime(2026, 8, 21));
      // …and details opened for the exact event that was tapped.
      expect(_detailsDate('Friday 21 August 2026'), _detailsIsOpen);
      expect(find.text('Edit Event'), findsOneWidget);
    });

    testWidgets('a search result whose legacy id COLLIDES still opens its own '
        'event', (tester) async {
      // The id is the thing a re-lookup would use, so two events sharing one
      // is the case that tells them apart. Search hands back the exact
      // ClientEvent; anything that went looking for `event.id` again could
      // resolve either row.
      const collidingId = 'portal:family:collision';
      final hub = _StubHub(
        calendarsPayload: const [_familyCalendar],
        eventsPayload: [
          _event(
            calendarId: 'portal:family',
            id: collidingId,
            title: 'Dentist Morning',
            readOnly: false,
            source: 'nextcloud',
            location: 'Surgery',
            startsAt: '2026-08-21T09:00:00',
            endsAt: '2026-08-21T10:00:00',
          ),
          _event(
            calendarId: 'portal:family',
            id: collidingId,
            title: 'Dentist Afternoon',
            readOnly: false,
            source: 'nextcloud',
            location: 'Other Surgery',
            startsAt: '2026-08-21T16:00:00',
            endsAt: '2026-08-21T17:00:00',
          ),
        ],
      );

      await _pumpCalendar(tester, hub: hub);

      await tester.tap(find.byKey(const Key('calendar_search_button')));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), 'Dentist Afternoon');
      await tester.pumpAndSettle();
      await tester.tap(find.text('Dentist Afternoon').last);
      await tester.pumpAndSettle();

      expect(_detailsDate('Friday 21 August 2026'), _detailsIsOpen);
      expect(find.text('16:00–17:00'), findsWidgets);
      expect(find.text('Other Surgery'), findsWidgets);
      expect(find.text('Surgery'), findsNothing);
    });
  });

  // ── E. Legacy composite-id collisions ─────────────────────────────────────

  group('E — colliding legacy ids', () {
    testWidgets('two events sharing one Hub id each open THEIR OWN details', (
      tester,
    ) async {
      const collidingId = 'portal:family:collision';
      final hub = _StubHub(
        calendarsPayload: const [_familyCalendar],
        eventsPayload: [
          _event(
            calendarId: 'portal:family',
            id: collidingId,
            title: 'Dentist',
            readOnly: false,
            source: 'nextcloud',
            location: 'Surgery',
            startsAt: '2026-08-21T13:00:00',
            endsAt: '2026-08-21T14:00:00',
          ),
          _event(
            calendarId: 'portal:family',
            id: collidingId,
            title: 'Soccer',
            readOnly: false,
            source: 'nextcloud',
            location: 'Oval',
            startsAt: '2026-08-21T16:00:00',
            endsAt: '2026-08-21T17:00:00',
          ),
        ],
      );

      await _pumpCalendar(tester, hub: hub);
      await _selectDefaultDay(tester);

      await _tapEvent(tester, 'Soccer');
      expect(find.text('16:00–17:00'), findsWidgets);
      expect(find.text('Oval'), findsWidgets);
      expect(find.text('Surgery'), findsNothing);

      await tester.tapAt(const Offset(20, 20));
      await tester.pumpAndSettle();

      await _tapEvent(tester, 'Dentist');
      expect(find.text('13:00–14:00'), findsWidgets);
      expect(find.text('Surgery'), findsWidgets);
    });
  });

  // ── F. Multi-day / date semantics ─────────────────────────────────────────

  group('F — date and time semantics', () {
    testWidgets('one-day all-day shows one date and "All day"', (tester) async {
      final hub = _StubHub(
        calendarsPayload: const [_familyCalendar],
        eventsPayload: [
          _event(
            calendarId: 'portal:family',
            title: 'Public Holiday',
            readOnly: false,
            source: 'nextcloud',
            allDay: true,
            startsAt: '2026-08-21',
            endsAt: '2026-08-22',
          ),
        ],
      );

      await _pumpCalendar(tester, hub: hub);
      await _selectDay(tester, '2026-08-21T00:00:00');
      await _tapEvent(tester, 'Public Holiday');

      expect(find.text('Friday 21 August 2026'), findsOneWidget);
      expect(find.text('All day'), findsWidgets);
    });

    testWidgets('multi-day all-day shows the INCLUSIVE range even though the '
        'transport end is exclusive', (tester) async {
      final hub = _StubHub(
        calendarsPayload: const [_familyCalendar],
        eventsPayload: [
          _event(
            calendarId: 'portal:family',
            title: 'Camp',
            readOnly: false,
            source: 'nextcloud',
            allDay: true,
            // Friday to Sunday; the wire carries the exclusive Monday.
            startsAt: '2026-08-21',
            endsAt: '2026-08-24',
          ),
        ],
      );

      await _pumpCalendar(tester, hub: hub);
      await _selectDay(tester, '2026-08-21T00:00:00');
      await _tapEvent(tester, 'Camp');

      expect(
        find.text('Friday 21 August 2026 – Sunday 23 August 2026'),
        findsOneWidget,
      );
      // Never the exclusive Monday.
      expect(find.textContaining('24 August'), findsNothing);
      expect(find.text('All day'), findsWidgets);
    });

    testWidgets('a same-day timed event shows one date and a start/end time', (
      tester,
    ) async {
      final hub = _StubHub(
        calendarsPayload: const [_familyCalendar],
        eventsPayload: [
          _event(
            calendarId: 'portal:family',
            title: 'Dentist',
            readOnly: false,
            source: 'nextcloud',
          ),
        ],
      );

      await _pumpCalendar(tester, hub: hub);
      await _selectDefaultDay(tester);
      await _tapEvent(tester, 'Dentist');

      expect(find.text('Friday 21 August 2026'), findsOneWidget);
      expect(find.text('13:00–14:00'), findsWidgets);
    });

    testWidgets('a timed event crossing midnight represents BOTH dates', (
      tester,
    ) async {
      final hub = _StubHub(
        calendarsPayload: const [_familyCalendar],
        eventsPayload: [
          _event(
            calendarId: 'portal:family',
            title: 'Night Shift',
            readOnly: false,
            source: 'nextcloud',
            startsAt: '2026-08-21T23:00:00',
            endsAt: '2026-08-22T01:00:00',
          ),
        ],
      );

      await _pumpCalendar(tester, hub: hub);
      await _selectDay(tester, '2026-08-21T23:00:00');
      await _tapEvent(tester, 'Night Shift');

      expect(
        find.text('Friday 21 August 2026 – Saturday 22 August 2026'),
        findsOneWidget,
      );
      expect(find.text('23:00–01:00'), findsWidgets);
    });

    testWidgets('12-hour display uses the 12-hour clock', (tester) async {
      final hub = _StubHub(
        calendarsPayload: const [_familyCalendar],
        eventsPayload: [
          _event(
            calendarId: 'portal:family',
            title: 'Dentist',
            readOnly: false,
            source: 'nextcloud',
            startsAt: '2026-08-21T13:30:00',
            endsAt: '2026-08-21T14:00:00',
          ),
        ],
      );

      await _pumpCalendar(tester, hub: hub, use24h: false);
      await _selectDefaultDay(tester);
      await _tapEvent(tester, 'Dentist');

      expect(find.text('1:30 PM–2 PM'), findsWidgets);
    });
  });

  // ── G. Google copy is truthful ────────────────────────────────────────────

  group('G — Google copy', () {
    testWidgets('says read-only in Calee and never offers to edit in Google', (
      tester,
    ) async {
      final hub = _StubHub(
        calendarsPayload: const [_googleCalendar],
        eventsPayload: [
          _event(
            calendarId: 'external:google-1',
            source: 'external',
            serviceId: 'external',
            providerKey: 'google_calendar',
          ),
        ],
      );

      await _pumpCalendar(tester, hub: hub);
      await _selectDefaultDay(tester);
      await _tapEvent(tester, 'Training');

      expect(
        find.text(
          'This event is from Google Calendar and is read-only in Calee.',
        ),
        findsOneWidget,
      );
      // Calee has no per-event Google deep link, so it must not imply one.
      expect(find.textContaining('Edit it in Google Calendar'), findsNothing);
      expect(find.textContaining('Edit in Google'), findsNothing);
      expect(find.textContaining('Open in Google'), findsNothing);
    });
  });

  // ── H. Recurrence is never overclaimed ────────────────────────────────────

  group('H — recurrence presentation', () {
    testWidgets('a non-recurring event asserts nothing about repeating', (
      tester,
    ) async {
      final hub = _StubHub(
        calendarsPayload: const [_googleCalendar],
        eventsPayload: [
          _event(
            calendarId: 'external:google-1',
            source: 'external',
            serviceId: 'external',
            providerKey: 'google_calendar',
          ),
        ],
      );

      await _pumpCalendar(tester, hub: hub);
      await _selectDefaultDay(tester);
      await _tapEvent(tester, 'Training');

      expect(find.textContaining('Does not repeat'), findsNothing);
      expect(find.textContaining('Repeat'), findsNothing);
    });

    testWidgets('a positively recurring event says so, and never shows the '
        'raw rule', (tester) async {
      final hub = _StubHub(
        calendarsPayload: const [_familyCalendar],
        eventsPayload: [
          ClientEvent(
            id: 'evt-r',
            calendarId: 'portal:family',
            serviceId: 'portal',
            serviceName: 'Portal',
            title: 'Swimming',
            startsAt: '2026-08-21T13:00:00',
            endsAt: '2026-08-21T14:00:00',
            allDay: false,
            source: 'nextcloud',
            recurring: true,
            recurrence: 'FREQ=WEEKLY;BYDAY=FR;INTERVAL=1',
            seriesId: 'portal:family:series-1',
            readOnly: false,
          ),
        ],
      );

      await _pumpCalendar(tester, hub: hub);
      await _selectDefaultDay(tester);
      await _tapEvent(tester, 'Swimming');

      expect(find.text('Repeating event'), findsOneWidget);
      expect(find.textContaining('FREQ='), findsNothing);
      expect(find.textContaining('BYDAY'), findsNothing);
    });
  });

  // ── I. Modal lifecycle ────────────────────────────────────────────────────

  group('I — details → action lifecycle', () {
    testWidgets('Edit closes details before the editor opens', (tester) async {
      final hub = _StubHub(
        calendarsPayload: const [_familyCalendar],
        eventsPayload: [
          _event(
            calendarId: 'portal:family',
            title: 'Dentist',
            readOnly: false,
            source: 'nextcloud',
          ),
        ],
      );

      await _pumpCalendar(tester, hub: hub);
      await _selectDefaultDay(tester);
      await _tapEvent(tester, 'Dentist');
      expect(_detailsDate('Friday 21 August 2026'), _detailsIsOpen);

      await tester.tap(find.text('Edit Event'));
      await tester.pumpAndSettle();

      // The editor is up…
      expect(find.byType(CreateEventSheet), findsOneWidget);
      // …and no stale details route is left underneath it.
      expect(find.text('Friday 21 August 2026'), findsNothing);
    });

    testWidgets('Delete closes details before the confirmation appears', (
      tester,
    ) async {
      final hub = _StubHub(
        calendarsPayload: const [_familyCalendar],
        eventsPayload: [
          _event(
            calendarId: 'portal:family',
            title: 'Dentist',
            readOnly: false,
            source: 'nextcloud',
          ),
        ],
      );

      await _pumpCalendar(tester, hub: hub);
      await _selectDefaultDay(tester);
      await _tapEvent(tester, 'Dentist');

      await tester.tap(find.text('Delete Event'));
      await tester.pumpAndSettle();

      expect(find.text('Delete event?'), findsOneWidget);
      expect(find.text('Friday 21 August 2026'), findsNothing);
    });
  });

  // ── J. Long content and large text ────────────────────────────────────────

  group('J — long content and accessibility', () {
    testWidgets('long title/location/description at 2x text scale stay '
        'readable and scrollable', (tester) async {
      const longTitle =
          'Interschool Athletics Carnival Semi-Final and Presentation Evening';
      const longLocation =
          'Morley Eagles Teeball Club, Corner of Wellington Road and '
          'Broadway Avenue, Morley, Western Australia 6062';
      const longDescription =
          'Please arrive thirty minutes early for marshalling. Bring a hat, '
          'sunscreen, a labelled water bottle and the signed permission '
          'slip. Parking is limited so carpooling is strongly encouraged. '
          'The canteen will be open from midday and card payments are '
          'accepted. In the event of extreme weather the carnival will be '
          'postponed and a notice will be published on this calendar.';

      final hub = _StubHub(
        calendarsPayload: const [_familyCalendar],
        eventsPayload: [
          _event(
            calendarId: 'portal:family',
            title: longTitle,
            readOnly: false,
            source: 'nextcloud',
            location: longLocation,
            description: longDescription,
          ),
        ],
      );

      await _pumpCalendar(
        tester,
        hub: hub,
        textScaler: const TextScaler.linear(2.0),
      );
      await _selectDefaultDay(tester);
      await _tapEvent(tester, longTitle);

      expect(tester.takeException(), isNull);
      expect(find.text(longTitle), findsWidgets);

      // The details body scrolls rather than overflowing.
      final scrollable = find.descendant(
        of: find.byType(BottomSheet),
        matching: find.byType(Scrollable),
      );
      expect(scrollable, findsWidgets);
      await tester.drag(scrollable.first, const Offset(0, -200));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    });

    testWidgets('an event row exposes a tappable button semantics node', (
      tester,
    ) async {
      final handle = tester.ensureSemantics();
      final hub = _StubHub(
        calendarsPayload: const [_familyCalendar],
        eventsPayload: [
          _event(
            calendarId: 'portal:family',
            title: 'Dentist',
            readOnly: false,
            source: 'nextcloud',
          ),
        ],
      );

      await _pumpCalendar(tester, hub: hub);
      await _selectDefaultDay(tester);

      // The whole row is one merged, tappable node — the title is announced
      // together with its time and calendar, and the node carries a tap
      // action rather than being a visual-only surface.
      final node = tester.getSemantics(find.text('Dentist').first);
      expect(node.label, contains('Dentist'));
      expect(
        node.getSemanticsData().hasAction(SemanticsAction.tap),
        isTrue,
        reason: 'a calendar row must be actionable, not decorative',
      );
      handle.dispose();
    });
  });
}

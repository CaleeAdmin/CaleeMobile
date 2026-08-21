// The signed-in public Event Link journey (CaleeAdmin/CaleeMobile#559).
//
// Signed in → subscribed public Calee calendar → tap event → read-only details
// → Share event → the ONE CalEmbed mint seam → the ONE share launcher.
//
// Both collaborators are injected fakes, so nothing here opens a socket or
// touches a platform share channel; what the tests assert is exactly which
// three values reached the mint call and which URI reached the share sheet.
//
// Kept in its own file rather than bolted onto calendar_page_test.dart: that
// file owns Calendar's view/refresh/lifecycle behaviour, this one owns
// sharing, and neither has to be read to change the other.

import 'dart:async';

import 'package:calee_mobile/data/api/calee_hub_client.dart';
import 'package:calee_mobile/data/models/client_bootstrap.dart';
import 'package:calee_mobile/data/models/client_calendar.dart';
import 'package:calee_mobile/features/calendar/calendar_page.dart';
import 'package:calee_mobile/features/calendar/shared/read_only_calendar_view.dart';
import 'package:calee_mobile/features/local_subscriber/calee_public_calendar_source.dart';
import 'package:calee_mobile/features/local_subscriber/local_event_details_sheet.dart';
import 'package:calee_mobile/features/local_subscriber/local_event_link_service.dart';
import 'package:calee_mobile/features/local_subscriber/local_event_share_launcher.dart';
import 'package:calee_mobile/ui/calee_design.dart';
import 'package:flutter/material.dart';
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

/// One recorded mint call — the COMPLETE set of values the page handed the
/// service. Anything the page sent that is not one of these three would have
/// to appear as a new field here to be sent at all.
class _MintCall {
  const _MintCall({
    required this.source,
    required this.uid,
    required this.occurrenceId,
  });

  final CaleePublicCalendarSource source;
  final String uid;
  final String? occurrenceId;
}

class _FakeEventLinkService implements LocalEventLinkService {
  _FakeEventLinkService({this.fail = false});

  /// The canonical link every successful mint returns.
  final String url = _kMintedUrl;

  bool fail;
  final List<_MintCall> calls = [];

  /// Held to model a mint that is still in flight.
  Completer<void>? gate;

  @override
  Future<Uri> mint({
    required CaleePublicCalendarSource source,
    required String uid,
    String? occurrenceId,
  }) async {
    calls.add(_MintCall(source: source, uid: uid, occurrenceId: occurrenceId));
    final pending = gate;
    if (pending != null) await pending.future;
    if (fail) throw const LocalEventLinkException();
    return Uri.parse(url);
  }
}

class _FakeShareLauncher implements LocalEventShareLauncher {
  final List<Uri> urls = [];
  final List<String> titles = [];
  final List<Rect> origins = [];
  bool fail = false;

  @override
  Future<void> share({
    required Uri url,
    required String title,
    required Rect sharePositionOrigin,
  }) async {
    urls.add(url);
    titles.add(title);
    origins.add(sharePositionOrigin);
    if (fail) throw StateError('share failed');
  }
}

// ── Fixtures ────────────────────────────────────────────────────────────────

const String _kPublicUrl =
    'https://portal.calee.com.au/remote.php/dav/public-calendars/abcdefgh?export';
const String _kMintedUrl =
    'https://calembed.calee.com.au/e/1.eyJhIjoxfQ.c2lnbmF0dXJl';

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

/// The already-public Calee subscription: read-only AND published.
const _publicCalendar = ClientCalendar(
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

/// Private, read-only, Google. Read-only exactly like the one above — the
/// only thing that differs is that it was never published.
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

/// A private HTTPS ICS feed the user follows. A subscription, read-only, and
/// still not public.
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

/// Calee-looking, but the URL fails strict validation (subdomain of a
/// registered host). Must never be sent anywhere.
const _lookalikeCalendar = ClientCalendar(
  id: 'portal:lookalike',
  serviceId: 'portal',
  serviceName: 'Portal',
  name: 'Looks Official',
  components: [],
  primaryKind: 'calendar',
  supportsEvents: true,
  supportsTasks: false,
  supportsChores: false,
  readOnly: true,
  isSubscription: true,
  subscriptionUrl:
      'https://portal.calee.com.au.attacker.example/remote.php/dav/public-calendars/abcdefgh?export',
  source: 'portal',
);

/// A normal private family calendar: writable, not a subscription.
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

ClientEvent _event({
  required String calendarId,
  String id = 'evt-1',
  String title = 'Training',
  String? sourceUid = 'event-uid-1',
  String? canonicalRecurrenceId,
  bool recurring = false,
  bool readOnly = true,
  String startsAt = '2026-08-18T05:30:00Z',
  String endsAt = '2026-08-18T06:30:00Z',
  String source = 'portal',
  String serviceId = 'portal',
  String? providerKey,
  String? seriesId,
  String? recurrenceId,
  String? occurrenceId,
}) => ClientEvent(
  id: id,
  calendarId: calendarId,
  serviceId: serviceId,
  serviceName: 'Portal',
  title: title,
  startsAt: startsAt,
  endsAt: endsAt,
  allDay: false,
  source: source,
  recurring: recurring,
  seriesId: seriesId,
  recurrenceId: recurrenceId,
  occurrenceId: occurrenceId,
  sourceUid: sourceUid,
  canonicalRecurrenceId: canonicalRecurrenceId,
  providerKey: providerKey,
  readOnly: readOnly,
);

/// The local calendar day an event starting at [utc] falls on, derived from
/// the instant so the assertion holds in any host timezone.
DateTime _dayOf(String utc) {
  final local = DateTime.parse(utc).toLocal();
  return DateTime(local.year, local.month, local.day);
}

// ── Harness ─────────────────────────────────────────────────────────────────

Future<void> _pumpCalendar(
  WidgetTester tester, {
  required _StubHub hub,
  _FakeEventLinkService? linkService,
  _FakeShareLauncher? shareLauncher,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      theme: CaleeTheme.buildThemeData(),
      home: Builder(
        builder: (context) => MediaQuery(
          data: MediaQuery.of(context).copyWith(alwaysUse24HourFormat: false),
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

/// Selects the day an event falls on, so its row is on screen in the agenda.
Future<void> _selectDay(WidgetTester tester, String utc) async {
  tester
      .widget<ReadOnlyCalendarView>(find.byType(ReadOnlyCalendarView))
      .onSelectDay(_dayOf(utc));
  await tester.pumpAndSettle();
}

/// Taps the agenda row whose title is [title].
Future<void> _tapEvent(WidgetTester tester, String title) async {
  final row = find.text(title);
  expect(row, findsWidgets, reason: 'the "$title" row is on screen');
  await tester.tap(row.first);
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

  group('public subscription — the signed-in share journey', () {
    testWidgets('a one-off mints with the exact UID and NO occurrence id', (
      tester,
    ) async {
      final link = _FakeEventLinkService();
      final launcher = _FakeShareLauncher();
      final hub = _StubHub(
        calendarsPayload: const [_publicCalendar],
        eventsPayload: [
          _event(calendarId: 'portal:lazers', sourceUid: '  spaced-uid  '),
        ],
      );

      await _pumpCalendar(
        tester,
        hub: hub,
        linkService: link,
        shareLauncher: launcher,
      );
      await _selectDay(tester, '2026-08-18T05:30:00Z');
      await _tapEvent(tester, 'Training');

      // Read-only details, with the Share action.
      expect(find.byKey(kLocalEventDetailsSheetKey), findsOneWidget);
      expect(find.byKey(kLocalEventShareButtonKey), findsOneWidget);
      expect(find.text('Share event'), findsOneWidget);
      // And no Edit/Delete anywhere: a public subscription is not writable.
      expect(find.text('Edit Event'), findsNothing);
      expect(find.text('Delete Event'), findsNothing);

      await tester.tap(find.byKey(kLocalEventShareButtonKey));
      await tester.pumpAndSettle();

      expect(link.calls, hasLength(1));
      expect(link.calls.single.source.canonicalUrl, _kPublicUrl);
      // Untrimmed, byte for byte.
      expect(link.calls.single.uid, '  spaced-uid  ');
      // A one-off sends no occurrence id at all.
      expect(link.calls.single.occurrenceId, isNull);

      // The minted URI reaches the share sheet unchanged — no query string, no
      // source/account marker, nothing appended.
      expect(launcher.urls, hasLength(1));
      expect(launcher.urls.single.toString(), _kMintedUrl);
      expect(launcher.urls.single.hasQuery, isFalse);
      expect(launcher.urls.single.hasFragment, isFalse);
      expect(launcher.titles.single, 'Training');
    });

    testWidgets('a recurring occurrence sends canonicalRecurrenceId, never '
        'the Hub composite ids', (tester) async {
      final link = _FakeEventLinkService();
      final launcher = _FakeShareLauncher();
      final hub = _StubHub(
        calendarsPayload: const [_publicCalendar],
        eventsPayload: [
          _event(
            calendarId: 'portal:lazers',
            id: 'portal:lazers:series-1:20260818T133000',
            recurring: true,
            sourceUid: 'series-one@calee.com.au',
            canonicalRecurrenceId: '20260818T053000Z',
            seriesId: 'portal:lazers:series-1',
            recurrenceId: '20260818T133000',
            occurrenceId: 'portal:lazers:series-1:20260818T133000',
          ),
        ],
      );

      await _pumpCalendar(
        tester,
        hub: hub,
        linkService: link,
        shareLauncher: launcher,
      );
      await _selectDay(tester, '2026-08-18T05:30:00Z');
      await _tapEvent(tester, 'Training');
      await tester.tap(find.byKey(kLocalEventShareButtonKey));
      await tester.pumpAndSettle();

      final call = link.calls.single;
      expect(call.uid, 'series-one@calee.com.au');
      expect(call.occurrenceId, '20260818T053000Z');
      // None of the four Hub-local composites leaked into the request.
      expect(call.uid, isNot('portal:lazers:series-1'));
      expect(call.occurrenceId, isNot('20260818T133000'));
      expect(
        call.occurrenceId,
        isNot('portal:lazers:series-1:20260818T133000'),
      );
    });

    testWidgets('a DETACHED moved occurrence keeps its ORIGINAL identity', (
      tester,
    ) async {
      final link = _FakeEventLinkService();
      final hub = _StubHub(
        calendarsPayload: const [_publicCalendar],
        eventsPayload: [
          _event(
            calendarId: 'portal:lazers',
            title: 'Moved Training',
            recurring: true,
            // Displayed two days later than the slot it belongs to.
            startsAt: '2026-08-20T01:00:00Z',
            endsAt: '2026-08-20T02:00:00Z',
            sourceUid: 'series-one',
            canonicalRecurrenceId: '20260818T053000Z',
            recurrenceId: '20260820T090000',
            occurrenceId: 'portal:lazers:series-1:20260820T090000',
          ),
        ],
      );

      await _pumpCalendar(
        tester,
        hub: hub,
        linkService: link,
        shareLauncher: _FakeShareLauncher(),
      );
      await _selectDay(tester, '2026-08-20T01:00:00Z');
      await _tapEvent(tester, 'Moved Training');
      await tester.tap(find.byKey(kLocalEventShareButtonKey));
      await tester.pumpAndSettle();

      // The moved display time changed nothing about the identity.
      expect(link.calls.single.occurrenceId, '20260818T053000Z');
      expect(link.calls.single.occurrenceId, isNot(contains('20260820')));
    });

    testWidgets('a public event with no canonical identity shows details but '
        'no Share, and mints nothing', (tester) async {
      final link = _FakeEventLinkService();
      final hub = _StubHub(
        calendarsPayload: const [_publicCalendar],
        eventsPayload: [
          _event(
            calendarId: 'portal:lazers',
            recurring: true,
            sourceUid: 'series-one',
            // Hub could not name this occurrence portably.
            canonicalRecurrenceId: null,
            recurrenceId: '20260818T133000',
          ),
        ],
      );

      await _pumpCalendar(tester, hub: hub, linkService: link);
      await _selectDay(tester, '2026-08-18T05:30:00Z');
      await _tapEvent(tester, 'Training');

      // Details still usable...
      expect(find.byKey(kLocalEventDetailsSheetKey), findsOneWidget);
      expect(find.text('Training'), findsWidgets);
      // ...but no link is invented for it.
      expect(find.byKey(kLocalEventShareUnavailableKey), findsOneWidget);
      expect(find.byKey(kLocalEventShareButtonKey), findsNothing);
      expect(link.calls, isEmpty);
    });

    testWidgets('a public event with no sourceUid offers no Share', (
      tester,
    ) async {
      final link = _FakeEventLinkService();
      final hub = _StubHub(
        calendarsPayload: const [_publicCalendar],
        eventsPayload: [_event(calendarId: 'portal:lazers', sourceUid: null)],
      );

      await _pumpCalendar(tester, hub: hub, linkService: link);
      await _selectDay(tester, '2026-08-18T05:30:00Z');
      await _tapEvent(tester, 'Training');

      expect(find.byKey(kLocalEventShareUnavailableKey), findsOneWidget);
      expect(find.byKey(kLocalEventShareButtonKey), findsNothing);
      expect(link.calls, isEmpty);
    });
  });

  // ── The #421 collision regression ─────────────────────────────────────────

  group('colliding legacy Hub ids', () {
    testWidgets('each tapped row mints with ITS OWN sourceUid', (tester) async {
      final link = _FakeEventLinkService();
      final launcher = _FakeShareLauncher();

      // Two DISTINCT source events that Hub gave the SAME composite id —
      // exactly the collision CaleeAdmin/calee-hub-core#421 documents. A
      // lookup by `e.id == displayEvent.id` would resolve both taps to
      // whichever came first, and would share the wrong event.
      const collidingId = 'portal:lazers:collision';
      final hub = _StubHub(
        calendarsPayload: const [_publicCalendar],
        eventsPayload: [
          _event(
            calendarId: 'portal:lazers',
            id: collidingId,
            title: 'Event A',
            sourceUid: 'uid-alpha',
            startsAt: '2026-08-18T05:30:00Z',
            endsAt: '2026-08-18T06:30:00Z',
          ),
          _event(
            calendarId: 'portal:lazers',
            id: collidingId,
            title: 'Event B',
            sourceUid: 'uid-beta',
            startsAt: '2026-08-18T08:00:00Z',
            endsAt: '2026-08-18T09:00:00Z',
          ),
        ],
      );

      await _pumpCalendar(
        tester,
        hub: hub,
        linkService: link,
        shareLauncher: launcher,
      );
      await _selectDay(tester, '2026-08-18T05:30:00Z');

      // Tap A → A's own UID.
      await _tapEvent(tester, 'Event A');
      expect(find.byKey(kLocalEventDetailsSheetKey), findsOneWidget);
      await tester.tap(find.byKey(kLocalEventShareButtonKey));
      await tester.pumpAndSettle();
      expect(link.calls, hasLength(1));
      expect(link.calls[0].uid, 'uid-alpha');

      // Close, then tap B → B's own UID.
      await tester.tapAt(const Offset(20, 20));
      await tester.pumpAndSettle();

      await _tapEvent(tester, 'Event B');
      expect(find.byKey(kLocalEventDetailsSheetKey), findsOneWidget);
      await tester.tap(find.byKey(kLocalEventShareButtonKey));
      await tester.pumpAndSettle();
      expect(link.calls, hasLength(2));
      expect(link.calls[1].uid, 'uid-beta');

      // The two taps produced two different identities, from one id.
      expect(link.calls[0].uid, isNot(link.calls[1].uid));
    });

    testWidgets('a colliding WRITABLE row edits the exact event tapped', (
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
            source: 'nextcloud',
            readOnly: false,
            sourceUid: 'uid-alpha',
            startsAt: '2026-08-18T05:30:00Z',
            endsAt: '2026-08-18T06:30:00Z',
          ),
          _event(
            calendarId: 'portal:family',
            id: collidingId,
            title: 'Soccer',
            source: 'nextcloud',
            readOnly: false,
            sourceUid: 'uid-beta',
            startsAt: '2026-08-18T08:00:00Z',
            endsAt: '2026-08-18T09:00:00Z',
          ),
        ],
      );

      await _pumpCalendar(tester, hub: hub);
      await _selectDay(tester, '2026-08-18T05:30:00Z');

      // The writable action sheet is titled with the event's own title, so it
      // shows which ClientEvent the tap actually resolved to.
      await _tapEvent(tester, 'Soccer');
      expect(find.text('Edit Event'), findsOneWidget);
      expect(find.text('Delete Event'), findsOneWidget);
      // Two 'Soccer' texts now: the agenda row behind, and the sheet title.
      expect(find.text('Soccer'), findsNWidgets(2));
    });
  });

  // ── Private read-only sources keep their existing UX ───────────────────────

  group('private read-only calendars are untouched', () {
    testWidgets('Google keeps its provider guidance and offers no Share', (
      tester,
    ) async {
      final link = _FakeEventLinkService();
      final hub = _StubHub(
        calendarsPayload: const [_googleCalendar],
        eventsPayload: [
          _event(
            calendarId: 'external:google-1',
            source: 'external',
            serviceId: 'external',
            providerKey: 'google_calendar',
            sourceUid: 'google-uid-1',
          ),
        ],
      );

      await _pumpCalendar(tester, hub: hub, linkService: link);
      await _selectDay(tester, '2026-08-18T05:30:00Z');
      await _tapEvent(tester, 'Training');

      expect(
        find.text(
          'This event comes from Google Calendar. '
          'Edit it in Google Calendar.',
        ),
        findsOneWidget,
      );
      expect(find.byKey(kLocalEventDetailsSheetKey), findsNothing);
      expect(find.byKey(kLocalEventShareButtonKey), findsNothing);
      expect(find.text('Share event'), findsNothing);
      expect(link.calls, isEmpty);
    });

    testWidgets('a private ICS subscription keeps read-only guidance and '
        'offers no Share', (tester) async {
      final link = _FakeEventLinkService();
      final hub = _StubHub(
        calendarsPayload: const [_privateIcsCalendar],
        eventsPayload: [
          _event(calendarId: 'portal:private-ics', sourceUid: 'private-uid'),
        ],
      );

      await _pumpCalendar(tester, hub: hub, linkService: link);
      await _selectDay(tester, '2026-08-18T05:30:00Z');
      await _tapEvent(tester, 'Training');

      expect(
        find.textContaining('This event is from a read-only calendar.'),
        findsOneWidget,
      );
      expect(find.byKey(kLocalEventDetailsSheetKey), findsNothing);
      expect(find.text('Share event'), findsNothing);
      expect(link.calls, isEmpty);
    });

    testWidgets('a Calee-LOOKALIKE URL offers no Share and is never sent', (
      tester,
    ) async {
      final link = _FakeEventLinkService();
      final hub = _StubHub(
        calendarsPayload: const [_lookalikeCalendar],
        eventsPayload: [
          _event(calendarId: 'portal:lookalike', sourceUid: 'uid-1'),
        ],
      );

      await _pumpCalendar(tester, hub: hub, linkService: link);
      await _selectDay(tester, '2026-08-18T05:30:00Z');
      await _tapEvent(tester, 'Training');

      expect(find.text('Share event'), findsNothing);
      expect(find.byKey(kLocalEventDetailsSheetKey), findsNothing);
      // The unvalidated URL never reached the mint seam at all.
      expect(link.calls, isEmpty);
    });
  });

  // ── Writable events keep their exact existing actions ─────────────────────

  group('writable calendars keep Edit / Delete', () {
    testWidgets(
      'a private writable event shows Edit and Delete, and no Share',
      (tester) async {
        final link = _FakeEventLinkService();
        final hub = _StubHub(
          calendarsPayload: const [_familyCalendar],
          eventsPayload: [
            _event(
              calendarId: 'portal:family',
              title: 'Dentist',
              source: 'nextcloud',
              readOnly: false,
              sourceUid: 'family-uid',
            ),
          ],
        );

        await _pumpCalendar(tester, hub: hub, linkService: link);
        await _selectDay(tester, '2026-08-18T05:30:00Z');
        await _tapEvent(tester, 'Dentist');

        expect(find.text('Edit Event'), findsOneWidget);
        expect(find.text('Delete Event'), findsOneWidget);
        expect(find.text('Share event'), findsNothing);
        expect(find.byKey(kLocalEventDetailsSheetKey), findsNothing);
        // Opening the actions never touches the network.
        expect(link.calls, isEmpty);
      },
    );

    testWidgets('a writable RECURRING event keeps the scoped Edit… / Delete…', (
      tester,
    ) async {
      final hub = _StubHub(
        calendarsPayload: const [_familyCalendar],
        eventsPayload: [
          _event(
            calendarId: 'portal:family',
            title: 'Swimming',
            source: 'nextcloud',
            readOnly: false,
            recurring: true,
            sourceUid: 'family-series',
            canonicalRecurrenceId: '20260818T053000Z',
            seriesId: 'portal:family:series-1',
          ),
        ],
      );

      await _pumpCalendar(tester, hub: hub);
      await _selectDay(tester, '2026-08-18T05:30:00Z');
      await _tapEvent(tester, 'Swimming');

      expect(find.text('Edit…'), findsOneWidget);
      expect(find.text('Delete…'), findsOneWidget);
      expect(find.text('Share event'), findsNothing);
    });
  });

  // ── Failure, lifecycle and double-tap, over the signed-in page ─────────────

  group('share lifecycle', () {
    testWidgets('a rapid double tap makes exactly ONE mint request', (
      tester,
    ) async {
      final link = _FakeEventLinkService();
      final launcher = _FakeShareLauncher();
      link.gate = Completer<void>();
      final hub = _StubHub(
        calendarsPayload: const [_publicCalendar],
        eventsPayload: [_event(calendarId: 'portal:lazers')],
      );

      await _pumpCalendar(
        tester,
        hub: hub,
        linkService: link,
        shareLauncher: launcher,
      );
      await _selectDay(tester, '2026-08-18T05:30:00Z');
      await _tapEvent(tester, 'Training');

      // Two taps in the same frame: no pump between them.
      final button = find.byKey(kLocalEventShareButtonKey);
      await tester.tap(button);
      await tester.tap(button, warnIfMissed: false);
      await tester.pump();

      expect(link.calls, hasLength(1));

      link.gate!.complete();
      await tester.pumpAndSettle();

      expect(link.calls, hasLength(1));
      expect(launcher.urls, hasLength(1));
    });

    testWidgets('closing the sheet mid-mint shares nothing', (tester) async {
      final link = _FakeEventLinkService();
      final launcher = _FakeShareLauncher();
      link.gate = Completer<void>();
      final hub = _StubHub(
        calendarsPayload: const [_publicCalendar],
        eventsPayload: [_event(calendarId: 'portal:lazers')],
      );

      await _pumpCalendar(
        tester,
        hub: hub,
        linkService: link,
        shareLauncher: launcher,
      );
      await _selectDay(tester, '2026-08-18T05:30:00Z');
      await _tapEvent(tester, 'Training');
      await tester.tap(find.byKey(kLocalEventShareButtonKey));
      await tester.pump();

      // Dismiss while the mint is still in flight.
      await tester.tapAt(const Offset(20, 20));
      await tester.pumpAndSettle();
      expect(find.byKey(kLocalEventDetailsSheetKey), findsNothing);

      link.gate!.complete();
      await tester.pumpAndSettle();

      // The request happened, but no share sheet is opened from a dead route,
      // and no setState lands on a disposed State.
      expect(link.calls, hasLength(1));
      expect(launcher.urls, isEmpty);
      expect(tester.takeException(), isNull);
    });

    testWidgets('a mint failure shows an inline message and stays retryable', (
      tester,
    ) async {
      final link = _FakeEventLinkService(fail: true);
      final launcher = _FakeShareLauncher();
      final hub = _StubHub(
        calendarsPayload: const [_publicCalendar],
        eventsPayload: [_event(calendarId: 'portal:lazers')],
      );

      await _pumpCalendar(
        tester,
        hub: hub,
        linkService: link,
        shareLauncher: launcher,
      );
      await _selectDay(tester, '2026-08-18T05:30:00Z');
      await _tapEvent(tester, 'Training');
      await tester.tap(find.byKey(kLocalEventShareButtonKey));
      await tester.pumpAndSettle();

      expect(find.byKey(kLocalEventShareErrorKey), findsOneWidget);
      expect(find.text(kLocalEventShareFailureMessage), findsOneWidget);
      expect(launcher.urls, isEmpty);
      // The sheet is still open and the button is live again.
      expect(find.byKey(kLocalEventDetailsSheetKey), findsOneWidget);

      // Retry, this time succeeding.
      link.fail = false;
      await tester.tap(find.byKey(kLocalEventShareButtonKey));
      await tester.pumpAndSettle();

      expect(link.calls, hasLength(2));
      expect(launcher.urls, hasLength(1));
      expect(launcher.urls.single.toString(), _kMintedUrl);
    });

    testWidgets('a share-sheet failure shows the same friendly message', (
      tester,
    ) async {
      final link = _FakeEventLinkService();
      final launcher = _FakeShareLauncher()..fail = true;
      final hub = _StubHub(
        calendarsPayload: const [_publicCalendar],
        eventsPayload: [_event(calendarId: 'portal:lazers')],
      );

      await _pumpCalendar(
        tester,
        hub: hub,
        linkService: link,
        shareLauncher: launcher,
      );
      await _selectDay(tester, '2026-08-18T05:30:00Z');
      await _tapEvent(tester, 'Training');
      await tester.tap(find.byKey(kLocalEventShareButtonKey));
      await tester.pumpAndSettle();

      expect(find.text(kLocalEventShareFailureMessage), findsOneWidget);
    });

    testWidgets('the iPad anchor is a real on-screen rect from the button', (
      tester,
    ) async {
      final link = _FakeEventLinkService();
      final launcher = _FakeShareLauncher();
      final hub = _StubHub(
        calendarsPayload: const [_publicCalendar],
        eventsPayload: [_event(calendarId: 'portal:lazers')],
      );

      await _pumpCalendar(
        tester,
        hub: hub,
        linkService: link,
        shareLauncher: launcher,
      );
      await _selectDay(tester, '2026-08-18T05:30:00Z');
      await _tapEvent(tester, 'Training');

      // The rect the anchor occupies BEFORE the tap — captured while the
      // button is still laid out, which is the geometry iPadOS needs.
      final expected = tester.getRect(find.byKey(kLocalEventShareAnchorKey));

      await tester.tap(find.byKey(kLocalEventShareButtonKey));
      await tester.pumpAndSettle();

      expect(launcher.origins, hasLength(1));
      final origin = launcher.origins.single;
      expect(origin.width, greaterThan(0));
      expect(origin.height, greaterThan(0));
      expect(origin, expected);
    });
  });
}

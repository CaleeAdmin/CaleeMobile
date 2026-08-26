// Authentication parity for public Event Links (CaleeAdmin/CaleeMobile#566).
//
// The invariant under test is the one the issue calls unacceptable to break:
//
//   an ALREADY-PUBLIC Calee event must not lose "Share event" solely because
//   the user signed in, and the SAME logical occurrence must resolve to the
//   SAME canonical Event Link on both sides of that transition.
//
// Signing in changes which screen renders the calendar (LocalSubscriber →
// CalendarPage) and which model the event arrives in (LocalCalendarEvent →
// ClientEvent). It changes nothing about whether the underlying calendar is
// published, so it must change nothing about the link.
//
// Both pages are driven through ONE shared fake mint service, so parity is
// asserted on the exact values that would have gone on the wire — the
// calendar reference, the source UID and the occurrence identity — not on
// two screenshots that happen to look alike.

import 'package:calee_mobile/data/api/calee_hub_client.dart';
import 'package:calee_mobile/data/models/client_bootstrap.dart';
import 'package:calee_mobile/data/models/client_calendar.dart';
import 'package:calee_mobile/features/calendar/calendar_page.dart';
import 'package:calee_mobile/features/local_subscriber/calee_public_calendar_source.dart';
import 'package:calee_mobile/features/local_subscriber/local_calendar_event.dart';
import 'package:calee_mobile/features/local_subscriber/local_calendar_ics_service.dart';
import 'package:calee_mobile/features/local_subscriber/local_calendar_occurrence_identity.dart';
import 'package:calee_mobile/features/local_subscriber/local_calendar_subscription.dart';
import 'package:calee_mobile/features/local_subscriber/local_calendar_subscription_repository.dart';
import 'package:calee_mobile/features/local_subscriber/local_event_details_sheet.dart';
import 'package:calee_mobile/features/local_subscriber/local_event_link_service.dart';
import 'package:calee_mobile/features/local_subscriber/local_event_share_launcher.dart';
import 'package:calee_mobile/features/local_subscriber/local_subscriber_calendar_page.dart';
import 'package:calee_mobile/ui/calee_design.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

// ── The one public source, and the one occurrence, both sides share ─────────

const String _kPublicToken = 'AbC123_-xyz';
const String _kPublicCalendarUrl =
    'https://portal.calee.com.au/remote.php/dav/public-calendars/'
    '$_kPublicToken?export';

/// The verbatim source UID Hub and the local ICS parser both read from the
/// same published component.
const String _kUid = 'shared-occurrence-uid@calee.com.au';

/// The canonical recurrence identity for the recurring case. Deliberately
/// NOT equal to any display value either side computes for itself.
const String _kCanonicalRecurrenceId = '20260818T073000Z';

const String _kMintedLink =
    'https://calembed.calee.com.au/e/1.eyJiIjoicG9ydGFsIn0.c2lnbmF0dXJl';

/// One mint request, reduced to the values that decide WHICH event a
/// recipient will open. Parity is equality of this record.
class _MintCall {
  const _MintCall({
    required this.calendarUrl,
    required this.uid,
    required this.occurrenceId,
  });

  final String calendarUrl;
  final String uid;
  final String? occurrenceId;

  @override
  bool operator ==(Object other) =>
      other is _MintCall &&
      other.calendarUrl == calendarUrl &&
      other.uid == uid &&
      other.occurrenceId == occurrenceId;

  @override
  int get hashCode => Object.hash(calendarUrl, uid, occurrenceId);

  @override
  String toString() =>
      'MintCall(calendarUrl: $calendarUrl, uid: $uid, '
      'occurrenceId: $occurrenceId)';
}

class _RecordingLinkService implements LocalEventLinkService {
  final List<_MintCall> calls = [];

  @override
  Future<Uri> mint({
    required CaleePublicCalendarSource source,
    required String uid,
    String? occurrenceId,
  }) async {
    calls.add(
      _MintCall(
        calendarUrl: source.canonicalUrl,
        uid: uid,
        occurrenceId: occurrenceId,
      ),
    );
    return Uri.parse(_kMintedLink);
  }
}

class _RecordingLauncher implements LocalEventShareLauncher {
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

// ── Signed-out side ────────────────────────────────────────────────────────

class _StubIcsService extends LocalCalendarIcsService {
  _StubIcsService(this._events);

  final List<LocalCalendarEvent> _events;

  @override
  Future<List<LocalCalendarEvent>> fetchEvents(
    LocalCalendarSubscription sub,
  ) async => _events;
}

LocalCalendarSubscription _localPublicSub() => LocalCalendarSubscription(
  id: 'sub1',
  title: 'Lazers (Morley Eagles)',
  url: _kPublicCalendarUrl,
  // Descriptive legacy state that says nothing about publication.
  source: 'somewhere-else',
  createdAt: DateTime(2024, 1, 1),
);

DateTime _todayAt(int hour, [int minute = 0]) {
  final now = DateTime.now();
  return DateTime(now.year, now.month, now.day, hour, minute);
}

LocalCalendarEvent _localEvent({
  String title = 'Training',
  bool recurring = false,
  String? canonicalRecurrenceId,
}) => LocalCalendarEvent(
  id: 'local-1',
  subscriptionId: 'sub1',
  subscriptionTitle: 'Lazers (Morley Eagles)',
  title: title,
  start: _todayAt(10),
  end: _todayAt(11),
  isAllDay: false,
  sourceUrl: _kPublicCalendarUrl,
  uid: _kUid,
  recurring: recurring,
  recurrenceId: recurring ? '20260818T153000Z' : null,
  canonicalRecurrenceId: canonicalRecurrenceId,
  canonicalStatus: CanonicalSourceStatus.ok,
);

Widget _signedOutPage({
  required List<LocalCalendarEvent> events,
  required LocalEventLinkService linkService,
  required LocalEventShareLauncher launcher,
  LocalCalendarSubscription? subscription,
}) => MaterialApp(
  theme: CaleeTheme.buildThemeData(),
  home: LocalSubscriberCalendarPage(
    subscriptions: [subscription ?? _localPublicSub()],
    repository: LocalCalendarSubscriptionRepository(),
    onSignIn: () {},
    onLearnAboutHome: () {},
    onSubscriptionsChanged: (_) {},
    icsService: _StubIcsService(events),
    eventLinkService: linkService,
    shareLauncher: launcher,
  ),
);

// ── Signed-in side ─────────────────────────────────────────────────────────

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

/// The SAME published calendar, as the signed-in client sees it.
ClientCalendar _hubPublicCalendar({required bool readOnly}) => ClientCalendar(
  id: 'portal:lazers',
  serviceId: 'portal',
  serviceName: 'Portal',
  name: 'Lazers (Morley Eagles)',
  components: const [],
  primaryKind: 'calendar',
  supportsEvents: true,
  supportsTasks: false,
  supportsChores: false,
  readOnly: readOnly,
  isSubscription: true,
  subscriptionUrl: _kPublicCalendarUrl,
  source: 'portal',
);

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

/// The SAME occurrence, as the signed-in client sees it. Its Hub composite id
/// and its display times are its own; only the canonical values are shared.
ClientEvent _hubEvent({
  String calendarId = 'portal:lazers',
  String title = 'Training',
  bool recurring = false,
  String? canonicalRecurrenceId,
  bool readOnly = true,
  String? sourceUid = _kUid,
}) {
  final start = _todayAt(10);
  final end = _todayAt(11);
  return ClientEvent(
    id: 'portal:lazers:composite:1',
    calendarId: calendarId,
    serviceId: 'portal',
    serviceName: 'Portal',
    title: title,
    startsAt: start.toIso8601String(),
    endsAt: end.toIso8601String(),
    allDay: false,
    source: readOnly ? 'portal' : 'nextcloud',
    recurring: recurring,
    seriesId: recurring ? 'portal:lazers:series-1' : null,
    recurrenceId: recurring ? '20260818T153000' : null,
    sourceUid: sourceUid,
    canonicalRecurrenceId: canonicalRecurrenceId,
    readOnly: readOnly,
  );
}

Widget _signedInPage({
  required _StubHub hub,
  required LocalEventLinkService linkService,
  required LocalEventShareLauncher launcher,
}) => MaterialApp(
  theme: CaleeTheme.buildThemeData(),
  home: CalendarPage(
    hubClient: hub,
    accessToken: 'tok',
    services: const [_service],
    accountId: 'acct1',
    isFamilyUxContext: true,
    eventLinkService: linkService,
    shareLauncher: launcher,
  ),
);

// ── Shared journey steps ───────────────────────────────────────────────────

Future<void> _tapEventAndShare(WidgetTester tester, String title) async {
  await tester.tap(find.text(title).first);
  await tester.pumpAndSettle();
  expect(
    find.text('Share event'),
    findsOneWidget,
    reason: 'the public event "$title" must offer Share',
  );
  await tester.tap(find.text('Share event'));
  await tester.pumpAndSettle();
  await _dismissSheet(tester);
}

/// Closes whatever sheet is open, the way a user does.
///
/// Both halves of a parity test run in ONE `WidgetTester`, and a modal route
/// left open survives `pumpWidget` into the next page — which would leave the
/// first page's Share button on screen and record its mint a second time.
Future<void> _dismissSheet(WidgetTester tester) async {
  await tester.tapAt(const Offset(20, 20));
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

  group('signing in preserves the canonical Event Link', () {
    testWidgets('a public ONE-OFF mints identically signed out and signed in', (
      tester,
    ) async {
      final signedOutLink = _RecordingLinkService();
      final signedInLink = _RecordingLinkService();

      // 1. Guest follows the public calendar and shares the event.
      await tester.pumpWidget(
        _signedOutPage(
          events: [_localEvent()],
          linkService: signedOutLink,
          launcher: _RecordingLauncher(),
        ),
      );
      await tester.pumpAndSettle();
      await _tapEventAndShare(tester, 'Training');

      // 2. The same person signs in and sees the same published calendar.
      await tester.pumpWidget(
        _signedInPage(
          hub: _StubHub(
            calendarsPayload: [_hubPublicCalendar(readOnly: true)],
            eventsPayload: [_hubEvent()],
          ),
          linkService: signedInLink,
          launcher: _RecordingLauncher(),
        ),
      );
      await tester.pumpAndSettle();
      await _tapEventAndShare(tester, 'Training');

      expect(signedOutLink.calls, hasLength(1));
      expect(signedInLink.calls, hasLength(1));
      // Same canonical calendar reference, same source UID, same (absent)
      // occurrence identity — the complete mint input, byte for byte.
      expect(signedInLink.calls.single, signedOutLink.calls.single);
      expect(signedOutLink.calls.single.calendarUrl, _kPublicCalendarUrl);
      expect(signedOutLink.calls.single.uid, _kUid);
      expect(signedOutLink.calls.single.occurrenceId, isNull);
    });

    testWidgets('a public RECURRING occurrence mints identically signed out '
        'and signed in', (tester) async {
      final signedOutLink = _RecordingLinkService();
      final signedInLink = _RecordingLinkService();

      await tester.pumpWidget(
        _signedOutPage(
          events: [
            _localEvent(
              recurring: true,
              canonicalRecurrenceId: _kCanonicalRecurrenceId,
            ),
          ],
          linkService: signedOutLink,
          launcher: _RecordingLauncher(),
        ),
      );
      await tester.pumpAndSettle();
      await _tapEventAndShare(tester, 'Training');

      await tester.pumpWidget(
        _signedInPage(
          hub: _StubHub(
            calendarsPayload: [_hubPublicCalendar(readOnly: true)],
            eventsPayload: [
              _hubEvent(
                recurring: true,
                canonicalRecurrenceId: _kCanonicalRecurrenceId,
              ),
            ],
          ),
          linkService: signedInLink,
          launcher: _RecordingLauncher(),
        ),
      );
      await tester.pumpAndSettle();
      await _tapEventAndShare(tester, 'Training');

      expect(signedInLink.calls.single, signedOutLink.calls.single);
      // The canonical identity, never either side's display recurrence id.
      expect(signedOutLink.calls.single.occurrenceId, _kCanonicalRecurrenceId);
    });

    testWidgets('signing in does NOT remove Share when the signed-in row is '
        'WRITABLE', (tester) async {
      // The regression this issue exists for. Guest sees a published,
      // read-only follow; the signed-in account happens to have write access
      // to the very same published calendar. Publication did not change, so
      // the link must not change — and Share must not disappear behind the
      // Edit/Delete branch.
      final signedOutLink = _RecordingLinkService();
      final signedInLink = _RecordingLinkService();

      await tester.pumpWidget(
        _signedOutPage(
          events: [_localEvent()],
          linkService: signedOutLink,
          launcher: _RecordingLauncher(),
        ),
      );
      await tester.pumpAndSettle();
      await _tapEventAndShare(tester, 'Training');

      await tester.pumpWidget(
        _signedInPage(
          hub: _StubHub(
            calendarsPayload: [_hubPublicCalendar(readOnly: false)],
            eventsPayload: [_hubEvent(readOnly: false)],
          ),
          linkService: signedInLink,
          launcher: _RecordingLauncher(),
        ),
      );
      await tester.pumpAndSettle();
      await _tapEventAndShare(tester, 'Training');

      expect(signedInLink.calls.single, signedOutLink.calls.single);
    });

    testWidgets('the minted URL reaches the share sheet unchanged on both '
        'sides', (tester) async {
      final signedOutLauncher = _RecordingLauncher();
      final signedInLauncher = _RecordingLauncher();

      await tester.pumpWidget(
        _signedOutPage(
          events: [_localEvent()],
          linkService: _RecordingLinkService(),
          launcher: signedOutLauncher,
        ),
      );
      await tester.pumpAndSettle();
      await _tapEventAndShare(tester, 'Training');

      await tester.pumpWidget(
        _signedInPage(
          hub: _StubHub(
            calendarsPayload: [_hubPublicCalendar(readOnly: true)],
            eventsPayload: [_hubEvent()],
          ),
          linkService: _RecordingLinkService(),
          launcher: signedInLauncher,
        ),
      );
      await tester.pumpAndSettle();
      await _tapEventAndShare(tester, 'Training');

      expect(signedOutLauncher.urls.single.toString(), _kMintedLink);
      expect(
        signedInLauncher.urls.single.toString(),
        signedOutLauncher.urls.single.toString(),
      );
    });
  });

  group('signing in does not CREATE publication either', () {
    testWidgets('a private family event is never shareable signed in', (
      tester,
    ) async {
      final link = _RecordingLinkService();
      await tester.pumpWidget(
        _signedInPage(
          hub: _StubHub(
            calendarsPayload: const [_familyCalendar],
            eventsPayload: [
              _hubEvent(
                calendarId: 'portal:family',
                title: 'Dentist',
                readOnly: false,
              ),
            ],
          ),
          linkService: link,
          launcher: _RecordingLauncher(),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Dentist').first);
      await tester.pumpAndSettle();

      expect(find.text('Share event'), findsNothing);
      expect(link.calls, isEmpty);
      await _dismissSheet(tester);
    });

    testWidgets('an arbitrary private ICS follow is never shareable signed '
        'out', (tester) async {
      final link = _RecordingLinkService();
      await tester.pumpWidget(
        _signedOutPage(
          subscription: LocalCalendarSubscription(
            id: 'sub-private',
            title: 'School Newsletter',
            url: 'https://school.example.com/private/feed.ics',
            source: 'school.example.com',
            createdAt: DateTime(2024, 1, 1),
          ),
          events: [_localEvent(title: 'Assembly')],
          linkService: link,
          launcher: _RecordingLauncher(),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Assembly').first);
      await tester.pumpAndSettle();

      expect(find.text('Share event'), findsNothing);
      expect(link.calls, isEmpty);
      await _dismissSheet(tester);
    });

    testWidgets('a public occurrence with no canonical recurrence identity '
        'is refused on BOTH sides', (tester) async {
      final signedOutLink = _RecordingLinkService();
      final signedInLink = _RecordingLinkService();

      await tester.pumpWidget(
        _signedOutPage(
          events: [_localEvent(recurring: true, canonicalRecurrenceId: null)],
          linkService: signedOutLink,
          launcher: _RecordingLauncher(),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Training').first);
      await tester.pumpAndSettle();
      expect(find.text('Share event'), findsNothing);
      expect(find.byKey(kLocalEventShareUnavailableKey), findsOneWidget);
      await _dismissSheet(tester);

      await tester.pumpWidget(
        _signedInPage(
          hub: _StubHub(
            calendarsPayload: [_hubPublicCalendar(readOnly: true)],
            eventsPayload: [
              _hubEvent(recurring: true, canonicalRecurrenceId: null),
            ],
          ),
          linkService: signedInLink,
          launcher: _RecordingLauncher(),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Training').first);
      await tester.pumpAndSettle();
      expect(find.text('Share event'), findsNothing);

      // Both sides say the same thing about the same occurrence.
      expect(find.byKey(kLocalEventShareUnavailableKey), findsOneWidget);
      expect(signedOutLink.calls, isEmpty);
      expect(signedInLink.calls, isEmpty);
    });
  });
}

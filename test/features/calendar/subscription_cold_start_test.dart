// The account-backed subscription COLD START, from the Mobile side.
//
// The journey this file exists for:
//
//   Add existing calendar → I already have a calendar link → validate →
//   "8 events found" → add → "Calendar added to Calee" → View calendar
//
// and then, in the reported defect, a Calendar showing Family dinner, the new
// "Club Events" calendar enabled and blue-checked, and no sign whatsoever of
// the Club Community Fundraiser it had just been told was in there.
//
// The contract these tests hold Mobile to is: Calee never presents a
// newly-added connected calendar as empty while it knows the first sync is
// still pending. Either the events are there (ready), or Calee says it is
// syncing and converges on its own.
//
// Deliberately covers the honest boundaries too — a genuinely empty feed is
// ready-and-empty and gets the ordinary UI, an old backend behaves exactly as
// before, a hidden calendar is not announced, polling stops on dispose, and
// the retries are bounded.

import 'package:calee_mobile/data/api/calee_hub_client.dart';
import 'package:calee_mobile/data/auth/calee_preferences.dart';
import 'package:calee_mobile/data/models/client_bootstrap.dart';
import 'package:calee_mobile/data/models/client_calendar.dart';
import 'package:calee_mobile/features/calendar/calendar_controller.dart';
import 'package:calee_mobile/features/calendar/calendar_page.dart';
import 'package:calee_mobile/features/calendar/calendar_repository.dart';
import 'package:calee_mobile/features/calendar/shared/read_only_calendar_view.dart';
import 'package:calee_mobile/features/calendar/widgets/calendar_error_state.dart';
import 'package:calee_mobile/features/calendar_onboarding/calendar_added_success_page.dart';
import 'package:calee_mobile/ui/calee_design.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

// ── Fixtures ─────────────────────────────────────────────────────────────────

const _service = ClientService(
  id: 'portal',
  displayName: 'Portal',
  baseUrl: 'http://localhost',
  launchUrl: 'http://localhost',
  serviceType: 'nextcloud_portal',
  accessStatus: 'active',
  calendarCredentialStatus: 'connected',
  source: 'test',
  capabilities: {'calendar': true, 'tasks': false, 'chores': false},
);

/// The connected calendar from the report.
ClientCalendar _clubEvents({CalendarSyncState? syncState}) => ClientCalendar(
  id: 'portal:club-events',
  serviceId: 'portal',
  serviceName: 'Portal',
  name: 'Club Events',
  components: const [],
  primaryKind: 'calendar',
  supportsEvents: true,
  supportsTasks: false,
  supportsChores: false,
  readOnly: true,
  isSubscription: true,
  source: 'portal',
  subscriptionSyncState: syncState,
);

/// The ordinary family calendar that must keep working throughout.
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
  source: 'portal',
);

/// The event the user could still see while the fundraiser was missing.
const _familyDinner = ClientEvent(
  id: 'family-dinner',
  calendarId: 'portal:family',
  serviceId: 'portal',
  serviceName: 'Portal',
  title: 'Family dinner',
  startsAt: '2026-10-25T09:00:00Z',
  endsAt: '2026-10-25T10:00:00Z',
  allDay: false,
  recurring: false,
  source: 'portal',
);

/// The event that was missing.
const _fundraiser = ClientEvent(
  id: 'club-fundraiser',
  calendarId: 'portal:club-events',
  serviceId: 'portal',
  serviceName: 'Portal',
  title: 'Club Community Fundraiser',
  startsAt: '2026-10-25T02:30:00Z',
  endsAt: '2026-10-25T06:30:00Z',
  allDay: false,
  recurring: false,
  readOnly: true,
  source: 'calendar_subscription',
);

// ── Stubs ────────────────────────────────────────────────────────────────────

class _StubPrefs extends CaleePreferences {
  @override
  Future<StoredPreferences> load() async => const StoredPreferences();
}

/// A Hub whose payload can transition from syncing to ready between loads,
/// exactly as the real backend does once the authoritative refresh completes.
class _StubHub extends CaleeHubClient {
  _StubHub({required this.calendarsPayload, required this.eventsPayload})
    : super();

  List<ClientCalendar> calendarsPayload;
  List<ClientEvent> eventsPayload;

  int calendarLoadCount = 0;
  int eventLoadCount = 0;

  /// Flips the payload to its ready form after this many calendar loads.
  int? becomeReadyAfterLoads;
  List<ClientCalendar>? readyCalendars;
  List<ClientEvent>? readyEvents;

  @override
  Future<ClientCalendarList> calendars({required String accessToken}) async {
    calendarLoadCount++;
    final threshold = becomeReadyAfterLoads;
    if (threshold != null && calendarLoadCount > threshold) {
      calendarsPayload = readyCalendars ?? calendarsPayload;
      eventsPayload = readyEvents ?? eventsPayload;
    }
    return ClientCalendarList(
      calendars: List<ClientCalendar>.from(calendarsPayload),
    );
  }

  @override
  Future<ClientEventList> events({
    required String accessToken,
    required String from,
    required String to,
  }) async {
    eventLoadCount++;
    return ClientEventList(
      from: from,
      to: to,
      events: List<ClientEvent>.from(eventsPayload),
    );
  }
}

CalendarController _controller(
  _StubHub hub, {
  Duration interval = const Duration(milliseconds: 20),
  int maxAttempts = 3,
}) => CalendarController(
  repository: CalendarRepository(
    hubClient: hub,
    accessToken: 'tok',
    preferences: _StubPrefs(),
  ),
  syncConvergenceInterval: interval,
  syncConvergenceMaxAttempts: maxAttempts,
);

Widget _hostCalendar(_StubHub hub) => MaterialApp(
  theme: CaleeTheme.buildThemeData(),
  home: CalendarPage(
    hubClient: hub,
    accessToken: 'tok',
    services: const [_service],
    accountId: 'acct1',
    isFamilyUxContext: true,
  ),
);

void main() {
  // Same platform-channel setup CalendarPage's own suite uses: the page
  // creates CaleePreferences internally, which reaches for shared preferences
  // and secure storage.
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

  // ───────────────────────────────────────────────────────────────────────────
  group('ClientCalendar.subscriptionSyncState', () {
    test('parses each state the Hub contract defines', () {
      ClientCalendar parse(Object? value) => ClientCalendar.fromJson({
        'id': 'portal:club-events',
        'isSubscription': true,
        'subscriptionSyncState': value,
      });

      expect(parse('ready').subscriptionSyncState, CalendarSyncState.ready);
      expect(parse('syncing').subscriptionSyncState, CalendarSyncState.syncing);
      expect(parse('error').subscriptionSyncState, CalendarSyncState.error);
    });

    test('an older Hub that omits the field is not treated as syncing', () {
      // The regression this guards: defaulting the absent field to "syncing"
      // would put a permanent banner on every calendar against an old backend.
      final calendar = ClientCalendar.fromJson({
        'id': 'portal:club-events',
        'isSubscription': true,
      });

      expect(calendar.subscriptionSyncState, isNull);
      expect(calendar.isInitialSyncPending, isFalse);
      expect(calendar.hasInitialSyncError, isFalse);
    });

    test('an unrecognised future state is not guessed at', () {
      final calendar = ClientCalendar.fromJson({
        'id': 'portal:club-events',
        'isSubscription': true,
        'subscriptionSyncState': 'reticulating',
      });

      expect(calendar.subscriptionSyncState, isNull);
      expect(calendar.isInitialSyncPending, isFalse);
    });

    test('a non-subscription calendar reports null, never a sync state', () {
      final calendar = ClientCalendar.fromJson({
        'id': 'portal:family',
        'isSubscription': false,
        'subscriptionSyncState': null,
      });

      expect(calendar.subscriptionSyncState, isNull);
    });
  });

  // ───────────────────────────────────────────────────────────────────────────
  group('CalendarController initial-sync convergence', () {
    test(
      'READY: the fundraiser is on screen and nothing is announced',
      () async {
        final hub = _StubHub(
          calendarsPayload: [
            _familyCalendar,
            _clubEvents(syncState: CalendarSyncState.ready),
          ],
          eventsPayload: [_familyDinner, _fundraiser],
        );
        final controller = _controller(hub);
        addTearDown(controller.dispose);

        await controller.loadMonth();

        expect(controller.syncingCalendars, isEmpty);
        expect(
          controller.events.map((e) => e.title),
          containsAll(<String>['Family dinner', 'Club Community Fundraiser']),
        );
      },
    );

    test(
      'SYNCING: announced, and the rest of the calendar is untouched',
      () async {
        final hub = _StubHub(
          calendarsPayload: [
            _familyCalendar,
            _clubEvents(syncState: CalendarSyncState.syncing),
          ],
          eventsPayload: [_familyDinner],
        );
        final controller = _controller(hub);
        addTearDown(controller.dispose);

        await controller.loadMonth();

        expect(controller.syncingCalendars.map((c) => c.name), <String>[
          'Club Events',
        ]);
        // The new calendar is enabled (#582) AND the family's own events are
        // still there. Neither may be traded for the other.
        expect(controller.isCalendarVisible('portal:club-events'), isTrue);
        expect(
          controller.events.map((e) => e.title),
          contains('Family dinner'),
        );
      },
    );

    test('converges automatically once the backend reports ready', () async {
      final hub =
          _StubHub(
              calendarsPayload: [
                _familyCalendar,
                _clubEvents(syncState: CalendarSyncState.syncing),
              ],
              eventsPayload: [_familyDinner],
            )
            ..becomeReadyAfterLoads = 1
            ..readyCalendars = [
              _familyCalendar,
              _clubEvents(syncState: CalendarSyncState.ready),
            ]
            ..readyEvents = [_familyDinner, _fundraiser];

      final controller = _controller(hub);
      addTearDown(controller.dispose);

      await controller.loadMonth();
      expect(controller.syncingCalendars, isNotEmpty, reason: 'starts syncing');

      // No user action: the bounded re-check does it.
      await Future<void>.delayed(const Duration(milliseconds: 120));

      expect(controller.syncingCalendars, isEmpty);
      expect(controller.syncConvergenceExhausted, isFalse);
      expect(
        controller.events.map((e) => e.title),
        contains('Club Community Fundraiser'),
      );
    });

    test('retries are bounded and end in a truthful passive state', () async {
      final hub = _StubHub(
        calendarsPayload: [
          _familyCalendar,
          _clubEvents(syncState: CalendarSyncState.syncing),
        ],
        eventsPayload: [_familyDinner],
      );
      final controller = _controller(hub, maxAttempts: 3);
      addTearDown(controller.dispose);

      await controller.loadMonth();
      await Future<void>.delayed(const Duration(milliseconds: 300));

      final settled = hub.calendarLoadCount;
      // 1 explicit load + at most maxAttempts automatic re-checks. Never an
      // indefinite poll.
      expect(settled, lessThanOrEqualTo(4));
      expect(controller.syncConvergenceExhausted, isTrue);

      // And it really has STOPPED, not merely slowed.
      await Future<void>.delayed(const Duration(milliseconds: 200));
      expect(hub.calendarLoadCount, settled);
    });

    test('no polling after dispose', () async {
      final hub = _StubHub(
        calendarsPayload: [
          _familyCalendar,
          _clubEvents(syncState: CalendarSyncState.syncing),
        ],
        eventsPayload: [_familyDinner],
      );
      final controller = _controller(hub, maxAttempts: 50);

      await controller.loadMonth();
      final atDispose = hub.calendarLoadCount;
      controller.dispose();

      await Future<void>.delayed(const Duration(milliseconds: 150));

      expect(hub.calendarLoadCount, atDispose);
    });

    test('a hidden calendar is neither announced nor polled for', () async {
      final hub = _StubHub(
        calendarsPayload: [
          _familyCalendar,
          _clubEvents(syncState: CalendarSyncState.syncing),
        ],
        eventsPayload: [_familyDinner],
      );
      final controller = _controller(hub, maxAttempts: 50);
      addTearDown(controller.dispose);

      await controller.loadMonth();
      // The user hides the newly-added calendar, which must still work.
      controller.toggleCalendarVisibility('portal:club-events');
      await controller.loadMonth();

      expect(controller.isCalendarVisible('portal:club-events'), isFalse);
      expect(controller.syncingCalendars, isEmpty);

      final settled = hub.calendarLoadCount;
      await Future<void>.delayed(const Duration(milliseconds: 150));
      expect(
        hub.calendarLoadCount,
        settled,
        reason: 'no polling for a hidden calendar',
      );
    });

    test(
      'a genuinely empty READY calendar gets no syncing treatment',
      () async {
        final hub = _StubHub(
          calendarsPayload: [
            _familyCalendar,
            _clubEvents(syncState: CalendarSyncState.ready),
          ],
          eventsPayload: [_familyDinner],
        );
        final controller = _controller(hub, maxAttempts: 50);
        addTearDown(controller.dispose);

        await controller.loadMonth();

        expect(controller.syncingCalendars, isEmpty);
        expect(controller.syncFailedCalendars, isEmpty);

        final settled = hub.calendarLoadCount;
        await Future<void>.delayed(const Duration(milliseconds: 150));
        expect(hub.calendarLoadCount, settled);
      },
    );

    test('an error state is reported truthfully and is not polled', () async {
      final hub = _StubHub(
        calendarsPayload: [
          _familyCalendar,
          _clubEvents(syncState: CalendarSyncState.error),
        ],
        eventsPayload: [_familyDinner],
      );
      final controller = _controller(hub, maxAttempts: 50);
      addTearDown(controller.dispose);

      await controller.loadMonth();

      expect(controller.syncingCalendars, isEmpty);
      expect(controller.syncFailedCalendars.map((c) => c.name), <String>[
        'Club Events',
      ]);

      final settled = hub.calendarLoadCount;
      await Future<void>.delayed(const Duration(milliseconds: 150));
      expect(
        hub.calendarLoadCount,
        settled,
        reason: 'an error is not a poll loop',
      );
    });
  });

  // ───────────────────────────────────────────────────────────────────────────
  group('CalendarSyncingBanner wording', () {
    test('names the calendar while syncing', () {
      const banner = CalendarSyncingBanner(
        syncingCalendarNames: ['Club Events'],
      );
      expect(banner.message, 'Syncing Club Events…');
    });

    test('summarises when several are syncing', () {
      const banner = CalendarSyncingBanner(
        syncingCalendarNames: ['Club Events', 'Under 16s'],
      );
      expect(banner.message, 'Syncing 2 calendars…');
    });

    test('goes passive rather than claiming a time, once exhausted', () {
      const banner = CalendarSyncingBanner(
        syncingCalendarNames: ['Club Events'],
        exhausted: true,
      );
      expect(banner.message, 'Still syncing Club Events. Pull to refresh.');
    });

    test('reports a failure without any backend detail', () {
      const banner = CalendarSyncingBanner(
        syncingCalendarNames: [],
        failedCalendarNames: ['Club Events'],
      );
      expect(
        banner.message,
        'Calee could not sync Club Events. Pull to refresh.',
      );
    });

    testWidgets('renders nothing at all when there is nothing to say', (
      tester,
    ) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(body: CalendarSyncingBanner(syncingCalendarNames: [])),
        ),
      );
      expect(find.byKey(const Key('calendar_syncing_banner')), findsNothing);
    });

    testWidgets('wraps rather than truncating at large text scale', (
      tester,
    ) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) => MediaQuery(
              data: MediaQuery.of(
                context,
              ).copyWith(textScaler: const TextScaler.linear(2.0)),
              child: const Scaffold(
                body: CalendarSyncingBanner(
                  syncingCalendarNames: ['Club Events'],
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      final text = tester.widget<Text>(find.text('Syncing Club Events…'));
      expect(text.maxLines, isNull);
      expect(text.overflow, isNot(TextOverflow.ellipsis));
    });
  });

  // ───────────────────────────────────────────────────────────────────────────
  group('CalendarAddedSuccessPage', () {
    testWidgets('says "Syncing events…" instead of promising them', (
      tester,
    ) async {
      await tester.pumpWidget(
        MaterialApp(
          home: CalendarAddedSuccessPage(
            onViewCalendar: () {},
            syncState: CalendarSyncState.syncing,
          ),
        ),
      );

      expect(find.text('Calendar added to Calee'), findsOneWidget);
      final detail = tester.widget<Text>(
        find.byKey(const Key('calendar_added_detail')),
      );
      expect(detail.data, contains('Syncing events…'));
      expect(
        detail.data,
        isNot(contains('will appear on your Calee display shortly')),
      );
    });

    testWidgets('keeps the original wording when ready or unknown', (
      tester,
    ) async {
      for (final state in <CalendarSyncState?>[CalendarSyncState.ready, null]) {
        await tester.pumpWidget(
          MaterialApp(
            home: CalendarAddedSuccessPage(
              onViewCalendar: () {},
              syncState: state,
            ),
          ),
        );
        final detail = tester.widget<Text>(
          find.byKey(const Key('calendar_added_detail')),
        );
        expect(
          detail.data,
          'Your events will appear on your Calee display shortly.',
        );
      }
    });
  });

  // ───────────────────────────────────────────────────────────────────────────
  group('Calendar screen journey', () {
    testWidgets('SYNCING shows the notice without taking the screen over', (
      tester,
    ) async {
      final hub = _StubHub(
        calendarsPayload: [
          _familyCalendar,
          _clubEvents(syncState: CalendarSyncState.syncing),
        ],
        eventsPayload: [_familyDinner],
      );

      await tester.pumpWidget(_hostCalendar(hub));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('calendar_syncing_banner')), findsOneWidget);
      expect(find.text('Syncing Club Events…'), findsOneWidget);

      // Non-blocking: the calendar itself is still on screen (not replaced by
      // a spinner or an error state), and the family's own event is still in
      // the month it renders. Asserted on the view's data rather than on a
      // visible row because the agenda opens on today, not on the fixture's
      // October date — the contract is "nothing was hidden", not "this row is
      // currently scrolled into view".
      expect(find.byType(ReadOnlyCalendarView), findsOneWidget);
      final view = tester.widget<ReadOnlyCalendarView>(
        find.byType(ReadOnlyCalendarView),
      );
      expect(view.events.map((e) => e.title), contains('Family dinner'));
    });

    testWidgets('the notice disappears once the event arrives', (tester) async {
      final hub =
          _StubHub(
              calendarsPayload: [
                _familyCalendar,
                _clubEvents(syncState: CalendarSyncState.syncing),
              ],
              eventsPayload: [_familyDinner],
            )
            ..becomeReadyAfterLoads = 1
            ..readyCalendars = [
              _familyCalendar,
              _clubEvents(syncState: CalendarSyncState.ready),
            ]
            ..readyEvents = [_familyDinner, _fundraiser];

      await tester.pumpWidget(_hostCalendar(hub));
      await tester.pumpAndSettle();

      expect(find.text('Syncing Club Events…'), findsOneWidget);

      // The page's own bounded re-check converges it — no user action.
      await tester.pump(const Duration(seconds: 6));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('calendar_syncing_banner')), findsNothing);
    });

    testWidgets('READY shows no notice at all', (tester) async {
      final hub = _StubHub(
        calendarsPayload: [
          _familyCalendar,
          _clubEvents(syncState: CalendarSyncState.ready),
        ],
        eventsPayload: [_familyDinner, _fundraiser],
      );

      await tester.pumpWidget(_hostCalendar(hub));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('calendar_syncing_banner')), findsNothing);
    });
  });
}

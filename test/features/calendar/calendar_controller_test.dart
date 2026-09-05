import 'dart:async';

import 'package:calee_mobile/data/api/calee_hub_client.dart';
import 'package:calee_mobile/data/auth/calee_preferences.dart';
import 'package:calee_mobile/data/models/client_calendar.dart';
import 'package:calee_mobile/features/calendar/calendar_controller.dart';
import 'package:calee_mobile/features/calendar/calendar_repository.dart';
import 'package:calee_mobile/features/calendar/newly_added_calendar_visibility.dart';
import 'package:calee_mobile/features/notifications/calendar_reminder_coordinator.dart';
import 'package:flutter_test/flutter_test.dart';

// ─── Stubs ────────────────────────────────────────────────────────────────────

class _StubPrefs extends CaleePreferences {
  _StubPrefs(this._stored);
  final StoredPreferences _stored;

  @override
  Future<StoredPreferences> load() async => _stored;
}

class _StubHubClient extends CaleeHubClient {
  _StubHubClient({
    List<ClientCalendar>? calendars,
    List<ClientEvent>? events,
    this.failCalendars = false,
  }) : _calendars = calendars ?? [],
       _events = events ?? [],
       super();

  final List<ClientCalendar> _calendars;
  final List<ClientEvent> _events;
  final bool failCalendars;

  @override
  Future<ClientCalendarList> calendars({required String accessToken}) async {
    if (failCalendars) throw Exception('network error');
    return ClientCalendarList(calendars: _calendars);
  }

  @override
  Future<ClientEventList> events({
    required String accessToken,
    required String from,
    required String to,
  }) async {
    return ClientEventList(from: from, to: to, events: _events);
  }

  @override
  Future<ClientEvent> createEvent({
    required String accessToken,
    required String serviceId,
    required String calendarId,
    required String title,
    required String startsAt,
    required String endsAt,
    required bool allDay,
    String? location,
    String? description,
    String? recurrence,
  }) async => _stubEvent(title);

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
  }) async => _stubEvent(title);

  @override
  Future<void> deleteEvent({
    required String accessToken,
    required String eventId,
    String? scope,
  }) async {}
}

/// Hub stub whose payload can change between fetches, that records every
/// requested window, and that can hold a fetch open so overlapping loads are
/// testable without arbitrary waits.
class _MutableStubHubClient extends CaleeHubClient {
  _MutableStubHubClient({
    List<ClientCalendar>? calendars,
    List<ClientEvent>? events,
  }) : calendarsPayload = calendars ?? [],
       eventsPayload = events ?? [],
       super();

  List<ClientCalendar> calendarsPayload;
  List<ClientEvent> eventsPayload;
  bool failEvents = false;
  int eventFetchCount = 0;
  final List<({String from, String to})> requestedWindows = [];

  /// When set, `events()` waits on it before returning — the payload it will
  /// return is snapshotted at call time, so a held-open fetch stays "old".
  Completer<void>? gate;

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
  }) async {
    eventFetchCount++;
    requestedWindows.add((from: from, to: to));
    final payload = List<ClientEvent>.from(eventsPayload);
    final shouldFail = failEvents;
    final pending = gate;
    if (pending != null) await pending.future;
    if (shouldFail) throw Exception('network error');
    return ClientEventList(from: from, to: to, events: payload);
  }
}

ClientEvent _stubEvent(String title) => ClientEvent(
  id: 'new',
  calendarId: 'cal1',
  serviceId: 'svc',
  serviceName: 'Test',
  title: title,
  startsAt: '2026-06-15T09:00:00',
  endsAt: '2026-06-15T10:00:00',
  allDay: false,
  recurring: false,
  source: 'test',
);

// ─── Helpers ──────────────────────────────────────────────────────────────────

ClientCalendar _calendar(String id, {String primaryKind = 'calendar'}) =>
    ClientCalendar(
      id: id,
      serviceId: 'svc',
      serviceName: 'Test',
      name: 'Cal $id',
      components: const [],
      primaryKind: primaryKind,
      supportsEvents: true,
      supportsTasks: false,
      supportsChores: false,
      readOnly: false,
      isSubscription: false,
      source: 'test',
    );

ClientEvent _event(
  String id, {
  String calendarId = 'cal1',
  bool allDay = false,
  String startsAt = '2026-06-15T09:00:00',
  String endsAt = '2026-06-15T10:00:00',
  bool recurring = false,
}) => ClientEvent(
  id: id,
  calendarId: calendarId,
  serviceId: 'svc',
  serviceName: 'Test',
  title: 'Event $id',
  startsAt: startsAt,
  endsAt: endsAt,
  allDay: allDay,
  recurring: recurring,
  source: 'test',
);

CalendarController _makeController({
  List<ClientCalendar>? calendars,
  List<ClientEvent>? events,
  bool failCalendars = false,
  StoredPreferences? prefs,
  Future<void> Function(CalendarReminderRefreshReason reason)?
  onRequestReminderRefresh,
}) {
  final hub = _StubHubClient(
    calendars: calendars,
    events: events,
    failCalendars: failCalendars,
  );
  final repo = CalendarRepository(
    hubClient: hub,
    accessToken: 'tok',
    preferences: _StubPrefs(prefs ?? const StoredPreferences()),
  );
  return CalendarController(
    repository: repo,
    onRequestReminderRefresh: onRequestReminderRefresh,
  );
}

CalendarController _controllerWithHub(
  CaleeHubClient hub, {
  StoredPreferences? prefs,
  Future<void> Function(CalendarReminderRefreshReason reason)?
  onRequestReminderRefresh,
  NewlyAddedCalendarVisibility? newlyAddedCalendarVisibility,
}) => CalendarController(
  repository: CalendarRepository(
    hubClient: hub,
    accessToken: 'tok',
    preferences: _StubPrefs(prefs ?? const StoredPreferences()),
  ),
  onRequestReminderRefresh: onRequestReminderRefresh,
  newlyAddedCalendarVisibility:
      newlyAddedCalendarVisibility ?? NewlyAddedCalendarVisibility(),
);

/// Lets pending microtasks (a repository fetch reaching the hub stub) run
/// without an arbitrary wall-clock wait.
Future<void> _settle() => Future<void>.delayed(Duration.zero);

// ─── Live-evidence fixtures ───────────────────────────────────────────────────
//
// The read-only subscribed calendar and the event that reproduced the stale-
// agenda defect on Pixel_9, taken verbatim from the confirmed hub responses.

const _lazersCalendarId = 'portal:lazers-morley-eagles';

const _lazersCalendar = ClientCalendar(
  id: _lazersCalendarId,
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
  source: 'portal',
);

const _setupEvent = ClientEvent(
  id: 'setup-1',
  calendarId: _lazersCalendarId,
  serviceId: 'portal',
  serviceName: 'Portal',
  title: 'Setup',
  startsAt: '2026-08-04T05:30:00Z',
  endsAt: '2026-08-04T06:30:00Z',
  allDay: false,
  recurring: false,
  readOnly: true,
  source: 'portal',
);

final _setupMonth = DateTime(2026, 8, 1);

/// The local calendar day the Setup event falls on. Derived from the UTC
/// instant so the test asserts the same thing in any host timezone (CI runs
/// Australia/Perth, where it renders as 1:30 PM–2:30 PM on 4 August).
final _setupDay = () {
  final local = DateTime.parse('2026-08-04T05:30:00Z').toLocal();
  return DateTime(local.year, local.month, local.day);
}();

// ─── Newly added connected calendar (the "Under 12s" defect) ─────────────────

const _under12sCalendarId = 'portal:under-12s';

const _under12sCalendar = ClientCalendar(
  id: _under12sCalendarId,
  serviceId: 'portal',
  serviceName: 'Calee Portal',
  name: 'Under 12s',
  components: [],
  primaryKind: 'calendar',
  supportsEvents: true,
  supportsTasks: false,
  supportsChores: false,
  readOnly: true,
  isSubscription: true,
  source: 'portal',
);

const _round4Event = ClientEvent(
  id: 'round-4',
  calendarId: _under12sCalendarId,
  serviceId: 'portal',
  serviceName: 'Calee Portal',
  title: 'Under 12s - Round 4 Home Fixture',
  startsAt: '2026-10-24T01:00:00Z',
  endsAt: '2026-10-24T02:00:00Z',
  allDay: false,
  recurring: false,
  readOnly: true,
  source: 'portal',
);

final _round4Month = DateTime(2026, 10, 1);

/// The local day the Round 4 fixture falls on, derived from its UTC instant so
/// the assertion holds in any host timezone.
final _round4Day = () {
  final local = DateTime.parse('2026-10-24T01:00:00Z').toLocal();
  return DateTime(local.year, local.month, local.day);
}();

// ─── Tests ────────────────────────────────────────────────────────────────────

void main() {
  // ── Repository ──────────────────────────────────────────────────────────────

  group('CalendarRepository.loadMonth', () {
    test('filters calendars to isCalendarKind', () async {
      final repo = CalendarRepository(
        hubClient: _StubHubClient(
          calendars: [
            _calendar('cal-calendar', primaryKind: 'calendar'),
            _calendar('cal-tasks', primaryKind: 'tasks'),
            _calendar('cal-chores', primaryKind: 'chores'),
          ],
        ),
        accessToken: 'tok',
        preferences: _StubPrefs(const StoredPreferences()),
      );

      final overview = await repo.loadMonth(
        selectedMonth: DateTime(2026, 6, 1),
      );

      expect(overview.calendars, hasLength(1));
      expect(overview.calendars.first.id, 'cal-calendar');
    });

    test('computes 42-day grid (6 weeks)', () async {
      final repo = CalendarRepository(
        hubClient: _StubHubClient(),
        accessToken: 'tok',
        preferences: _StubPrefs(const StoredPreferences()),
      );

      final overview = await repo.loadMonth(
        selectedMonth: DateTime(2026, 6, 1),
      );

      final diff = overview.gridEnd.difference(overview.gridStart).inDays;
      expect(diff, 41); // gridStart + 41 days = 42-day window
    });
  });

  // ── Controller loading ──────────────────────────────────────────────────────

  group('CalendarController.loadMonth', () {
    test('sets isLoading true then false on success', () async {
      final ctrl = _makeController(calendars: [_calendar('c1')]);

      final loadingStates = <bool>[];
      ctrl.addListener(() => loadingStates.add(ctrl.isLoading));

      await ctrl.loadMonth();

      expect(loadingStates.first, isTrue);
      expect(loadingStates.last, isFalse);
    });

    test('sets error on failure', () async {
      final ctrl = _makeController(failCalendars: true);

      await ctrl.loadMonth();

      expect(ctrl.error, isNotNull);
      expect(ctrl.isLoading, isFalse);
    });

    test('populates calendars on success', () async {
      final ctrl = _makeController(
        calendars: [_calendar('c1'), _calendar('c2')],
      );

      await ctrl.loadMonth();

      expect(ctrl.calendars, hasLength(2));
      expect(ctrl.error, isNull);
    });
  });

  // ── Background refresh ──────────────────────────────────────────────────────
  //
  // The controller keeps the loaded month in memory for as long as CalendarPage
  // stays alive, so an event that reaches the hub after the initial load (a
  // subscribed calendar syncing, for example) used to stay invisible until the
  // user left Calendar and came back. refreshInBackground() is the deterministic
  // refresh path the page drives from the app-resume lifecycle transition.

  group('CalendarController.refreshInBackground', () {
    test('shows a subscribed-calendar event that appeared after the initial '
        'load', () async {
      final hub = _MutableStubHubClient(calendars: [_lazersCalendar]);
      final ctrl = _controllerWithHub(hub);
      ctrl.selectedMonth = _setupMonth;
      ctrl.selectedDay = _setupDay;

      await ctrl.loadMonth();
      expect(
        ctrl.eventsForDay(_setupDay),
        isEmpty,
        reason: 'initial load returns the pre-sync feed',
      );

      // The subscribed feed now carries the event.
      hub.eventsPayload = [_setupEvent];
      await ctrl.refreshInBackground();

      final shown = ctrl.eventsForDay(_setupDay);
      expect(shown.map((e) => e.title), ['Setup']);
      expect(shown.single.calendarId, _lazersCalendarId);
      expect(
        ctrl.calendarForEvent(shown.single)?.name,
        'Lazers (Morley Eagles)',
      );
      expect(
        ctrl.calendarForEvent(shown.single)?.readOnly,
        isTrue,
        reason: 'the read-only subscribed calendar still renders',
      );
    });

    test('never raises the blocking loading state', () async {
      final hub = _MutableStubHubClient(calendars: [_lazersCalendar]);
      final ctrl = _controllerWithHub(hub);
      await ctrl.loadMonth();

      final observedLoading = <bool>[];
      ctrl.addListener(() => observedLoading.add(ctrl.isLoading));

      hub.eventsPayload = [_setupEvent];
      await ctrl.refreshInBackground();

      expect(observedLoading, isNotEmpty, reason: 'the refresh did publish');
      expect(
        observedLoading.any((loading) => loading),
        isFalse,
        reason: 'an automatic refresh must not flash a full-screen spinner',
      );
      expect(ctrl.isLoading, isFalse);
    });

    test(
      'preserves the selected day, month, and hidden-calendar filters',
      () async {
        final hub = _MutableStubHubClient(calendars: [_lazersCalendar]);
        final ctrl = _controllerWithHub(hub);
        ctrl.selectedMonth = _setupMonth;
        ctrl.selectedDay = _setupDay;
        await ctrl.loadMonth();

        ctrl.toggleCalendarVisibility(_lazersCalendarId);
        hub.eventsPayload = [_setupEvent];
        await ctrl.refreshInBackground();

        expect(ctrl.selectedDay, _setupDay);
        expect(ctrl.selectedMonth, _setupMonth);
        expect(ctrl.isCalendarVisible(_lazersCalendarId), isFalse);
        expect(
          ctrl.eventsForDay(_setupDay),
          isEmpty,
          reason: 'a hidden calendar stays filtered out after a refresh',
        );

        ctrl.toggleCalendarVisibility(_lazersCalendarId);
        expect(ctrl.eventsForDay(_setupDay).map((e) => e.title), ['Setup']);
      },
    );

    test('refetches only the displayed 42-day grid, not all history', () async {
      final hub = _MutableStubHubClient(calendars: [_lazersCalendar]);
      final ctrl = _controllerWithHub(hub);
      ctrl.selectedMonth = _setupMonth;
      await ctrl.loadMonth();
      hub.requestedWindows.clear();

      await ctrl.refreshInBackground();

      final gridStart = CalendarRepository.computeGridStart(
        _setupMonth,
        FirstDayOfWeek.sunday,
      );
      expect(hub.requestedWindows, hasLength(1));
      expect(
        hub.requestedWindows.single.from,
        CalendarRepository.formatDate(gridStart),
      );
      expect(
        hub.requestedWindows.single.to,
        CalendarRepository.formatDate(gridStart.add(const Duration(days: 41))),
      );
    });

    test('is skipped while another load is already in flight', () async {
      final hub = _MutableStubHubClient(calendars: [_lazersCalendar]);
      final ctrl = _controllerWithHub(hub);
      final gate = Completer<void>();
      hub.gate = gate;

      final initial = ctrl.loadMonth();
      await _settle();
      expect(hub.eventFetchCount, 1);

      // Repeated lifecycle notifications must not stack overlapping requests.
      await ctrl.refreshInBackground();
      await ctrl.refreshInBackground();
      expect(hub.eventFetchCount, 1);

      gate.complete();
      await initial;
      expect(hub.eventFetchCount, 1);

      // Once nothing is in flight, a refresh runs normally again.
      hub.gate = null;
      await ctrl.refreshInBackground();
      expect(hub.eventFetchCount, 2);
    });

    test('an older in-flight result cannot overwrite newer state', () async {
      final hub = _MutableStubHubClient(calendars: [_lazersCalendar]);
      final ctrl = _controllerWithHub(hub);
      ctrl.selectedMonth = _setupMonth;
      ctrl.selectedDay = _setupDay;
      await ctrl.loadMonth();

      // Hold a background refresh open on the stale (empty) payload…
      final gate = Completer<void>();
      hub.gate = gate;
      final stale = ctrl.refreshInBackground();
      await _settle();

      // …then let a newer explicit load complete with the Setup event.
      hub.gate = null;
      hub.eventsPayload = [_setupEvent];
      await ctrl.loadMonth();
      expect(ctrl.events.map((e) => e.title), ['Setup']);

      // The older fetch now returns its stale, empty payload.
      gate.complete();
      await stale;

      expect(
        ctrl.events.map((e) => e.title),
        ['Setup'],
        reason: 'a superseded result must never replace newer state',
      );
    });

    test('a failed background refresh keeps the last good snapshot', () async {
      final hub = _MutableStubHubClient(
        calendars: [_lazersCalendar],
        events: [_setupEvent],
      );
      final ctrl = _controllerWithHub(hub);
      ctrl.selectedMonth = _setupMonth;
      ctrl.selectedDay = _setupDay;
      await ctrl.loadMonth();

      hub.failEvents = true;
      await ctrl.refreshInBackground();

      expect(ctrl.eventsForDay(_setupDay).map((e) => e.title), ['Setup']);
      expect(ctrl.calendars, hasLength(1));
      expect(
        ctrl.error,
        isNull,
        reason: 'a silent refresh failure must not swap in the error screen',
      );
    });

    test('does not request a reminder refresh', () async {
      final reasons = <CalendarReminderRefreshReason>[];
      final hub = _MutableStubHubClient(calendars: [_lazersCalendar]);
      final ctrl = _controllerWithHub(
        hub,
        onRequestReminderRefresh: (r) async => reasons.add(r),
      );
      await ctrl.loadMonth();
      reasons.clear();

      await ctrl.refreshInBackground();
      await _settle();

      expect(
        reasons,
        isEmpty,
        reason: 'app-resume reminder reconciliation is owned by CaleeApp',
      );
    });

    // Pull-to-refresh enters through refresh(); app-resume enters through
    // refreshInBackground(). This pins the interaction between the two entry
    // points — the surrounding tests cover each in isolation.
    test('a pull refresh racing a background refresh publishes only the '
        'newest data', () async {
      final reasons = <CalendarReminderRefreshReason>[];
      final hub = _MutableStubHubClient(calendars: [_lazersCalendar]);
      final ctrl = _controllerWithHub(
        hub,
        onRequestReminderRefresh: (r) async => reasons.add(r),
      );
      ctrl.selectedMonth = _setupMonth;
      ctrl.selectedDay = _setupDay;
      await ctrl.loadMonth();
      reasons.clear();

      // A background (app-resume) refresh is in flight on the stale payload…
      final backgroundGate = Completer<void>();
      hub.gate = backgroundGate;
      final background = ctrl.refreshInBackground();
      await _settle();
      final fetchesAfterBackground = hub.eventFetchCount;

      // …when the user pulls to refresh. The pull must still run.
      hub.gate = null;
      hub.eventsPayload = [_setupEvent];
      await ctrl.refresh();
      await _settle();

      expect(hub.eventFetchCount, fetchesAfterBackground + 1);
      expect(ctrl.eventsForDay(_setupDay).map((e) => e.title), ['Setup']);
      expect(reasons, [
        CalendarReminderRefreshReason.manualRefresh,
      ], reason: 'a pull keeps manual-refresh semantics');

      // The older background response now lands carrying the pre-sync payload.
      backgroundGate.complete();
      await background;

      expect(
        ctrl.eventsForDay(_setupDay).map((e) => e.title),
        ['Setup'],
        reason: 'a superseded background result must not undo the pull',
      );
    });

    test('a result arriving after dispose is dropped safely', () async {
      final hub = _MutableStubHubClient(calendars: [_lazersCalendar]);
      final ctrl = _controllerWithHub(hub);
      await ctrl.loadMonth();

      final gate = Completer<void>();
      hub.gate = gate;
      final pending = ctrl.refreshInBackground();
      await _settle();

      ctrl.dispose();
      gate.complete();

      // notifyListeners() after dispose would throw into this future.
      await expectLater(pending, completes);
    });
  });

  // ── Navigation ──────────────────────────────────────────────────────────────

  group('CalendarController navigation', () {
    test('previousMonth decrements month', () async {
      final ctrl = _makeController();

      // Override selectedMonth to a known value for a deterministic test
      ctrl.selectedMonth = DateTime(2026, 6, 1);
      ctrl.selectedDay = DateTime(2026, 6, 15);

      ctrl.previousMonth();
      await Future<void>.delayed(Duration.zero); // let async loadMonth settle

      expect(ctrl.selectedMonth, DateTime(2026, 5, 1));
    });

    test('nextMonth increments month', () async {
      final ctrl = _makeController();
      ctrl.selectedMonth = DateTime(2026, 6, 1);
      ctrl.selectedDay = DateTime(2026, 6, 15);

      ctrl.nextMonth();
      await Future<void>.delayed(Duration.zero);

      expect(ctrl.selectedMonth, DateTime(2026, 7, 1));
    });

    test('previousMonth resets selectedDay when outside new month', () async {
      final ctrl = _makeController();
      ctrl.selectedMonth = DateTime(2026, 6, 1);
      ctrl.selectedDay = DateTime(2026, 6, 15); // in June

      ctrl.previousMonth(); // goes to May
      await Future<void>.delayed(Duration.zero);

      // selectedDay is in June but new month is May → reset to 1st of May
      expect(ctrl.selectedDay, DateTime(2026, 5, 1));
    });

    test('nextMonth keeps selectedDay when inside new month', () async {
      final ctrl = _makeController();
      ctrl.selectedMonth = DateTime(2026, 6, 1);
      ctrl.selectedDay = DateTime(2026, 6, 1); // same as first of month

      ctrl.nextMonth(); // goes to July; selectedDay was June 1
      await Future<void>.delayed(Duration.zero);

      // selectedDay (June 1) is not in July → reset to 1st of July
      expect(ctrl.selectedDay, DateTime(2026, 7, 1));
    });
  });

  // ── Calendar visibility ─────────────────────────────────────────────────────

  group('CalendarController visibility', () {
    test('toggleCalendarVisibility hides a visible calendar', () {
      final ctrl = _makeController();
      expect(ctrl.isCalendarVisible('cal1'), isTrue);

      ctrl.toggleCalendarVisibility('cal1');

      expect(ctrl.isCalendarVisible('cal1'), isFalse);
    });

    test('toggleCalendarVisibility shows a hidden calendar', () {
      final ctrl = _makeController();
      ctrl.toggleCalendarVisibility('cal1');
      expect(ctrl.isCalendarVisible('cal1'), isFalse);

      ctrl.toggleCalendarVisibility('cal1');

      expect(ctrl.isCalendarVisible('cal1'), isTrue);
    });

    test('showAllCalendars clears all hidden IDs', () {
      final ctrl = _makeController();
      ctrl.toggleCalendarVisibility('cal1');
      ctrl.toggleCalendarVisibility('cal2');
      expect(ctrl.hiddenCalendarIds, hasLength(2));

      ctrl.showAllCalendars();

      expect(ctrl.hiddenCalendarIds, isEmpty);
    });
  });

  // ── Newly added connected calendar visibility ───────────────────────────────

  group('CalendarController newly added calendar visibility', () {
    /// Puts the controller in the state the user was in before adding:
    /// existing calendars loaded, one of them hidden by choice, and a stale
    /// hidden entry for the id the new calendar will arrive with.
    Future<(CalendarController, _MutableStubHubClient)> loadedWithHiddenIds({
      required NewlyAddedCalendarVisibility newlyAdded,
    }) async {
      final hub = _MutableStubHubClient(
        calendars: [_calendar('cal1'), _calendar('cal2')],
      );
      final ctrl = _controllerWithHub(
        hub,
        newlyAddedCalendarVisibility: newlyAdded,
      );
      ctrl.selectedMonth = _round4Month;
      ctrl.selectedDay = _round4Day;
      await ctrl.loadMonth();

      ctrl.toggleCalendarVisibility('cal2'); // an existing, deliberate choice
      // A same-id entry left behind by an earlier "Under 12s" that this client
      // never saw disappear — the state that showed the new calendar unchecked.
      ctrl.toggleCalendarVisibility(_under12sCalendarId);
      return (ctrl, hub);
    }

    test('a just-added connected calendar is visible and its events render '
        'on the next load', () async {
      final newlyAdded = NewlyAddedCalendarVisibility();
      final (ctrl, hub) = await loadedWithHiddenIds(newlyAdded: newlyAdded);

      // The add succeeded ("Calendar added to Calee") and the calendar and its
      // already-available events are now in hub's payload.
      newlyAdded.record(_under12sCalendarId);
      hub.calendarsPayload = [
        _calendar('cal1'),
        _calendar('cal2'),
        _under12sCalendar,
      ];
      hub.eventsPayload = [_round4Event];

      await ctrl.refresh();

      expect(ctrl.isCalendarVisible(_under12sCalendarId), isTrue);
      expect(ctrl.eventsForDay(_round4Day).map((e) => e.title), [
        'Under 12s - Round 4 Home Fixture',
      ]);
    });

    test('adding one calendar leaves other hidden calendars hidden', () async {
      final newlyAdded = NewlyAddedCalendarVisibility();
      final (ctrl, hub) = await loadedWithHiddenIds(newlyAdded: newlyAdded);

      newlyAdded.record(_under12sCalendarId);
      hub.calendarsPayload = [
        _calendar('cal1'),
        _calendar('cal2'),
        _under12sCalendar,
      ];

      await ctrl.refresh();

      expect(ctrl.isCalendarVisible('cal2'), isFalse);
      expect(ctrl.isCalendarVisible('cal1'), isTrue);
      expect(ctrl.hiddenCalendarIds, {'cal2'});
    });

    test('hiding the new calendar afterwards still works and survives a '
        'reload', () async {
      final newlyAdded = NewlyAddedCalendarVisibility();
      final (ctrl, hub) = await loadedWithHiddenIds(newlyAdded: newlyAdded);

      newlyAdded.record(_under12sCalendarId);
      hub.calendarsPayload = [
        _calendar('cal1'),
        _calendar('cal2'),
        _under12sCalendar,
      ];
      hub.eventsPayload = [_round4Event];
      await ctrl.refresh();

      ctrl.toggleCalendarVisibility(_under12sCalendarId);
      await ctrl.refresh();

      expect(ctrl.isCalendarVisible(_under12sCalendarId), isFalse);
      expect(ctrl.eventsForDay(_round4Day), isEmpty);
      expect(ctrl.isCalendarVisible('cal2'), isFalse);
    });
  });

  // ── eventsForDay ────────────────────────────────────────────────────────────

  group('CalendarController.eventsForDay', () {
    test('returns timed event on its start date', () async {
      final ctrl = _makeController(
        calendars: [_calendar('cal1')],
        events: [_event('e1', startsAt: '2026-06-15T09:00:00')],
      );
      await ctrl.loadMonth();

      final result = ctrl.eventsForDay(DateTime(2026, 6, 15));

      expect(result, hasLength(1));
      expect(result.first.id, 'e1');
    });

    test('returns all-day event using exclusive endsAt', () async {
      // Event runs June 15–17 (endsAt June 18 exclusive)
      final ctrl = _makeController(
        calendars: [_calendar('cal1')],
        events: [
          _event(
            'e1',
            allDay: true,
            startsAt: '2026-06-15',
            endsAt: '2026-06-18', // exclusive end
          ),
        ],
      );
      await ctrl.loadMonth();

      expect(ctrl.eventsForDay(DateTime(2026, 6, 15)), hasLength(1));
      expect(ctrl.eventsForDay(DateTime(2026, 6, 17)), hasLength(1));
      expect(ctrl.eventsForDay(DateTime(2026, 6, 18)), isEmpty); // exclusive
    });

    test('excludes events from hidden calendars', () async {
      final ctrl = _makeController(
        calendars: [_calendar('cal1')],
        events: [_event('e1', calendarId: 'cal1')],
      );
      await ctrl.loadMonth();

      ctrl.toggleCalendarVisibility('cal1');
      final result = ctrl.eventsForDay(DateTime(2026, 6, 15));

      expect(result, isEmpty);
    });
  });

  // ── searchEvents ────────────────────────────────────────────────────────────

  group('CalendarController.searchEvents', () {
    test('returns empty list for empty query', () async {
      final ctrl = _makeController(
        calendars: [_calendar('cal1')],
        events: [_event('e1')],
      );
      await ctrl.loadMonth();

      expect(ctrl.searchEvents(''), isEmpty);
    });

    test('matches event by title', () async {
      final ctrl = _makeController(
        calendars: [_calendar('cal1')],
        events: [_event('e1')],
      );
      await ctrl.loadMonth();

      // _event sets title to 'Event e1'
      final results = ctrl.searchEvents('event e1');
      expect(results, hasLength(1));
    });

    test('hides events from hidden calendars', () async {
      final ctrl = _makeController(
        calendars: [_calendar('cal1')],
        events: [_event('e1', calendarId: 'cal1')],
      );
      await ctrl.loadMonth();

      ctrl.toggleCalendarVisibility('cal1');
      final results = ctrl.searchEvents('event');

      expect(results, isEmpty);
    });
  });

  // ── Reminder-refresh integration ─────────────────────────────────────────────
  //
  // Month navigation (loadMonth) must NEVER touch device reminders; only
  // explicit changes (CRUD) and manual refreshes request a reminder refresh.

  group('CalendarController reminder-refresh triggers', () {
    test('loadMonth does not request a reminder refresh', () async {
      final reasons = <CalendarReminderRefreshReason>[];
      final ctrl = _makeController(
        calendars: [_calendar('cal1')],
        events: [_event('e1')],
        onRequestReminderRefresh: (r) async => reasons.add(r),
      );

      await ctrl.loadMonth();
      await Future<void>.delayed(Duration.zero);

      expect(reasons, isEmpty);
    });

    test('month navigation does not request a reminder refresh', () async {
      final reasons = <CalendarReminderRefreshReason>[];
      final ctrl = _makeController(
        calendars: [_calendar('cal1')],
        events: [_event('e1')],
        onRequestReminderRefresh: (r) async => reasons.add(r),
      );
      await ctrl.loadMonth();
      reasons.clear();

      ctrl.selectedMonth = DateTime(2026, 6, 1);
      ctrl.nextMonth();
      await Future<void>.delayed(Duration.zero);
      ctrl.previousMonth();
      await Future<void>.delayed(Duration.zero);
      ctrl.goToToday();
      await Future<void>.delayed(Duration.zero);

      expect(
        reasons,
        isEmpty,
        reason: 'navigating months must not reconcile reminders',
      );
    });

    test('createEvent requests an eventCreated refresh', () async {
      final reasons = <CalendarReminderRefreshReason>[];
      final ctrl = _makeController(
        calendars: [_calendar('cal1')],
        onRequestReminderRefresh: (r) async => reasons.add(r),
      );

      await ctrl.createEvent(
        calendar: _calendar('cal1'),
        title: 'New',
        startsAt: DateTime(2026, 6, 15, 9),
        endsAt: DateTime(2026, 6, 15, 10),
        allDay: false,
      );
      await Future<void>.delayed(Duration.zero);

      expect(reasons, [CalendarReminderRefreshReason.eventCreated]);
    });

    test('updateEvent requests an eventUpdated refresh', () async {
      final reasons = <CalendarReminderRefreshReason>[];
      final ctrl = _makeController(
        calendars: [_calendar('cal1')],
        onRequestReminderRefresh: (r) async => reasons.add(r),
      );

      await ctrl.updateEvent(
        event: _event('e1'),
        title: 'Edited',
        startsAt: DateTime(2026, 6, 15, 11),
        endsAt: DateTime(2026, 6, 15, 12),
        allDay: false,
      );
      await Future<void>.delayed(Duration.zero);

      expect(reasons, [CalendarReminderRefreshReason.eventUpdated]);
    });

    test('deleteEvent requests an eventDeleted refresh', () async {
      final reasons = <CalendarReminderRefreshReason>[];
      final ctrl = _makeController(
        calendars: [_calendar('cal1')],
        onRequestReminderRefresh: (r) async => reasons.add(r),
      );

      await ctrl.deleteEvent(event: _event('e1'));
      await Future<void>.delayed(Duration.zero);

      expect(reasons, [CalendarReminderRefreshReason.eventDeleted]);
    });

    test(
      'refresh() requests a manualRefresh after a successful reload',
      () async {
        final reasons = <CalendarReminderRefreshReason>[];
        final ctrl = _makeController(
          calendars: [_calendar('cal1')],
          onRequestReminderRefresh: (r) async => reasons.add(r),
        );

        await ctrl.refresh();
        await Future<void>.delayed(Duration.zero);

        expect(reasons, [CalendarReminderRefreshReason.manualRefresh]);
      },
    );

    test(
      'refresh() does not request a reminder refresh when the reload fails',
      () async {
        final reasons = <CalendarReminderRefreshReason>[];
        final ctrl = _makeController(
          failCalendars: true,
          onRequestReminderRefresh: (r) async => reasons.add(r),
        );

        await ctrl.refresh();
        await Future<void>.delayed(Duration.zero);

        expect(reasons, isEmpty);
      },
    );

    test(
      'a reminder-refresh failure does not turn a successful CRUD op into a failure',
      () async {
        final ctrl = _makeController(
          calendars: [_calendar('cal1')],
          onRequestReminderRefresh: (r) async =>
              throw Exception('reminder refresh boom'),
        );

        // The create itself succeeds even though the reminder refresh throws.
        await expectLater(
          ctrl.createEvent(
            calendar: _calendar('cal1'),
            title: 'New',
            startsAt: DateTime(2026, 6, 15, 9),
            endsAt: DateTime(2026, 6, 15, 10),
            allDay: false,
          ),
          completes,
        );
        await Future<void>.delayed(Duration.zero);
      },
    );
  });
}

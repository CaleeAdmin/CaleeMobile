// Tests for CalendarReminderCoordinator: signed-out guard, disabled/permission
// handling, throttling, forced reconciliation, single-flight, and fetch-failure
// behaviour.

import 'dart:async';
import 'dart:convert';

import 'package:calee_mobile/data/api/calee_hub_client.dart';
import 'package:calee_mobile/data/auth/calee_preferences.dart';
import 'package:calee_mobile/data/models/calendar_reminder_manifest.dart';
import 'package:calee_mobile/data/models/client_calendar.dart';
import 'package:calee_mobile/features/notifications/calendar_notification_candidates.dart';
import 'package:calee_mobile/features/notifications/calendar_reminder_coordinator.dart';
import 'package:calee_mobile/features/notifications/local_calendar_notification_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

// ── Fakes ─────────────────────────────────────────────────────────────────────

class _FakeHub extends CaleeHubClient {
  _FakeHub({this.eventsToReturn = const [], this.fail = false})
    : super(baseUri: Uri.parse('http://localhost'));

  final List<ClientEvent> eventsToReturn;
  final bool fail;
  int eventsCallCount = 0;
  final List<String> requestedFrom = [];
  final List<String> requestedTo = [];

  @override
  Future<ClientEventList> events({
    required String accessToken,
    required String from,
    required String to,
  }) async {
    eventsCallCount++;
    requestedFrom.add(from);
    requestedTo.add(to);
    if (fail) {
      throw const CaleeHubException(statusCode: 500, message: 'server error');
    }
    return ClientEventList(from: from, to: to, events: eventsToReturn);
  }
}

/// Blocks inside events() until [release] completes, so overlapping refreshes
/// can be observed.
class _BlockingHub extends CaleeHubClient {
  _BlockingHub() : super(baseUri: Uri.parse('http://localhost'));

  final Completer<void> release = Completer<void>();
  int eventsCallCount = 0;

  @override
  Future<ClientEventList> events({
    required String accessToken,
    required String from,
    required String to,
  }) async {
    eventsCallCount++;
    await release.future;
    return ClientEventList(from: from, to: to, events: const []);
  }
}

/// A hub whose every `events()` call can be individually observed (when it
/// begins) and released (when it may return), so overlapping and queued
/// refreshes can be driven deterministically. Optionally fails specific calls.
class _GatedHub extends CaleeHubClient {
  _GatedHub({this.failCalls = const <int>{}})
    : super(baseUri: Uri.parse('http://localhost'));

  final Set<int> failCalls;
  int eventsCallCount = 0;
  final List<String> tokens = [];
  final List<Completer<void>> _gates = [];
  final List<Completer<void>> _reached = [];

  void _ensure(int index) {
    while (_gates.length <= index) {
      _gates.add(Completer<void>());
      _reached.add(Completer<void>());
    }
  }

  /// Resolves once the 0-based [callIndex]th `events()` call has begun.
  Future<void> reached(int callIndex) {
    _ensure(callIndex);
    return _reached[callIndex].future;
  }

  /// Allows the 0-based [callIndex]th `events()` call to return (or throw).
  void release(int callIndex) {
    _ensure(callIndex);
    if (!_gates[callIndex].isCompleted) _gates[callIndex].complete();
  }

  @override
  Future<ClientEventList> events({
    required String accessToken,
    required String from,
    required String to,
  }) async {
    final index = eventsCallCount++;
    tokens.add(accessToken);
    _ensure(index);
    if (!_reached[index].isCompleted) _reached[index].complete();
    await _gates[index].future;
    if (failCalls.contains(index)) {
      throw const CaleeHubException(statusCode: 500, message: 'server error');
    }
    return ClientEventList(from: from, to: to, events: const []);
  }
}

class _FakeNotifs extends LocalCalendarNotificationService {
  _FakeNotifs({this.permission = true}) : super.forTest();

  final bool permission;
  int reconcileCount = 0;
  int disableCount = 0;
  final List<List<ClientEvent>> reconcileArgs = [];
  final List<String?> reconcileOwnerKeys = [];
  final List<String> disableOwnerKeys = [];

  @override
  Future<bool> requestPermissionIfNeeded() async => permission;

  @override
  Future<CalendarReminderDisableResult> disableCalendarReminders({
    required String ownerKey,
    bool includeLegacyOwnerless = false,
  }) async {
    disableCount++;
    disableOwnerKeys.add(ownerKey);
    return const CalendarReminderDisableResult(
      cancelledCount: 0,
      failedCount: 0,
      manifestPersisted: true,
    );
  }

  @override
  Future<CalendarReconciliationResult> reconcileCalendarReminders(
    List<ClientEvent> events, {
    DateTime? now,
    String? ownerKey,
    CalendarReminderOperationContext? context,
  }) async {
    reconcileCount++;
    reconcileArgs.add(events);
    reconcileOwnerKeys.add(context?.ownerKey ?? ownerKey);
    return CalendarReconciliationResult(
      eventsFetched: events.length,
      eligibleCandidates: events.length,
      scheduledCount: events.length,
      cancelledCount: 0,
      unchangedCount: 0,
      failedCount: 0,
      completedAt: now ?? DateTime(2026),
    );
  }
}

/// Notification service spy that records targeted-cleanup calls and returns a
/// configurable [CalendarReminderDisableResult], used for the disabled-cleanup
/// and permission-denied coordinator paths.
class _CleanupSpyNotifs extends LocalCalendarNotificationService {
  _CleanupSpyNotifs({
    this.permission = true,
    this.disableResult = const CalendarReminderDisableResult(
      cancelledCount: 2,
      failedCount: 0,
      manifestPersisted: true,
    ),
  }) : super.forTest();

  final bool permission;
  final CalendarReminderDisableResult disableResult;
  int disableCount = 0;
  int reconcileCount = 0;
  final List<String> disableOwnerKeys = [];
  final List<bool> disableIncludeLegacy = [];

  @override
  Future<bool> requestPermissionIfNeeded() async => permission;

  @override
  Future<CalendarReminderDisableResult> disableCalendarReminders({
    required String ownerKey,
    bool includeLegacyOwnerless = false,
  }) async {
    disableCount++;
    disableOwnerKeys.add(ownerKey);
    disableIncludeLegacy.add(includeLegacyOwnerless);
    return disableResult;
  }

  @override
  Future<CalendarReconciliationResult> reconcileCalendarReminders(
    List<ClientEvent> events, {
    DateTime? now,
    String? ownerKey,
    CalendarReminderOperationContext? context,
  }) async {
    reconcileCount++;
    return CalendarReconciliationResult(
      eventsFetched: events.length,
      eligibleCandidates: events.length,
      scheduledCount: events.length,
      cancelledCount: 0,
      unchangedCount: 0,
      failedCount: 0,
      completedAt: now ?? DateTime(2026),
    );
  }
}

/// Preferences stub returning a configured structured load result, and
/// optionally throwing on save, so the coordinator's preference-unavailable and
/// permission-denied-plus-save-failure paths can be driven without real storage.
class _StubPrefs extends CaleePreferences {
  _StubPrefs(this.loadResult, {this.saveError});

  final CalendarReminderPreferenceLoadResult loadResult;
  final Object? saveError;
  int loadCount = 0;
  int saveCount = 0;

  @override
  Future<CalendarReminderPreferenceLoadResult>
  loadCalendarRemindersEnabledResult({String? ownerKey}) async {
    loadCount++;
    return loadResult;
  }

  @override
  Future<void> saveCalendarRemindersEnabled({
    String? ownerKey,
    required bool enabled,
  }) async {
    saveCount++;
    if (saveError != null) throw saveError!;
  }
}

/// Preferences stub whose load blocks until [releaseLoad] is called, so a
/// session change can be injected while a preference read is in flight.
class _BlockingLoadPrefs extends CaleePreferences {
  _BlockingLoadPrefs(this._result);

  final CalendarReminderPreferenceLoadResult _result;
  final Completer<void> _reached = Completer<void>();
  final Completer<void> _gate = Completer<void>();
  int loadCount = 0;
  int saveCount = 0;

  Future<void> get reachedLoad => _reached.future;
  void releaseLoad() {
    if (!_gate.isCompleted) _gate.complete();
  }

  @override
  Future<CalendarReminderPreferenceLoadResult>
  loadCalendarRemindersEnabledResult({String? ownerKey}) async {
    loadCount++;
    if (!_reached.isCompleted) _reached.complete();
    await _gate.future;
    return _result;
  }

  @override
  Future<void> saveCalendarRemindersEnabled({
    String? ownerKey,
    required bool enabled,
  }) async {
    saveCount++;
  }
}

/// Preferences stub whose `saveCalendarRemindersEnabled` blocks until released,
/// so a sign-out / account switch can be injected while the permission-denied
/// preference write is still queued (Fix: stale permission-denied cleanup race).
class _BlockingSavePrefs extends CaleePreferences {
  _BlockingSavePrefs(this._loadResult, {this.saveError});

  final CalendarReminderPreferenceLoadResult _loadResult;
  final Object? saveError;
  final Completer<void> _reached = Completer<void>();
  final Completer<void> _gate = Completer<void>();
  int loadCount = 0;
  int saveCount = 0;

  Future<void> get reachedSave => _reached.future;
  void releaseSave() {
    if (!_gate.isCompleted) _gate.complete();
  }

  @override
  Future<CalendarReminderPreferenceLoadResult>
  loadCalendarRemindersEnabledResult({String? ownerKey}) async {
    loadCount++;
    return _loadResult;
  }

  @override
  Future<void> saveCalendarRemindersEnabled({
    String? ownerKey,
    required bool enabled,
  }) async {
    saveCount++;
    if (!_reached.isCompleted) _reached.complete();
    await _gate.future;
    if (saveError != null) throw saveError!;
  }
}

/// Notification service whose permission request blocks until released, so a
/// session change can be injected while the permission dialog is resolving.
class _BlockingPermissionNotifs extends LocalCalendarNotificationService {
  _BlockingPermissionNotifs({required this.grant}) : super.forTest();

  final bool grant;
  final Completer<void> _reached = Completer<void>();
  final Completer<void> _gate = Completer<void>();
  int reconcileCount = 0;
  int disableCount = 0;

  Future<void> get reachedPermission => _reached.future;
  void releasePermission() {
    if (!_gate.isCompleted) _gate.complete();
  }

  @override
  Future<bool> requestPermissionIfNeeded() async {
    if (!_reached.isCompleted) _reached.complete();
    await _gate.future;
    return grant;
  }

  @override
  Future<CalendarReminderDisableResult> disableCalendarReminders({
    required String ownerKey,
    bool includeLegacyOwnerless = false,
  }) async {
    disableCount++;
    return const CalendarReminderDisableResult(
      cancelledCount: 0,
      failedCount: 0,
      manifestPersisted: true,
    );
  }

  @override
  Future<CalendarReconciliationResult> reconcileCalendarReminders(
    List<ClientEvent> events, {
    DateTime? now,
    String? ownerKey,
    CalendarReminderOperationContext? context,
  }) async {
    reconcileCount++;
    return CalendarReconciliationResult(
      eventsFetched: events.length,
      eligibleCandidates: events.length,
      scheduledCount: events.length,
      cancelledCount: 0,
      unchangedCount: 0,
      failedCount: 0,
      completedAt: now ?? DateTime(2026),
    );
  }
}

// ── Helpers ───────────────────────────────────────────────────────────────────

final _now = DateTime(2026, 7, 4, 12, 0, 0);

ClientEvent _event(String id) => ClientEvent(
  id: id,
  calendarId: 'cal1',
  serviceId: 'svc',
  serviceName: 'Test',
  title: 'Event $id',
  startsAt: '2026-07-05T09:00:00',
  endsAt: '2026-07-05T10:00:00',
  allDay: false,
  recurring: false,
  source: 'test',
);

/// Builds a coordinator and, by default, begins an active reminder session for
/// [beginAccount]. A refresh now requires an active session (a non-empty token
/// is not sufficient), so tests that exercise refresh behaviour need an owner;
/// pass `beginAccount: null` for tests that deliberately start with no session
/// (e.g. verifying an empty/whitespace begin creates no owner).
CalendarReminderCoordinator _make({
  required CaleeHubClient hub,
  required LocalCalendarNotificationService notifs,
  DateTime Function()? clock,
  Duration throttle = const Duration(minutes: 5),
  CaleePreferences? prefs,
  String? beginAccount = 'acct-A',
}) {
  final coord = CalendarReminderCoordinator(
    hubClient: hub,
    notificationService: notifs,
    preferences: prefs,
    now: clock ?? () => _now,
    throttle: throttle,
  );
  if (beginAccount != null) {
    coord.beginSession(accountId: beginAccount);
  }
  return coord;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({
      'calee_pref_migrated_to_shared_prefs': true,
      'calee_pref_calendar_reminders_enabled': true,
    });
  });

  test('signed out: does not fetch or reconcile', () async {
    final hub = _FakeHub();
    final notifs = _FakeNotifs();
    final coord = _make(hub: hub, notifs: notifs);

    final result = await coord.refresh(
      accessToken: null,
      reason: CalendarReminderRefreshReason.sessionRestored,
    );

    expect(result.status, CalendarReminderRefreshStatus.skippedSignedOut);
    expect(hub.eventsCallCount, 0);
    expect(notifs.reconcileCount, 0);
  });

  group('active-session guard (Defect 2)', () {
    test('a non-empty token without an active session does nothing', () async {
      final hub = _FakeHub(eventsToReturn: [_event('e1')]);
      final notifs = _FakeNotifs();
      // A stub that records whether the preference was even read.
      final prefs = _StubPrefs(
        const CalendarReminderPreferenceLoadResult.loaded(true),
      );
      // No session: begin nothing.
      final coord = _make(
        hub: hub,
        notifs: notifs,
        prefs: prefs,
        beginAccount: null,
      );
      expect(coord.hasActiveSession, isFalse);

      final result = await coord.refresh(
        accessToken: 'tok',
        reason: CalendarReminderRefreshReason.sessionRestored,
      );

      expect(
        result.status,
        CalendarReminderRefreshStatus.skippedNoActiveSession,
      );
      expect(
        prefs.loadCount,
        0,
        reason: 'no preference read without a session',
      );
      expect(hub.eventsCallCount, 0, reason: 'no event fetch');
      expect(notifs.reconcileCount, 0, reason: 'no reconciliation');
      expect(notifs.disableCount, 0, reason: 'no notification mutation');
    });

    test('beginning a valid session then permits a refresh', () async {
      final hub = _FakeHub(eventsToReturn: [_event('e1')]);
      final notifs = _FakeNotifs();
      final coord = _make(
        hub: hub,
        notifs: notifs,
        prefs: _StubPrefs(
          const CalendarReminderPreferenceLoadResult.loaded(true),
        ),
        beginAccount: null,
      );

      // Guarded before a session exists.
      final skipped = await coord.refresh(
        accessToken: 'tok',
        reason: CalendarReminderRefreshReason.sessionRestored,
      );
      expect(
        skipped.status,
        CalendarReminderRefreshStatus.skippedNoActiveSession,
      );

      // After a valid session begins, the refresh proceeds.
      coord.beginSession(accountId: 'acct-A');
      expect(coord.hasActiveSession, isTrue);
      final result = await coord.refresh(
        accessToken: 'tok',
        reason: CalendarReminderRefreshReason.sessionRestored,
      );
      expect(result.status, CalendarReminderRefreshStatus.reconciled);
      expect(hub.eventsCallCount, 1);
      expect(notifs.reconcileCount, 1);
    });
  });

  test('reminders disabled: does not fetch or reconcile', () async {
    SharedPreferences.setMockInitialValues({
      'calee_pref_migrated_to_shared_prefs': true,
      'calee_pref_calendar_reminders_enabled': false,
    });
    final hub = _FakeHub();
    final notifs = _FakeNotifs();
    final coord = _make(hub: hub, notifs: notifs);

    final result = await coord.refresh(
      accessToken: 'tok',
      reason: CalendarReminderRefreshReason.sessionRestored,
    );

    expect(result.status, CalendarReminderRefreshStatus.skippedDisabled);
    expect(hub.eventsCallCount, 0);
    expect(notifs.reconcileCount, 0);
  });

  test(
    'restored signed-in session fetches the 30-day window and reconciles',
    () async {
      final hub = _FakeHub(eventsToReturn: [_event('e1')]);
      final notifs = _FakeNotifs();
      final coord = _make(hub: hub, notifs: notifs);

      final result = await coord.refresh(
        accessToken: 'tok',
        reason: CalendarReminderRefreshReason.sessionRestored,
      );

      expect(result.status, CalendarReminderRefreshStatus.reconciled);
      expect(result.didReconcile, isTrue);
      expect(hub.eventsCallCount, 1);
      expect(notifs.reconcileCount, 1);
      // Window: start of the current local day through 30 days ahead.
      expect(hub.requestedFrom.single, '2026-07-04');
      expect(hub.requestedTo.single, '2026-08-03');
      expect(result.reconciliation, isNotNull);
    },
  );

  test(
    'permission denied: flips the stored preference off and does not fetch',
    () async {
      final hub = _FakeHub();
      final notifs = _FakeNotifs(permission: false);
      final coord = _make(hub: hub, notifs: notifs);

      final result = await coord.refresh(
        accessToken: 'tok',
        reason: CalendarReminderRefreshReason.remindersEnabled,
      );

      expect(result.status, CalendarReminderRefreshStatus.permissionDenied);
      expect(hub.eventsCallCount, 0);
      expect(
        await CaleePreferences().loadCalendarRemindersEnabled(),
        isFalse,
        reason: 'stored preference is kept honest when permission is missing',
      );
    },
  );

  group('fetch failure', () {
    test('reports fetchFailed and does not reconcile', () async {
      final hub = _FakeHub(fail: true);
      final notifs = _FakeNotifs();
      final coord = _make(hub: hub, notifs: notifs);

      final result = await coord.refresh(
        accessToken: 'tok',
        reason: CalendarReminderRefreshReason.appResumed,
      );

      expect(result.status, CalendarReminderRefreshStatus.fetchFailed);
      expect(result.didFetchFail, isTrue);
      expect(result.errorCategory, isNotNull);
      expect(notifs.reconcileCount, 0);
    });

    test(
      'preserves the existing manifest (does not clear or cancel)',
      () async {
        SharedPreferences.setMockInitialValues({
          'calee_pref_migrated_to_shared_prefs': true,
          'calee_pref_calendar_reminders_enabled': true,
          'calee_pref_calendar_reminder_manifest': _manifestJson([7, 8, 9]),
        });
        final hub = _FakeHub(fail: true);
        final notifs = _FakeNotifs();
        final coord = _make(hub: hub, notifs: notifs);

        await coord.refresh(
          accessToken: 'tok',
          reason: CalendarReminderRefreshReason.manualRefresh,
        );

        final manifest = await CaleePreferences()
            .loadCalendarReminderManifest();
        expect(manifest.scheduledIds, [7, 8, 9]);
      },
    );
  });

  group('throttling', () {
    test('routine refreshes are throttled within the window', () async {
      final hub = _FakeHub(eventsToReturn: [_event('e1')]);
      final notifs = _FakeNotifs();
      final coord = _make(hub: hub, notifs: notifs);

      final first = await coord.refresh(
        accessToken: 'tok',
        reason: CalendarReminderRefreshReason.appResumed,
      );
      final second = await coord.refresh(
        accessToken: 'tok',
        reason: CalendarReminderRefreshReason.appResumed,
      );

      expect(first.status, CalendarReminderRefreshStatus.reconciled);
      expect(second.status, CalendarReminderRefreshStatus.skippedThrottled);
      expect(hub.eventsCallCount, 1, reason: 'only the first fetch runs');
    });

    test(
      'explicit reasons force reconciliation even within the throttle window',
      () async {
        final hub = _FakeHub(eventsToReturn: [_event('e1')]);
        final notifs = _FakeNotifs();
        final coord = _make(hub: hub, notifs: notifs);

        await coord.refresh(
          accessToken: 'tok',
          reason: CalendarReminderRefreshReason.appResumed,
        );
        final forced = await coord.refresh(
          accessToken: 'tok',
          reason: CalendarReminderRefreshReason.eventCreated,
        );

        expect(forced.status, CalendarReminderRefreshStatus.reconciled);
        expect(hub.eventsCallCount, 2);
        expect(notifs.reconcileCount, 2);
      },
    );

    test('force flag overrides throttling for a routine reason', () async {
      final hub = _FakeHub(eventsToReturn: [_event('e1')]);
      final notifs = _FakeNotifs();
      final coord = _make(hub: hub, notifs: notifs);

      await coord.refresh(
        accessToken: 'tok',
        reason: CalendarReminderRefreshReason.appResumed,
      );
      final forced = await coord.refresh(
        accessToken: 'tok',
        reason: CalendarReminderRefreshReason.appResumed,
        force: true,
      );

      expect(forced.status, CalendarReminderRefreshStatus.reconciled);
      expect(hub.eventsCallCount, 2);
    });
  });

  test('concurrent triggers share a single in-flight refresh', () async {
    final hub = _BlockingHub();
    final notifs = _FakeNotifs();
    final coord = _make(hub: hub, notifs: notifs);

    final f1 = coord.refresh(
      accessToken: 'tok',
      reason: CalendarReminderRefreshReason.sessionRestored,
    );
    final f2 = coord.refresh(
      accessToken: 'tok',
      reason: CalendarReminderRefreshReason.appResumed,
    );

    // Let the first refresh reach the (blocked) fetch.
    await Future<void>.delayed(Duration.zero);
    hub.release.complete();

    final r1 = await f1;
    final r2 = await f2;

    expect(hub.eventsCallCount, 1, reason: 'only one fetch for both triggers');
    expect(identical(r1, r2), isTrue, reason: 'both share the same result');
    expect(notifs.reconcileCount, 1);
  });

  group('forced follow-up queueing (Defect 1)', () {
    test('a forced request during an in-flight routine refresh runs as exactly '
        'one follow-up and its result goes to the forced caller', () async {
      final hub = _GatedHub();
      final notifs = _FakeNotifs();
      final coord = _make(hub: hub, notifs: notifs);

      // 1. An app-resume refresh is blocked in the event API.
      final f1 = coord.refresh(
        accessToken: 'tok',
        reason: CalendarReminderRefreshReason.appResumed,
      );
      await hub.reached(0);
      expect(hub.eventsCallCount, 1);

      // 2. eventCreated is requested while the first refresh is in flight.
      final f2 = coord.refresh(
        accessToken: 'tok',
        reason: CalendarReminderRefreshReason.eventCreated,
      );
      expect(coord.hasPendingForcedRefresh, isTrue);

      // 3. The first refresh completes.
      hub.release(0);
      final r1 = await f1;
      expect(r1.reason, CalendarReminderRefreshReason.appResumed);

      // 4. Exactly one forced follow-up runs.
      await hub.reached(1);
      hub.release(1);
      final r2 = await f2;

      // 5. Two event API calls occur in total.
      expect(hub.eventsCallCount, 2);
      expect(notifs.reconcileCount, 2);

      // 6. The forced caller receives the follow-up result (not the old one).
      expect(r2.reason, CalendarReminderRefreshReason.eventCreated);
      expect(r2.status, CalendarReminderRefreshStatus.reconciled);
      expect(identical(r1, r2), isFalse);
      expect(coord.hasPendingForcedRefresh, isFalse);
    });

    test(
      'multiple forced requests during one in-flight refresh coalesce into a '
      'single follow-up using the latest token and reason',
      () async {
        final hub = _GatedHub();
        final notifs = _FakeNotifs();
        final coord = _make(hub: hub, notifs: notifs);

        final f1 = coord.refresh(
          accessToken: 'tok0',
          reason: CalendarReminderRefreshReason.appResumed,
        );
        await hub.reached(0);

        final f2 = coord.refresh(
          accessToken: 'tokA',
          reason: CalendarReminderRefreshReason.eventCreated,
        );
        final f3 = coord.refresh(
          accessToken: 'tokB',
          reason: CalendarReminderRefreshReason.eventUpdated,
        );
        expect(coord.hasPendingForcedRefresh, isTrue);

        hub.release(0);
        final r1 = await f1;
        expect(r1.reason, CalendarReminderRefreshReason.appResumed);
        await hub.reached(1);
        hub.release(1);
        final r2 = await f2;
        final r3 = await f3;

        expect(
          hub.eventsCallCount,
          2,
          reason: 'one initial fetch plus one coalesced follow-up fetch',
        );
        expect(
          identical(r2, r3),
          isTrue,
          reason: 'both forced callers observe the same follow-up result',
        );
        expect(
          r2.reason,
          CalendarReminderRefreshReason.eventUpdated,
          reason: 'the latest forced reason is preserved',
        );
        expect(
          hub.tokens[1],
          'tokB',
          reason: 'the follow-up uses the latest valid access token',
        );
      },
    );

    test('a forced follow-up bypasses the routine throttle window', () async {
      // The clock is fixed at _now, so the follow-up starts squarely inside the
      // throttle window opened by the first refresh — yet it must still run.
      final hub = _GatedHub();
      final notifs = _FakeNotifs();
      final coord = _make(hub: hub, notifs: notifs);

      final f1 = coord.refresh(
        accessToken: 'tok',
        reason: CalendarReminderRefreshReason.appResumed,
      );
      await hub.reached(0);
      final f2 = coord.refresh(
        accessToken: 'tok',
        reason: CalendarReminderRefreshReason.eventCreated,
      );

      hub.release(0);
      await f1;
      await hub.reached(1);
      hub.release(1);
      await f2;

      expect(
        hub.eventsCallCount,
        2,
        reason:
            'the follow-up fetched despite being within the throttle window',
      );
    });

    test(
      'a failed first refresh still runs the queued forced follow-up',
      () async {
        final hub = _GatedHub(failCalls: {0});
        final notifs = _FakeNotifs();
        final coord = _make(hub: hub, notifs: notifs);

        final f1 = coord.refresh(
          accessToken: 'tok',
          reason: CalendarReminderRefreshReason.appResumed,
        );
        await hub.reached(0);
        final f2 = coord.refresh(
          accessToken: 'tok',
          reason: CalendarReminderRefreshReason.eventCreated,
        );

        hub.release(0);
        final r1 = await f1;
        expect(r1.status, CalendarReminderRefreshStatus.fetchFailed);

        await hub.reached(1);
        hub.release(1);
        final r2 = await f2;

        expect(r2.status, CalendarReminderRefreshStatus.reconciled);
        expect(hub.eventsCallCount, 2);
        expect(
          notifs.reconcileCount,
          1,
          reason: 'only the successful follow-up reconciles',
        );
      },
    );

    test(
      'a routine request arriving while a forced follow-up is pending adds no '
      'new refresh',
      () async {
        final hub = _GatedHub();
        final notifs = _FakeNotifs();
        final coord = _make(hub: hub, notifs: notifs);

        final f1 = coord.refresh(
          accessToken: 'tok',
          reason: CalendarReminderRefreshReason.appResumed,
        );
        await hub.reached(0);

        final f2 = coord.refresh(
          accessToken: 'tok',
          reason: CalendarReminderRefreshReason.eventCreated,
        );
        // Routine request while the forced follow-up is queued.
        final f3 = coord.refresh(
          accessToken: 'tok',
          reason: CalendarReminderRefreshReason.appResumed,
        );
        expect(coord.hasPendingForcedRefresh, isTrue);

        hub.release(0);
        final r1 = await f1;
        final r3 = await f3;
        expect(
          identical(r1, r3),
          isTrue,
          reason: 'the routine request joined the in-flight refresh',
        );

        await hub.reached(1);
        hub.release(1);
        await f2;

        expect(
          hub.eventsCallCount,
          2,
          reason: 'initial fetch plus one forced follow-up; routine added none',
        );
      },
    );

    test('a signed-out forced request never fetches or queues', () async {
      final hub = _GatedHub();
      final notifs = _FakeNotifs();
      final coord = _make(hub: hub, notifs: notifs);

      final f1 = coord.refresh(
        accessToken: 'tok',
        reason: CalendarReminderRefreshReason.appResumed,
      );
      await hub.reached(0);

      final signedOut = await coord.refresh(
        accessToken: null,
        reason: CalendarReminderRefreshReason.eventCreated,
      );
      expect(signedOut.status, CalendarReminderRefreshStatus.skippedSignedOut);
      expect(coord.hasPendingForcedRefresh, isFalse);

      hub.release(0);
      await f1;
      expect(hub.eventsCallCount, 1, reason: 'no follow-up was queued');
    });
  });

  group('disabled cleanup retry (Requirement 7)', () {
    test('disabled with an empty manifest does nothing', () async {
      SharedPreferences.setMockInitialValues({
        'calee_pref_migrated_to_shared_prefs': true,
        'calee_pref_calendar_reminders_enabled': false,
      });
      final hub = _FakeHub();
      final notifs = _CleanupSpyNotifs();
      final coord = _make(hub: hub, notifs: notifs);

      final result = await coord.refresh(
        accessToken: 'tok',
        reason: CalendarReminderRefreshReason.appResumed,
      );

      expect(result.status, CalendarReminderRefreshStatus.skippedDisabled);
      expect(hub.eventsCallCount, 0);
      expect(notifs.disableCount, 0, reason: 'no leftover IDs ⇒ no cleanup');
    });

    test(
      'disabled with leftover manifest IDs retries targeted cleanup',
      () async {
        SharedPreferences.setMockInitialValues({
          'calee_pref_migrated_to_shared_prefs': true,
          'calee_pref_calendar_reminders_enabled': false,
          'calee_pref_calendar_reminder_manifest': _manifestJson([11, 22]),
        });
        final hub = _FakeHub();
        final notifs = _CleanupSpyNotifs();
        final coord = _make(hub: hub, notifs: notifs);

        final result = await coord.refresh(
          accessToken: 'tok',
          reason: CalendarReminderRefreshReason.appResumed,
        );

        expect(
          result.status,
          CalendarReminderRefreshStatus.disabledCleanupCompleted,
        );
        expect(hub.eventsCallCount, 0, reason: 'never fetch while disabled');
        expect(notifs.disableCount, 1, reason: 'cleanup retried');
      },
    );

    test(
      'a corrupt manifest while disabled reports corrupt and cleans nothing',
      () async {
        SharedPreferences.setMockInitialValues({
          'calee_pref_migrated_to_shared_prefs': true,
          'calee_pref_calendar_reminders_enabled': false,
          'calee_pref_calendar_reminder_manifest': '{not valid json',
        });
        final hub = _FakeHub();
        final notifs = _CleanupSpyNotifs();
        final coord = _make(hub: hub, notifs: notifs);

        final result = await coord.refresh(
          accessToken: 'tok',
          reason: CalendarReminderRefreshReason.appResumed,
        );

        expect(result.status, CalendarReminderRefreshStatus.manifestCorrupt);
        expect(hub.eventsCallCount, 0);
        expect(
          notifs.disableCount,
          0,
          reason: 'ownership is unknown, so nothing is cleaned',
        );
      },
    );

    test(
      'a partial cleanup while disabled reports the partial status',
      () async {
        SharedPreferences.setMockInitialValues({
          'calee_pref_migrated_to_shared_prefs': true,
          'calee_pref_calendar_reminders_enabled': false,
          'calee_pref_calendar_reminder_manifest': _manifestJson([11, 22]),
        });
        final hub = _FakeHub();
        final notifs = _CleanupSpyNotifs(
          disableResult: const CalendarReminderDisableResult(
            cancelledCount: 1,
            failedCount: 1,
            manifestPersisted: true,
          ),
        );
        final coord = _make(hub: hub, notifs: notifs);

        final result = await coord.refresh(
          accessToken: 'tok',
          reason: CalendarReminderRefreshReason.appResumed,
        );

        expect(
          result.status,
          CalendarReminderRefreshStatus.disabledCleanupPartial,
        );
        expect(result.cleanup?.failedCount, 1);
      },
    );
  });

  group('permission denied cleanup (Requirement 8)', () {
    test(
      'runs targeted cleanup, keeps the preference disabled, and never fetches',
      () async {
        final hub = _FakeHub();
        final notifs = _CleanupSpyNotifs(permission: false);
        final coord = _make(hub: hub, notifs: notifs);

        final result = await coord.refresh(
          accessToken: 'tok',
          reason: CalendarReminderRefreshReason.appResumed,
        );

        expect(result.status, CalendarReminderRefreshStatus.permissionDenied);
        expect(hub.eventsCallCount, 0, reason: 'never fetch when denied');
        expect(notifs.disableCount, 1, reason: 'owned reminders cleaned up');
        expect(
          await CaleePreferences().loadCalendarRemindersEnabled(),
          isFalse,
          reason: 'preference remains disabled after permission denial',
        );
      },
    );
  });

  group('session invalidation (Defect 1)', () {
    test('sign-out during a blocked fetch prevents reconciliation', () async {
      final hub = _GatedHub();
      final notifs = _FakeNotifs();
      final coord = _make(hub: hub, notifs: notifs);
      coord.beginSession(accountId: 'acct-A');

      final f1 = coord.refresh(
        accessToken: 'tok',
        reason: CalendarReminderRefreshReason.sessionRestored,
      );
      await hub.reached(0);

      // Sign out while the fetch is still blocked.
      final cleanup = coord.endSession();

      hub.release(0);
      final r1 = await f1;
      await cleanup;

      expect(
        r1.status,
        CalendarReminderRefreshStatus.skippedSessionInvalidated,
      );
      expect(
        notifs.reconcileCount,
        0,
        reason: 'the stale fetch must never reconcile after sign-out',
      );
    });

    test('sign-out cancels a queued forced follow-up; the caller gets '
        'skippedSessionInvalidated and no pending completer remains', () async {
      final hub = _GatedHub();
      final notifs = _FakeNotifs();
      final coord = _make(hub: hub, notifs: notifs);
      coord.beginSession(accountId: 'acct-A');

      final f1 = coord.refresh(
        accessToken: 'tok',
        reason: CalendarReminderRefreshReason.appResumed,
      );
      await hub.reached(0);
      final f2 = coord.refresh(
        accessToken: 'tok',
        reason: CalendarReminderRefreshReason.eventCreated,
      );
      expect(coord.hasPendingForcedRefresh, isTrue);

      await coord.endSession();
      expect(
        coord.hasPendingForcedRefresh,
        isFalse,
        reason: 'the queued follow-up is dropped on sign-out',
      );

      final r2 = await f2;
      expect(
        r2.status,
        CalendarReminderRefreshStatus.skippedSessionInvalidated,
      );

      hub.release(0);
      final r1 = await f1;
      expect(
        r1.status,
        CalendarReminderRefreshStatus.skippedSessionInvalidated,
      );
      expect(
        hub.eventsCallCount,
        1,
        reason: 'the invalidated follow-up never fetched',
      );
      expect(notifs.reconcileCount, 0);
    });

    test(
      'beginning account B while account A is fetching prevents A from writing',
      () async {
        final hub = _GatedHub();
        final notifs = _FakeNotifs();
        final coord = _make(hub: hub, notifs: notifs);
        coord.beginSession(accountId: 'acct-A');

        final fA = coord.refresh(
          accessToken: 'tokA',
          reason: CalendarReminderRefreshReason.sessionRestored,
        );
        await hub.reached(0);

        // Account switch: account B begins while A's fetch is in flight.
        coord.beginSession(accountId: 'acct-B');

        hub.release(0);
        final rA = await fA;

        expect(
          rA.status,
          CalendarReminderRefreshStatus.skippedSessionInvalidated,
        );
        expect(
          notifs.reconcileCount,
          0,
          reason: 'account A must not reconcile/write after account B begins',
        );
      },
    );

    test('sign-out cleanup runs targeted disable and never fetches', () async {
      final hub = _GatedHub();
      final notifs = _CleanupSpyNotifs();
      final coord = _make(hub: hub, notifs: notifs);
      coord.beginSession(accountId: 'acct-A');

      final result = await coord.endSession();

      expect(notifs.disableCount, 1, reason: 'targeted cleanup ran');
      expect(notifs.reconcileCount, 0);
      expect(hub.eventsCallCount, 0, reason: 'sign-out cleanup never fetches');
      expect(result.isFullyClean, isTrue);
    });

    test('sign-out completes even when cleanup reports partial', () async {
      final notifs = _CleanupSpyNotifs(
        disableResult: const CalendarReminderDisableResult(
          cancelledCount: 1,
          failedCount: 1,
          manifestPersisted: true,
        ),
      );
      final coord = _make(hub: _FakeHub(), notifs: notifs);
      coord.beginSession(accountId: 'acct-A');

      final result = await coord.endSession();

      expect(result.hasFailures, isTrue);
      expect(result.isFullyClean, isFalse);
      expect(notifs.disableCount, 1);
    });

    test('the coordinator passes the account owner key to reconcile', () async {
      final hub = _FakeHub(eventsToReturn: [_event('e1')]);
      final notifs = _FakeNotifs();
      final coord = _make(hub: hub, notifs: notifs);
      coord.beginSession(accountId: 'acct-A');

      await coord.refresh(
        accessToken: 'tok',
        reason: CalendarReminderRefreshReason.sessionRestored,
      );

      expect(notifs.reconcileOwnerKeys.single, reminderOwnerKey('acct-A'));
    });

    test('beginSession and endSession each advance the session generation', () {
      final coord = _make(hub: _FakeHub(), notifs: _FakeNotifs());
      final g0 = coord.sessionGeneration;
      coord.beginSession(accountId: 'A');
      final g1 = coord.sessionGeneration;
      expect(g1, greaterThan(g0));
      coord.endSession();
      expect(coord.sessionGeneration, greaterThan(g1));
    });
  });

  group('cross-generation refresh handling (Requirement 1)', () {
    // Both accounts are enabled via their account-scoped keys so each performs
    // its own fetch (the legacy-global migration would otherwise leave B off).
    void seedEnabled() {
      SharedPreferences.setMockInitialValues({
        'calee_pref_migrated_to_shared_prefs': true,
        'calee_pref_calendar_reminders_enabled_${reminderOwnerKey('acct-A')}':
            true,
        'calee_pref_calendar_reminders_enabled_${reminderOwnerKey('acct-B')}':
            true,
      });
    }

    test('account B routine refresh does not join account A active future and '
        'runs its own fetch after A is invalidated', () async {
      seedEnabled();
      final hub = _GatedHub();
      final notifs = _FakeNotifs();
      final coord = _make(hub: hub, notifs: notifs);

      // 1. Account A begins a blocked routine refresh.
      coord.beginSession(accountId: 'acct-A');
      final fA = coord.refresh(
        accessToken: 'tokA',
        reason: CalendarReminderRefreshReason.sessionRestored,
      );
      await hub.reached(0);
      expect(hub.eventsCallCount, 1);

      // 2. Account B begins.
      coord.beginSession(accountId: 'acct-B');

      // 3. Account B requests a routine refresh — must not join A's future.
      final fB = coord.refresh(
        accessToken: 'tokB',
        reason: CalendarReminderRefreshReason.sessionRestored,
      );

      // 4. Account A finishes as invalidated.
      hub.release(0);
      final rA = await fA;
      expect(
        rA.status,
        CalendarReminderRefreshStatus.skippedSessionInvalidated,
      );

      // 5. Account B performs its own fetch.
      await hub.reached(1);
      hub.release(1);
      final rB = await fB;

      // 6. Two network calls occur.
      expect(hub.eventsCallCount, 2);
      expect(hub.tokens, ['tokA', 'tokB']);

      // 7. Account B receives its own reconciliation result.
      expect(rB.status, CalendarReminderRefreshStatus.reconciled);
      expect(identical(rA, rB), isFalse);
      expect(notifs.reconcileCount, 1, reason: 'only B reconciled');
      expect(notifs.reconcileOwnerKeys, [reminderOwnerKey('acct-B')]);
    });

    test(
      'an old operation finishing cannot clear a newer active refresh',
      () async {
        seedEnabled();
        final hub = _GatedHub();
        final notifs = _FakeNotifs();
        final coord = _make(hub: hub, notifs: notifs);

        coord.beginSession(accountId: 'acct-A');
        final fA = coord.refresh(
          accessToken: 'tokA',
          reason: CalendarReminderRefreshReason.sessionRestored,
        );
        await hub.reached(0);

        // Account B begins and queues its refresh behind A.
        coord.beginSession(accountId: 'acct-B');
        final fB = coord.refresh(
          accessToken: 'tokB',
          reason: CalendarReminderRefreshReason.sessionRestored,
        );

        // A finishes (invalidated) → B starts and becomes the active refresh.
        hub.release(0);
        await fA;
        await hub.reached(1);

        // While B is the active (blocked) refresh, it must still be running: A's
        // finally block must not have cleared B's active reference.
        expect(coord.isRefreshing, isTrue);

        hub.release(1);
        final rB = await fB;
        expect(rB.status, CalendarReminderRefreshStatus.reconciled);
        expect(coord.isRefreshing, isFalse);
      },
    );

    test('forced requests coalesce only within the same generation', () async {
      seedEnabled();
      final hub = _GatedHub();
      final notifs = _FakeNotifs();
      final coord = _make(hub: hub, notifs: notifs);

      coord.beginSession(accountId: 'acct-A');
      final fA = coord.refresh(
        accessToken: 'tokA',
        reason: CalendarReminderRefreshReason.appResumed,
      );
      await hub.reached(0);

      // A forced request within A's generation queues a follow-up.
      final fForcedA = coord.refresh(
        accessToken: 'tokA2',
        reason: CalendarReminderRefreshReason.eventCreated,
      );
      expect(coord.hasPendingForcedRefresh, isTrue);

      // Account B begins — the A-generation follow-up must be invalidated, not
      // coalesced into B's work.
      coord.beginSession(accountId: 'acct-B');
      final rForcedA = await fForcedA;
      expect(
        rForcedA.status,
        CalendarReminderRefreshStatus.skippedSessionInvalidated,
      );
      expect(coord.hasPendingForcedRefresh, isFalse);

      // B queues its own refresh behind A's still-running fetch.
      final fB = coord.refresh(
        accessToken: 'tokB',
        reason: CalendarReminderRefreshReason.sessionRestored,
      );

      hub.release(0);
      final rA = await fA;
      expect(
        rA.status,
        CalendarReminderRefreshStatus.skippedSessionInvalidated,
      );

      await hub.reached(1);
      hub.release(1);
      final rB = await fB;
      expect(rB.status, CalendarReminderRefreshStatus.reconciled);
      expect(notifs.reconcileOwnerKeys, [reminderOwnerKey('acct-B')]);
    });

    test(
      'transitionSession invalidates the old session and cleans the previous '
      'owner before beginning the new one',
      () async {
        seedEnabled();
        final hub = _GatedHub();
        final notifs = _CleanupSpyNotifs();
        final coord = _make(hub: hub, notifs: notifs);

        // Signed out → signed in A.
        await coord.transitionSession(
          previousAccountId: null,
          nextAccountId: 'acct-A',
        );
        expect(notifs.disableCount, 0, reason: 'no previous owner to clean');

        // A → B: cleans A, begins B.
        await coord.transitionSession(
          previousAccountId: 'acct-A',
          nextAccountId: 'acct-B',
        );
        expect(notifs.disableCount, 1, reason: 'previous owner A was cleaned');
        expect(notifs.disableOwnerKeys.single, reminderOwnerKey('acct-A'));
        expect(coord.ownerKey, reminderOwnerKey('acct-B'));
      },
    );
  });

  group('preference load result (Fix 2)', () {
    test('unavailable preference read preserves reminders: no fetch, no '
        'reconcile, no cleanup, no permission request', () async {
      final hub = _FakeHub(eventsToReturn: [_event('e1')]);
      final notifs = _FakeNotifs();
      final coord = _make(
        hub: hub,
        notifs: notifs,
        prefs: _StubPrefs(
          const CalendarReminderPreferenceLoadResult.unavailable('io'),
        ),
      );

      final result = await coord.refresh(
        accessToken: 'tok',
        reason: CalendarReminderRefreshReason.sessionRestored,
      );

      expect(
        result.status,
        CalendarReminderRefreshStatus.preferenceUnavailable,
      );
      expect(result.errorCategory, 'io');
      expect(hub.eventsCallCount, 0, reason: 'never fetch on unavailable read');
      expect(notifs.reconcileCount, 0, reason: 'never reconcile');
      expect(notifs.disableCount, 0, reason: 'never cancel/clean');
    });

    test('loaded-true preference proceeds to reconcile', () async {
      final hub = _FakeHub(eventsToReturn: [_event('e1')]);
      final notifs = _FakeNotifs();
      final coord = _make(
        hub: hub,
        notifs: notifs,
        prefs: _StubPrefs(
          const CalendarReminderPreferenceLoadResult.loaded(true),
        ),
      );

      final result = await coord.refresh(
        accessToken: 'tok',
        reason: CalendarReminderRefreshReason.sessionRestored,
      );

      expect(result.status, CalendarReminderRefreshStatus.reconciled);
      expect(hub.eventsCallCount, 1);
      expect(notifs.reconcileCount, 1);
    });

    test(
      'loaded-false preference takes the disabled path (no fetch)',
      () async {
        final hub = _FakeHub();
        final notifs = _FakeNotifs();
        final coord = _make(
          hub: hub,
          notifs: notifs,
          prefs: _StubPrefs(
            const CalendarReminderPreferenceLoadResult.loaded(false),
          ),
        );

        final result = await coord.refresh(
          accessToken: 'tok',
          reason: CalendarReminderRefreshReason.sessionRestored,
        );

        expect(result.status, CalendarReminderRefreshStatus.skippedDisabled);
        expect(hub.eventsCallCount, 0);
        expect(notifs.reconcileCount, 0);
      },
    );

    test(
      'absent preference takes the default-disabled path (no fetch)',
      () async {
        final hub = _FakeHub();
        final notifs = _FakeNotifs();
        final coord = _make(
          hub: hub,
          notifs: notifs,
          prefs: _StubPrefs(
            const CalendarReminderPreferenceLoadResult.absent(),
          ),
        );

        final result = await coord.refresh(
          accessToken: 'tok',
          reason: CalendarReminderRefreshReason.sessionRestored,
        );

        expect(result.status, CalendarReminderRefreshStatus.skippedDisabled);
        expect(hub.eventsCallCount, 0);
        expect(notifs.reconcileCount, 0);
      },
    );
  });

  group('permission denied + preference save failure (Fix 3)', () {
    test(
      'permission denial with a failed preference write cleans up but is not '
      'fully successful',
      () async {
        final hub = _FakeHub();
        final notifs = _CleanupSpyNotifs(permission: false);
        final coord = _make(
          hub: hub,
          notifs: notifs,
          prefs: _StubPrefs(
            const CalendarReminderPreferenceLoadResult.loaded(true),
            saveError: const CalendarReminderPreferenceStorageException('save'),
          ),
        );

        final result = await coord.refresh(
          accessToken: 'tok',
          reason: CalendarReminderRefreshReason.remindersEnabled,
        );

        expect(result.status, CalendarReminderRefreshStatus.permissionDenied);
        expect(
          result.preferenceSaveFailed,
          isTrue,
          reason: 'a failed preference write must be exposed, not swallowed',
        );
        expect(
          notifs.disableCount,
          1,
          reason: 'targeted owner cleanup still runs for safety',
        );
        expect(hub.eventsCallCount, 0, reason: 'never fetch when denied');
      },
    );

    test('permission denial with a successful preference write reports no save '
        'failure', () async {
      final hub = _FakeHub();
      final notifs = _CleanupSpyNotifs(permission: false);
      final coord = _make(
        hub: hub,
        notifs: notifs,
        prefs: _StubPrefs(
          const CalendarReminderPreferenceLoadResult.loaded(true),
        ),
      );

      final result = await coord.refresh(
        accessToken: 'tok',
        reason: CalendarReminderRefreshReason.remindersEnabled,
      );

      expect(result.status, CalendarReminderRefreshStatus.permissionDenied);
      expect(result.preferenceSaveFailed, isFalse);
      expect(notifs.disableCount, 1);
    });
  });

  group('permission-denied save/session race (Fix 6)', () {
    test('sign-out while the denied preference save is blocked → invalidated, '
        'no extra cleanup from the stale refresh', () async {
      final hub = _FakeHub();
      final notifs = _CleanupSpyNotifs(permission: false);
      final prefs = _BlockingSavePrefs(
        const CalendarReminderPreferenceLoadResult.loaded(true),
      );
      final coord = _make(hub: hub, notifs: notifs, prefs: prefs);

      final future = coord.refresh(
        accessToken: 'tok',
        reason: CalendarReminderRefreshReason.remindersEnabled,
      );
      await prefs.reachedSave;

      // Sign out while the save is still queued. endSession runs its own
      // owner-scoped cleanup (disableCount becomes 1).
      final signOut = coord.endSession();
      prefs.releaseSave();
      final result = await future;
      await signOut;

      expect(
        result.status,
        CalendarReminderRefreshStatus.skippedSessionInvalidated,
      );
      // Exactly one cleanup — endSession's — and none from the stale refresh.
      expect(notifs.disableCount, 1);
      expect(notifs.disableOwnerKeys.single, reminderOwnerKey('acct-A'));
      expect(hub.eventsCallCount, 0);
    });

    test('account switch while the save is blocked → no incoming-account '
        'cleanup', () async {
      final hub = _FakeHub();
      final notifs = _CleanupSpyNotifs(permission: false);
      final prefs = _BlockingSavePrefs(
        const CalendarReminderPreferenceLoadResult.loaded(true),
      );
      final coord = _make(hub: hub, notifs: notifs, prefs: prefs);

      final future = coord.refresh(
        accessToken: 'tok',
        reason: CalendarReminderRefreshReason.remindersEnabled,
      );
      await prefs.reachedSave;

      // Switch A → B while the save is queued.
      await coord.transitionSession(
        previousAccountId: 'acct-A',
        nextAccountId: 'acct-B',
      );
      prefs.releaseSave();
      final result = await future;

      expect(
        result.status,
        CalendarReminderRefreshStatus.skippedSessionInvalidated,
      );
      // Only the outgoing owner A was cleaned; the incoming account B never is.
      expect(notifs.disableOwnerKeys, [reminderOwnerKey('acct-A')]);
      expect(
        notifs.disableOwnerKeys,
        isNot(contains(reminderOwnerKey('acct-B'))),
      );
    });

    test('save failure plus session invalidation preserves the save outcome '
        'and skips cleanup', () async {
      final hub = _FakeHub();
      final notifs = _CleanupSpyNotifs(permission: false);
      final prefs = _BlockingSavePrefs(
        const CalendarReminderPreferenceLoadResult.loaded(true),
        saveError: const CalendarReminderPreferenceStorageException('save'),
      );
      final coord = _make(hub: hub, notifs: notifs, prefs: prefs);

      final future = coord.refresh(
        accessToken: 'tok',
        reason: CalendarReminderRefreshReason.remindersEnabled,
      );
      await prefs.reachedSave;
      final signOut = coord.endSession();
      prefs.releaseSave();
      final result = await future;
      await signOut;

      expect(
        result.status,
        CalendarReminderRefreshStatus.skippedSessionInvalidated,
      );
      expect(result.preferenceSaveFailed, isTrue);
      // Stale refresh launched no cleanup; only endSession's ran.
      expect(notifs.disableCount, 1);
    });

    test('normal sign-out cleanup still runs when there is no race', () async {
      final hub = _FakeHub();
      final notifs = _CleanupSpyNotifs(permission: false);
      final coord = _make(
        hub: hub,
        notifs: notifs,
        prefs: _StubPrefs(
          const CalendarReminderPreferenceLoadResult.loaded(true),
        ),
      );

      // No race: the permission-denied refresh completes and cleans up once.
      final result = await coord.refresh(
        accessToken: 'tok',
        reason: CalendarReminderRefreshReason.remindersEnabled,
      );
      expect(result.status, CalendarReminderRefreshStatus.permissionDenied);
      expect(notifs.disableCount, 1);
    });
  });

  group('invalid account identity (Fix 1)', () {
    test('beginSession with an empty account ID is skipped: no owner, no '
        'generation change', () {
      final coord = _make(
        hub: _FakeHub(),
        notifs: _FakeNotifs(),
        beginAccount: null,
      );
      final g0 = coord.sessionGeneration;

      final result = coord.beginSession(accountId: '');

      expect(
        result.status,
        CalendarReminderSessionStartStatus.skippedInvalidAccount,
      );
      expect(coord.ownerKey, isNull, reason: 'no owner from an empty ID');
      expect(
        coord.sessionGeneration,
        g0,
        reason: 'an invalid begin must not advance the generation',
      );
    });

    test('beginSession with a whitespace-only account ID is skipped', () {
      final coord = _make(
        hub: _FakeHub(),
        notifs: _FakeNotifs(),
        beginAccount: null,
      );
      final g0 = coord.sessionGeneration;

      final result = coord.beginSession(accountId: '   ');

      expect(
        result.status,
        CalendarReminderSessionStartStatus.skippedInvalidAccount,
      );
      expect(coord.ownerKey, isNull);
      expect(coord.sessionGeneration, g0);
    });

    test('a valid account arriving after an invalid one starts normally', () {
      final coord = _make(hub: _FakeHub(), notifs: _FakeNotifs());

      final skipped = coord.beginSession(accountId: '');
      expect(
        skipped.status,
        CalendarReminderSessionStartStatus.skippedInvalidAccount,
      );

      final started = coord.beginSession(accountId: 'acct-A');
      expect(started.status, CalendarReminderSessionStartStatus.started);
      expect(coord.ownerKey, reminderOwnerKey('acct-A'));
    });

    test('a valid account-to-account switch begins each session', () {
      final coord = _make(hub: _FakeHub(), notifs: _FakeNotifs());

      coord.beginSession(accountId: 'acct-A');
      expect(coord.ownerKey, reminderOwnerKey('acct-A'));
      final gA = coord.sessionGeneration;

      coord.beginSession(accountId: 'acct-B');
      expect(coord.ownerKey, reminderOwnerKey('acct-B'));
      expect(coord.sessionGeneration, greaterThan(gA));
    });

    test(
      'an invalid begin does not invalidate a currently valid session or its '
      'queued follow-up',
      () async {
        final hub = _GatedHub();
        final notifs = _FakeNotifs();
        final coord = _make(hub: hub, notifs: notifs);
        coord.beginSession(accountId: 'acct-A');

        // Start a refresh and queue a forced follow-up behind it.
        final f1 = coord.refresh(
          accessToken: 'tok',
          reason: CalendarReminderRefreshReason.appResumed,
        );
        await hub.reached(0);
        final f2 = coord.refresh(
          accessToken: 'tok',
          reason: CalendarReminderRefreshReason.eventCreated,
        );
        expect(coord.hasPendingForcedRefresh, isTrue);
        final ownerBefore = coord.ownerKey;
        final genBefore = coord.sessionGeneration;

        // A duplicate transient callback lacking bootstrap data begins '' — it
        // must be a no-op that leaves the valid session and follow-up intact.
        final skipped = coord.beginSession(accountId: '');
        expect(
          skipped.status,
          CalendarReminderSessionStartStatus.skippedInvalidAccount,
        );
        expect(coord.ownerKey, ownerBefore);
        expect(coord.sessionGeneration, genBefore);
        expect(
          coord.hasPendingForcedRefresh,
          isTrue,
          reason: 'the queued follow-up must survive an invalid begin',
        );

        // The session runs to completion normally.
        hub.release(0);
        await f1;
        await hub.reached(1);
        hub.release(1);
        final r2 = await f2;
        expect(r2.status, CalendarReminderRefreshStatus.reconciled);
        expect(
          notifs.reconcileOwnerKeys,
          everyElement(reminderOwnerKey('acct-A')),
          reason: 'every reconcile stayed under the valid acct-A owner',
        );
      },
    );

    test(
      'transitionSession to an invalid next account is a no-op: no owner, no '
      'cleanup',
      () async {
        final notifs = _CleanupSpyNotifs();
        final coord = _make(
          hub: _FakeHub(),
          notifs: notifs,
          beginAccount: null,
        );

        await coord.transitionSession(
          previousAccountId: null,
          nextAccountId: '',
        );

        expect(
          coord.ownerKey,
          isNull,
          reason: 'no owner from an invalid switch',
        );
        expect(notifs.disableCount, 0);
      },
    );

    test('transitionSession with an invalid next account preserves the current '
        'valid session', () async {
      final notifs = _CleanupSpyNotifs();
      final coord = _make(hub: _FakeHub(), notifs: notifs);
      coord.beginSession(accountId: 'acct-A');
      final gA = coord.sessionGeneration;

      await coord.transitionSession(
        previousAccountId: 'acct-A',
        nextAccountId: '   ',
      );

      expect(
        coord.ownerKey,
        reminderOwnerKey('acct-A'),
        reason: 'the valid session must survive an invalid transition',
      );
      expect(coord.sessionGeneration, gA);
      expect(
        notifs.disableCount,
        0,
        reason: 'no cleanup for an invalid switch',
      );
    });
  });

  group('session boundary races (Fix 6: revalidate after every await)', () {
    test(
      'sign-out during the preference read: no permission, no fetch',
      () async {
        final hub = _FakeHub(eventsToReturn: [_event('e1')]);
        final notifs = _FakeNotifs();
        final prefs = _BlockingLoadPrefs(
          const CalendarReminderPreferenceLoadResult.loaded(true),
        );
        final coord = _make(
          hub: hub,
          notifs: notifs,
          prefs: prefs,
          beginAccount: null,
        );
        coord.beginSession(accountId: 'acct-A');

        final future = coord.refresh(
          accessToken: 'tok',
          reason: CalendarReminderRefreshReason.sessionRestored,
        );
        await prefs.reachedLoad;

        // Sign out while the preference read is blocked.
        await coord.endSession();
        prefs.releaseLoad();

        final result = await future;
        expect(
          result.status,
          CalendarReminderRefreshStatus.skippedSessionInvalidated,
        );
        expect(hub.eventsCallCount, 0, reason: 'no stale-token fetch');
        expect(notifs.reconcileCount, 0);
      },
    );

    test(
      'account switch during the preference read: no old-account fetch',
      () async {
        final hub = _FakeHub(eventsToReturn: [_event('e1')]);
        final notifs = _FakeNotifs();
        final prefs = _BlockingLoadPrefs(
          const CalendarReminderPreferenceLoadResult.loaded(true),
        );
        final coord = _make(
          hub: hub,
          notifs: notifs,
          prefs: prefs,
          beginAccount: null,
        );
        coord.beginSession(accountId: 'acct-A');

        final future = coord.refresh(
          accessToken: 'tokA',
          reason: CalendarReminderRefreshReason.sessionRestored,
        );
        await prefs.reachedLoad;

        // Account B begins while A's preference read is blocked.
        coord.beginSession(accountId: 'acct-B');
        prefs.releaseLoad();

        final result = await future;
        expect(
          result.status,
          CalendarReminderRefreshStatus.skippedSessionInvalidated,
        );
        expect(hub.eventsCallCount, 0, reason: 'no old-account fetch');
        expect(notifs.reconcileCount, 0);
      },
    );

    test('sign-out while a granted permission resolves: no stale-token fetch or '
        'write', () async {
      final hub = _FakeHub(eventsToReturn: [_event('e1')]);
      final notifs = _BlockingPermissionNotifs(grant: true);
      final coord = _make(
        hub: hub,
        notifs: notifs,
        prefs: _StubPrefs(
          const CalendarReminderPreferenceLoadResult.loaded(true),
        ),
        beginAccount: null,
      );
      coord.beginSession(accountId: 'acct-A');

      final future = coord.refresh(
        accessToken: 'tok',
        reason: CalendarReminderRefreshReason.sessionRestored,
      );
      await notifs.reachedPermission;

      // Sign out while the permission dialog resolves; permission then grants.
      await coord.endSession();
      notifs.releasePermission();

      final result = await future;
      expect(
        result.status,
        CalendarReminderRefreshStatus.skippedSessionInvalidated,
      );
      expect(
        hub.eventsCallCount,
        0,
        reason: 'permission granted after sign-out must not fetch',
      );
      expect(notifs.reconcileCount, 0);
    });

    test('sign-out while a denied permission resolves: no old-session write or '
        'cleanup', () async {
      final hub = _FakeHub();
      final notifs = _BlockingPermissionNotifs(grant: false);
      final prefs = _StubPrefs(
        const CalendarReminderPreferenceLoadResult.loaded(true),
      );
      final coord = _make(
        hub: hub,
        notifs: notifs,
        prefs: prefs,
        beginAccount: null,
      );
      coord.beginSession(accountId: 'acct-A');

      final future = coord.refresh(
        accessToken: 'tok',
        reason: CalendarReminderRefreshReason.sessionRestored,
      );
      await notifs.reachedPermission;

      // Sign out while the permission dialog resolves; permission then denies.
      await coord.endSession();
      final disableCountAfterSignOut = notifs.disableCount;
      notifs.releasePermission();

      final result = await future;
      expect(
        result.status,
        CalendarReminderRefreshStatus.skippedSessionInvalidated,
      );
      expect(
        prefs.saveCount,
        0,
        reason: 'no old-session preference write after sign-out',
      );
      expect(
        notifs.disableCount,
        disableCountAfterSignOut,
        reason: 'no additional old-session cleanup from the stale refresh',
      );
    });
  });
}

String _manifestJson(List<int> ids) =>
    jsonEncode(CalendarReminderManifest.fromIds(ids).toJson());

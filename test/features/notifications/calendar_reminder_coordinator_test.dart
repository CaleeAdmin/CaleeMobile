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

  @override
  Future<bool> requestPermissionIfNeeded() async => permission;

  @override
  Future<CalendarReminderDisableResult> disableCalendarReminders() async {
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
  }) async {
    reconcileCount++;
    reconcileArgs.add(events);
    reconcileOwnerKeys.add(ownerKey);
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

  @override
  Future<bool> requestPermissionIfNeeded() async => permission;

  @override
  Future<CalendarReminderDisableResult> disableCalendarReminders() async {
    disableCount++;
    return disableResult;
  }

  @override
  Future<CalendarReconciliationResult> reconcileCalendarReminders(
    List<ClientEvent> events, {
    DateTime? now,
    String? ownerKey,
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

CalendarReminderCoordinator _make({
  required CaleeHubClient hub,
  required LocalCalendarNotificationService notifs,
  DateTime Function()? clock,
  Duration throttle = const Duration(minutes: 5),
}) => CalendarReminderCoordinator(
  hubClient: hub,
  notificationService: notifs,
  now: clock ?? () => _now,
  throttle: throttle,
);

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
}

String _manifestJson(List<int> ids) =>
    jsonEncode(CalendarReminderManifest.fromIds(ids).toJson());

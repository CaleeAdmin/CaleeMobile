// Tests for CalendarReminderCoordinator: signed-out guard, disabled/permission
// handling, throttling, forced reconciliation, single-flight, and fetch-failure
// behaviour.

import 'dart:async';
import 'dart:convert';

import 'package:calee_mobile/data/api/calee_hub_client.dart';
import 'package:calee_mobile/data/auth/calee_preferences.dart';
import 'package:calee_mobile/data/models/calendar_reminder_manifest.dart';
import 'package:calee_mobile/data/models/client_calendar.dart';
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

class _FakeNotifs extends LocalCalendarNotificationService {
  _FakeNotifs({this.permission = true}) : super.forTest();

  final bool permission;
  int reconcileCount = 0;
  final List<List<ClientEvent>> reconcileArgs = [];

  @override
  Future<bool> requestPermissionIfNeeded() async => permission;

  @override
  Future<CalendarReconciliationResult> reconcileCalendarReminders(
    List<ClientEvent> events, {
    DateTime? now,
  }) async {
    reconcileCount++;
    reconcileArgs.add(events);
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
}

String _manifestJson(List<int> ids) => jsonEncode(
  CalendarReminderManifest(
    version: CalendarReminderManifest.currentVersion,
    scheduledIds: ids,
  ).toJson(),
);

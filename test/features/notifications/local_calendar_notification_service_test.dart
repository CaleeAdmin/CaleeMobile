// Tests for LocalCalendarNotificationService reconciliation, disable, and
// retry-safe initialization.
//
// Uses forTest() subclassing to control plugin operations (schedule / cancel /
// initialize) without hitting flutter_local_notifications platform channels.

import 'dart:convert';

import 'package:calee_mobile/data/auth/calee_preferences.dart';
import 'package:calee_mobile/data/models/calendar_reminder_manifest.dart';
import 'package:calee_mobile/data/models/client_calendar.dart';
import 'package:calee_mobile/features/notifications/calendar_notification_candidates.dart';
import 'package:calee_mobile/features/notifications/local_calendar_notification_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

// ── Test subclasses ─────────────────────────────────────────────────────────

/// Records schedule/cancel operations and pretends initialization succeeded.
class _RecordingService extends LocalCalendarNotificationService {
  _RecordingService({this.failScheduleIds = const <int>{}}) : super.forTest();

  final Set<int> failScheduleIds;
  final List<int> cancelled = [];
  final List<int> scheduled = [];

  @override
  Future<bool> ensureInitialized() async => true;

  @override
  Future<void> cancelNotification(int id) async {
    cancelled.add(id);
  }

  @override
  Future<bool> scheduleReminder(CalendarNotificationCandidate c) async {
    if (failScheduleIds.contains(c.notificationId)) return false;
    scheduled.add(c.notificationId);
    return true;
  }
}

/// Fails its first plugin-initialization attempt, then succeeds.
class _FlakyInitService extends LocalCalendarNotificationService {
  _FlakyInitService() : super.forTest();

  int attempts = 0;
  bool failFirst = true;

  @override
  Future<void> performPluginInitialization() async {
    attempts++;
    if (failFirst && attempts == 1) {
      throw Exception('simulated init failure');
    }
  }
}

// ── Helpers ─────────────────────────────────────────────────────────────────

ClientEvent _event(String id, {String startsAt = '2026-07-05T09:00:00'}) =>
    ClientEvent(
      id: id,
      calendarId: 'cal1',
      serviceId: 'svc',
      serviceName: 'Test',
      title: 'Event $id',
      startsAt: startsAt,
      endsAt: '2026-07-05T10:00:00',
      allDay: false,
      recurring: false,
      source: 'test',
    );

// 2026-07-04T12:00 → the 2026-07-05T09:00 events are eligible (30-day horizon).
final _now = DateTime(2026, 7, 4, 12, 0, 0);

String _manifestJson(List<int> ids) => jsonEncode(
  CalendarReminderManifest(
    version: CalendarReminderManifest.currentVersion,
    scheduledIds: ids,
  ).toJson(),
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({
      'calee_pref_migrated_to_shared_prefs': true,
    });
  });

  group('reconcileCalendarReminders — scheduling', () {
    test('schedules new IDs and records them in the manifest', () async {
      final service = _RecordingService();
      final e1 = _event('e1');

      final result = await service.reconcileCalendarReminders([e1], now: _now);

      final id = notificationIdForEvent(e1);
      expect(service.scheduled, [id]);
      expect(service.cancelled, isEmpty);
      expect(result.scheduledCount, 1);
      expect(result.eventsFetched, 1);
      expect(result.eligibleCandidates, 1);

      final manifest = await CaleePreferences().loadCalendarReminderManifest();
      expect(manifest.scheduledIds, contains(id));
    });

    test('does not reschedule unchanged IDs and cancels nothing', () async {
      final e1 = _event('e1');
      final id = notificationIdForEvent(e1);
      SharedPreferences.setMockInitialValues({
        'calee_pref_migrated_to_shared_prefs': true,
        'calee_pref_calendar_reminder_manifest': _manifestJson([id]),
      });

      final service = _RecordingService();
      final result = await service.reconcileCalendarReminders([e1], now: _now);

      expect(service.scheduled, isEmpty, reason: 'already scheduled');
      expect(service.cancelled, isEmpty, reason: 'still desired');
      expect(result.unchangedCount, 1);
      expect(result.scheduledCount, 0);
      expect(result.cancelledCount, 0);
    });
  });

  group('reconcileCalendarReminders — stale cancellation', () {
    test(
      'cancels only stale IDs individually, never a blanket cancel',
      () async {
        final e1 = _event('e1');
        final keepId = notificationIdForEvent(e1);
        const staleId = 424242; // in the manifest but no longer desired

        SharedPreferences.setMockInitialValues({
          'calee_pref_migrated_to_shared_prefs': true,
          'calee_pref_calendar_reminder_manifest': _manifestJson([
            keepId,
            staleId,
          ]),
        });

        final service = _RecordingService();
        final result = await service.reconcileCalendarReminders([
          e1,
        ], now: _now);

        expect(service.cancelled, [staleId]);
        expect(service.cancelled, isNot(contains(keepId)));
        expect(result.cancelledCount, 1);
        expect(result.unchangedCount, 1);

        final manifest = await CaleePreferences()
            .loadCalendarReminderManifest();
        expect(manifest.scheduledIds, contains(keepId));
        expect(manifest.scheduledIds, isNot(contains(staleId)));
      },
    );

    test('reconciling all-unchanged events cancels nothing', () async {
      final e1 = _event('e1');
      final e2 = _event('e2', startsAt: '2026-07-06T09:00:00');
      final ids = [e1, e2].map(notificationIdForEvent).toList();
      SharedPreferences.setMockInitialValues({
        'calee_pref_migrated_to_shared_prefs': true,
        'calee_pref_calendar_reminder_manifest': _manifestJson(ids),
      });

      final service = _RecordingService();
      await service.reconcileCalendarReminders([e1, e2], now: _now);

      expect(service.cancelled, isEmpty);
      expect(service.scheduled, isEmpty);
    });
  });

  group('reconcileCalendarReminders — scheduling failures', () {
    test(
      'a scheduling failure is reflected in the result and not claimed in the manifest',
      () async {
        final e1 = _event('e1');
        final failId = notificationIdForEvent(e1);
        final service = _RecordingService(failScheduleIds: {failId});

        final result = await service.reconcileCalendarReminders([
          e1,
        ], now: _now);

        expect(result.failedCount, 1);
        expect(result.scheduledCount, 0);
        expect(result.hasFailures, isTrue);

        final manifest = await CaleePreferences()
            .loadCalendarReminderManifest();
        expect(
          manifest.scheduledIds,
          isNot(contains(failId)),
          reason: 'manifest must not claim a failed notification is scheduled',
        );
      },
    );
  });

  group('reconcileCalendarReminders — initialization failure', () {
    test('preserves the existing manifest when not initialized', () async {
      const existingId = 999;
      SharedPreferences.setMockInitialValues({
        'calee_pref_migrated_to_shared_prefs': true,
        'calee_pref_calendar_reminder_manifest': _manifestJson([existingId]),
      });

      // Recording service that reports NOT initialized.
      final service = _UninitializedService();
      final result = await service.reconcileCalendarReminders([
        _event('e1'),
      ], now: _now);

      expect(result.failedCount, greaterThan(0));

      final manifest = await CaleePreferences().loadCalendarReminderManifest();
      expect(
        manifest.scheduledIds,
        contains(existingId),
        reason: 'existing reminders must be preserved when init fails',
      );
    });
  });

  group('disableCalendarReminders', () {
    test('cancels only manifest IDs and clears the manifest', () async {
      SharedPreferences.setMockInitialValues({
        'calee_pref_migrated_to_shared_prefs': true,
        'calee_pref_calendar_reminder_manifest': _manifestJson([11, 22, 33]),
      });

      final service = _RecordingService();
      await service.disableCalendarReminders();

      expect(service.cancelled, [11, 22, 33]);

      final manifest = await CaleePreferences().loadCalendarReminderManifest();
      expect(manifest.scheduledIds, isEmpty);
    });

    test('cancels nothing when the manifest is empty', () async {
      final service = _RecordingService();
      await service.disableCalendarReminders();
      expect(service.cancelled, isEmpty);
    });
  });

  group('initialize — retry safety', () {
    test(
      'does not permanently believe init succeeded after a failure',
      () async {
        final service = _FlakyInitService();

        final firstOk = await service.ensureInitialized();
        expect(firstOk, isFalse, reason: 'first attempt failed');
        expect(service.debugInitialized, isFalse);

        final secondOk = await service.ensureInitialized();
        expect(secondOk, isTrue, reason: 'retry succeeds');
        expect(service.debugInitialized, isTrue);
        expect(service.attempts, 2);
      },
    );

    test('concurrent initialize calls share a single attempt', () async {
      final service = _FlakyInitService()..failFirst = false;

      await Future.wait([service.initialize(), service.initialize()]);

      expect(service.attempts, 1);
      expect(service.debugInitialized, isTrue);
    });

    test(
      'ensureInitialized returns false (never throws) on a failed attempt',
      () async {
        final service = _FlakyInitService()..failFirst = true;
        // The first attempt fails; ensureInitialized swallows it and reports false
        // rather than propagating — app startup must not crash.
        await expectLater(service.ensureInitialized(), completion(isFalse));
      },
    );
  });
}

/// Reports as not-initialized so reconcile takes the init-failure path.
class _UninitializedService extends LocalCalendarNotificationService {
  _UninitializedService() : super.forTest();

  @override
  Future<bool> ensureInitialized() async => false;
}

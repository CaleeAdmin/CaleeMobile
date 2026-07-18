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
/// Optional [prefs] injects an in-memory preference store so manifest
/// persistence failures can be simulated; otherwise the real (mocked)
/// [CaleePreferences] is used.
class _RecordingService extends LocalCalendarNotificationService {
  _RecordingService({
    this.failScheduleIds = const <int>{},
    this.failCancelIds = const <int>{},
    this.prefsOverride,
  }) : super.forTest();

  final Set<int> failScheduleIds;
  final Set<int> failCancelIds;
  final CaleePreferences? prefsOverride;
  final List<int> cancelled = [];
  final List<int> scheduled = [];

  @override
  CaleePreferences get preferences => prefsOverride ?? super.preferences;

  @override
  Future<bool> ensureInitialized() async => true;

  @override
  Future<void> cancelNotification(int id) async {
    if (failCancelIds.contains(id)) {
      throw Exception('simulated cancel failure for $id');
    }
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

/// Reports as not-initialized so reconcile takes the init-failure path.
class _UninitializedService extends LocalCalendarNotificationService {
  _UninitializedService() : super.forTest();

  @override
  Future<bool> ensureInitialized() async => false;
}

/// In-memory [CaleePreferences] so manifest persistence can be observed and its
/// failures simulated without SharedPreferences.
class _InMemoryPreferences extends CaleePreferences {
  _InMemoryPreferences({
    CalendarReminderManifest? initial,
    this.failSaveCount = 0,
    this.failClear = false,
    this.corruptOnLoad = false,
  }) : _manifest = initial;

  CalendarReminderManifest? _manifest;
  int failSaveCount;
  bool failClear;

  /// When true, loads report the stored manifest as corrupt so conservative
  /// paths (no schedule/cancel/overwrite) can be exercised with observable
  /// save/clear counts.
  final bool corruptOnLoad;
  int saveCount = 0;
  int clearCount = 0;

  @override
  Future<CalendarReminderManifestLoadResult>
  loadCalendarReminderManifestResult() async {
    if (corruptOnLoad) {
      return const CalendarReminderManifestLoadResult(
        manifest: CalendarReminderManifest.empty,
        status: CalendarReminderManifestLoadStatus.corrupt,
      );
    }
    final m = _manifest;
    return CalendarReminderManifestLoadResult(
      manifest: m ?? CalendarReminderManifest.empty,
      status: m == null
          ? CalendarReminderManifestLoadStatus.absent
          : CalendarReminderManifestLoadStatus.loaded,
    );
  }

  @override
  Future<CalendarReminderManifest> loadCalendarReminderManifest() async =>
      _manifest ?? CalendarReminderManifest.empty;

  @override
  Future<void> saveCalendarReminderManifest(
    CalendarReminderManifest manifest,
  ) async {
    saveCount++;
    if (failSaveCount > 0) {
      failSaveCount--;
      throw const CalendarReminderManifestStorageException('save');
    }
    _manifest = manifest;
  }

  @override
  Future<void> clearCalendarReminderManifest() async {
    clearCount++;
    if (failClear) {
      throw const CalendarReminderManifestStorageException('clear');
    }
    _manifest = CalendarReminderManifest.empty;
  }
}

// ── Helpers ─────────────────────────────────────────────────────────────────

ClientEvent _event(
  String id, {
  String startsAt = '2026-07-05T09:00:00',
  String? title,
}) => ClientEvent(
  id: id,
  calendarId: 'cal1',
  serviceId: 'svc',
  serviceName: 'Test',
  title: title ?? 'Event $id',
  startsAt: startsAt,
  endsAt: '2026-07-05T10:00:00',
  allDay: false,
  recurring: false,
  source: 'test',
);

// 2026-07-04T12:00 → the 2026-07-05T09:00 events are eligible (30-day horizon).
final _now = DateTime(2026, 7, 4, 12, 0, 0);

/// A v2 manifest with correct fingerprints for [events] at [now] — i.e. what
/// the service would persist after successfully scheduling them.
CalendarReminderManifest _fingerprintedManifest(
  List<ClientEvent> events, {
  required DateTime now,
}) {
  final candidates = buildNotificationCandidates(events, now: now);
  return CalendarReminderManifest(
    version: CalendarReminderManifest.currentVersion,
    entries: [
      for (final c in candidates)
        CalendarReminderManifestEntry(
          notificationId: c.notificationId,
          fingerprint: scheduleFingerprint(c),
        ),
    ],
  );
}

String _fingerprintedManifestJson(
  List<ClientEvent> events, {
  required DateTime now,
}) => jsonEncode(_fingerprintedManifest(events, now: now).toJson());

/// A bare v2 manifest JSON owning [ids] with no fingerprints.
String _idOnlyManifestJson(List<int> ids) =>
    jsonEncode(CalendarReminderManifest.fromIds(ids).toJson());

String _expectedFingerprint(ClientEvent event, {required DateTime now}) =>
    scheduleFingerprint(buildNotificationCandidates([event], now: now).single);

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
      expect(result.manifestPersisted, isTrue);
      expect(result.isFullySuccessful, isTrue);

      final manifest = await CaleePreferences().loadCalendarReminderManifest();
      expect(manifest.scheduledIds, contains(id));
      expect(
        manifest.entryFor(id)!.fingerprint,
        _expectedFingerprint(e1, now: _now),
        reason: 'a fingerprint is recorded for the scheduled notification',
      );
    });

    test('reconciliation is conservative on a corrupt stored manifest: it does '
        'not crash, schedule, cancel, or overwrite the stored value', () async {
      SharedPreferences.setMockInitialValues({
        'calee_pref_migrated_to_shared_prefs': true,
        'calee_pref_calendar_reminder_manifest': '{not valid json',
      });
      final service = _RecordingService();
      final e1 = _event('e1');

      final result = await service.reconcileCalendarReminders([e1], now: _now);

      // Ownership is unknown, so nothing is scheduled or cancelled and the
      // result reports corruption rather than silently treating it as empty.
      expect(result.manifestCorrupt, isTrue);
      expect(result.scheduledCount, 0);
      expect(result.isFullySuccessful, isFalse);
      expect(service.scheduled, isEmpty);
      expect(service.cancelled, isEmpty);

      // The corrupt stored value is preserved (not overwritten by an empty
      // manifest), so a later pass can retry once it is readable.
      final prefs = await SharedPreferences.getInstance();
      expect(
        prefs.getString('calee_pref_calendar_reminder_manifest'),
        '{not valid json',
      );
    });

    test('never stores the raw event title in the manifest JSON', () async {
      final prefs = _InMemoryPreferences();
      final service = _RecordingService(prefsOverride: prefs);
      final e1 = _event('e1', title: 'Confidential board meeting');

      await service.reconcileCalendarReminders([e1], now: _now);

      final storedJson = jsonEncode(
        (await prefs.loadCalendarReminderManifest()).toJson(),
      );
      expect(
        storedJson.contains('Confidential'),
        isFalse,
        reason: 'the manifest persists only a fingerprint, never raw content',
      );
    });

    test(
      'does not reschedule an unchanged (fingerprint-matching) ID and cancels '
      'nothing',
      () async {
        final e1 = _event('e1');
        SharedPreferences.setMockInitialValues({
          'calee_pref_migrated_to_shared_prefs': true,
          'calee_pref_calendar_reminder_manifest': _fingerprintedManifestJson([
            e1,
          ], now: _now),
        });

        final service = _RecordingService();
        final result = await service.reconcileCalendarReminders([
          e1,
        ], now: _now);

        expect(service.scheduled, isEmpty, reason: 'already scheduled');
        expect(service.cancelled, isEmpty, reason: 'still desired');
        expect(result.unchangedCount, 1);
        expect(result.updatedCount, 0);
        expect(result.scheduledCount, 0);
        expect(result.cancelledCount, 0);
      },
    );
  });

  group('reconcileCalendarReminders — changed content (Defect 4)', () {
    test(
      'a title-only edit re-schedules the same ID in place, no cancellation',
      () async {
        final original = _event('e1', title: 'Original title');
        final renamed = _event('e1', title: 'Renamed title');
        final id = notificationIdForEvent(original);
        expect(
          notificationIdForEvent(renamed),
          id,
          reason: 'notification ID is identity-based, so it is unchanged',
        );

        final prefs = _InMemoryPreferences(
          initial: _fingerprintedManifest([original], now: _now),
        );
        final service = _RecordingService(prefsOverride: prefs);

        final result = await service.reconcileCalendarReminders([
          renamed,
        ], now: _now);

        expect(result.updatedCount, 1, reason: 'content changed');
        expect(result.scheduledCount, 0);
        expect(result.cancelledCount, 0);
        expect(result.unchangedCount, 0);
        expect(
          service.scheduled,
          [id],
          reason: 'same ID re-scheduled → replaces the platform notification',
        );
        expect(
          service.cancelled,
          isEmpty,
          reason: 'never a global or targeted cancel for a content change',
        );

        final stored = await prefs.loadCalendarReminderManifest();
        expect(stored.scheduledIds, [id]);
        expect(
          stored.entryFor(id)!.fingerprint,
          _expectedFingerprint(renamed, now: _now),
          reason: 'the manifest now records the new content fingerprint',
        );
      },
    );

    test(
      'a legacy (null-fingerprint) entry is re-scheduled once, then unchanged',
      () async {
        final e1 = _event('e1');
        final id = notificationIdForEvent(e1);
        final prefs = _InMemoryPreferences(
          initial: CalendarReminderManifest.fromIds([id]),
        );
        final service = _RecordingService(prefsOverride: prefs);

        final first = await service.reconcileCalendarReminders([e1], now: _now);
        expect(
          first.updatedCount,
          1,
          reason: 'null fingerprint ⇒ changed ⇒ re-scheduled once to migrate',
        );
        expect(first.unchangedCount, 0);
        expect(service.scheduled, [id]);
        expect(service.cancelled, isEmpty);

        final migrated = await prefs.loadCalendarReminderManifest();
        expect(
          migrated.entryFor(id)!.fingerprint,
          isNotNull,
          reason: 'entry migrated to the v2 schema with a fingerprint',
        );

        service.scheduled.clear();
        final second = await service.reconcileCalendarReminders([
          e1,
        ], now: _now);
        expect(second.unchangedCount, 1);
        expect(second.updatedCount, 0);
        expect(
          service.scheduled,
          isEmpty,
          reason: 'already fingerprinted ⇒ no further reschedule',
        );
      },
    );

    test(
      'a start-time change is a new+stale pair, handled correctly',
      () async {
        final original = _event('e1', startsAt: '2026-07-05T09:00:00');
        final moved = _event('e1', startsAt: '2026-07-06T09:00:00');
        final oldId = notificationIdForEvent(original);
        final newId = notificationIdForEvent(moved);
        expect(oldId, isNot(newId), reason: 'ID includes start value');

        final prefs = _InMemoryPreferences(
          initial: _fingerprintedManifest([original], now: _now),
        );
        final service = _RecordingService(prefsOverride: prefs);

        final result = await service.reconcileCalendarReminders([
          moved,
        ], now: _now);

        expect(service.scheduled, [newId], reason: 'new occurrence scheduled');
        expect(service.cancelled, [oldId], reason: 'old occurrence cancelled');
        expect(result.scheduledCount, 1);
        expect(result.cancelledCount, 1);

        final stored = await prefs.loadCalendarReminderManifest();
        expect(stored.scheduledIds, [newId]);
      },
    );
  });

  group('reconcileCalendarReminders — stale cancellation', () {
    test(
      'cancels only stale IDs individually, never a blanket cancel',
      () async {
        final e1 = _event('e1');
        final keepId = notificationIdForEvent(e1);
        const staleId = 424242; // in the manifest but no longer desired

        final prefs = _InMemoryPreferences(
          initial: CalendarReminderManifest(
            version: CalendarReminderManifest.currentVersion,
            entries: [
              CalendarReminderManifestEntry(
                notificationId: keepId,
                fingerprint: _expectedFingerprint(e1, now: _now),
              ),
              const CalendarReminderManifestEntry(
                notificationId: staleId,
                fingerprint: 'stale-fp',
              ),
            ],
          ),
        );

        final service = _RecordingService(prefsOverride: prefs);
        final result = await service.reconcileCalendarReminders([
          e1,
        ], now: _now);

        expect(service.cancelled, [staleId]);
        expect(service.cancelled, isNot(contains(keepId)));
        expect(result.cancelledCount, 1);
        expect(result.unchangedCount, 1);

        final manifest = await prefs.loadCalendarReminderManifest();
        expect(manifest.scheduledIds, contains(keepId));
        expect(manifest.scheduledIds, isNot(contains(staleId)));
      },
    );

    test('a failed stale cancellation is retained in the manifest', () async {
      const staleId = 555;
      final prefs = _InMemoryPreferences(
        initial: CalendarReminderManifest.fromIds([staleId]),
      );
      final service = _RecordingService(
        prefsOverride: prefs,
        failCancelIds: {staleId},
      );

      final result = await service.reconcileCalendarReminders(
        const [],
        now: _now,
      );

      expect(result.cancelledCount, 0);
      expect(result.failedCount, 1);
      final stored = await prefs.loadCalendarReminderManifest();
      expect(
        stored.scheduledIds,
        [staleId],
        reason: 'a stale ID we could not cancel is kept for a later retry',
      );
    });

    test('reconciling all-unchanged events cancels nothing', () async {
      final e1 = _event('e1');
      final e2 = _event('e2', startsAt: '2026-07-06T09:00:00');
      SharedPreferences.setMockInitialValues({
        'calee_pref_migrated_to_shared_prefs': true,
        'calee_pref_calendar_reminder_manifest': _fingerprintedManifestJson([
          e1,
          e2,
        ], now: _now),
      });

      final service = _RecordingService();
      await service.reconcileCalendarReminders([e1, e2], now: _now);

      expect(service.cancelled, isEmpty);
      expect(service.scheduled, isEmpty);
    });
  });

  group('reconcileCalendarReminders — scheduling failures', () {
    test(
      'a scheduling failure is reflected in the result and not claimed in the '
      'manifest',
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
        expect(result.isFullySuccessful, isFalse);

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

  group('reconcileCalendarReminders — manifest save failure (Defect 3/5)', () {
    test(
      'a save failure rolls back new IDs and preserves the previous manifest',
      () async {
        final e1 = _event('e1'); // previously scheduled, stays unchanged
        final e2 = _event('e2', startsAt: '2026-07-06T09:00:00'); // new
        final id1 = notificationIdForEvent(e1);
        final id2 = notificationIdForEvent(e2);

        final prefs = _InMemoryPreferences(
          initial: _fingerprintedManifest([e1], now: _now),
          failSaveCount: 1,
        );
        final service = _RecordingService(prefsOverride: prefs);

        final result = await service.reconcileCalendarReminders([
          e1,
          e2,
        ], now: _now);

        expect(service.scheduled, [id2], reason: 'only the new ID scheduled');
        expect(
          service.cancelled,
          [id2],
          reason: 'the new ID is rolled back after the save failure',
        );
        expect(result.manifestPersisted, isFalse);
        expect(result.isFullySuccessful, isFalse);

        final stored = await prefs.loadCalendarReminderManifest();
        expect(stored.scheduledIds, [
          id1,
        ], reason: 'the previous manifest remains available');
        expect(stored.scheduledIds, isNot(contains(id2)));
      },
    );

    test(
      'when rollback cancellation also fails, a recovery write re-tracks the '
      'still-owned ID',
      () async {
        final e1 = _event('e1');
        final e2 = _event('e2', startsAt: '2026-07-06T09:00:00');
        final id1 = notificationIdForEvent(e1);
        final id2 = notificationIdForEvent(e2);

        // Fail only the reconcile save; the recovery save succeeds.
        final prefs = _InMemoryPreferences(
          initial: _fingerprintedManifest([e1], now: _now),
          failSaveCount: 1,
        );
        // Make the rollback cancel of the new ID fail, forcing recovery.
        final service = _RecordingService(
          prefsOverride: prefs,
          failCancelIds: {id2},
        );

        final result = await service.reconcileCalendarReminders([
          e1,
          e2,
        ], now: _now);

        expect(result.manifestPersisted, isFalse);
        expect(
          prefs.saveCount,
          2,
          reason: 'reconcile save failed; one recovery save was attempted',
        );

        final stored = await prefs.loadCalendarReminderManifest();
        expect(
          stored.scheduledIds,
          containsAll(<int>[id1, id2]),
          reason:
              'recovery re-establishes tracking of the still-scheduled ID '
              'without discarding the previous manifest',
        );
      },
    );

    test('a save failure with no new IDs needs no rollback', () async {
      // Only a stale cancellation happens; nothing new was scheduled.
      const staleId = 777;
      final prefs = _InMemoryPreferences(
        initial: CalendarReminderManifest.fromIds([staleId]),
        failSaveCount: 1,
      );
      final service = _RecordingService(prefsOverride: prefs);

      final result = await service.reconcileCalendarReminders(
        const [],
        now: _now,
      );

      expect(service.cancelled, [staleId]);
      expect(result.manifestPersisted, isFalse);
      // Previous manifest untouched (save failed) → stale ID still tracked.
      final stored = await prefs.loadCalendarReminderManifest();
      expect(stored.scheduledIds, [staleId]);
    });
  });

  group('reconcileCalendarReminders — initialization failure', () {
    test('preserves the existing manifest when not initialized', () async {
      const existingId = 999;
      SharedPreferences.setMockInitialValues({
        'calee_pref_migrated_to_shared_prefs': true,
        'calee_pref_calendar_reminder_manifest': _idOnlyManifestJson([
          existingId,
        ]),
      });

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
        'calee_pref_calendar_reminder_manifest': _idOnlyManifestJson([
          11,
          22,
          33,
        ]),
      });

      final service = _RecordingService();
      final result = await service.disableCalendarReminders();

      expect(service.cancelled, [11, 22, 33]);
      expect(result.cancelledCount, 3);
      expect(result.failedCount, 0);
      expect(result.manifestPersisted, isTrue);
      expect(result.isFullyClean, isTrue);

      final manifest = await CaleePreferences().loadCalendarReminderManifest();
      expect(manifest.scheduledIds, isEmpty);
    });

    test('cancels nothing when the manifest is empty', () async {
      final service = _RecordingService();
      final result = await service.disableCalendarReminders();
      expect(service.cancelled, isEmpty);
      expect(result.cancelledCount, 0);
      expect(result.isFullyClean, isTrue);
    });

    test('retains only the failed ID on partial cancellation', () async {
      final prefs = _InMemoryPreferences(
        initial: CalendarReminderManifest.fromIds([11, 22, 33]),
      );
      final service = _RecordingService(
        prefsOverride: prefs,
        failCancelIds: {22},
      );

      final result = await service.disableCalendarReminders();

      expect(result.cancelledCount, 2);
      expect(result.failedCount, 1);
      expect(result.manifestPersisted, isTrue);
      expect(service.cancelled, containsAll(<int>[11, 33]));
      expect(service.cancelled, isNot(contains(22)));

      final stored = await prefs.loadCalendarReminderManifest();
      expect(
        stored.scheduledIds,
        [22],
        reason: 'only the ID whose cancellation failed is retained',
      );
    });

    test('a later cleanup retries and removes the retained ID', () async {
      final prefs = _InMemoryPreferences(
        initial: CalendarReminderManifest.fromIds([22]),
      );
      final service = _RecordingService(prefsOverride: prefs);

      final result = await service.disableCalendarReminders();

      expect(result.cancelledCount, 1);
      expect(result.failedCount, 0);
      expect(service.cancelled, [22]);
      final stored = await prefs.loadCalendarReminderManifest();
      expect(stored.scheduledIds, isEmpty);
    });

    test('manifest clear failure is reported', () async {
      final prefs = _InMemoryPreferences(
        initial: CalendarReminderManifest.fromIds([11]),
        failClear: true,
      );
      final service = _RecordingService(prefsOverride: prefs);

      final result = await service.disableCalendarReminders();

      expect(result.cancelledCount, 1);
      expect(
        result.manifestPersisted,
        isFalse,
        reason: 'a clear failure is surfaced, not swallowed',
      );
      expect(result.isFullyClean, isFalse);
    });

    test('manifest save failure while retaining IDs is reported', () async {
      final prefs = _InMemoryPreferences(
        initial: CalendarReminderManifest.fromIds([11, 22]),
        failSaveCount: 1,
      );
      final service = _RecordingService(
        prefsOverride: prefs,
        failCancelIds: {22},
      );

      final result = await service.disableCalendarReminders();

      expect(result.cancelledCount, 1);
      expect(result.failedCount, 1);
      expect(
        result.manifestPersisted,
        isFalse,
        reason: 'a save failure of the retained IDs is surfaced',
      );
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

  group('reconcileCalendarReminders — account isolation (Defect 2)', () {
    final ownerA = reminderOwnerKey('acct-A');
    final ownerB = reminderOwnerKey('acct-B');

    CalendarReminderManifestEntry ownedEntry(ClientEvent e, String owner) {
      final cand = buildNotificationCandidates(
        [e],
        now: _now,
        ownerKey: owner,
      ).single;
      return CalendarReminderManifestEntry(
        notificationId: cand.notificationId,
        fingerprint: scheduleFingerprint(cand),
        ownerKey: owner,
      );
    }

    test('schedules account-scoped IDs and records the owner', () async {
      final prefs = _InMemoryPreferences();
      final service = _RecordingService(prefsOverride: prefs);
      final e1 = _event('e1');
      final idA = notificationIdForEvent(e1, ownerKey: ownerA);

      final result = await service.reconcileCalendarReminders(
        [e1],
        now: _now,
        ownerKey: ownerA,
      );

      expect(result.scheduledCount, 1);
      expect(service.scheduled, [idA]);
      final stored = await prefs.loadCalendarReminderManifest();
      expect(stored.entryFor(idA)!.ownerKey, ownerA);
    });

    test(
      'account A entries are never unchanged for account B: they are cleaned '
      'and fresh B-owned entries are scheduled',
      () async {
        final e1 = _event('e1');
        final idA = notificationIdForEvent(e1, ownerKey: ownerA);
        final idB = notificationIdForEvent(e1, ownerKey: ownerB);
        expect(idA, isNot(idB));

        final prefs = _InMemoryPreferences(
          initial: CalendarReminderManifest(
            version: CalendarReminderManifest.currentVersion,
            entries: [ownedEntry(e1, ownerA)],
          ),
        );
        final service = _RecordingService(prefsOverride: prefs);

        final result = await service.reconcileCalendarReminders(
          [e1],
          now: _now,
          ownerKey: ownerB,
        );

        expect(result.unchangedCount, 0, reason: 'A is not unchanged for B');
        expect(service.scheduled, [idB], reason: 'fresh B-owned entry');
        expect(service.cancelled, [idA], reason: 'A-owned entry cleaned up');

        final stored = await prefs.loadCalendarReminderManifest();
        expect(stored.scheduledIds, [idB]);
        expect(stored.entryFor(idB)!.ownerKey, ownerB);
      },
    );

    test(
      'ownerless v1/v2 entries are cleaned and migrated to owned entries',
      () async {
        final e1 = _event('e1');
        final legacyId = notificationIdForEvent(e1); // null-owner ID
        final ownedId = notificationIdForEvent(e1, ownerKey: ownerA);
        expect(legacyId, isNot(ownedId));

        final prefs = _InMemoryPreferences(
          initial: CalendarReminderManifest.fromIds([legacyId]),
        );
        final service = _RecordingService(prefsOverride: prefs);

        await service.reconcileCalendarReminders(
          [e1],
          now: _now,
          ownerKey: ownerA,
        );

        expect(service.cancelled, [legacyId], reason: 'legacy entry cleaned');
        expect(service.scheduled, [ownedId], reason: 'fresh owned entry');
        final stored = await prefs.loadCalendarReminderManifest();
        expect(stored.scheduledIds, [ownedId]);
        expect(stored.entryFor(ownedId)!.ownerKey, ownerA);
      },
    );

    test('a failed cleanup of an old account entry remains tracked', () async {
      final e1 = _event('e1');
      final idA = notificationIdForEvent(e1, ownerKey: ownerA);
      final idB = notificationIdForEvent(e1, ownerKey: ownerB);
      final prefs = _InMemoryPreferences(
        initial: CalendarReminderManifest(
          version: CalendarReminderManifest.currentVersion,
          entries: [ownedEntry(e1, ownerA)],
        ),
      );
      final service = _RecordingService(
        prefsOverride: prefs,
        failCancelIds: {idA},
      );

      final result = await service.reconcileCalendarReminders(
        [e1],
        now: _now,
        ownerKey: ownerB,
      );

      expect(result.failedCount, 1);
      final stored = await prefs.loadCalendarReminderManifest();
      expect(stored.scheduledIds, containsAll(<int>[idA, idB]));
      expect(
        stored.entryFor(idA)!.ownerKey,
        ownerA,
        reason: 'the retained old-account entry keeps its owner',
      );
      expect(stored.entryFor(idB)!.ownerKey, ownerB);
    });

    test('no raw account ID, title, location, or description appears in the '
        'manifest JSON', () async {
      final prefs = _InMemoryPreferences();
      final service = _RecordingService(prefsOverride: prefs);
      const e1 = ClientEvent(
        id: 'e1',
        calendarId: 'cal1',
        serviceId: 'svc',
        serviceName: 'Test',
        title: 'Confidential title',
        startsAt: '2026-07-05T09:00:00',
        endsAt: '2026-07-05T10:00:00',
        allDay: false,
        recurring: false,
        source: 'test',
        location: 'Secret location',
        description: 'Secret description',
      );
      const rawAccountId = 'account-1234-raw';
      final ownerKey = reminderOwnerKey(rawAccountId);

      await service.reconcileCalendarReminders(
        [e1],
        now: _now,
        ownerKey: ownerKey,
      );

      final storedJson = jsonEncode(
        (await prefs.loadCalendarReminderManifest()).toJson(),
      );
      expect(storedJson.contains(rawAccountId), isFalse);
      expect(storedJson.contains('Confidential'), isFalse);
      expect(storedJson.contains('Secret'), isFalse);
      expect(
        storedJson.contains(ownerKey),
        isTrue,
        reason: 'the privacy-safe owner digest IS stored',
      );
    });
  });

  group('reconcileCalendarReminders — corrupt manifest (Defect 4)', () {
    test(
      'does not schedule, cancel, or overwrite on a corrupt manifest',
      () async {
        final prefs = _InMemoryPreferences(corruptOnLoad: true);
        final service = _RecordingService(prefsOverride: prefs);

        final result = await service.reconcileCalendarReminders([
          _event('e1'),
        ], now: _now);

        expect(result.manifestCorrupt, isTrue);
        expect(result.isFullySuccessful, isFalse);
        expect(service.scheduled, isEmpty);
        expect(service.cancelled, isEmpty);
        expect(
          prefs.saveCount,
          0,
          reason: 'the stored value is not overwritten',
        );
        expect(prefs.clearCount, 0);
      },
    );
  });

  group('disableCalendarReminders — result semantics (Defect 3)', () {
    test(
      'cancellation success + clear success is fully clean (no failures)',
      () async {
        final prefs = _InMemoryPreferences(
          initial: CalendarReminderManifest.fromIds([11]),
        );
        final service = _RecordingService(prefsOverride: prefs);

        final result = await service.disableCalendarReminders();

        expect(result.cancelledCount, 1);
        expect(result.manifestPersisted, isTrue);
        expect(result.isFullyClean, isTrue);
        expect(result.hasFailures, isFalse);
      },
    );

    test(
      'cancellation success + manifest clear FAILURE reports failures',
      () async {
        final prefs = _InMemoryPreferences(
          initial: CalendarReminderManifest.fromIds([11]),
          failClear: true,
        );
        final service = _RecordingService(prefsOverride: prefs);

        final result = await service.disableCalendarReminders();

        expect(result.cancelledCount, 1);
        expect(result.failedCount, 0);
        expect(result.manifestPersisted, isFalse);
        expect(
          result.hasFailures,
          isTrue,
          reason: 'a persistence failure is a cleanup failure, not success',
        );
        expect(result.isFullyClean, isFalse);
      },
    );

    test(
      'is conservative on a corrupt manifest: cancels nothing, no clear',
      () async {
        final prefs = _InMemoryPreferences(corruptOnLoad: true);
        final service = _RecordingService(prefsOverride: prefs);

        final result = await service.disableCalendarReminders();

        expect(service.cancelled, isEmpty);
        expect(result.manifestPersisted, isFalse);
        expect(result.hasFailures, isTrue);
        expect(prefs.clearCount, 0, reason: 'the corrupt value is left intact');
        expect(prefs.saveCount, 0);
      },
    );
  });

  group('reconcileCalendarReminders — rollback result (Defect 6)', () {
    ClientEvent newEvent() => _event('e2', startsAt: '2026-07-06T09:00:00');

    test('a successful rollback is represented in the result', () async {
      final e1 = _event('e1');
      final e2 = newEvent();
      final id2 = notificationIdForEvent(e2);
      final prefs = _InMemoryPreferences(
        initial: _fingerprintedManifest([e1], now: _now),
        failSaveCount: 1,
      );
      final service = _RecordingService(prefsOverride: prefs);

      final result = await service.reconcileCalendarReminders([
        e1,
        e2,
      ], now: _now);

      expect(result.manifestPersisted, isFalse);
      expect(result.rollback, isNotNull);
      expect(result.rollback!.rollbackCancelledCount, 1);
      expect(result.rollback!.rollbackFailedCount, 0);
      expect(result.rollback!.recoveryWriteAttempted, isFalse);
      expect(result.rollback!.isFullySuccessful, isTrue);
      expect(result.isFullySuccessful, isFalse);
      expect(service.cancelled, [id2]);
    });

    test(
      'a rollback cancellation failure with successful recovery is represented',
      () async {
        final e1 = _event('e1');
        final e2 = newEvent();
        final id2 = notificationIdForEvent(e2);
        final prefs = _InMemoryPreferences(
          initial: _fingerprintedManifest([e1], now: _now),
          failSaveCount: 1,
        );
        final service = _RecordingService(
          prefsOverride: prefs,
          failCancelIds: {id2},
        );

        final result = await service.reconcileCalendarReminders([
          e1,
          e2,
        ], now: _now);

        expect(result.rollback!.rollbackFailedCount, 1);
        expect(result.rollback!.recoveryWriteAttempted, isTrue);
        expect(result.rollback!.recoveryManifestPersisted, isTrue);
        expect(
          result.rollback!.isFullySuccessful,
          isTrue,
          reason: 'recovery re-tracked the ID that could not be cancelled',
        );
        expect(result.isFullySuccessful, isFalse);
      },
    );

    test('a failed recovery write is represented, not swallowed', () async {
      final e1 = _event('e1');
      final e2 = newEvent();
      final id2 = notificationIdForEvent(e2);
      // Fail the reconcile save AND the recovery save.
      final prefs = _InMemoryPreferences(
        initial: _fingerprintedManifest([e1], now: _now),
        failSaveCount: 2,
      );
      final service = _RecordingService(
        prefsOverride: prefs,
        failCancelIds: {id2},
      );

      final result = await service.reconcileCalendarReminders([
        e1,
        e2,
      ], now: _now);

      expect(result.rollback!.rollbackFailedCount, 1);
      expect(result.rollback!.recoveryWriteAttempted, isTrue);
      expect(result.rollback!.recoveryManifestPersisted, isFalse);
      expect(result.rollback!.isFullySuccessful, isFalse);
      expect(result.isFullySuccessful, isFalse);
    });

    test(
      'a save failure with no new IDs yields an empty (successful) rollback',
      () async {
        const staleId = 888;
        final prefs = _InMemoryPreferences(
          initial: CalendarReminderManifest.fromIds([staleId]),
          failSaveCount: 1,
        );
        final service = _RecordingService(prefsOverride: prefs);

        final result = await service.reconcileCalendarReminders(
          const [],
          now: _now,
        );

        expect(result.manifestPersisted, isFalse);
        expect(result.rollback, isNotNull);
        expect(result.rollback!.rollbackCancelledCount, 0);
        expect(result.rollback!.rollbackFailedCount, 0);
        expect(result.rollback!.isFullySuccessful, isTrue);
      },
    );
  });
}

// Tests for LocalCalendarNotificationService reconciliation, disable, and
// retry-safe initialization.
//
// Uses forTest() subclassing to control plugin operations (schedule / cancel /
// initialize) without hitting flutter_local_notifications platform channels.

import 'dart:async';
import 'dart:convert';

import 'package:calee_mobile/data/auth/calee_preferences.dart';
import 'package:calee_mobile/data/models/calendar_reminder_manifest.dart';
import 'package:calee_mobile/data/models/client_calendar.dart';
import 'package:calee_mobile/features/notifications/calendar_notification_candidates.dart';
import 'package:calee_mobile/features/notifications/local_calendar_notification_service.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
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
  Future<LocalNotificationInitializationResult>
  performPluginInitialization() async {
    attempts++;
    if (failFirst && attempts == 1) {
      throw Exception('simulated init failure');
    }
    return const LocalNotificationInitializationResult(
      status: LocalNotificationInitializationStatus.initialized,
    );
  }
}

/// Reports as not-initialized so reconcile takes the init-failure path.
class _UninitializedService extends LocalCalendarNotificationService {
  _UninitializedService() : super.forTest();

  @override
  Future<bool> ensureInitialized() async => false;
}

/// Drives [performPluginInitialization] through its real orchestration while
/// controlling every low-level seam (plugin result, platform, Android impl,
/// channel creation) so each initialization outcome can be exercised without
/// platform channels.
class _ConfigurableInitService extends LocalCalendarNotificationService {
  _ConfigurableInitService({
    this.pluginResult = true,
    this.android = true,
    this.androidImplPresent = true,
    this.channelThrows = false,
    this.pluginThrows = false,
  }) : super.forTest();

  bool? pluginResult;
  bool android;
  bool androidImplPresent;
  bool channelThrows;
  bool pluginThrows;
  int pluginCalls = 0;
  int channelCalls = 0;

  @override
  Future<bool?> initializePlugin(InitializationSettings settings) async {
    pluginCalls++;
    if (pluginThrows) throw Exception('simulated plugin init throw');
    return pluginResult;
  }

  @override
  bool get isAndroidPlatform => android;

  @override
  Object? resolveAndroidImplementation() => androidImplPresent ? _marker : null;

  static final Object _marker = Object();

  @override
  Future<void> createAndroidChannel(Object androidImpl) async {
    channelCalls++;
    if (channelThrows) throw Exception('simulated channel failure');
  }
}

/// Controls pending platform requests and the manifest so [collectDiagnostics]
/// can be exercised without platform channels.
class _DiagnosticsService extends LocalCalendarNotificationService {
  _DiagnosticsService({
    required this.pending,
    this.prefsOverride,
    this.pendingThrows = false,
  }) : super.forTest();

  final List<PendingNotificationRequest> pending;
  final CaleePreferences? prefsOverride;
  final bool pendingThrows;

  @override
  CaleePreferences get preferences => prefsOverride ?? super.preferences;

  @override
  Future<bool> ensureInitialized() async => true;

  @override
  Future<List<PendingNotificationRequest>> pendingNotificationRequests() async {
    if (pendingThrows) throw Exception('simulated pending query failure');
    return pending;
  }
}

/// A Calee calendar-reminder pending request whose payload embeds event data
/// (so diagnostics privacy can be verified).
PendingNotificationRequest _caleePending(
  int id, {
  String title = 'Secret title',
  String eventId = 'evt-secret',
}) => PendingNotificationRequest(
  id,
  title,
  'body-secret',
  jsonEncode({
    'type': 'calendar_event_reminder',
    'eventId': eventId,
    'occurrenceId': 'occ-secret',
    'calendarId': 'cal-secret',
    'startsAt': '2030-01-01T00:00:00Z',
  }),
);

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

// A privacy-safe owner key for cleanup tests. The legacy manifests these tests
// seed carry no owner, so cleanup is exercised with includeLegacyOwnerless.
final _testOwner = reminderOwnerKey('acct-test');

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
      final result = await service.disableCalendarReminders(
        ownerKey: _testOwner,
        includeLegacyOwnerless: true,
      );

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
      final result = await service.disableCalendarReminders(
        ownerKey: _testOwner,
        includeLegacyOwnerless: true,
      );
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

      final result = await service.disableCalendarReminders(
        ownerKey: _testOwner,
        includeLegacyOwnerless: true,
      );

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

      final result = await service.disableCalendarReminders(
        ownerKey: _testOwner,
        includeLegacyOwnerless: true,
      );

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

      final result = await service.disableCalendarReminders(
        ownerKey: _testOwner,
        includeLegacyOwnerless: true,
      );

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

      final result = await service.disableCalendarReminders(
        ownerKey: _testOwner,
        includeLegacyOwnerless: true,
      );

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

  group('initialize — structured result (Defect 3)', () {
    test('plugin returns true → initialized, service usable', () async {
      final service = _ConfigurableInitService(pluginResult: true);
      final result = await service.initialize();
      expect(result.status, LocalNotificationInitializationStatus.initialized);
      expect(result.isInitialized, isTrue);
      expect(service.debugInitialized, isTrue);
      expect(service.channelCalls, 1, reason: 'channel created after init');
    });

    test('plugin returns false → not initialized', () async {
      final service = _ConfigurableInitService(pluginResult: false);
      final result = await service.initialize();
      expect(
        result.status,
        LocalNotificationInitializationStatus.pluginRejected,
      );
      expect(service.debugInitialized, isFalse);
      expect(service.channelCalls, 0, reason: 'no channel on rejected init');
    });

    test('plugin returns null → not initialized', () async {
      final service = _ConfigurableInitService(pluginResult: null);
      final result = await service.initialize();
      expect(
        result.status,
        LocalNotificationInitializationStatus.pluginResultMissing,
      );
      expect(service.debugInitialized, isFalse);
    });

    test('Android implementation missing → not initialized', () async {
      final service = _ConfigurableInitService(
        pluginResult: true,
        android: true,
        androidImplPresent: false,
      );
      final result = await service.initialize();
      expect(
        result.status,
        LocalNotificationInitializationStatus.platformImplementationMissing,
      );
      expect(service.debugInitialized, isFalse);
    });

    test('channel creation failure → not initialized', () async {
      final service = _ConfigurableInitService(
        pluginResult: true,
        channelThrows: true,
      );
      final result = await service.initialize();
      expect(
        result.status,
        LocalNotificationInitializationStatus.channelCreationFailed,
      );
      expect(result.errorCategory, isNotNull);
      expect(service.debugInitialized, isFalse);
    });

    test('exception during plugin init → not initialized', () async {
      final service = _ConfigurableInitService(pluginThrows: true);
      final result = await service.initialize();
      expect(result.status, LocalNotificationInitializationStatus.exception);
      expect(service.debugInitialized, isFalse);
    });

    test('non-Android platform skips channel creation', () async {
      final service = _ConfigurableInitService(
        pluginResult: true,
        android: false,
      );
      final result = await service.initialize();
      expect(result.isInitialized, isTrue);
      expect(service.channelCalls, 0);
    });

    test('retry succeeds after each failure type', () async {
      for (final configure in <void Function(_ConfigurableInitService)>[
        (s) => s.pluginResult = false,
        (s) => s.pluginResult = null,
        (s) => s.androidImplPresent = false,
        (s) => s.channelThrows = true,
        (s) => s.pluginThrows = true,
      ]) {
        final service = _ConfigurableInitService();
        configure(service);
        final failed = await service.initialize();
        expect(failed.isInitialized, isFalse);
        expect(service.debugInitialized, isFalse);

        // Fix the fault and retry: the failed attempt must not poison it.
        service
          ..pluginResult = true
          ..androidImplPresent = true
          ..channelThrows = false
          ..pluginThrows = false;
        final ok = await service.initialize();
        expect(ok.isInitialized, isTrue);
        expect(service.debugInitialized, isTrue);
      }
    });

    test('concurrent callers share one in-flight attempt', () async {
      final service = _ConfigurableInitService(pluginResult: true);
      await Future.wait([
        service.initialize(),
        service.initialize(),
        service.initialize(),
      ]);
      expect(service.pluginCalls, 1);
      expect(service.debugInitialized, isTrue);
    });

    test('lastInitializationResult carries no sensitive data', () async {
      final service = _ConfigurableInitService(channelThrows: true);
      await service.initialize();
      final text = service.lastInitializationResult.toString();
      // Only status/category, never content.
      expect(text, contains('channelCreationFailed'));
      expect(text, isNot(contains('@')));
    });
  });

  group('collectDiagnostics — pending vs manifest (Defect 8)', () {
    test('counts only Calee reminders and agrees with manifest', () async {
      final prefs = _InMemoryPreferences(
        initial: CalendarReminderManifest.fromIds([1, 2]),
      );
      final service = _DiagnosticsService(
        prefsOverride: prefs,
        pending: [
          _caleePending(1),
          _caleePending(2),
          // A non-Calee notification the diagnostics must ignore.
          PendingNotificationRequest(
            999,
            't',
            'b',
            jsonEncode({'type': 'other'}),
          ),
        ],
      );

      final d = await service.collectDiagnostics();
      expect(d.initialized, isTrue);
      expect(d.pendingPlatformCount, 2);
      expect(d.trackedManifestCount, 2);
      expect(d.trackedButNotPendingCount, 0);
      expect(d.pendingButUntrackedCalendarCount, 0);
      expect(d.scheduleMode, 'inexactAllowWhileIdle');
    });

    test('detects manifest-claims-but-not-pending', () async {
      final prefs = _InMemoryPreferences(
        initial: CalendarReminderManifest.fromIds([1, 2, 3]),
      );
      final service = _DiagnosticsService(
        prefsOverride: prefs,
        pending: [_caleePending(1)],
      );
      final d = await service.collectDiagnostics();
      expect(d.pendingPlatformCount, 1);
      expect(d.trackedManifestCount, 3);
      expect(d.trackedButNotPendingCount, 2);
      expect(d.pendingButUntrackedCalendarCount, 0);
    });

    test('detects pending-but-untracked', () async {
      final prefs = _InMemoryPreferences(
        initial: CalendarReminderManifest.fromIds([1]),
      );
      final service = _DiagnosticsService(
        prefsOverride: prefs,
        pending: [_caleePending(1), _caleePending(2)],
      );
      final d = await service.collectDiagnostics();
      expect(d.pendingButUntrackedCalendarCount, 1);
    });

    test('a pending-query failure is non-destructive and reported', () async {
      final prefs = _InMemoryPreferences(
        initial: CalendarReminderManifest.fromIds([1]),
      );
      final service = _DiagnosticsService(
        prefsOverride: prefs,
        pending: const [],
        pendingThrows: true,
      );
      final d = await service.collectDiagnostics();
      expect(d.errorCategory, isNotNull);
      // Nothing was cancelled or written.
      expect(prefs.saveCount, 0);
      expect(prefs.clearCount, 0);
    });

    test('diagnostic output contains no event or account data', () async {
      final prefs = _InMemoryPreferences(
        initial: CalendarReminderManifest.fromIds([1]),
      );
      final service = _DiagnosticsService(
        prefsOverride: prefs,
        pending: [
          _caleePending(1, title: 'Dentist at 3pm', eventId: 'evt-12345'),
        ],
      );
      final d = await service.collectDiagnostics();
      final text = d.toString();
      for (final leak in [
        'Dentist',
        'evt-12345',
        'occ-secret',
        'cal-secret',
        'body-secret',
        '2030-01-01',
      ]) {
        expect(text, isNot(contains(leak)), reason: 'leaked $leak');
      }
    });
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

    test('account A entries are retained (never cancelled) when account B '
        'reconciles; a fresh B-owned entry is scheduled alongside', () async {
      // Foreign-owner (A) reminders belong to another account on the device.
      // B's reconcile must never cancel or overwrite them — it reserves their
      // IDs and retains them, scheduling its own entry independently. A's own
      // cleanup (sign-out / owner-scoped disable) is the only thing that
      // removes A's reminders.
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
      expect(
        service.cancelled,
        isEmpty,
        reason: 'the foreign A entry is retained, never cancelled',
      );

      final stored = await prefs.loadCalendarReminderManifest();
      expect(
        stored.scheduledIds,
        containsAll(<int>[idA, idB]),
        reason: 'both accounts are independently represented',
      );
      expect(stored.entryFor(idA)!.ownerKey, ownerA);
      expect(stored.entryFor(idB)!.ownerKey, ownerB);
    });

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

    test('a foreign-owner entry is retained and never cancelled, so a failing '
        'cancel is never even attempted', () async {
      final e1 = _event('e1');
      final idA = notificationIdForEvent(e1, ownerKey: ownerA);
      final idB = notificationIdForEvent(e1, ownerKey: ownerB);
      final prefs = _InMemoryPreferences(
        initial: CalendarReminderManifest(
          version: CalendarReminderManifest.currentVersion,
          entries: [ownedEntry(e1, ownerA)],
        ),
      );
      // Even if cancelling A's ID would fail, reconcile never touches it.
      final service = _RecordingService(
        prefsOverride: prefs,
        failCancelIds: {idA},
      );

      final result = await service.reconcileCalendarReminders(
        [e1],
        now: _now,
        ownerKey: ownerB,
      );

      expect(
        result.failedCount,
        0,
        reason: 'the foreign entry is never cancelled, so there is no failure',
      );
      expect(service.cancelled, isEmpty);
      final stored = await prefs.loadCalendarReminderManifest();
      expect(stored.scheduledIds, containsAll(<int>[idA, idB]));
      expect(
        stored.entryFor(idA)!.ownerKey,
        ownerA,
        reason: 'the retained foreign entry keeps its owner',
      );
      expect(stored.entryFor(idB)!.ownerKey, ownerB);
    });

    test('a forced foreign-owner ID collision: the candidate probes to a new '
        'ID, the foreign notification is never replaced, and both remain '
        '(Fix 5)', () async {
      const foreignId = 424242;
      final e1 = _event('e1');
      final prefs = _InMemoryPreferences(
        initial: CalendarReminderManifest(
          version: CalendarReminderManifest.currentVersion,
          entries: [
            CalendarReminderManifestEntry(
              notificationId: foreignId,
              fingerprint: 'f' * 64,
              ownerKey: ownerA,
            ),
          ],
        ),
      );
      final service = _RecordingService(prefsOverride: prefs);
      // Force the new account's (B) base ID to equal the foreign entry's ID;
      // probe p resolves to foreignId + p.
      service.debugNotificationIdOverride = (c, probe) => foreignId + probe;

      final result = await service.reconcileCalendarReminders(
        [e1],
        now: _now,
        ownerKey: ownerB,
      );

      expect(
        service.scheduled,
        [foreignId + 1],
        reason: 'the current candidate uses a probed (non-foreign) ID',
      );
      expect(result.collisionsResolved, 1);
      expect(
        service.cancelled,
        isEmpty,
        reason: 'no global cancellation; the foreign notification is untouched',
      );

      final stored = await prefs.loadCalendarReminderManifest();
      expect(
        stored.scheduledIds,
        containsAll(<int>[foreignId, foreignId + 1]),
        reason: 'both entries remain independently represented',
      );
      expect(
        stored.entryFor(foreignId)!.ownerKey,
        ownerA,
        reason: 'the foreign entry is preserved with its owner',
      );
      expect(stored.entryFor(foreignId + 1)!.ownerKey, ownerB);
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

        final result = await service.disableCalendarReminders(
          ownerKey: _testOwner,
          includeLegacyOwnerless: true,
        );

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

        final result = await service.disableCalendarReminders(
          ownerKey: _testOwner,
          includeLegacyOwnerless: true,
        );

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

        final result = await service.disableCalendarReminders(
          ownerKey: _testOwner,
          includeLegacyOwnerless: true,
        );

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

  group('disableCalendarReminders — owner-scoped (Requirement 4)', () {
    final ownerA = reminderOwnerKey('acct-A');
    final ownerB = reminderOwnerKey('acct-B');

    CalendarReminderManifestEntry owned(int id, String owner) =>
        CalendarReminderManifestEntry(
          notificationId: id,
          fingerprint: null,
          ownerKey: owner,
        );

    test(
      'cancels only the given owner entries; other owners are preserved',
      () async {
        final prefs = _InMemoryPreferences(
          initial: CalendarReminderManifest(
            version: CalendarReminderManifest.currentVersion,
            entries: [owned(1, ownerA), owned(2, ownerB), owned(3, ownerA)],
          ),
        );
        final service = _RecordingService(prefsOverride: prefs);

        final result = await service.disableCalendarReminders(ownerKey: ownerA);

        expect(service.cancelled, [1, 3]);
        expect(result.cancelledCount, 2);
        final stored = await prefs.loadCalendarReminderManifest();
        expect(stored.scheduledIds, [
          2,
        ], reason: 'the other account is preserved');
        expect(stored.entryFor(2)!.ownerKey, ownerB);
      },
    );

    test('a failed cancellation stays owned by the same account', () async {
      final prefs = _InMemoryPreferences(
        initial: CalendarReminderManifest(
          version: CalendarReminderManifest.currentVersion,
          entries: [owned(1, ownerA), owned(2, ownerB)],
        ),
      );
      final service = _RecordingService(
        prefsOverride: prefs,
        failCancelIds: {1},
      );

      final result = await service.disableCalendarReminders(ownerKey: ownerA);

      expect(result.failedCount, 1);
      final stored = await prefs.loadCalendarReminderManifest();
      expect(stored.scheduledIds, containsAll(<int>[1, 2]));
      expect(stored.entryFor(1)!.ownerKey, ownerA);
      expect(stored.entryFor(2)!.ownerKey, ownerB);
    });

    test(
      'ownerless legacy entries are cleaned only with includeLegacyOwnerless',
      () async {
        final prefs = _InMemoryPreferences(
          initial: CalendarReminderManifest(
            version: CalendarReminderManifest.currentVersion,
            entries: [
              const CalendarReminderManifestEntry(
                notificationId: 9,
                fingerprint: null,
              ),
              owned(1, ownerA),
            ],
          ),
        );
        final service = _RecordingService(prefsOverride: prefs);

        // Without the flag the ownerless entry is preserved.
        await service.disableCalendarReminders(ownerKey: ownerA);
        expect(service.cancelled, [1]);
        var stored = await prefs.loadCalendarReminderManifest();
        expect(stored.scheduledIds, [9]);

        // With the flag the ownerless entry is cancelled too.
        service.cancelled.clear();
        await service.disableCalendarReminders(
          ownerKey: ownerA,
          includeLegacyOwnerless: true,
        );
        expect(service.cancelled, [9]);
        stored = await prefs.loadCalendarReminderManifest();
        expect(stored.scheduledIds, isEmpty);
      },
    );

    test(
      'never clears the whole manifest while foreign entries remain',
      () async {
        final prefs = _InMemoryPreferences(
          initial: CalendarReminderManifest(
            version: CalendarReminderManifest.currentVersion,
            entries: [owned(1, ownerA), owned(2, ownerB)],
          ),
        );
        final service = _RecordingService(prefsOverride: prefs);

        await service.disableCalendarReminders(ownerKey: ownerA);

        expect(
          prefs.clearCount,
          0,
          reason: 'a save keeps the foreign entry, never a clear',
        );
        final stored = await prefs.loadCalendarReminderManifest();
        expect(stored.scheduledIds, [2]);
      },
    );

    test(
      'a corrupt manifest causes no cancellation and is left intact',
      () async {
        final prefs = _InMemoryPreferences(corruptOnLoad: true);
        final service = _RecordingService(prefsOverride: prefs);

        final result = await service.disableCalendarReminders(ownerKey: ownerA);

        expect(service.cancelled, isEmpty);
        expect(result.manifestPersisted, isFalse);
        expect(prefs.saveCount, 0);
        expect(prefs.clearCount, 0);
      },
    );
  });

  group('reconcileCalendarReminders — ID collision resolution (Requirement 9)', () {
    test('two forced-collision candidates are both scheduled with distinct IDs '
        'that stay stable across passes', () async {
      final prefs = _InMemoryPreferences();
      final service = _RecordingService(prefsOverride: prefs);
      // Force both events to the same base id 777; probe p resolves to 777 + p.
      service.debugNotificationIdOverride = (c, probe) => 777 + probe;

      final e1 = _event('e1', startsAt: '2026-07-05T09:00:00');
      final e2 = _event('e2', startsAt: '2026-07-06T09:00:00');

      final result = await service.reconcileCalendarReminders([
        e1,
        e2,
      ], now: _now);

      expect(
        service.scheduled,
        [777, 778],
        reason: 'both candidates survive with distinct IDs (no map overwrite)',
      );
      expect(result.scheduledCount, 2);
      expect(result.collisionsResolved, 1);
      expect(result.idAllocationFailures, 0);
      final stored = await prefs.loadCalendarReminderManifest();
      expect(stored.scheduledIds, [777, 778]);

      // Re-run: IDs are stable, nothing rescheduled, no duplicate created.
      service.scheduled.clear();
      final second = await service.reconcileCalendarReminders([
        e1,
        e2,
      ], now: _now);
      expect(second.unchangedCount, 2);
      expect(second.scheduledCount, 0);
      expect(service.scheduled, isEmpty);
    });

    test('an exhausted probe limit is reported, not silently dropped', () async {
      final prefs = _InMemoryPreferences();
      final service = _RecordingService(prefsOverride: prefs);
      // Every probe returns the same ID, so the second event can never allocate.
      service.debugNotificationIdOverride = (c, probe) => 555;

      final e1 = _event('e1', startsAt: '2026-07-05T09:00:00');
      final e2 = _event('e2', startsAt: '2026-07-06T09:00:00');

      final result = await service.reconcileCalendarReminders([
        e1,
        e2,
      ], now: _now);

      expect(service.scheduled, [555]);
      expect(result.idAllocationFailures, 1);
      expect(result.hasFailures, isTrue);
      expect(result.isFullySuccessful, isFalse);
    });
  });

  group('reconcileCalendarReminders — mid-pass invalidation (Requirement 3)', () {
    final owner = reminderOwnerKey('acct-A');

    CalendarReminderOperationContext ctx(bool Function() isCurrent) =>
        CalendarReminderOperationContext(
          generation: 1,
          ownerKey: owner,
          isCurrent: isCurrent,
        );

    test('invalidation before the first mutation schedules nothing and writes '
        'no manifest', () async {
      final prefs = _InMemoryPreferences();
      final service = _RecordingService(prefsOverride: prefs);

      final result = await service.reconcileCalendarReminders(
        [_event('e1')],
        now: _now,
        ownerKey: owner,
        context: ctx(() => false),
      );

      expect(result.sessionInvalidated, isTrue);
      expect(service.scheduled, isEmpty);
      expect(service.cancelled, isEmpty);
      expect(prefs.saveCount, 0, reason: 'no stale-session manifest write');
    });

    test('invalidation after one schedule rolls back new IDs and writes no '
        'manifest', () async {
      final prefs = _InMemoryPreferences();
      final service = _RecordingService(prefsOverride: prefs);
      final e1 = _event('e1', startsAt: '2026-07-05T09:00:00');
      final e2 = _event('e2', startsAt: '2026-07-06T09:00:00');

      final result = await service.reconcileCalendarReminders(
        [e1, e2],
        now: _now,
        ownerKey: owner,
        context: ctx(() => service.scheduled.isEmpty),
      );

      expect(result.sessionInvalidated, isTrue);
      expect(result.manifestPersisted, isFalse);
      expect(prefs.saveCount, 0);
      expect(service.scheduled, hasLength(1));
      expect(
        service.cancelled,
        service.scheduled,
        reason: 'the one scheduled ID was rolled back',
      );
    });

    test('invalidation during stale cancellation writes no manifest and '
        'preserves the previous one', () async {
      const staleId = 909;
      final prefs = _InMemoryPreferences(
        initial: CalendarReminderManifest.fromIds([staleId]),
      );
      final service = _RecordingService(prefsOverride: prefs);

      final result = await service.reconcileCalendarReminders(
        const [],
        now: _now,
        ownerKey: owner,
        context: ctx(() => service.cancelled.isEmpty),
      );

      expect(result.sessionInvalidated, isTrue);
      expect(prefs.saveCount, 0);
      final stored = await prefs.loadCalendarReminderManifest();
      expect(
        stored.scheduledIds,
        [staleId],
        reason: 'the previous manifest is left intact for the new session',
      );
    });

    test(
      'invalidation immediately before persistence writes no manifest',
      () async {
        final e1 = _event('e1');
        // Seed the manifest so e1 is unchanged for [owner]: no schedule/cancel, so
        // only the init checks and the before-persist check run.
        final cand = buildNotificationCandidates(
          [e1],
          now: _now,
          ownerKey: owner,
        ).single;
        final prefs = _InMemoryPreferences(
          initial: CalendarReminderManifest(
            version: CalendarReminderManifest.currentVersion,
            entries: [
              CalendarReminderManifestEntry(
                notificationId: cand.notificationId,
                fingerprint: scheduleFingerprint(cand),
                ownerKey: owner,
              ),
            ],
          ),
        );
        final service = _RecordingService(prefsOverride: prefs);
        var calls = 0;

        final result = await service.reconcileCalendarReminders(
          [e1],
          now: _now,
          ownerKey: owner,
          // Pass the before-init and after-init checks, fail the before-persist one.
          context: ctx(() {
            calls++;
            return calls < 3;
          }),
        );

        expect(result.sessionInvalidated, isTrue);
        expect(service.scheduled, isEmpty);
        expect(service.cancelled, isEmpty);
        expect(
          prefs.saveCount,
          0,
          reason: 'the stale final manifest is never written',
        );
      },
    );

    test(
      'invalidation during save-failure rollback skips the recovery write',
      () async {
        final e1 = _event('e1', startsAt: '2026-07-05T09:00:00');
        final id = notificationIdForEvent(e1, ownerKey: owner);
        var current = true;
        final prefs = _FlipThenThrowPreferences(
          initial: CalendarReminderManifest.empty,
          onSave: () => current = false,
        );
        // The rollback cancel of the new id fails, which would normally force a
        // recovery write — but the session is now invalid, so it must be skipped.
        final service = _RecordingService(
          prefsOverride: prefs,
          failCancelIds: {id},
        );

        final result = await service.reconcileCalendarReminders(
          [e1],
          now: _now,
          ownerKey: owner,
          context: ctx(() => current),
        );

        expect(result.manifestPersisted, isFalse);
        expect(result.rollback, isNotNull);
        expect(result.rollback!.rollbackFailedCount, 1);
        expect(
          result.rollback!.recoveryWriteAttempted,
          isFalse,
          reason: 'a stale session must not write a recovery manifest',
        );
        expect(
          prefs.saveCount,
          1,
          reason: 'only the failed final save was attempted',
        );
      },
    );
  });

  group('reconcileCalendarReminders — invalidation rollback of new AND '
      'replaced schedules (Fix 6)', () {
    final owner = reminderOwnerKey('acct-A');

    CalendarReminderOperationContext ctx(bool Function() isCurrent) =>
        CalendarReminderOperationContext(
          generation: 1,
          ownerKey: owner,
          isCurrent: isCurrent,
        );

    // A current-owner entry for [e] with a deliberately stale (but valid-shaped)
    // fingerprint, so reconciling [e] classifies it as changed → a replacement.
    CalendarReminderManifestEntry staleOwned(ClientEvent e) =>
        CalendarReminderManifestEntry(
          notificationId: notificationIdForEvent(e, ownerKey: owner),
          fingerprint: '0' * 64,
          ownerKey: owner,
        );

    test(
      'invalidation after a replacement schedule cancels the replacement and '
      'reports it structurally',
      () async {
        final e1 = _event('e1');
        final id = notificationIdForEvent(e1, ownerKey: owner);
        final prefs = _InMemoryPreferences(
          initial: CalendarReminderManifest(
            version: CalendarReminderManifest.currentVersion,
            entries: [staleOwned(e1)],
          ),
        );
        final service = _RecordingService(prefsOverride: prefs);

        final result = await service.reconcileCalendarReminders(
          [e1],
          now: _now,
          ownerKey: owner,
          // Becomes invalid right after the replacement is scheduled.
          context: ctx(() => service.scheduled.isEmpty),
        );

        expect(result.sessionInvalidated, isTrue);
        expect(service.scheduled, [
          id,
        ], reason: 'the replacement was scheduled');
        expect(
          service.cancelled,
          [id],
          reason: 'the replacement is rolled back, not left on the device',
        );
        expect(result.invalidationRollback, isNotNull);
        expect(result.invalidationRollback!.replacedIdsCancelled, 1);
        expect(result.invalidationRollback!.newIdsCancelled, 0);
        expect(result.invalidationRollback!.cancellationFailures, 0);
        expect(result.isFullySuccessful, isFalse);
        expect(prefs.saveCount, 0, reason: 'no stale-session manifest write');
        final stored = await prefs.loadCalendarReminderManifest();
        expect(
          stored.entryFor(id)!.fingerprint,
          '0' * 64,
          reason: 'the previous manifest is left untouched',
        );
      },
    );

    test('invalidation after BOTH a new and a replacement schedule rolls back '
        'both', () async {
      final changed = _event('e1', startsAt: '2026-07-05T09:00:00');
      final fresh = _event('e2', startsAt: '2026-07-06T09:00:00');
      final changedId = notificationIdForEvent(changed, ownerKey: owner);
      final freshId = notificationIdForEvent(fresh, ownerKey: owner);
      final prefs = _InMemoryPreferences(
        initial: CalendarReminderManifest(
          version: CalendarReminderManifest.currentVersion,
          entries: [staleOwned(changed)],
        ),
      );
      final service = _RecordingService(prefsOverride: prefs);

      final result = await service.reconcileCalendarReminders(
        [changed, fresh],
        now: _now,
        ownerKey: owner,
        // Invalid only after two successful schedules (the new + the change).
        context: ctx(() => service.scheduled.length < 2),
      );

      expect(result.sessionInvalidated, isTrue);
      expect(service.scheduled, containsAll(<int>[freshId, changedId]));
      expect(
        service.cancelled,
        containsAll(<int>[freshId, changedId]),
        reason: 'both the new and the replacement schedule are rolled back',
      );
      expect(result.invalidationRollback!.newIdsCancelled, 1);
      expect(result.invalidationRollback!.replacedIdsCancelled, 1);
      expect(result.invalidationRollback!.cancellationFailures, 0);
      expect(prefs.saveCount, 0);
    });

    test('a rollback cancellation failure is represented structurally, not '
        'only debug-logged', () async {
      final e1 = _event('e1');
      final id = notificationIdForEvent(e1, ownerKey: owner);
      final prefs = _InMemoryPreferences();
      final service = _RecordingService(
        prefsOverride: prefs,
        failCancelIds: {id},
      );

      final result = await service.reconcileCalendarReminders(
        [e1],
        now: _now,
        ownerKey: owner,
        context: ctx(() => service.scheduled.isEmpty),
      );

      expect(result.sessionInvalidated, isTrue);
      expect(result.invalidationRollback, isNotNull);
      expect(
        result.invalidationRollback!.newIdsCancelled,
        0,
        reason: 'the rollback cancel failed, so nothing was cancelled',
      );
      expect(result.invalidationRollback!.cancellationFailures, 1);
      expect(result.invalidationRollback!.isFullySuccessful, isFalse);
      expect(result.isFullySuccessful, isFalse);
    });

    test('invalidation before any successful schedule attaches no rollback '
        'record', () async {
      final e1 = _event('e1');
      final prefs = _InMemoryPreferences();
      final service = _RecordingService(prefsOverride: prefs);

      // Invalid the instant the first schedule is about to run (before-schedule
      // check trips), so nothing is ever scheduled.
      final result = await service.reconcileCalendarReminders(
        [e1],
        now: _now,
        ownerKey: owner,
        context: ctx(() => service.scheduled.isEmpty ? false : true),
      );

      expect(result.sessionInvalidated, isTrue);
      expect(service.scheduled, isEmpty);
      expect(
        result.invalidationRollback,
        isNull,
        reason: 'nothing was scheduled, so there is nothing to roll back',
      );
    });

    test('account B waits for account A serialized rollback to reach a terminal '
        'state before mutating', () async {
      // Account A reconcile is invalidated mid-pass; account B reconcile is
      // submitted while A holds the serial lock. B must not begin until A has
      // fully rolled back and released the lock.
      final ownerB = reminderOwnerKey('acct-B');
      final e1 = _event('e1');
      final prefs = _InMemoryPreferences();
      final service = _SerialService(prefsOverride: prefs);
      service.scheduleGate = Completer<void>();

      var aCurrent = true;
      // A schedules e1 (blocked at the gate), then is invalidated.
      final fA = service.reconcileCalendarReminders(
        [e1],
        now: _now,
        ownerKey: owner,
        context: CalendarReminderOperationContext(
          generation: 1,
          ownerKey: owner,
          isCurrent: () => aCurrent,
        ),
      );
      await pumpEventQueue();
      expect(service.log, [
        'schedule-start',
      ], reason: 'A holds the serial lock');

      // Submit B while A is mid-schedule — it must queue behind A.
      final fB = service.reconcileCalendarReminders(
        [e1],
        now: _now,
        ownerKey: ownerB,
      );
      await pumpEventQueue();
      expect(
        service.log.where((e) => e.startsWith('cancel')),
        isEmpty,
        reason: 'B has not started; only A is running',
      );

      // Invalidate A, then release its blocked schedule → A rolls back (cancels)
      // and releases the lock; only then may B run.
      aCurrent = false;
      service.scheduleGate!.complete();
      final rA = await fA;
      final rB = await fB;

      expect(rA.sessionInvalidated, isTrue);
      // A's rollback cancel happens before B's first schedule.
      final firstCancel = service.log.indexWhere((e) => e.startsWith('cancel'));
      final bScheduleStarts = <int>[];
      for (var i = 0; i < service.log.length; i++) {
        if (service.log[i] == 'schedule-start') bScheduleStarts.add(i);
      }
      expect(firstCancel, isNonNegative, reason: "A's rollback cancel ran");
      // The second schedule-start (B's) must come after A's rollback cancel.
      expect(
        bScheduleStarts.last,
        greaterThan(firstCancel),
        reason: "B's mutation runs only after A's rollback reached terminal",
      );
      expect(rB.sessionInvalidated, isFalse);
    });
  });

  group('serialized mutations (Requirement 2)', () {
    test(
      'a failed serialized operation does not poison later operations',
      () async {
        final service = _RecordingService();
        var secondRan = false;

        final f1 = service.runSerialized<int>(() async {
          throw Exception('boom');
        });
        final f2 = service.runSerialized<int>(() async {
          secondRan = true;
          return 42;
        });

        await expectLater(f1, throwsA(isA<Exception>()));
        expect(await f2, 42);
        expect(secondRan, isTrue);
      },
    );

    test(
      'serialized operations run in submission order, one at a time',
      () async {
        final service = _RecordingService();
        final order = <int>[];
        final gate = Completer<void>();

        final f1 = service.runSerialized<void>(() async {
          await gate.future;
          order.add(1);
        });
        final f2 = service.runSerialized<void>(() async {
          order.add(2);
        });

        await pumpEventQueue();
        expect(order, isEmpty, reason: 'the second op waits for the first');

        gate.complete();
        await Future.wait([f1, f2]);
        expect(order, [1, 2]);
      },
    );

    test(
      'reconcile and cleanup never interleave their platform mutations',
      () async {
        final ownerA = reminderOwnerKey('acct-A');
        final prefs = _InMemoryPreferences();
        final service = _SerialService(prefsOverride: prefs);
        service.scheduleGate = Completer<void>();

        // Reconcile schedules a new id (blocked mid-schedule at the gate).
        final fReconcile = service.reconcileCalendarReminders(
          [_event('e1')],
          now: _now,
          ownerKey: ownerA,
        );
        await pumpEventQueue();
        expect(service.log, [
          'schedule-start',
        ], reason: 'reconcile holds the lock, blocked mid-schedule');

        // Submit cleanup of the same owner concurrently — it must queue.
        final fDisable = service.disableCalendarReminders(
          ownerKey: ownerA,
          includeLegacyOwnerless: true,
        );
        await pumpEventQueue();
        expect(
          service.log.where((e) => e.startsWith('cancel')),
          isEmpty,
          reason: 'cleanup waits until reconcile releases the serial lock',
        );

        // Release reconcile → it finishes, then cleanup runs.
        service.scheduleGate!.complete();
        await fReconcile;
        await fDisable;

        final scheduleEnd = service.log.indexOf('schedule-end');
        final firstCancel = service.log.indexWhere(
          (e) => e.startsWith('cancel'),
        );
        expect(scheduleEnd, isNonNegative);
        expect(
          firstCancel,
          greaterThan(scheduleEnd),
          reason:
              'every reconcile mutation completes before any cleanup mutation',
        );
      },
    );
  });
}

/// A service whose schedule/cancel operations append to an observable [log] and
/// whose scheduling can be gated, so serialization ordering can be checked.
class _SerialService extends LocalCalendarNotificationService {
  _SerialService({this.prefsOverride}) : super.forTest();

  final CaleePreferences? prefsOverride;
  final List<String> log = [];
  Completer<void>? scheduleGate;

  @override
  CaleePreferences get preferences => prefsOverride ?? super.preferences;

  @override
  Future<bool> ensureInitialized() async => true;

  @override
  Future<bool> scheduleReminder(CalendarNotificationCandidate c) async {
    log.add('schedule-start');
    final gate = scheduleGate;
    if (gate != null) await gate.future;
    log.add('schedule-end');
    return true;
  }

  @override
  Future<void> cancelNotification(int id) async {
    log.add('cancel:$id');
  }
}

/// Preferences whose manifest save flips a caller-provided flag and then throws,
/// so the save-failure rollback path can be exercised while the session is being
/// invalidated mid-save.
class _FlipThenThrowPreferences extends CaleePreferences {
  _FlipThenThrowPreferences({required this.initial, required this.onSave});

  final CalendarReminderManifest initial;
  final void Function() onSave;
  int saveCount = 0;

  @override
  Future<CalendarReminderManifestLoadResult>
  loadCalendarReminderManifestResult() async =>
      CalendarReminderManifestLoadResult(
        manifest: initial,
        status: CalendarReminderManifestLoadStatus.loaded,
      );

  @override
  Future<CalendarReminderManifest> loadCalendarReminderManifest() async =>
      initial;

  @override
  Future<void> saveCalendarReminderManifest(
    CalendarReminderManifest manifest,
  ) async {
    saveCount++;
    onSave();
    throw const CalendarReminderManifestStorageException('save');
  }

  @override
  Future<void> clearCalendarReminderManifest() async {}
}

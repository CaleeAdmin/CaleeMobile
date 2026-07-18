import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:timezone/timezone.dart' as tz;

import '../../data/auth/calee_preferences.dart';
import '../../data/models/calendar_reminder_manifest.dart';
import '../../data/models/client_calendar.dart';
import 'calendar_notification_candidates.dart';

// Local event reminders are an MVP fallback. They are based on an independent
// upcoming-event window the app fetches (see CalendarReminderCoordinator) and
// can become stale if calendars change elsewhere. The long-term reliable
// design is server-side occurrence scheduling plus push delivery.

/// Structured outcome of a single calendar reminder reconciliation pass.
///
/// Deliberately holds only counts, flags, and a timestamp — never event titles,
/// locations, descriptions, tokens, or URLs — so it is safe to log.
class CalendarReconciliationResult {
  const CalendarReconciliationResult({
    required this.eventsFetched,
    required this.eligibleCandidates,
    required this.scheduledCount,
    required this.cancelledCount,
    required this.unchangedCount,
    required this.failedCount,
    required this.completedAt,
    this.updatedCount = 0,
    this.manifestPersisted = true,
    this.manifestCorrupt = false,
    this.rollback,
  });

  final int eventsFetched;
  final int eligibleCandidates;

  /// Newly-desired IDs (not previously owned) scheduled this pass.
  final int scheduledCount;

  /// Previously-owned IDs whose schedule fingerprint changed and which were
  /// re-scheduled (replacing the platform notification) this pass.
  final int updatedCount;

  /// Stale IDs (previously owned, no longer desired) cancelled this pass.
  final int cancelledCount;

  /// IDs whose fingerprint matched the desired schedule — left untouched.
  final int unchangedCount;

  /// Schedule/cancel operations that failed this pass.
  final int failedCount;

  /// Whether the final manifest reflecting the actual scheduled state was
  /// persisted. `false` means the reconciliation transaction did not complete:
  /// callers must treat the pass as not fully successful.
  final bool manifestPersisted;

  /// Whether the stored manifest was unreadable/corrupt, so ownership is
  /// unknown. When true nothing was scheduled or cancelled and the stored value
  /// was left intact for a later retry — never silently overwritten.
  final bool manifestCorrupt;

  /// Present only when the final manifest save failed and a rollback ran;
  /// describes how completely the newly-scheduled IDs were undone/recovered.
  final CalendarReminderRollbackResult? rollback;

  final DateTime completedAt;

  bool get hasFailures =>
      failedCount > 0 || !manifestPersisted || manifestCorrupt;

  /// True only when every operation succeeded, the manifest was persisted, the
  /// stored value was not corrupt, and any rollback/recovery fully succeeded.
  bool get isFullySuccessful =>
      failedCount == 0 &&
      manifestPersisted &&
      !manifestCorrupt &&
      (rollback?.isFullySuccessful ?? true);

  @override
  String toString() =>
      'CalendarReconciliationResult(events: $eventsFetched, '
      'eligible: $eligibleCandidates, scheduled: $scheduledCount, '
      'updated: $updatedCount, cancelled: $cancelledCount, '
      'unchanged: $unchangedCount, failed: $failedCount, '
      'manifestPersisted: $manifestPersisted, '
      'manifestCorrupt: $manifestCorrupt'
      '${rollback != null ? ', $rollback' : ''})';
}

/// Structured, log-safe outcome of rolling back after a failed final manifest
/// save during reconciliation.
///
/// Because the save failed, the previous manifest is still on disk untouched, so
/// previously-owned IDs remain tracked. The only IDs now on the device but not
/// owned by that manifest are the newly-scheduled ones; this result records how
/// completely they were cancelled and, if a cancel failed, whether a one-shot
/// recovery write re-established tracking of the still-scheduled IDs.
class CalendarReminderRollbackResult {
  const CalendarReminderRollbackResult({
    this.rollbackCancelledCount = 0,
    this.rollbackFailedCount = 0,
    this.recoveryWriteAttempted = false,
    this.recoveryManifestPersisted = false,
  });

  /// Newly-scheduled IDs successfully cancelled (rolled back).
  final int rollbackCancelledCount;

  /// Newly-scheduled IDs whose rollback cancellation failed and which are
  /// therefore still on the device.
  final int rollbackFailedCount;

  /// Whether a one-shot recovery manifest write was attempted (only when at
  /// least one rollback cancel failed, leaving an untracked scheduled ID).
  final bool recoveryWriteAttempted;

  /// Whether that recovery write persisted successfully.
  final bool recoveryManifestPersisted;

  /// True when the rollback fully undid the new IDs, or when the recovery write
  /// re-tracked every ID that could not be cancelled.
  bool get isFullySuccessful =>
      rollbackFailedCount == 0 ||
      (recoveryWriteAttempted && recoveryManifestPersisted);

  @override
  String toString() =>
      'CalendarReminderRollbackResult(cancelled: $rollbackCancelledCount, '
      'failed: $rollbackFailedCount, recoveryAttempted: $recoveryWriteAttempted, '
      'recoveryPersisted: $recoveryManifestPersisted)';
}

/// Structured, log-safe outcome of a targeted calendar-reminder cleanup
/// (disabling reminders, or a retry of a previously partial cleanup).
class CalendarReminderDisableResult {
  const CalendarReminderDisableResult({
    required this.cancelledCount,
    required this.failedCount,
    required this.manifestPersisted,
  });

  /// Owned IDs cancelled successfully.
  final int cancelledCount;

  /// Owned IDs whose cancellation failed and which remain in the manifest for a
  /// later retry.
  final int failedCount;

  /// Whether the resulting manifest state was persisted (cleared when all IDs
  /// were cancelled, or rewritten to retain the failed IDs).
  final bool manifestPersisted;

  /// A cleanup has failures when a cancellation failed *or* the resulting
  /// manifest state could not be persisted — a persistence failure means the
  /// cleanup did not fully complete and must be retried, so it is not success.
  bool get hasFailures => failedCount > 0 || !manifestPersisted;

  /// True only when nothing was left owned and the manifest state persisted.
  bool get isFullyClean => failedCount == 0 && manifestPersisted;

  @override
  String toString() =>
      'CalendarReminderDisableResult(cancelled: $cancelledCount, '
      'failed: $failedCount, manifestPersisted: $manifestPersisted)';
}

class LocalCalendarNotificationService {
  LocalCalendarNotificationService._();

  // Named constructor for test subclassing only.
  @visibleForTesting
  LocalCalendarNotificationService.forTest();

  static final _defaultInstance = LocalCalendarNotificationService._();
  static LocalCalendarNotificationService? _testOverride;

  static LocalCalendarNotificationService get instance =>
      _testOverride ?? _defaultInstance;

  @visibleForTesting
  static set testOverride(LocalCalendarNotificationService? service) =>
      _testOverride = service;

  final FlutterLocalNotificationsPlugin _plugin =
      FlutterLocalNotificationsPlugin();

  // True only after plugin init AND Android channel creation have both
  // completed without error. Left false on failure so a later call retries.
  bool _initialized = false;
  // Shared in-flight initialization, so concurrent callers await one attempt.
  Future<void>? _initializing;

  static const _channelId = 'calendar_event_reminders';
  static const _channelName = 'Calendar event reminders';
  static const _channelDescription =
      'Reminders for upcoming Calee calendar events';

  /// Maximum number of calendar reminders scheduled at once. Kept well within
  /// the iOS 64 pending-local-notification ceiling.
  static const _maxScheduled = 50;

  /// Preferences accessor. Overridable in tests via [forTest] subclasses that
  /// need to observe manifest reads/writes; production uses [CaleePreferences].
  @visibleForTesting
  CaleePreferences get preferences => CaleePreferences();

  // ── Initialization ──────────────────────────────────────────────────────

  /// Initializes the plugin and Android channel. Retry-safe: on failure the
  /// service does not mark itself initialized, so a later call can retry.
  /// Concurrent calls share a single in-flight attempt.
  Future<void> initialize() {
    if (_initialized) return Future<void>.value();
    final existing = _initializing;
    if (existing != null) return existing;
    final future = _doInitialize();
    _initializing = future;
    return future;
  }

  Future<void> _doInitialize() async {
    try {
      await performPluginInitialization();
      // Only now — after plugin init AND channel creation both succeeded — is
      // the service safe to use.
      _initialized = true;
    } catch (e) {
      // Leave _initialized false so a later reconcile can retry.
      _initialized = false;
      _debugLog('initialize failed (${_errorCategory(e)})');
      rethrow;
    } finally {
      _initializing = null;
    }
  }

  /// Performs the actual plugin initialization and Android channel creation.
  /// Overridable so init retry-safety can be tested without platform channels.
  @visibleForTesting
  Future<void> performPluginInitialization() async {
    const androidSettings = AndroidInitializationSettings(
      '@mipmap/ic_launcher',
    );
    const darwinSettings = DarwinInitializationSettings(
      requestAlertPermission: false,
      requestBadgePermission: false,
      requestSoundPermission: false,
    );
    const settings = InitializationSettings(
      android: androidSettings,
      iOS: darwinSettings,
    );
    await _plugin.initialize(settings);

    await _plugin
        .resolvePlatformSpecificImplementation<
          AndroidFlutterLocalNotificationsPlugin
        >()
        ?.createNotificationChannel(
          const AndroidNotificationChannel(
            _channelId,
            _channelName,
            description: _channelDescription,
            importance: Importance.defaultImportance,
          ),
        );
  }

  /// Whether initialization has completed successfully (test observability).
  @visibleForTesting
  bool get debugInitialized => _initialized;

  /// Ensures initialization, returning whether the service is usable. Never
  /// throws, so callers (and app startup) are not crashed by a plugin failure.
  @visibleForTesting
  Future<bool> ensureInitialized() async {
    try {
      await initialize();
      return _initialized;
    } catch (_) {
      return false;
    }
  }

  // ── Permissions ───────────────────────────────────────────────────────────

  Future<bool> requestPermissionIfNeeded() async {
    var granted = false;

    final androidImpl = _plugin
        .resolvePlatformSpecificImplementation<
          AndroidFlutterLocalNotificationsPlugin
        >();
    if (androidImpl != null) {
      granted = await androidImpl.requestNotificationsPermission() ?? false;
    }

    final iosImpl = _plugin
        .resolvePlatformSpecificImplementation<
          IOSFlutterLocalNotificationsPlugin
        >();
    if (iosImpl != null) {
      granted =
          await iosImpl.requestPermissions(
            alert: true,
            badge: true,
            sound: true,
          ) ??
          false;
    }

    return granted;
  }

  // ── Reconciliation ────────────────────────────────────────────────────────

  /// Reconciles scheduled calendar reminders against [events].
  ///
  /// Never uses a global `cancelAll()`; only calendar reminder IDs recorded in
  /// the persisted manifest are cancelled. Candidates are classified against
  /// the previous manifest by ID *and* schedule fingerprint:
  ///   * **unchanged** — same ID, same fingerprint: left untouched;
  ///   * **changed** — same ID, different/missing fingerprint: re-scheduled,
  ///     which replaces the platform notification in place (so a title-only
  ///     edit refreshes the notification body without changing its ID);
  ///   * **new** — ID not previously owned: scheduled;
  ///   * **stale** — previously owned, no longer desired: cancelled individually.
  ///
  /// Operation order:
  ///   1. Load and validate the existing manifest (bail conservatively if it is
  ///      corrupt — ownership is unknown, so nothing is scheduled or cancelled).
  ///   2. Build the desired entries (with fingerprints), scoped to [ownerKey].
  ///   3. Schedule new and changed entries.
  ///   4. Cancel stale entries individually (including entries owned by another
  ///      account, which are never treated as unchanged for [ownerKey]).
  ///   5. Persist a manifest reflecting what is actually scheduled — a
  ///      notification that failed to schedule is never recorded as scheduled.
  ///      If persistence fails, roll back newly-scheduled IDs (see
  ///      [_rollbackAfterSaveFailure]) so nothing becomes untracked.
  ///
  /// [ownerKey] is the privacy-safe key of the signed-in account these reminders
  /// belong to. Entries whose owner does not match are targeted for cleanup and
  /// re-scheduled under the current owner, so a shared device never interprets
  /// one account's reminders as another's. A `null` [ownerKey] is the
  /// account-agnostic path (legacy data and account-independent tests).
  Future<CalendarReconciliationResult> reconcileCalendarReminders(
    List<ClientEvent> events, {
    DateTime? now,
    String? ownerKey,
  }) async {
    final at = now ?? DateTime.now();

    final candidates = buildNotificationCandidates(
      events,
      now: at,
      maxCandidates: _maxScheduled,
      ownerKey: ownerKey,
    );

    final prefs = preferences;
    final loadResult = await prefs.loadCalendarReminderManifestResult();
    if (loadResult.isCorrupt) {
      // Ownership is unknown. Do not schedule or cancel anything, and do not
      // overwrite the stored value — report corruption so the caller can retry
      // or diagnose. Never a global cancel.
      _debugLog('reconcile skipped: manifest corrupt');
      return CalendarReconciliationResult(
        eventsFetched: events.length,
        eligibleCandidates: candidates.length,
        scheduledCount: 0,
        updatedCount: 0,
        cancelledCount: 0,
        unchangedCount: 0,
        failedCount: 0,
        manifestPersisted: false,
        manifestCorrupt: true,
        completedAt: at,
      );
    }
    final previous = loadResult.manifest;
    final previousById = <int, CalendarReminderManifestEntry>{
      for (final entry in previous.entries) entry.notificationId: entry,
    };

    final initialized = await ensureInitialized();
    if (!initialized) {
      // Preserve the existing manifest/schedule; report the failure instead of
      // wiping reminders we cannot currently manage.
      _debugLog('reconcile skipped: notifications not initialized');
      return CalendarReconciliationResult(
        eventsFetched: events.length,
        eligibleCandidates: candidates.length,
        scheduledCount: 0,
        updatedCount: 0,
        cancelledCount: 0,
        unchangedCount: previous.entries.length,
        failedCount: candidates.length,
        // The existing manifest is intact and still valid — nothing was written.
        manifestPersisted: true,
        completedAt: at,
      );
    }

    // Desired schedules keyed by notification ID, with their fingerprints.
    final desiredById = <int, CalendarNotificationCandidate>{
      for (final c in candidates) c.notificationId: c,
    };
    final desiredFingerprint = <int, String>{
      for (final e in desiredById.entries) e.key: scheduleFingerprint(e.value),
    };

    final desiredIds = desiredById.keys.toSet();

    // Classify every previously-owned ID and every desired ID, treating owner
    // mismatch as "not the current account's" so a foreign or legacy entry is
    // never classified as unchanged. Owner-scoped IDs make a cross-account
    // collision astronomically unlikely, but the owner check makes it explicit.
    final staleIds = <int>{};
    final newIds = <int>{};
    final changedIds = <int>{};
    final unchangedIds = <int>{};

    for (final id in previousById.keys) {
      if (!desiredIds.contains(id)) staleIds.add(id);
    }
    for (final id in desiredIds) {
      final prev = previousById[id];
      if (prev == null || prev.ownerKey != ownerKey) {
        // Not owned by the current account (new, foreign, or legacy) — schedule
        // fresh under the current owner. A same-ID foreign entry is re-scheduled
        // in place (which replaces the platform notification), so it is not also
        // added to [staleIds].
        if (prev == null) {
          newIds.add(id);
        } else {
          changedIds.add(id);
        }
      } else {
        final prevFp = prev.fingerprint;
        if (prevFp != null && prevFp == desiredFingerprint[id]) {
          unchangedIds.add(id);
        } else {
          changedIds.add(id);
        }
      }
    }

    // Entries believed to be on the device after this pass, each carrying the
    // fingerprint of the content actually scheduled for that ID and the current
    // owner key.
    final keptEntries = <int, CalendarReminderManifestEntry>{};
    for (final id in unchangedIds) {
      keptEntries[id] = CalendarReminderManifestEntry(
        notificationId: id,
        fingerprint: desiredFingerprint[id],
        ownerKey: ownerKey,
      );
    }

    var scheduled = 0;
    var updated = 0;
    var cancelled = 0;
    var failed = 0;

    // Newly-scheduled IDs not previously owned — the exact set to roll back if
    // the final manifest write fails.
    final newlyScheduledIds = <int>{};

    // 3a. Schedule newly-desired reminders.
    for (final id in newIds) {
      final ok = await scheduleReminder(desiredById[id]!);
      if (ok) {
        scheduled++;
        newlyScheduledIds.add(id);
        keptEntries[id] = CalendarReminderManifestEntry(
          notificationId: id,
          fingerprint: desiredFingerprint[id],
          ownerKey: ownerKey,
        );
      } else {
        failed++;
      }
    }

    // 3b. Re-schedule changed reminders. Scheduling the same ID replaces the
    //     platform notification, so no separate cancel is needed.
    for (final id in changedIds) {
      final ok = await scheduleReminder(desiredById[id]!);
      if (ok) {
        updated++;
        keptEntries[id] = CalendarReminderManifestEntry(
          notificationId: id,
          fingerprint: desiredFingerprint[id],
          ownerKey: ownerKey,
        );
      } else {
        // Replacement failed: the previous notification is still on the device
        // and still owned. Keep the PREVIOUS entry (fingerprint and owner) so it
        // is retried next pass.
        failed++;
        keptEntries[id] = previousById[id]!;
      }
    }

    // 4. Cancel only stale calendar reminder IDs, individually.
    for (final id in staleIds) {
      try {
        await cancelNotification(id);
        cancelled++;
      } catch (e) {
        // Cancel failed — the notification is likely still scheduled, so keep
        // it in the manifest to retry cancelling it next time.
        failed++;
        keptEntries[id] = previousById[id]!;
        _debugLog('cancel failed for id=$id (${_errorCategory(e)})');
      }
    }

    // 5. Persist the manifest reflecting the actual scheduled state (kept
    //    entries), never claiming a failed schedule succeeded.
    final finalManifest = CalendarReminderManifest(
      version: CalendarReminderManifest.currentVersion,
      entries: _sortedEntries(keptEntries.values),
      lastReconciledAt: at,
    );

    var manifestPersisted = true;
    CalendarReminderRollbackResult? rollback;
    try {
      await prefs.saveCalendarReminderManifest(finalManifest);
    } catch (e) {
      manifestPersisted = false;
      _debugLog('manifest persist failed (${_errorCategory(e)})');
      rollback = await _rollbackAfterSaveFailure(
        prefs: prefs,
        previous: previous,
        newlyScheduledIds: newlyScheduledIds,
        desiredFingerprint: desiredFingerprint,
        ownerKey: ownerKey,
      );
    }

    final result = CalendarReconciliationResult(
      eventsFetched: events.length,
      eligibleCandidates: candidates.length,
      scheduledCount: scheduled,
      updatedCount: updated,
      cancelledCount: cancelled,
      unchangedCount: unchangedIds.length,
      failedCount: failed,
      manifestPersisted: manifestPersisted,
      rollback: rollback,
      completedAt: at,
    );
    _debugLog('reconcile complete: $result');
    return result;
  }

  /// Recovers from a failed final manifest write, returning a structured
  /// [CalendarReminderRollbackResult] describing how completely it recovered.
  ///
  /// Because the write failed, the previous manifest is still on disk untouched
  /// — previously-owned changed and stale IDs remain tracked and retryable. The
  /// only IDs now on the device but *not* owned by that manifest are the
  /// newly-scheduled ones, so those are cancelled (rolled back). If a rollback
  /// cancel also fails, that ID is genuinely still scheduled and untracked, so
  /// a single recovery manifest write (previous entries plus the still-owned
  /// IDs) is attempted rather than silently discarding the condition.
  Future<CalendarReminderRollbackResult> _rollbackAfterSaveFailure({
    required CaleePreferences prefs,
    required CalendarReminderManifest previous,
    required Set<int> newlyScheduledIds,
    required Map<int, String> desiredFingerprint,
    required String? ownerKey,
  }) async {
    if (newlyScheduledIds.isEmpty) {
      return const CalendarReminderRollbackResult();
    }

    var rolledBack = 0;
    final failedRollback = <int>[];
    for (final id in newlyScheduledIds) {
      try {
        await cancelNotification(id);
        rolledBack++;
      } catch (e) {
        failedRollback.add(id);
        _debugLog('rollback cancel failed for id=$id (${_errorCategory(e)})');
      }
    }
    if (failedRollback.isEmpty) {
      return CalendarReminderRollbackResult(rollbackCancelledCount: rolledBack);
    }

    // Some newly-scheduled IDs are still on the device but untracked. Attempt
    // ONE recovery write re-establishing tracking: previous entries plus the
    // still-scheduled IDs.
    final recoveryById = <int, CalendarReminderManifestEntry>{
      for (final entry in previous.entries) entry.notificationId: entry,
    };
    for (final id in failedRollback) {
      recoveryById[id] = CalendarReminderManifestEntry(
        notificationId: id,
        fingerprint: desiredFingerprint[id],
        ownerKey: ownerKey,
      );
    }
    var recoveryPersisted = false;
    try {
      await prefs.saveCalendarReminderManifest(
        CalendarReminderManifest(
          version: CalendarReminderManifest.currentVersion,
          entries: _sortedEntries(recoveryById.values),
          lastReconciledAt: previous.lastReconciledAt,
        ),
      );
      recoveryPersisted = true;
    } catch (e) {
      _debugLog('recovery manifest write failed (${_errorCategory(e)})');
    }
    return CalendarReminderRollbackResult(
      rollbackCancelledCount: rolledBack,
      rollbackFailedCount: failedRollback.length,
      recoveryWriteAttempted: true,
      recoveryManifestPersisted: recoveryPersisted,
    );
  }

  /// Targeted cleanup of the calendar reminders this app scheduled.
  ///
  /// Only IDs the calendar reminder manifest owns are cancelled — notifications
  /// from other Calee features are left untouched, and `cancelAll()` is never
  /// used. Retry-safe: an ID whose cancellation fails is retained in the
  /// manifest so a later call can retry it, and the manifest is only cleared
  /// when every owned ID was cancelled. Storage failures are reported, never
  /// swallowed.
  Future<CalendarReminderDisableResult> disableCalendarReminders() async {
    final prefs = preferences;
    final loadResult = await prefs.loadCalendarReminderManifestResult();
    if (loadResult.isCorrupt) {
      // Ownership is unknown, so we cannot safely target IDs and must never fall
      // back to a global cancel. Leave the stored value intact and report the
      // cleanup as not complete so it is retried once the manifest is readable.
      _debugLog('disable skipped: manifest corrupt');
      return const CalendarReminderDisableResult(
        cancelledCount: 0,
        failedCount: 0,
        manifestPersisted: false,
      );
    }
    final manifest = loadResult.manifest;

    var cancelled = 0;
    final retained = <CalendarReminderManifestEntry>[];
    for (final entry in manifest.entries) {
      try {
        await cancelNotification(entry.notificationId);
        cancelled++;
      } catch (e) {
        retained.add(entry);
        _debugLog(
          'disable cancel failed for id=${entry.notificationId} '
          '(${_errorCategory(e)})',
        );
      }
    }

    var manifestPersisted = true;
    try {
      if (retained.isEmpty) {
        await prefs.clearCalendarReminderManifest();
      } else {
        // Retain exactly the IDs still owned (cancellation failed) for retry.
        await prefs.saveCalendarReminderManifest(
          CalendarReminderManifest(
            version: CalendarReminderManifest.currentVersion,
            entries: _sortedEntries(retained),
            lastReconciledAt: manifest.lastReconciledAt,
          ),
        );
      }
    } catch (e) {
      manifestPersisted = false;
      _debugLog('disable manifest persist failed (${_errorCategory(e)})');
    }

    final result = CalendarReminderDisableResult(
      cancelledCount: cancelled,
      failedCount: retained.length,
      manifestPersisted: manifestPersisted,
    );
    _debugLog('disable complete: $result');
    return result;
  }

  // ── Low-level plugin operations (overridable in tests) ────────────────────

  /// Cancels a single scheduled notification by ID. Overridable so reconcile
  /// tests can observe cancellations without the platform plugin.
  @visibleForTesting
  Future<void> cancelNotification(int id) => _plugin.cancel(id);

  /// Schedules a single reminder. Returns true on success. Overridable so
  /// reconcile tests can simulate scheduling success/failure without the
  /// platform plugin.
  @visibleForTesting
  Future<bool> scheduleReminder(CalendarNotificationCandidate c) async {
    const details = NotificationDetails(
      android: AndroidNotificationDetails(
        _channelId,
        _channelName,
        channelDescription: _channelDescription,
        importance: Importance.defaultImportance,
        priority: Priority.defaultPriority,
      ),
      iOS: DarwinNotificationDetails(),
    );

    final event = c.event;
    final payload = jsonEncode({
      'type': 'calendar_event_reminder',
      'eventId': event.id,
      if (event.occurrenceId != null) 'occurrenceId': event.occurrenceId,
      'calendarId': event.calendarId,
      'startsAt': event.startsAt,
    });

    try {
      await _plugin.zonedSchedule(
        c.notificationId,
        'Upcoming event',
        '${event.title} starts at ${_formatTime(c.startLocal)}',
        tz.TZDateTime.from(c.reminderTime, tz.local),
        details,
        uiLocalNotificationDateInterpretation:
            UILocalNotificationDateInterpretation.absoluteTime,
        androidScheduleMode: AndroidScheduleMode.inexactAllowWhileIdle,
        payload: payload,
      );
      return true;
    } catch (e) {
      // Surface the failure (ID + sanitised category only) rather than
      // silently swallowing it, but never crash scheduling.
      _debugLog(
        'schedule failed for id=${c.notificationId} (${_errorCategory(e)})',
      );
      return false;
    }
  }

  // ── Helpers ───────────────────────────────────────────────────────────────

  static List<CalendarReminderManifestEntry> _sortedEntries(
    Iterable<CalendarReminderManifestEntry> entries,
  ) =>
      entries.toList()
        ..sort((a, b) => a.notificationId.compareTo(b.notificationId));

  String _formatTime(DateTime dt) {
    final hour = dt.hour;
    final minute = dt.minute;
    final period = hour < 12 ? 'AM' : 'PM';
    final h12 = hour == 0 ? 12 : (hour > 12 ? hour - 12 : hour);
    final mm = minute.toString().padLeft(2, '0');
    return '$h12:$mm $period';
  }

  /// Returns a short, non-sensitive category for an error suitable for logs.
  /// Never includes event content, tokens, or URLs.
  String _errorCategory(Object error) => error.runtimeType.toString();

  void _debugLog(String message) {
    if (kDebugMode) debugPrint('[CalendarReminders] $message');
  }
}

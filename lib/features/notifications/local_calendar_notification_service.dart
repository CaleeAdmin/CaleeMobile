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
/// Deliberately holds only counts and a timestamp — never event titles,
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
  });

  final int eventsFetched;
  final int eligibleCandidates;
  final int scheduledCount;
  final int cancelledCount;
  final int unchangedCount;
  final int failedCount;
  final DateTime completedAt;

  bool get hasFailures => failedCount > 0;

  @override
  String toString() =>
      'CalendarReconciliationResult(events: $eventsFetched, '
      'eligible: $eligibleCandidates, scheduled: $scheduledCount, '
      'cancelled: $cancelledCount, unchanged: $unchangedCount, '
      'failed: $failedCount)';
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
  /// the persisted manifest are cancelled. Steps:
  ///   1. Build the eligible candidate set (sorted, capped at [_maxScheduled]).
  ///   2. Read previously scheduled calendar reminder IDs from the manifest.
  ///   3. Cancel only stale IDs (previously scheduled, no longer desired).
  ///   4. Schedule newly-desired IDs.
  ///   5. Persist a manifest reflecting what is actually scheduled — a
  ///      notification that failed to schedule is never recorded as scheduled.
  Future<CalendarReconciliationResult> reconcileCalendarReminders(
    List<ClientEvent> events, {
    DateTime? now,
  }) async {
    final at = now ?? DateTime.now();

    final candidates = buildNotificationCandidates(
      events,
      now: at,
      maxCandidates: _maxScheduled,
    );

    final prefs = preferences;
    final previous = await prefs.loadCalendarReminderManifest();
    final previousIds = previous.scheduledIds.toSet();

    final initialized = await ensureInitialized();
    if (!initialized) {
      // Preserve the existing manifest/schedule; report the failure instead of
      // wiping reminders we cannot currently manage.
      _debugLog('reconcile skipped: notifications not initialized');
      return CalendarReconciliationResult(
        eventsFetched: events.length,
        eligibleCandidates: candidates.length,
        scheduledCount: 0,
        cancelledCount: 0,
        unchangedCount: previousIds.length,
        failedCount: candidates.length,
        completedAt: at,
      );
    }

    final desiredById = <int, CalendarNotificationCandidate>{
      for (final c in candidates) c.notificationId: c,
    };
    final desiredIds = desiredById.keys.toSet();

    final staleIds = previousIds.difference(desiredIds);
    final newIds = desiredIds.difference(previousIds);
    final unchangedIds = desiredIds.intersection(previousIds);

    // IDs we believe are scheduled on the device after this pass.
    final keptIds = <int>{...unchangedIds};
    var cancelled = 0;
    var scheduled = 0;
    var failed = 0;

    // Cancel only stale calendar reminder IDs, individually.
    for (final id in staleIds) {
      try {
        await cancelNotification(id);
        cancelled++;
      } catch (e) {
        // Cancel failed — the notification is likely still scheduled, so keep
        // it in the manifest to retry cancelling it next time.
        failed++;
        keptIds.add(id);
        _debugLog('cancel failed for id=$id (${_errorCategory(e)})');
      }
    }

    // Schedule newly-desired reminders.
    for (final id in newIds) {
      final candidate = desiredById[id]!;
      final ok = await scheduleReminder(candidate);
      if (ok) {
        scheduled++;
        keptIds.add(id);
      } else {
        failed++;
      }
    }

    // Persist the manifest only after reconciliation, reflecting the actual
    // scheduled state (kept IDs), never claiming a failed schedule succeeded.
    await prefs.saveCalendarReminderManifest(
      CalendarReminderManifest(
        version: CalendarReminderManifest.currentVersion,
        scheduledIds: keptIds.toList()..sort(),
        lastReconciledAt: at,
      ),
    );

    final result = CalendarReconciliationResult(
      eventsFetched: events.length,
      eligibleCandidates: candidates.length,
      scheduledCount: scheduled,
      cancelledCount: cancelled,
      unchangedCount: unchangedIds.length,
      failedCount: failed,
      completedAt: at,
    );
    _debugLog('reconcile complete: $result');
    return result;
  }

  /// Cancels every calendar reminder this app scheduled and clears the
  /// manifest. Only IDs the calendar reminder manifest owns are cancelled —
  /// notifications from other Calee features are left untouched.
  Future<void> disableCalendarReminders() async {
    final prefs = preferences;
    final manifest = await prefs.loadCalendarReminderManifest();
    for (final id in manifest.scheduledIds) {
      try {
        await cancelNotification(id);
      } catch (e) {
        _debugLog('disable cancel failed for id=$id (${_errorCategory(e)})');
      }
    }
    await prefs.clearCalendarReminderManifest();
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

// ignore_for_file: prefer_initializing_formals
import 'package:flutter/foundation.dart';

import '../../data/api/calee_hub_client.dart';
import '../../data/auth/calee_preferences.dart';
import '../../data/models/client_calendar.dart';
import 'local_calendar_notification_service.dart';

/// Why a reminder refresh was requested. Reasons are explicit rather than
/// unrelated booleans, and they decide whether a refresh may be throttled
/// (routine lifecycle events) or must force reconciliation (explicit changes).
enum CalendarReminderRefreshReason {
  /// A signed-in session was restored on launch.
  sessionRestored,

  /// The app returned to the foreground after being backgrounded.
  appResumed,

  /// The user just enabled calendar reminders.
  remindersEnabled,

  /// A user-initiated calendar refresh succeeded.
  manualRefresh,

  /// An event was successfully created.
  eventCreated,

  /// An event was successfully updated.
  eventUpdated,

  /// An event was successfully deleted.
  eventDeleted,

  /// A calendar connection/subscription changed.
  calendarConnectionChanged,
}

extension CalendarReminderRefreshReasonBehaviour
    on CalendarReminderRefreshReason {
  /// Explicit state changes must reconcile immediately and bypass throttling;
  /// routine lifecycle refreshes may be throttled.
  bool get forcesReconciliation {
    switch (this) {
      case CalendarReminderRefreshReason.remindersEnabled:
      case CalendarReminderRefreshReason.eventCreated:
      case CalendarReminderRefreshReason.eventUpdated:
      case CalendarReminderRefreshReason.eventDeleted:
      case CalendarReminderRefreshReason.calendarConnectionChanged:
        return true;
      case CalendarReminderRefreshReason.sessionRestored:
      case CalendarReminderRefreshReason.appResumed:
      case CalendarReminderRefreshReason.manualRefresh:
        return false;
    }
  }
}

/// The outcome of a [CalendarReminderCoordinator.refresh] call.
enum CalendarReminderRefreshStatus {
  /// Events were fetched and reconciliation ran (inspect [reconciliation] for
  /// per-notification detail, including any scheduling failures).
  reconciled,

  /// No access token — signed out. Nothing was fetched or changed.
  skippedSignedOut,

  /// Calendar reminders are disabled. Nothing was fetched or changed.
  skippedDisabled,

  /// A routine refresh was throttled. Nothing was fetched or changed.
  skippedThrottled,

  /// Notification permission is not granted. The stored preference was flipped
  /// back off; nothing was scheduled.
  permissionDenied,

  /// The upcoming-event fetch failed. Existing reminders are preserved and the
  /// manifest is left intact.
  fetchFailed,
}

/// Structured, log-safe result of a reminder refresh.
class CalendarReminderRefreshResult {
  const CalendarReminderRefreshResult({
    required this.reason,
    required this.status,
    required this.completedAt,
    this.reconciliation,
    this.errorCategory,
  });

  final CalendarReminderRefreshReason reason;
  final CalendarReminderRefreshStatus status;
  final DateTime completedAt;

  /// Present only when [status] is
  /// [CalendarReminderRefreshStatus.reconciled].
  final CalendarReconciliationResult? reconciliation;

  /// Short, non-sensitive error category when [status] is
  /// [CalendarReminderRefreshStatus.fetchFailed].
  final String? errorCategory;

  bool get didReconcile => status == CalendarReminderRefreshStatus.reconciled;

  bool get didFetchFail => status == CalendarReminderRefreshStatus.fetchFailed;

  @override
  String toString() =>
      'CalendarReminderRefreshResult(reason: ${reason.name}, '
      'status: ${status.name}'
      '${reconciliation != null ? ', $reconciliation' : ''}'
      '${errorCategory != null ? ', error: $errorCategory' : ''})';
}

/// Application-level coordinator that keeps device calendar reminders in sync
/// with an independent upcoming-event window — deliberately decoupled from the
/// calendar month currently on screen.
///
/// Responsibilities:
/// * fetch events for [horizon] starting at the current local day using the
///   existing authenticated [CaleeHubClient];
/// * hand the fetched events to [LocalCalendarNotificationService] for
///   manifest-based reconciliation;
/// * prevent overlapping refreshes with a single-flight guard;
/// * throttle routine lifecycle refreshes while letting explicit changes force
///   reconciliation;
/// * return a structured, log-safe [CalendarReminderRefreshResult].
class CalendarReminderCoordinator {
  CalendarReminderCoordinator({
    required CaleeHubClient hubClient,
    LocalCalendarNotificationService? notificationService,
    CaleePreferences? preferences,
    DateTime Function()? now,
    Duration throttle = const Duration(minutes: 5),
    Duration horizon = const Duration(days: 30),
  }) : _hubClient = hubClient,
       _notificationService =
           notificationService ?? LocalCalendarNotificationService.instance,
       _preferences = preferences ?? CaleePreferences(),
       _now = now ?? DateTime.now,
       _throttle = throttle,
       _horizon = horizon;

  final CaleeHubClient _hubClient;
  final LocalCalendarNotificationService _notificationService;
  final CaleePreferences _preferences;
  final DateTime Function() _now;
  final Duration _throttle;
  final Duration _horizon;

  Future<CalendarReminderRefreshResult>? _inFlight;
  DateTime? _lastRefreshAt;

  /// Whether a refresh is currently running (exposed for tests).
  @visibleForTesting
  bool get isRefreshing => _inFlight != null;

  /// Refreshes upcoming reminders.
  ///
  /// [accessToken] is passed per call so the coordinator never runs signed
  /// out. Concurrent calls share one in-flight refresh. Routine reasons are
  /// throttled; explicit reasons (or [force]) reconcile immediately.
  Future<CalendarReminderRefreshResult> refresh({
    required String? accessToken,
    required CalendarReminderRefreshReason reason,
    bool force = false,
  }) {
    final token = accessToken;
    if (token == null || token.isEmpty) {
      return Future<CalendarReminderRefreshResult>.value(
        _skipped(reason, CalendarReminderRefreshStatus.skippedSignedOut),
      );
    }

    // Single-flight: join any refresh already running.
    final existing = _inFlight;
    if (existing != null) return existing;

    final startedAt = _now();
    final explicit = force || reason.forcesReconciliation;
    if (!explicit && _isThrottled(startedAt)) {
      return Future<CalendarReminderRefreshResult>.value(
        _skipped(reason, CalendarReminderRefreshStatus.skippedThrottled),
      );
    }

    final future = _runGuarded(
      accessToken: token,
      reason: reason,
      startedAt: startedAt,
    );
    _inFlight = future;
    return future;
  }

  bool _isThrottled(DateTime now) {
    final last = _lastRefreshAt;
    return last != null && now.difference(last) < _throttle;
  }

  Future<CalendarReminderRefreshResult> _runGuarded({
    required String accessToken,
    required CalendarReminderRefreshReason reason,
    required DateTime startedAt,
  }) async {
    try {
      return await _run(
        accessToken: accessToken,
        reason: reason,
        startedAt: startedAt,
      );
    } finally {
      _inFlight = null;
    }
  }

  Future<CalendarReminderRefreshResult> _run({
    required String accessToken,
    required CalendarReminderRefreshReason reason,
    required DateTime startedAt,
  }) async {
    final enabled = await _preferences.loadCalendarRemindersEnabled();
    if (!enabled) {
      _log(reason, CalendarReminderRefreshStatus.skippedDisabled);
      return _skipped(reason, CalendarReminderRefreshStatus.skippedDisabled);
    }

    final granted = await _notificationService.requestPermissionIfNeeded();
    if (!granted) {
      // Keep the stored preference honest so Settings does not keep showing a
      // switch that is silently doing nothing.
      await _preferences.saveCalendarRemindersEnabled(false);
      _log(reason, CalendarReminderRefreshStatus.permissionDenied);
      return _skipped(reason, CalendarReminderRefreshStatus.permissionDenied);
    }

    // Mark the routine-throttle clock now that a real attempt is under way.
    _lastRefreshAt = startedAt;

    final startOfDay = DateTime(startedAt.year, startedAt.month, startedAt.day);
    final end = startOfDay.add(_horizon);

    final List<ClientEvent> events;
    try {
      final list = await _hubClient.events(
        accessToken: accessToken,
        from: _formatDate(startOfDay),
        to: _formatDate(end),
      );
      events = list.events;
    } catch (e) {
      // Preserve existing scheduled reminders and the manifest — do not cancel
      // anything on a transient fetch failure.
      final category = _errorCategory(e);
      _log(reason, CalendarReminderRefreshStatus.fetchFailed, error: category);
      return CalendarReminderRefreshResult(
        reason: reason,
        status: CalendarReminderRefreshStatus.fetchFailed,
        completedAt: _now(),
        errorCategory: category,
      );
    }

    final reconciliation = await _notificationService
        .reconcileCalendarReminders(events, now: startedAt);

    final result = CalendarReminderRefreshResult(
      reason: reason,
      status: CalendarReminderRefreshStatus.reconciled,
      completedAt: _now(),
      reconciliation: reconciliation,
    );
    _log(reason, result.status, result: reconciliation);
    return result;
  }

  CalendarReminderRefreshResult _skipped(
    CalendarReminderRefreshReason reason,
    CalendarReminderRefreshStatus status,
  ) => CalendarReminderRefreshResult(
    reason: reason,
    status: status,
    completedAt: _now(),
  );

  // ── Helpers ───────────────────────────────────────────────────────────────

  static String _formatDate(DateTime value) {
    final local = value.toLocal();
    final year = local.year.toString().padLeft(4, '0');
    final month = local.month.toString().padLeft(2, '0');
    final day = local.day.toString().padLeft(2, '0');
    return '$year-$month-$day';
  }

  /// Short, non-sensitive category for logs. For Hub errors this is the status
  /// code/error code; otherwise the runtime type. Never a URL, token, message,
  /// or event content.
  String _errorCategory(Object error) {
    if (error is CaleeHubException) {
      return 'hub_${error.statusCode}${error.code != null ? '_${error.code}' : ''}';
    }
    return error.runtimeType.toString();
  }

  void _log(
    CalendarReminderRefreshReason reason,
    CalendarReminderRefreshStatus status, {
    CalendarReconciliationResult? result,
    String? error,
  }) {
    if (!kDebugMode) return;
    final buffer = StringBuffer(
      '[CalendarReminders] refresh reason=${reason.name} status=${status.name}',
    );
    if (result != null) buffer.write(' $result');
    if (error != null) buffer.write(' error=$error');
    debugPrint(buffer.toString());
  }
}

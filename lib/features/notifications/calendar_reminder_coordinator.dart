// ignore_for_file: prefer_initializing_formals
import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../data/api/calee_hub_client.dart';
import '../../data/auth/calee_preferences.dart';
import '../../data/models/client_calendar.dart';
import 'calendar_notification_candidates.dart';
import 'local_calendar_notification_service.dart';

/// The outcome of attempting to begin a reminder session.
enum CalendarReminderSessionStart {
  /// A session was begun for a non-empty stable account ID.
  started,

  /// No session was begun because the account ID was empty — e.g. signed in but
  /// the account bootstrap is not yet available. No owner key is derived from an
  /// empty string; a later [CalendarReminderCoordinator.beginSession] with a real
  /// account ID starts the session (the caller retries when bootstrap arrives).
  skippedEmptyAccount,
}

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

  /// Calendar reminders are disabled and there was nothing owned to clean up.
  /// Nothing was fetched or changed.
  skippedDisabled,

  /// Calendar reminders are disabled, but a previous cleanup had left owned IDs
  /// behind; a targeted cleanup retry ran and cancelled all of them.
  disabledCleanupCompleted,

  /// Calendar reminders are disabled and a targeted cleanup retry ran, but at
  /// least one owned ID could not be cancelled and remains tracked for retry.
  disabledCleanupPartial,

  /// A routine refresh was throttled. Nothing was fetched or changed.
  skippedThrottled,

  /// Notification permission is not granted. The stored preference was flipped
  /// back off and a targeted cleanup of owned reminders was attempted; nothing
  /// was scheduled.
  permissionDenied,

  /// The upcoming-event fetch failed. Existing reminders are preserved and the
  /// manifest is left intact.
  fetchFailed,

  /// The reminder session was invalidated (sign-out, or a newer session began)
  /// before this work could run or reconcile. Nothing was fetched, scheduled,
  /// or written — the result belongs to a session that is no longer current.
  skippedSessionInvalidated,

  /// Events were fetched but the stored manifest was corrupt, so ownership is
  /// unknown: nothing was scheduled or cancelled and the stored value was left
  /// intact for a later retry.
  manifestCorrupt,
}

/// Structured, log-safe result of a reminder refresh.
class CalendarReminderRefreshResult {
  const CalendarReminderRefreshResult({
    required this.reason,
    required this.status,
    required this.completedAt,
    this.reconciliation,
    this.cleanup,
    this.errorCategory,
  });

  final CalendarReminderRefreshReason reason;
  final CalendarReminderRefreshStatus status;
  final DateTime completedAt;

  /// Present only when [status] is
  /// [CalendarReminderRefreshStatus.reconciled].
  final CalendarReconciliationResult? reconciliation;

  /// Present when a targeted cleanup ran — i.e. [status] is
  /// [CalendarReminderRefreshStatus.disabledCleanupCompleted],
  /// [CalendarReminderRefreshStatus.disabledCleanupPartial], or
  /// [CalendarReminderRefreshStatus.permissionDenied].
  final CalendarReminderDisableResult? cleanup;

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
      '${cleanup != null ? ', $cleanup' : ''}'
      '${errorCategory != null ? ', error: $errorCategory' : ''})';
}

/// A single forced refresh queued to run immediately after the in-flight
/// refresh finishes. At most one is ever pending: additional forced requests
/// coalesce into it (adopting the latest token and reason), so an in-flight
/// refresh can never lose an explicit state change and the queue is bounded.
class _PendingForcedRefresh {
  _PendingForcedRefresh({
    required this.accessToken,
    required this.reason,
    required this.generation,
  }) : completer = Completer<CalendarReminderRefreshResult>();

  /// The latest valid access token to use for the follow-up.
  String accessToken;

  /// The latest forced reason — preserved for diagnostics.
  CalendarReminderRefreshReason reason;

  /// The session generation this follow-up belongs to. If the session changes
  /// before the follow-up runs, it must not start (stale token/account).
  final int generation;

  /// Completed with the follow-up's result (success or error).
  final Completer<CalendarReminderRefreshResult> completer;
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
/// * prevent overlapping refreshes with a single-flight guard, while queueing
///   one forced follow-up so explicit state changes are never lost;
/// * throttle routine lifecycle refreshes while letting explicit changes force
///   reconciliation;
/// * when reminders are disabled or permission is denied, run targeted cleanup
///   (never fetching, never a global cancel) so owned reminders don't linger;
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
  _PendingForcedRefresh? _pendingForced;
  DateTime? _lastRefreshAt;

  // Monotonic reminder-session generation. Every [beginSession]/[endSession]
  // increments it. Async work captures the generation it started under and must
  // re-check before reconciling or writing, so an old session never schedules,
  // cancels, or writes the manifest after a new one begins.
  int _sessionGeneration = 0;

  // Privacy-safe key of the account owning the current reminder session, or
  // null while signed out. Folded into notification IDs and fingerprints so a
  // shared device keeps accounts' reminders isolated. Retained internally so
  // cleanup can run after [SessionController] has cleared its bootstrap/tokens.
  String? _ownerKey;

  /// Whether a refresh is currently running (exposed for tests).
  @visibleForTesting
  bool get isRefreshing => _inFlight != null;

  /// Whether a forced follow-up is queued behind the in-flight refresh
  /// (exposed for tests).
  @visibleForTesting
  bool get hasPendingForcedRefresh => _pendingForced != null;

  /// The current reminder-session generation (exposed for tests).
  @visibleForTesting
  int get sessionGeneration => _sessionGeneration;

  // ── Session lifecycle ─────────────────────────────────────────────────────

  /// Begins a reminder session for [accountId].
  ///
  /// A reminder session REQUIRES a non-empty stable account ID: an empty ID
  /// (e.g. signed in but the account bootstrap is not yet available) never begins
  /// a session and never derives an owner key from an empty string. In that case
  /// nothing changes (the previous session, if any, is left intact) and
  /// [CalendarReminderSessionStart.skippedEmptyAccount] is returned so the caller
  /// can retry once bootstrap becomes available.
  ///
  /// Otherwise records a privacy-safe cryptographic owner key derived from the
  /// account ID (never the raw ID) and opens a new session generation,
  /// invalidating any in-flight or queued work from a previous session so it can
  /// neither reconcile nor write the manifest.
  CalendarReminderSessionStart beginSession({required String accountId}) {
    if (accountId.isEmpty) {
      return CalendarReminderSessionStart.skippedEmptyAccount;
    }
    _invalidatePendingForced();
    _sessionGeneration++;
    _ownerKey = reminderOwnerKey(accountId);
    _lastRefreshAt = null;
    return CalendarReminderSessionStart.started;
  }

  /// Ends the current reminder session (sign-out or unauthorized sign-out).
  ///
  /// Immediately invalidates all in-flight and queued reminder work (so an
  /// in-flight fetch cannot reconcile and a queued forced follow-up cannot
  /// start), then runs a targeted cleanup of all manifest-owned reminders —
  /// never fetching, never a global `cancelAll()`. IDs whose cancellation fails
  /// stay tracked, and a manifest-persistence failure is reported (not
  /// swallowed) so the retryable cleanup state is preserved. Sign-out itself is
  /// never blocked or failed by a cleanup failure: the outcome is returned for
  /// diagnostics only.
  Future<CalendarReminderDisableResult> endSession() async {
    _invalidatePendingForced();
    _sessionGeneration++;
    _ownerKey = null;
    _lastRefreshAt = null;
    final cleanup = await _notificationService.disableCalendarReminders();
    _logSignOutCleanup(cleanup);
    return cleanup;
  }

  /// Whether [generation] is still the current session generation.
  bool _isCurrentGeneration(int generation) => generation == _sessionGeneration;

  /// Drops any queued forced follow-up, completing its caller with an explicit
  /// [CalendarReminderRefreshStatus.skippedSessionInvalidated] result so no
  /// completer is ever left dangling across a session boundary.
  void _invalidatePendingForced() {
    final pending = _pendingForced;
    if (pending == null) return;
    _pendingForced = null;
    if (!pending.completer.isCompleted) {
      pending.completer.complete(
        _skipped(
          pending.reason,
          CalendarReminderRefreshStatus.skippedSessionInvalidated,
        ),
      );
    }
  }

  /// Refreshes upcoming reminders.
  ///
  /// [accessToken] is passed per call so the coordinator never runs signed
  /// out. Routine reasons join any in-flight refresh and are throttled;
  /// explicit reasons (or [force]) reconcile immediately, and if one arrives
  /// while a refresh is in flight it is queued as a single forced follow-up
  /// (coalescing additional forced requests) rather than being dropped.
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

    final generation = _sessionGeneration;
    final explicit = force || reason.forcesReconciliation;

    // A refresh is already running.
    final existing = _inFlight;
    if (existing != null) {
      if (!explicit) {
        // Routine request: join the in-flight refresh; start no new work. This
        // also covers a routine request arriving while a forced follow-up is
        // already queued — it must not add another refresh.
        return existing;
      }
      // Forced request: queue exactly one forced follow-up (coalescing).
      return _enqueueForcedFollowUp(token, reason, generation);
    }

    final startedAt = _now();
    if (!explicit && _isThrottled(startedAt)) {
      return Future<CalendarReminderRefreshResult>.value(
        _skipped(reason, CalendarReminderRefreshStatus.skippedThrottled),
      );
    }

    return _start(
      accessToken: token,
      reason: reason,
      startedAt: startedAt,
      generation: generation,
    );
  }

  /// Queues (or coalesces into) the single pending forced follow-up and returns
  /// the future that resolves to that follow-up's result.
  Future<CalendarReminderRefreshResult> _enqueueForcedFollowUp(
    String accessToken,
    CalendarReminderRefreshReason reason,
    int generation,
  ) {
    final pending = _pendingForced;
    if (pending != null && pending.generation == generation) {
      // Coalesce: keep one follow-up, adopt the latest token and reason.
      pending.accessToken = accessToken;
      pending.reason = reason;
      return pending.completer.future;
    }
    // No pending follow-up (or a stale-generation one that a session change
    // already invalidated): create a fresh one for this generation.
    _invalidatePendingForced();
    final created = _PendingForcedRefresh(
      accessToken: accessToken,
      reason: reason,
      generation: generation,
    );
    _pendingForced = created;
    return created.completer.future;
  }

  Future<CalendarReminderRefreshResult> _start({
    required String accessToken,
    required CalendarReminderRefreshReason reason,
    required DateTime startedAt,
    required int generation,
  }) {
    final future = _runGuarded(
      accessToken: accessToken,
      reason: reason,
      startedAt: startedAt,
      generation: generation,
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
    required int generation,
  }) async {
    try {
      return await _run(
        accessToken: accessToken,
        reason: reason,
        startedAt: startedAt,
        generation: generation,
      );
    } finally {
      // Clear the in-flight guard, then synchronously kick any queued forced
      // follow-up. There is no await between these, so no routine request can
      // slip in and start a duplicate refresh while the follow-up is pending.
      _inFlight = null;
      _startPendingForcedIfAny();
    }
  }

  /// Starts the queued forced follow-up, if one is pending. Runs synchronously
  /// (no await) so state transitions atomically from the just-finished refresh
  /// to the follow-up.
  void _startPendingForcedIfAny() {
    final pending = _pendingForced;
    if (pending == null) return;
    _pendingForced = null;

    // A session change since this follow-up was queued means it belongs to an
    // ended session — do not start it; complete its caller as invalidated.
    if (!_isCurrentGeneration(pending.generation)) {
      if (!pending.completer.isCompleted) {
        pending.completer.complete(
          _skipped(
            pending.reason,
            CalendarReminderRefreshStatus.skippedSessionInvalidated,
          ),
        );
      }
      return;
    }

    // Forced follow-ups bypass throttling by construction: they go straight to
    // a guarded run without an [_isThrottled] check.
    final future = _runGuarded(
      accessToken: pending.accessToken,
      reason: pending.reason,
      startedAt: _now(),
      generation: pending.generation,
    );
    _inFlight = future;
    // Resolve the queued callers with the follow-up's outcome. Always completes
    // (success or error), so a pending completer can never dangle.
    future.then(
      pending.completer.complete,
      onError: pending.completer.completeError,
    );
  }

  Future<CalendarReminderRefreshResult> _run({
    required String accessToken,
    required CalendarReminderRefreshReason reason,
    required DateTime startedAt,
    required int generation,
  }) async {
    // The session may have ended before this work even began running.
    if (!_isCurrentGeneration(generation)) {
      return _skipped(
        reason,
        CalendarReminderRefreshStatus.skippedSessionInvalidated,
      );
    }

    final enabled = await _preferences.loadCalendarRemindersEnabled();
    if (!enabled) {
      return _runDisabled(reason, generation);
    }

    final granted = await _notificationService.requestPermissionIfNeeded();
    if (!granted) {
      // The session may have ended while permission was being resolved. Do not
      // let an old session write (clear) the manifest after a new one began.
      if (!_isCurrentGeneration(generation)) {
        return _skipped(
          reason,
          CalendarReminderRefreshStatus.skippedSessionInvalidated,
        );
      }
      // Keep the stored preference honest so Settings does not keep showing a
      // switch that is silently doing nothing.
      await _preferences.saveCalendarRemindersEnabled(false);
      // Previously scheduled reminders would otherwise become unmanaged if the
      // user later re-grants permission via system settings. Cancel the ones we
      // own (targeted, never a global cancelAll) and keep any that fail for a
      // later retry. Do not fetch events.
      final cleanup = await _notificationService.disableCalendarReminders();
      _log(reason, CalendarReminderRefreshStatus.permissionDenied);
      return CalendarReminderRefreshResult(
        reason: reason,
        status: CalendarReminderRefreshStatus.permissionDenied,
        completedAt: _now(),
        cleanup: cleanup,
      );
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

    // The fetch may complete after the session ended (sign-out, or account B
    // began). Never reconcile or write the manifest for a stale session.
    if (!_isCurrentGeneration(generation)) {
      _log(reason, CalendarReminderRefreshStatus.skippedSessionInvalidated);
      return _skipped(
        reason,
        CalendarReminderRefreshStatus.skippedSessionInvalidated,
      );
    }

    final reconciliation = await _notificationService
        .reconcileCalendarReminders(
          events,
          now: startedAt,
          ownerKey: _ownerKey,
        );

    final status = reconciliation.manifestCorrupt
        ? CalendarReminderRefreshStatus.manifestCorrupt
        : CalendarReminderRefreshStatus.reconciled;
    final result = CalendarReminderRefreshResult(
      reason: reason,
      status: status,
      completedAt: _now(),
      reconciliation: reconciliation,
    );
    _log(reason, result.status, result: reconciliation);
    return result;
  }

  /// Handles a refresh while calendar reminders are disabled.
  ///
  /// Never fetches events or requests permission. If the manifest is already
  /// empty there is nothing to do. If a previous cleanup left owned IDs behind,
  /// the targeted disable/cleanup path is retried so cancellation can complete
  /// — without repeatedly doing work once the manifest is empty.
  Future<CalendarReminderRefreshResult> _runDisabled(
    CalendarReminderRefreshReason reason,
    int generation,
  ) async {
    final manifest = await _preferences.loadCalendarReminderManifest();
    if (manifest.scheduledIds.isEmpty) {
      _log(reason, CalendarReminderRefreshStatus.skippedDisabled);
      return _skipped(reason, CalendarReminderRefreshStatus.skippedDisabled);
    }

    // A new session may have begun while we were reading the manifest — an old
    // session must not clear/rewrite it after that.
    if (!_isCurrentGeneration(generation)) {
      return _skipped(
        reason,
        CalendarReminderRefreshStatus.skippedSessionInvalidated,
      );
    }

    final cleanup = await _notificationService.disableCalendarReminders();
    // A fully clean cleanup requires both every cancellation to succeed *and*
    // the manifest state to persist (cleared, or the retained IDs saved).
    final status = cleanup.isFullyClean
        ? CalendarReminderRefreshStatus.disabledCleanupCompleted
        : CalendarReminderRefreshStatus.disabledCleanupPartial;
    _log(reason, status);
    return CalendarReminderRefreshResult(
      reason: reason,
      status: status,
      completedAt: _now(),
      cleanup: cleanup,
    );
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

  /// Distinct diagnostic line for the sign-out cleanup path, so a partial
  /// sign-out cleanup is distinguishable in logs from a refresh cleanup.
  void _logSignOutCleanup(CalendarReminderDisableResult cleanup) {
    if (!kDebugMode) return;
    final outcome = cleanup.isFullyClean ? 'completed' : 'partial';
    debugPrint('[CalendarReminders] signOut cleanup status=$outcome $cleanup');
  }
}

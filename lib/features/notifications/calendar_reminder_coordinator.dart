// ignore_for_file: prefer_initializing_formals
import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../data/api/calee_hub_client.dart';
import '../../data/auth/calee_preferences.dart';
import '../../data/models/client_calendar.dart';
import 'calendar_notification_candidates.dart';
import 'local_calendar_notification_service.dart';

/// Outcome of an attempt to begin a reminder session.
enum CalendarReminderSessionStartStatus {
  /// A new session generation and owner key were created for a valid account.
  started,

  /// The account identity was missing, empty, or whitespace-only, so no owner
  /// was created and no active session was entered. Any currently-valid session
  /// is left untouched (a duplicate transient callback must not tear it down).
  skippedInvalidAccount,
}

/// Structured, log-safe result of [CalendarReminderCoordinator.beginSession].
class CalendarReminderSessionStartResult {
  const CalendarReminderSessionStartResult({
    required this.status,
    required this.generation,
  });

  final CalendarReminderSessionStartStatus status;

  /// The session generation after the call. For
  /// [CalendarReminderSessionStartStatus.started] this is the new generation;
  /// for [CalendarReminderSessionStartStatus.skippedInvalidAccount] it is the
  /// unchanged current generation.
  final int generation;

  bool get started => status == CalendarReminderSessionStartStatus.started;

  @override
  String toString() =>
      'CalendarReminderSessionStartResult(status: ${status.name}, '
      'generation: $generation)';
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

  /// There is no active account-owned reminder session (no owner key), so no
  /// reminder work may run — a non-empty access token is not sufficient on its
  /// own. Nothing was read, fetched, or changed: no preference read, no
  /// permission request, no event fetch, no reconciliation or cleanup. The
  /// initial refresh runs once the session listener begins a valid session.
  skippedNoActiveSession,

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
  /// before this work could run or reconcile, or partway through reconciliation.
  /// Nothing that this session scheduled or wrote survives — the result belongs
  /// to a session that is no longer current.
  skippedSessionInvalidated,

  /// The stored manifest was corrupt, so ownership is unknown: nothing was
  /// scheduled or cancelled and the stored value was left intact for a later
  /// retry.
  manifestCorrupt,

  /// The reminders-enabled preference could not be read — a SharedPreferences
  /// access failure, or a write required to complete the one-time migration
  /// failed — so the stored value is unknown. Nothing was fetched, no
  /// permission was requested, nothing was scheduled or cancelled, the manifest
  /// and stored preference were left untouched, and existing reminders are
  /// preserved. The read is retried on a later refresh.
  preferenceUnavailable,
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
    this.preferenceSaveFailed = false,
  });

  final CalendarReminderRefreshReason reason;
  final CalendarReminderRefreshStatus status;
  final DateTime completedAt;

  /// Present when reconciliation ran — i.e. [status] is
  /// [CalendarReminderRefreshStatus.reconciled] or
  /// [CalendarReminderRefreshStatus.manifestCorrupt], or a mid-pass
  /// invalidation was reported.
  final CalendarReconciliationResult? reconciliation;

  /// Present when a targeted cleanup ran — i.e. [status] is
  /// [CalendarReminderRefreshStatus.disabledCleanupCompleted],
  /// [CalendarReminderRefreshStatus.disabledCleanupPartial], or
  /// [CalendarReminderRefreshStatus.permissionDenied].
  final CalendarReminderDisableResult? cleanup;

  /// Short, non-sensitive error category when [status] is
  /// [CalendarReminderRefreshStatus.fetchFailed] or
  /// [CalendarReminderRefreshStatus.preferenceUnavailable].
  final String? errorCategory;

  /// Whether persisting the reminders-enabled preference failed on the
  /// permission-denied path. When true, the coordinator flipped the switch off
  /// for safety but could not confirm the write persisted, so this result is not
  /// fully successful even though owned reminders were cleaned up.
  final bool preferenceSaveFailed;

  bool get didReconcile => status == CalendarReminderRefreshStatus.reconciled;

  bool get didFetchFail => status == CalendarReminderRefreshStatus.fetchFailed;

  @override
  String toString() =>
      'CalendarReminderRefreshResult(reason: ${reason.name}, '
      'status: ${status.name}'
      '${reconciliation != null ? ', $reconciliation' : ''}'
      '${cleanup != null ? ', $cleanup' : ''}'
      '${errorCategory != null ? ', error: $errorCategory' : ''}'
      '${preferenceSaveFailed ? ', preferenceSaveFailed: true' : ''})';
}

/// The reminder refresh currently running, tagged with the session it belongs
/// to. A routine request may join this future only when it belongs to the same
/// session generation and owner; a request from a newer session must never
/// receive an older session's (possibly invalidated) result.
class _ActiveReminderRefresh {
  const _ActiveReminderRefresh({
    required this.generation,
    required this.ownerKey,
    required this.future,
  });

  final int generation;
  final String? ownerKey;
  final Future<CalendarReminderRefreshResult> future;
}

/// A single refresh queued to run immediately after the active refresh reaches
/// a safe terminal point. At most one is ever pending: additional requests
/// coalesce into it (within the same session) or replace it (a newer session),
/// so the queue is bounded and no forced change or new-session refresh is lost.
class _PendingRefresh {
  _PendingRefresh({
    required this.accessToken,
    required this.reason,
    required this.generation,
    required this.ownerKey,
  }) : completer = Completer<CalendarReminderRefreshResult>();

  /// The latest valid access token to use for the follow-up.
  String accessToken;

  /// The latest reason — preserved for diagnostics.
  CalendarReminderRefreshReason reason;

  /// The session generation this follow-up belongs to. If the session changes
  /// before it runs, it must not start (stale token/account).
  final int generation;

  /// The owner key of the session this follow-up belongs to.
  final String? ownerKey;

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
///   manifest-based reconciliation, scoped to the current account;
/// * prevent overlapping refreshes with a single-flight guard that is aware of
///   the reminder session, so a newer session never joins an older session's
///   in-flight future and a queued follow-up is never lost;
/// * throttle routine lifecycle refreshes while letting explicit changes force
///   reconciliation;
/// * when reminders are disabled or permission is denied, run targeted,
///   owner-scoped cleanup (never fetching, never a global cancel) so owned
///   reminders don't linger;
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

  _ActiveReminderRefresh? _activeRefresh;
  _PendingRefresh? _pending;
  DateTime? _lastRefreshAt;

  // Monotonic reminder-session generation. Every [beginSession]/[endSession]/
  // [transitionSession] increments it. Async work captures the generation it
  // started under and must re-check before reconciling or writing, so an old
  // session never schedules, cancels, or writes the manifest after a new one
  // begins.
  int _sessionGeneration = 0;

  // Privacy-safe key of the account owning the current reminder session, or
  // null while signed out. Folded into notification IDs and fingerprints so a
  // shared device keeps accounts' reminders isolated. Retained internally so
  // cleanup can run after [SessionController] has cleared its bootstrap/tokens.
  String? _ownerKey;

  /// Whether a refresh is currently running (exposed for tests).
  @visibleForTesting
  bool get isRefreshing => _activeRefresh != null;

  /// Whether a follow-up refresh is queued behind the active refresh (exposed
  /// for tests). Named for historical continuity with the forced-follow-up
  /// queue it generalises.
  @visibleForTesting
  bool get hasPendingForcedRefresh => _pending != null;

  /// The current reminder-session generation (exposed for tests).
  @visibleForTesting
  int get sessionGeneration => _sessionGeneration;

  /// The current account owner key, or null while signed out (exposed for
  /// tests).
  @visibleForTesting
  String? get ownerKey => _ownerKey;

  /// Whether an account-owned reminder session is currently active.
  ///
  /// A refresh requires this to be true: a non-empty access token alone is not
  /// enough. Lifecycle handlers gate on it so a signed-in-but-bootstrap-not-yet-
  /// available state never fires a null-owner refresh.
  bool get hasActiveSession => _ownerKey != null;

  // ── Session lifecycle ─────────────────────────────────────────────────────

  /// Begins a reminder session for [accountId].
  ///
  /// Records a privacy-safe owner key derived from the account ID (never the raw
  /// ID) and opens a new session generation, invalidating any in-flight or
  /// queued work from a previous session so it can neither reconcile nor write
  /// the manifest.
  ///
  /// An empty, whitespace-only, or otherwise invalid [accountId] is rejected:
  /// no owner key is created, the generation is NOT advanced, and any queued
  /// follow-up and currently-valid session are left intact. This prevents a
  /// missing/temporarily-unavailable bootstrap from both creating a bogus
  /// empty-account owner and tearing down a valid session via a duplicate
  /// transient callback. The structured result reports which happened.
  CalendarReminderSessionStartResult beginSession({required String accountId}) {
    if (!isValidReminderAccountId(accountId)) {
      return CalendarReminderSessionStartResult(
        status: CalendarReminderSessionStartStatus.skippedInvalidAccount,
        generation: _sessionGeneration,
      );
    }
    _invalidatePending();
    _sessionGeneration++;
    _ownerKey = reminderOwnerKey(accountId);
    _lastRefreshAt = null;
    return CalendarReminderSessionStartResult(
      status: CalendarReminderSessionStartStatus.started,
      generation: _sessionGeneration,
    );
  }

  /// Ends the current reminder session (sign-out or unauthorized sign-out).
  ///
  /// Captures the ended account's owner key, immediately invalidates all
  /// in-flight and queued reminder work (so an in-flight fetch cannot reconcile
  /// and a queued follow-up cannot start), then runs a targeted, owner-scoped
  /// cleanup of just that account's manifest entries — never fetching, never a
  /// global `cancelAll()`, and never using a new account's owner key. The
  /// cleanup runs through the notification service's serialized mutation queue.
  /// Sign-out itself is never blocked or failed by a cleanup failure: the
  /// outcome is returned for diagnostics only.
  Future<CalendarReminderDisableResult> endSession() async {
    final endedOwnerKey = _ownerKey;
    _invalidatePending();
    _sessionGeneration++;
    _ownerKey = null;
    _lastRefreshAt = null;
    final cleanup = await _cleanupOwner(endedOwnerKey);
    _logSignOutCleanup(cleanup);
    return cleanup;
  }

  /// Performs an explicit account transition rather than beginning a new session
  /// over an old one.
  ///
  /// Invalidates the outgoing session's work synchronously, queues an
  /// owner-scoped cleanup of the previous account through the serialized
  /// mutation queue, then begins the new generation. The caller fires the new
  /// account's initial refresh afterwards; because both the old cleanup and the
  /// new reconcile run through the same serialization boundary, the new
  /// reconcile waits for the old cleanup to reach a safe terminal point, and the
  /// old cleanup can never cancel the new account's entries (it is owner-scoped
  /// to the previous account). Never blocks on cleanup: the returned future is
  /// for diagnostics only.
  ///
  /// Covers signed out → signed in ([previousAccountId] null), account A →
  /// account B, and re-entry after an unauthorized sign-out.
  Future<void> transitionSession({
    required String? previousAccountId,
    required String nextAccountId,
  }) {
    // An invalid next identity must not begin a session, must not tear down the
    // current (possibly valid) session, and must not clean up the previous
    // owner: a transient callback lacking bootstrap data is a no-op.
    if (!isValidReminderAccountId(nextAccountId)) {
      return Future<void>.value();
    }
    final endedOwnerKey = _ownerKey;
    // Queue the previous owner's cleanup before the new session's work is
    // enqueued, so it runs first in the serialized mutation queue.
    Future<void> cleanup = Future<void>.value();
    if (previousAccountId != null && endedOwnerKey != null) {
      cleanup = _cleanupOwner(endedOwnerKey).then(_logSignOutCleanup);
    }
    // Begin the new generation, invalidating any in-flight/queued old-session
    // work so it can neither reconcile nor write after the new session begins.
    beginSession(accountId: nextAccountId);
    return cleanup;
  }

  /// Owner-scoped targeted cleanup through the notification service's serialized
  /// mutation queue. Cleans ownerless legacy entries too, so a departing (or
  /// disabling) account's pre-migration reminders don't linger. A null owner is
  /// the account-agnostic legacy path.
  Future<CalendarReminderDisableResult> _cleanupOwner(String? ownerKey) =>
      _notificationService.disableCalendarReminders(
        ownerKey: ownerKey ?? '',
        includeLegacyOwnerless: true,
      );

  /// Whether [generation] is still the current session generation.
  bool _isCurrentGeneration(int generation) => generation == _sessionGeneration;

  /// Whether [generation] and [owner] both still match the current reminder
  /// session. Validates the captured owner as well as the generation, so an
  /// account switch (which changes the owner) invalidates in-flight work even in
  /// the unlikely event the generation counter alone did not disambiguate it.
  bool _isCurrentSession(int generation, String? owner) =>
      generation == _sessionGeneration && owner == _ownerKey;

  /// Drops any queued follow-up, completing its caller with an explicit
  /// [CalendarReminderRefreshStatus.skippedSessionInvalidated] result so no
  /// completer is ever left dangling across a session boundary.
  void _invalidatePending() {
    final pending = _pending;
    if (pending == null) return;
    _pending = null;
    _completePendingInvalidated(pending);
  }

  void _completePendingInvalidated(_PendingRefresh pending) {
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
  /// out. A routine request joins the active refresh only when it belongs to
  /// the same session (generation + owner); a request from a newer session, or
  /// any explicit request while a refresh is in flight, is queued as a single
  /// pending follow-up (coalescing within a session, replacing across sessions)
  /// rather than being dropped or joined to a stale future.
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
    final owner = _ownerKey;
    // A non-empty access token is not sufficient: there must be an active
    // account-owned reminder session. Without an owner, do nothing — no
    // preference read, no permission request, no fetch, no cleanup — so
    // production never runs the null-owner legacy path.
    if (owner == null) {
      return Future<CalendarReminderRefreshResult>.value(
        _skipped(reason, CalendarReminderRefreshStatus.skippedNoActiveSession),
      );
    }
    final explicit = force || reason.forcesReconciliation;

    final active = _activeRefresh;
    if (active != null) {
      final sameSession =
          active.generation == generation && active.ownerKey == owner;
      if (sameSession && !explicit) {
        // Routine request within the current session: join the active refresh;
        // start no new work.
        return active.future;
      }
      // Same-session forced request, or a request from a newer session that
      // must not join the older future — queue a single pending follow-up.
      return _enqueuePending(token, reason, generation, owner);
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
      owner: owner,
    );
  }

  /// Queues (or coalesces into / replaces) the single pending follow-up and
  /// returns the future that resolves to that follow-up's result.
  Future<CalendarReminderRefreshResult> _enqueuePending(
    String accessToken,
    CalendarReminderRefreshReason reason,
    int generation,
    String? owner,
  ) {
    final pending = _pending;
    if (pending != null &&
        pending.generation == generation &&
        pending.ownerKey == owner) {
      // Coalesce: keep one follow-up, adopt the latest token and reason.
      pending.accessToken = accessToken;
      pending.reason = reason;
      return pending.completer.future;
    }
    // No pending follow-up, or one belonging to a now-superseded session:
    // invalidate it and create a fresh one for this session.
    _invalidatePending();
    final created = _PendingRefresh(
      accessToken: accessToken,
      reason: reason,
      generation: generation,
      ownerKey: owner,
    );
    _pending = created;
    return created.completer.future;
  }

  Future<CalendarReminderRefreshResult> _start({
    required String accessToken,
    required CalendarReminderRefreshReason reason,
    required DateTime startedAt,
    required int generation,
    required String? owner,
  }) {
    late _ActiveReminderRefresh active;
    final future = _runGuarded(
      accessToken: accessToken,
      reason: reason,
      startedAt: startedAt,
      generation: generation,
      owner: owner,
      self: () => active,
    );
    active = _ActiveReminderRefresh(
      generation: generation,
      ownerKey: owner,
      future: future,
    );
    _activeRefresh = active;
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
    required String? owner,
    required _ActiveReminderRefresh Function() self,
  }) async {
    try {
      return await _run(
        accessToken: accessToken,
        reason: reason,
        startedAt: startedAt,
        generation: generation,
        owner: owner,
      );
    } finally {
      // Clear the active guard only if it is still THIS operation — never stomp
      // a newer session's active refresh that has already replaced it. Then
      // synchronously kick any queued follow-up. There is no await between
      // these, so no routine request can slip in and start a duplicate refresh.
      if (identical(_activeRefresh, self())) {
        _activeRefresh = null;
      }
      _startPendingIfAny();
    }
  }

  /// Starts the queued follow-up, if one is pending and still current. Runs
  /// synchronously (no await) so state transitions atomically from the
  /// just-finished refresh to the follow-up.
  void _startPendingIfAny() {
    final pending = _pending;
    if (pending == null) return;
    _pending = null;

    // A session change since this follow-up was queued means it belongs to an
    // ended session — do not start it; complete its caller as invalidated.
    if (!_isCurrentGeneration(pending.generation)) {
      _completePendingInvalidated(pending);
      return;
    }

    // Follow-ups bypass throttling by construction: they go straight to a
    // guarded run without an [_isThrottled] check.
    late _ActiveReminderRefresh active;
    final future = _runGuarded(
      accessToken: pending.accessToken,
      reason: pending.reason,
      startedAt: _now(),
      generation: pending.generation,
      owner: pending.ownerKey,
      self: () => active,
    );
    active = _ActiveReminderRefresh(
      generation: pending.generation,
      ownerKey: pending.ownerKey,
      future: future,
    );
    _activeRefresh = active;
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
    required String? owner,
  }) async {
    // The session may have ended before this work even began running.
    if (!_isCurrentSession(generation, owner)) {
      return _skipped(
        reason,
        CalendarReminderRefreshStatus.skippedSessionInvalidated,
      );
    }

    final ownerKey = owner;
    final prefResult = await _preferences.loadCalendarRemindersEnabledResult(
      ownerKey: ownerKey,
    );
    // The session may have ended (sign-out) or switched (account B) while the
    // preference was loading. Do not request permission or fetch for a stale
    // session — even to interpret an unavailable read.
    if (!_isCurrentSession(generation, owner)) {
      return _skipped(
        reason,
        CalendarReminderRefreshStatus.skippedSessionInvalidated,
      );
    }
    if (prefResult.isUnavailable) {
      // The stored value is unknown (storage failure, or a required migration
      // write failed). Do NOT reinterpret this as disabled: request no
      // permission, fetch nothing, schedule/cancel nothing, touch neither the
      // manifest nor the preference — preserve existing reminders and retry on a
      // later refresh.
      _log(
        reason,
        CalendarReminderRefreshStatus.preferenceUnavailable,
        error: prefResult.errorCategory,
      );
      return CalendarReminderRefreshResult(
        reason: reason,
        status: CalendarReminderRefreshStatus.preferenceUnavailable,
        completedAt: _now(),
        errorCategory: prefResult.errorCategory,
      );
    }
    if (prefResult.enabled != true) {
      // `absent` (normal default-disabled) or `loaded false` (explicit disable):
      // both take the disabled-cleanup path, which retries any leftover owned
      // IDs and otherwise does nothing.
      return _runDisabled(reason, generation, owner);
    }
    // `loaded true` — continue to permission + reconciliation below.

    // Immediately before requesting permission, confirm the session is still
    // current: a sign-out during the preference load must not surface a
    // permission prompt for a session that no longer exists.
    if (!_isCurrentSession(generation, owner)) {
      return _skipped(
        reason,
        CalendarReminderRefreshStatus.skippedSessionInvalidated,
      );
    }

    final granted = await _notificationService.requestPermissionIfNeeded();
    if (!granted) {
      // The session may have ended while permission was being resolved. Do not
      // let an old session write (clear) the manifest, or clean up, after a new
      // one began — validate both generation and owner.
      if (!_isCurrentSession(generation, owner)) {
        return _skipped(
          reason,
          CalendarReminderRefreshStatus.skippedSessionInvalidated,
        );
      }
      // Keep the stored preference honest so Settings does not keep showing a
      // switch that is silently doing nothing — scoped to the current account.
      // Surface a persistence failure (never swallow it): the result must not
      // look fully successful if the write did not persist.
      var preferenceSaveFailed = false;
      try {
        await _preferences.saveCalendarRemindersEnabled(
          ownerKey: ownerKey,
          enabled: false,
        );
      } on CalendarReminderPreferenceStorageException catch (e) {
        preferenceSaveFailed = true;
        _log(
          reason,
          CalendarReminderRefreshStatus.permissionDenied,
          error: '$e',
        );
      }
      // Previously scheduled reminders would otherwise become unmanaged if the
      // user later re-grants permission via system settings. Cancel the ones
      // this account owns (targeted, never a global cancelAll) and keep any that
      // fail for a later retry. Do not fetch events.
      final cleanup = await _cleanupOwner(ownerKey);
      _log(reason, CalendarReminderRefreshStatus.permissionDenied);
      return CalendarReminderRefreshResult(
        reason: reason,
        status: CalendarReminderRefreshStatus.permissionDenied,
        completedAt: _now(),
        cleanup: cleanup,
        preferenceSaveFailed: preferenceSaveFailed,
      );
    }

    // Permission was granted. Confirm the session is still current before
    // beginning an event fetch: permission granted after the session ended must
    // not fetch with the old token.
    if (!_isCurrentSession(generation, owner)) {
      return _skipped(
        reason,
        CalendarReminderRefreshStatus.skippedSessionInvalidated,
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
    // began). Never reconcile or write the manifest for a stale session — and,
    // before passing work into reconciliation, validate both generation and
    // owner.
    if (!_isCurrentSession(generation, owner)) {
      _log(reason, CalendarReminderRefreshStatus.skippedSessionInvalidated);
      return _skipped(
        reason,
        CalendarReminderRefreshStatus.skippedSessionInvalidated,
      );
    }

    // Thread a session-validity context into reconciliation so it stops (and
    // never writes) the instant this session stops being current — including
    // while it waits its turn in the serialized mutation queue.
    final context = ownerKey == null
        ? null
        : CalendarReminderOperationContext(
            generation: generation,
            ownerKey: ownerKey,
            isCurrent: () => _isCurrentSession(generation, owner),
          );

    final reconciliation = await _notificationService
        .reconcileCalendarReminders(
          events,
          now: startedAt,
          ownerKey: ownerKey,
          context: context,
        );

    final CalendarReminderRefreshStatus status;
    if (reconciliation.sessionInvalidated) {
      status = CalendarReminderRefreshStatus.skippedSessionInvalidated;
    } else if (reconciliation.manifestCorrupt) {
      status = CalendarReminderRefreshStatus.manifestCorrupt;
    } else {
      status = CalendarReminderRefreshStatus.reconciled;
    }
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
  /// Never fetches events or requests permission. Uses the structured manifest
  /// load result so a corrupt manifest is handled conservatively (no cleanup,
  /// no write, explicit corrupt result) instead of being mistaken for an empty
  /// manifest. If the manifest is empty there is nothing to do; if a previous
  /// cleanup left owned IDs behind, the targeted owner-scoped cleanup is retried.
  Future<CalendarReminderRefreshResult> _runDisabled(
    CalendarReminderRefreshReason reason,
    int generation,
    String? owner,
  ) async {
    final loadResult = await _preferences.loadCalendarReminderManifestResult();
    if (loadResult.isCorrupt) {
      // Ownership is unknown: never schedule, cancel, or write. Report corrupt.
      _log(reason, CalendarReminderRefreshStatus.manifestCorrupt);
      return _skipped(reason, CalendarReminderRefreshStatus.manifestCorrupt);
    }
    if (loadResult.manifest.scheduledIds.isEmpty) {
      _log(reason, CalendarReminderRefreshStatus.skippedDisabled);
      return _skipped(reason, CalendarReminderRefreshStatus.skippedDisabled);
    }

    // A new session may have begun (or the account switched) while we were
    // reading the manifest — an old session must not clear/rewrite it after
    // that. Validate both generation and owner.
    if (!_isCurrentSession(generation, owner)) {
      return _skipped(
        reason,
        CalendarReminderRefreshStatus.skippedSessionInvalidated,
      );
    }

    final cleanup = await _cleanupOwner(_ownerKey);
    // A fully clean cleanup requires both every owned cancellation to succeed
    // *and* the manifest state to persist.
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

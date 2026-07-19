import 'dart:async';
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

/// Why a notification-service initialization attempt ended. Every value except
/// [initialized] leaves the service unusable (`_initialized == false`) and
/// retryable. Deliberately privacy-safe: a status name carries no notification
/// content, tokens, URLs, or account identifiers.
enum LocalNotificationInitializationStatus {
  /// Plugin initialization returned exactly `true` and (on Android) the channel
  /// was created. The only usable state.
  initialized,

  /// `FlutterLocalNotificationsPlugin.initialize()` returned `false`.
  pluginRejected,

  /// `FlutterLocalNotificationsPlugin.initialize()` returned `null` (result not
  /// confirmed).
  pluginResultMissing,

  /// On Android, the Android platform implementation could not be resolved, so
  /// the notification channel could not be created.
  platformImplementationMissing,

  /// Creating the Android notification channel threw.
  channelCreationFailed,

  /// An unexpected exception was thrown during initialization.
  exception,
}

/// Structured, log-safe outcome of a notification-service initialization
/// attempt. Holds only a status and a sanitized error category — never
/// notification content, tokens, URLs, or account identifiers.
class LocalNotificationInitializationResult {
  const LocalNotificationInitializationResult({
    required this.status,
    this.errorCategory,
  });

  final LocalNotificationInitializationStatus status;

  /// A short, non-sensitive category (typically a runtime type name) for the
  /// underlying failure, when one applies. Never event content or identifiers.
  final String? errorCategory;

  /// Whether initialization fully succeeded and the service is usable.
  bool get isInitialized =>
      status == LocalNotificationInitializationStatus.initialized;

  @override
  String toString() =>
      'LocalNotificationInitializationResult(status: ${status.name}'
      '${errorCategory != null ? ', errorCategory: $errorCategory' : ''})';
}

/// Session-validity context threaded into a reconciliation pass so it can stop
/// (and never write) the moment its reminder session stops being current — e.g.
/// a sign-out or an account switch that began while the pass was running.
///
/// [isCurrent] is re-evaluated at each safe point (before/after init, before/
/// after every schedule and cancel, and before any manifest persistence), so an
/// old session can never schedule, cancel, or persist after a new one begins.
class CalendarReminderOperationContext {
  const CalendarReminderOperationContext({
    required this.generation,
    required this.ownerKey,
    required this.isCurrent,
  });

  /// The reminder-session generation this operation belongs to.
  final int generation;

  /// The privacy-safe owner key of the account this operation belongs to.
  final String ownerKey;

  /// Whether this operation's session is still the current one.
  final bool Function() isCurrent;
}

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
    this.sessionInvalidated = false,
    this.collisionsResolved = 0,
    this.idAllocationFailures = 0,
    this.rollback,
    this.invalidationRollback,
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

  /// Whether this pass's reminder session was invalidated (sign-out, or a newer
  /// session began) partway through. When true, any IDs this pass had scheduled
  /// were rolled back, the stale final manifest was NOT persisted, and the
  /// previous manifest was left intact for the new session.
  final bool sessionInvalidated;

  /// How many candidates needed a deterministic probe to avoid a colliding
  /// 31-bit notification ID this pass (Defect 6). Zero in the overwhelmingly
  /// common no-collision case.
  final int collisionsResolved;

  /// Candidates that could not be allocated a unique 31-bit ID within the probe
  /// limit and were therefore not scheduled. Surfaced (never silently dropped)
  /// so an exhausted probe limit is observable.
  final int idAllocationFailures;

  /// Present only when the final manifest save failed and a rollback ran;
  /// describes how completely the newly-scheduled IDs were undone/recovered.
  final CalendarReminderRollbackResult? rollback;

  /// Present only when [sessionInvalidated] is true and the stale pass had
  /// already scheduled at least one notification; describes how completely those
  /// stale schedules (both brand-new and replacement) were rolled back.
  final CalendarReminderInvalidationRollbackResult? invalidationRollback;

  final DateTime completedAt;

  bool get hasFailures =>
      failedCount > 0 ||
      !manifestPersisted ||
      manifestCorrupt ||
      sessionInvalidated ||
      idAllocationFailures > 0;

  /// True only when every operation succeeded, the manifest was persisted, the
  /// stored value was not corrupt, the session stayed current, every candidate
  /// got an ID, and any rollback/recovery fully succeeded.
  bool get isFullySuccessful =>
      failedCount == 0 &&
      manifestPersisted &&
      !manifestCorrupt &&
      !sessionInvalidated &&
      idAllocationFailures == 0 &&
      (rollback?.isFullySuccessful ?? true) &&
      (invalidationRollback?.isFullySuccessful ?? true);

  @override
  String toString() =>
      'CalendarReconciliationResult(events: $eventsFetched, '
      'eligible: $eligibleCandidates, scheduled: $scheduledCount, '
      'updated: $updatedCount, cancelled: $cancelledCount, '
      'unchanged: $unchangedCount, failed: $failedCount, '
      'manifestPersisted: $manifestPersisted, '
      'manifestCorrupt: $manifestCorrupt, '
      'sessionInvalidated: $sessionInvalidated, '
      'collisionsResolved: $collisionsResolved, '
      'idAllocationFailures: $idAllocationFailures'
      '${rollback != null ? ', $rollback' : ''}'
      '${invalidationRollback != null ? ', $invalidationRollback' : ''})';
}

/// Structured, log-safe outcome of rolling back the platform schedules a stale
/// (session-invalidated) reconciliation pass had already made before it noticed
/// its session was no longer current.
///
/// Every notification the stale pass successfully scheduled — both brand-new IDs
/// and replacements of existing (changed) IDs — is cancelled, so nothing the
/// dead session put on the device survives. The stale pass never persists its
/// manifest, leaving the previous stored manifest intact for the new session's
/// serialized cleanup/reconcile to repair device state. Cancellation failures
/// are represented here structurally (a count), not merely debug-logged.
class CalendarReminderInvalidationRollbackResult {
  const CalendarReminderInvalidationRollbackResult({
    this.newIdsCancelled = 0,
    this.replacedIdsCancelled = 0,
    this.cancellationFailures = 0,
  });

  /// Brand-new IDs (not previously owned) the stale pass had scheduled, then
  /// successfully cancelled during rollback.
  final int newIdsCancelled;

  /// Previously-owned IDs the stale pass had re-scheduled (replaced), then
  /// successfully cancelled during rollback.
  final int replacedIdsCancelled;

  /// Rollback cancellations that themselves failed; those notifications may
  /// still be on the device and are left for the new session's cleanup.
  final int cancellationFailures;

  /// The total number of stale schedules successfully rolled back.
  int get totalCancelled => newIdsCancelled + replacedIdsCancelled;

  /// True when every stale schedule was cancelled without a failure.
  bool get isFullySuccessful => cancellationFailures == 0;

  @override
  String toString() =>
      'CalendarReminderInvalidationRollbackResult(newIdsCancelled: '
      '$newIdsCancelled, replacedIdsCancelled: $replacedIdsCancelled, '
      'cancellationFailures: $cancellationFailures)';
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

  /// Whether the resulting manifest state was persisted (cleared when all owned
  /// IDs were cancelled, or rewritten to retain foreign/failed IDs). `true` also
  /// when nothing needed persisting because nothing was cancelled.
  final bool manifestPersisted;

  /// A cleanup has failures when a cancellation failed *or* the resulting
  /// manifest state could not be persisted — a persistence failure means the
  /// cleanup did not fully complete and must be retried, so it is not success.
  bool get hasFailures => failedCount > 0 || !manifestPersisted;

  /// True only when nothing owned was left uncancelled and the manifest state
  /// persisted. Foreign-owner entries deliberately left behind do not count as a
  /// failure for the owner being cleaned up.
  bool get isFullyClean => failedCount == 0 && manifestPersisted;

  @override
  String toString() =>
      'CalendarReminderDisableResult(cancelled: $cancelledCount, '
      'failed: $failedCount, manifestPersisted: $manifestPersisted)';
}

/// Structured, log-safe snapshot comparing the platform's scheduled calendar
/// reminders against the persisted manifest.
///
/// Deliberately holds only counts, booleans, status names, and sanitized
/// categories — never titles, bodies, event IDs, occurrence IDs, calendar IDs,
/// owner keys, tokens, or URLs — so it is always safe to log. It distinguishes
/// three states without being destructive: nothing scheduled; the manifest
/// claims schedules the platform does not have; platform and manifest agree.
class LocalNotificationDiagnostics {
  const LocalNotificationDiagnostics({
    required this.initialized,
    required this.pendingPlatformCount,
    required this.trackedManifestCount,
    required this.trackedButNotPendingCount,
    required this.pendingButUntrackedCalendarCount,
    required this.scheduleMode,
    required this.timezoneName,
    this.errorCategory,
  });

  /// Whether the notification service is initialized/usable.
  final bool initialized;

  /// Count of pending platform requests whose payload is a Calee calendar
  /// reminder. Never includes other apps'/features' notifications.
  final int pendingPlatformCount;

  /// Count of reminder IDs tracked in the persisted manifest.
  final int trackedManifestCount;

  /// Tracked (manifest) IDs the platform does NOT report as pending.
  final int trackedButNotPendingCount;

  /// Pending Calee-reminder IDs not tracked by the manifest.
  final int pendingButUntrackedCalendarCount;

  /// The Android schedule mode in use (a constant name; no content).
  final String scheduleMode;

  /// The local timezone name reminders are scheduled against.
  final String timezoneName;

  /// Set only when diagnostics collection failed; a sanitized category. A
  /// failure never cancels or alters reminders.
  final String? errorCategory;

  @override
  String toString() =>
      'LocalNotificationDiagnostics(initialized: $initialized, '
      'pendingPlatform: $pendingPlatformCount, '
      'trackedManifest: $trackedManifestCount, '
      'trackedButNotPending: $trackedButNotPendingCount, '
      'pendingButUntracked: $pendingButUntrackedCalendarCount, '
      'scheduleMode: $scheduleMode, timezone: $timezoneName'
      '${errorCategory != null ? ', errorCategory: $errorCategory' : ''})';
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
  Future<LocalNotificationInitializationResult>? _initializing;

  // Tail of the serial mutation queue. Every operation that mutates platform
  // notifications or the manifest chains onto it (see [runSerialized]), so
  // reconciliation and sign-out/account-switch cleanup never interleave their
  // schedule/cancel/persist steps against the shared device manifest.
  Future<void> _mutationTail = Future<void>.value();

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

  /// Test-only override for notification-ID derivation, so ID collisions can be
  /// forced deterministically (probe 0 collides, probe 1+ resolves) without
  /// brute-forcing SHA-256 pre-images. Never set in production.
  @visibleForTesting
  NotificationIdDerivation? debugNotificationIdOverride;

  // ── Serial mutation queue ─────────────────────────────────────────────────

  /// Runs [operation] serialized against every other mutation on this service.
  ///
  /// Operations run one at a time in submission order. A failed operation does
  /// not poison the queue: its error is delivered to that caller only, and the
  /// tail still advances so later operations run. Never deadlocks (each
  /// operation is awaited to completion before the next starts) and never leaves
  /// a completer unresolved (the caller's future always completes with the
  /// operation's success or error).
  @visibleForTesting
  Future<T> runSerialized<T>(Future<T> Function() operation) {
    final completer = Completer<T>();
    final previous = _mutationTail;
    _mutationTail = previous.then((_) async {
      try {
        completer.complete(await operation());
      } catch (e, st) {
        completer.completeError(e, st);
      }
    });
    return completer.future;
  }

  // ── Initialization ──────────────────────────────────────────────────────

  /// The structured result of the most recent initialization attempt, retained
  /// for diagnostics and tests. Null until the first attempt runs.
  LocalNotificationInitializationResult? _lastInitResult;

  /// The result of the most recent initialization attempt (test/diagnostic
  /// observability). Never carries notification content, tokens, URLs, or
  /// account identifiers.
  @visibleForTesting
  LocalNotificationInitializationResult? get lastInitializationResult =>
      _lastInitResult;

  /// Small monochrome status-bar icon for calendar reminders. Referenced by
  /// name (a resource identifier, not the launcher asset) so both plugin init
  /// and each scheduled notification use the dedicated icon. Kept from resource
  /// shrinking by `res/raw/keep.xml`.
  static const androidNotificationIcon = 'ic_stat_calee';

  /// Initializes the plugin and Android channel, returning a structured,
  /// log-safe result. Retry-safe: on any non-success the service does not mark
  /// itself initialized, so a later call retries. Concurrent callers share a
  /// single in-flight attempt, and a failed attempt does not poison later
  /// retries (the shared future is always cleared when it settles).
  Future<LocalNotificationInitializationResult> initialize() {
    if (_initialized) {
      return Future<LocalNotificationInitializationResult>.value(
        _lastInitResult ??
            const LocalNotificationInitializationResult(
              status: LocalNotificationInitializationStatus.initialized,
            ),
      );
    }
    final existing = _initializing;
    if (existing != null) return existing;
    final future = _doInitialize();
    _initializing = future;
    return future;
  }

  Future<LocalNotificationInitializationResult> _doInitialize() async {
    LocalNotificationInitializationResult result;
    try {
      result = await performPluginInitialization();
    } catch (e) {
      // Any unexpected throw is a failed attempt, not a crash: capture it as a
      // structured result so a later reconcile can retry.
      result = LocalNotificationInitializationResult(
        status: LocalNotificationInitializationStatus.exception,
        errorCategory: _errorCategory(e),
      );
    } finally {
      // Always clear the shared in-flight future so a failed attempt never
      // poisons later retries.
      _initializing = null;
    }
    // Only an exact `initialized` status marks the service usable; false, null,
    // a missing Android implementation, a channel failure, or an exception all
    // leave _initialized false.
    _initialized =
        result.status == LocalNotificationInitializationStatus.initialized;
    _lastInitResult = result;
    if (!_initialized) {
      _debugLog('initialize failed (${result.status.name})');
    }
    return result;
  }

  /// Performs the actual plugin initialization and Android channel creation,
  /// returning a structured result. Overridable so init behaviour can be tested
  /// without platform channels.
  @visibleForTesting
  Future<LocalNotificationInitializationResult>
  performPluginInitialization() async {
    const androidSettings = AndroidInitializationSettings(
      androidNotificationIcon,
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

    // 1. Initialize the plugin and require an exact `true` result. A `false` or
    //    `null` result means platform initialization was not confirmed.
    final bool? initialized = await initializePlugin(settings);
    if (initialized == null) {
      return const LocalNotificationInitializationResult(
        status: LocalNotificationInitializationStatus.pluginResultMissing,
      );
    }
    if (initialized != true) {
      return const LocalNotificationInitializationResult(
        status: LocalNotificationInitializationStatus.pluginRejected,
      );
    }

    // 2. On Android, the platform implementation must be present to create the
    //    notification channel.
    if (isAndroidPlatform) {
      final androidImpl = resolveAndroidImplementation();
      if (androidImpl == null) {
        return const LocalNotificationInitializationResult(
          status: LocalNotificationInitializationStatus
              .platformImplementationMissing,
        );
      }
      // 3. Create the channel only after a successful plugin initialization. A
      //    channel-creation failure leaves the service uninitialized.
      try {
        await createAndroidChannel(androidImpl);
      } catch (e) {
        return LocalNotificationInitializationResult(
          status: LocalNotificationInitializationStatus.channelCreationFailed,
          errorCategory: _errorCategory(e),
        );
      }
    }

    return const LocalNotificationInitializationResult(
      status: LocalNotificationInitializationStatus.initialized,
    );
  }

  /// Invokes the plugin's `initialize`. Overridable so init results (true/false/
  /// null) can be simulated in tests without platform channels.
  @visibleForTesting
  Future<bool?> initializePlugin(InitializationSettings settings) =>
      _plugin.initialize(settings);

  /// Whether the current platform is Android. Overridable in tests so the
  /// Android-implementation requirement can be exercised off-device.
  @visibleForTesting
  bool get isAndroidPlatform => defaultTargetPlatform == TargetPlatform.android;

  /// Resolves the Android platform implementation. Overridable so a missing
  /// implementation can be simulated in tests. Returns an opaque marker object
  /// (the resolved plugin) that is passed back to [createAndroidChannel].
  @visibleForTesting
  Object? resolveAndroidImplementation() => _plugin
      .resolvePlatformSpecificImplementation<
        AndroidFlutterLocalNotificationsPlugin
      >();

  /// Creates the Android notification channel using the resolved implementation.
  /// Overridable so a channel-creation failure can be simulated in tests without
  /// a real platform implementation.
  @visibleForTesting
  Future<void> createAndroidChannel(Object androidImpl) async {
    if (androidImpl is AndroidFlutterLocalNotificationsPlugin) {
      await androidImpl.createNotificationChannel(
        const AndroidNotificationChannel(
          _channelId,
          _channelName,
          description: _channelDescription,
          importance: Importance.defaultImportance,
        ),
      );
    }
  }

  /// Whether initialization has completed successfully (test observability).
  @visibleForTesting
  bool get debugInitialized => _initialized;

  /// Ensures initialization, returning whether the service is usable. Never
  /// throws, so callers (and app startup) are not crashed by a plugin failure.
  @visibleForTesting
  Future<bool> ensureInitialized() async {
    try {
      final result = await initialize();
      return result.status == LocalNotificationInitializationStatus.initialized;
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
  /// Runs serialized against all other mutations (see [runSerialized]) so it
  /// never interleaves with a concurrent sign-out/account-switch cleanup.
  ///
  /// Never uses a global `cancelAll()`; only calendar reminder IDs recorded in
  /// the persisted manifest are cancelled. Candidates are assigned collision-
  /// free 31-bit IDs (see [allocateNotificationIds]) and then classified against
  /// the previous manifest by ID *and* schedule fingerprint:
  ///   * **unchanged** — same ID, same fingerprint: left untouched;
  ///   * **changed** — same ID, different/missing fingerprint: re-scheduled;
  ///   * **new** — ID not previously owned: scheduled;
  ///   * **stale** — previously owned, no longer desired: cancelled individually.
  ///
  /// If [context] is supplied, session validity is re-checked at every safe
  /// point; the moment it stops being current the pass stops, rolls back any IDs
  /// it scheduled, does not persist a stale manifest, and returns a result with
  /// [CalendarReconciliationResult.sessionInvalidated] set.
  ///
  /// The effective owner is `context.ownerKey` when a [context] is given, else
  /// [ownerKey]. A `null` effective owner is the account-agnostic path (legacy
  /// data and account-independent tests).
  Future<CalendarReconciliationResult> reconcileCalendarReminders(
    List<ClientEvent> events, {
    DateTime? now,
    String? ownerKey,
    CalendarReminderOperationContext? context,
  }) => runSerialized(
    () => _reconcileLocked(
      events,
      now: now,
      ownerKey: ownerKey,
      context: context,
    ),
  );

  Future<CalendarReconciliationResult> _reconcileLocked(
    List<ClientEvent> events, {
    DateTime? now,
    String? ownerKey,
    CalendarReminderOperationContext? context,
  }) async {
    final at = now ?? DateTime.now();
    final effectiveOwner = context?.ownerKey ?? ownerKey;
    bool isCurrent() => context?.isCurrent() ?? true;

    final rawCandidates = buildNotificationCandidates(
      events,
      now: at,
      maxCandidates: _maxScheduled,
      ownerKey: effectiveOwner,
    );

    // Session may have ended before this (possibly queued) pass began. Nothing
    // has been allocated or mutated yet.
    if (!isCurrent()) {
      return _invalidatedResult(events.length, rawCandidates.length, 0, 0, at);
    }

    // Load and validate the manifest BEFORE allocating final notification IDs,
    // so IDs still on the device but owned by another account (or by an
    // ownerless legacy entry) can be reserved and never overwritten. A corrupt
    // manifest allocates and mutates nothing.
    final prefs = preferences;
    final loadResult = await prefs.loadCalendarReminderManifestResult();
    if (loadResult.isCorrupt) {
      // Ownership is unknown. Do not schedule or cancel anything, and do not
      // overwrite the stored value — report corruption so the caller can retry
      // or diagnose. Never a global cancel.
      _debugLog('reconcile skipped: manifest corrupt');
      return CalendarReconciliationResult(
        eventsFetched: events.length,
        eligibleCandidates: rawCandidates.length,
        scheduledCount: 0,
        updatedCount: 0,
        cancelledCount: 0,
        unchangedCount: 0,
        failedCount: 0,
        manifestPersisted: false,
        manifestCorrupt: true,
        collisionsResolved: 0,
        idAllocationFailures: 0,
        completedAt: at,
      );
    }
    final previous = loadResult.manifest;
    final previousById = <int, CalendarReminderManifestEntry>{
      for (final entry in previous.entries) entry.notificationId: entry,
    };

    // Partition previously-owned entries relative to the current account:
    //  * foreign — owned by another (non-null) account: reserve its ID and
    //    retain it untouched; never cancel or overwrite another account's
    //    notification;
    //  * ownerless legacy (only when the current owner is a real account):
    //    reserve its ID during this pass so a candidate cannot land on it, then
    //    clean it up as stale (migrated to a current-owner entry);
    //  * current-owner — normal unchanged/changed/stale handling below; its ID
    //    is deliberately NOT reserved so the same occurrence can reuse it.
    final reservedIds = <int>{};
    final retainedForeign = <int, CalendarReminderManifestEntry>{};
    final legacyStaleIds = <int>{};
    final currentOwnerIds = <int>{};
    for (final entry in previous.entries) {
      final id = entry.notificationId;
      if (entry.ownerKey != null && entry.ownerKey != effectiveOwner) {
        reservedIds.add(id);
        retainedForeign[id] = entry;
      } else if (entry.ownerKey == null && effectiveOwner != null) {
        reservedIds.add(id);
        legacyStaleIds.add(id);
      } else {
        currentOwnerIds.add(id);
      }
    }

    // Assign collision-free IDs across the selected set, reserving the foreign
    // and ownerless-legacy IDs so no candidate is scheduled onto one. A
    // candidate that exhausts its probe budget is reported (never silently
    // dropped, never allowed to overwrite a reserved ID).
    final allocation = allocateNotificationIds(
      rawCandidates,
      reservedIds: reservedIds,
      idDerivation: debugNotificationIdOverride,
    );
    final candidates = allocation.candidates;
    final collisionsResolved = allocation.collisionsResolved;
    final idAllocationFailures = allocation.unresolved.length;
    if (idAllocationFailures > 0) {
      _debugLog(
        'reconcile: $idAllocationFailures candidate(s) exhausted the ID probe '
        'limit and were not scheduled',
      );
    }

    final initialized = await ensureInitialized();
    // Session may have ended while initialization resolved.
    if (!isCurrent()) {
      return _invalidatedResult(
        events.length,
        candidates.length,
        collisionsResolved,
        idAllocationFailures,
        at,
      );
    }
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
        collisionsResolved: collisionsResolved,
        idAllocationFailures: idAllocationFailures,
        completedAt: at,
      );
    }

    // Desired schedules keyed by (unique) notification ID, with fingerprints.
    final desiredById = <int, CalendarNotificationCandidate>{
      for (final c in candidates) c.notificationId: c,
    };
    final desiredFingerprint = <int, String>{
      for (final e in desiredById.entries) e.key: scheduleFingerprint(e.value),
    };

    final desiredIds = desiredById.keys.toSet();

    // Classify desired IDs against the current account's own entries only.
    // Foreign and legacy IDs were reserved out of the candidate pool, so a
    // candidate's final ID is either brand-new or a reuse of a current-owner ID
    // for the same occurrence — never a foreign/legacy ID.
    final newIds = <int>{};
    final changedIds = <int>{};
    final unchangedIds = <int>{};
    for (final id in desiredIds) {
      final prev = previousById[id];
      if (prev == null || prev.ownerKey != effectiveOwner) {
        // Brand-new under the current owner.
        newIds.add(id);
      } else {
        final prevFp = prev.fingerprint;
        if (prevFp != null && prevFp == desiredFingerprint[id]) {
          unchangedIds.add(id);
        } else {
          changedIds.add(id);
        }
      }
    }

    // Current-owner entries no longer desired are stale; ownerless legacy
    // entries are always cleaned (migrated). Foreign entries are never stale —
    // they belong to another account and are retained untouched.
    final staleIds = <int>{...legacyStaleIds};
    for (final id in currentOwnerIds) {
      if (!desiredIds.contains(id)) staleIds.add(id);
    }

    // Entries believed to be on the device after this pass. Foreign entries are
    // retained untouched from the start so another account's reminders survive.
    final keptEntries = <int, CalendarReminderManifestEntry>{
      ...retainedForeign,
    };
    for (final id in unchangedIds) {
      keptEntries[id] = CalendarReminderManifestEntry(
        notificationId: id,
        fingerprint: desiredFingerprint[id],
        ownerKey: effectiveOwner,
      );
    }

    var scheduled = 0;
    var updated = 0;
    var cancelled = 0;
    var failed = 0;

    // Every successful platform schedule this pass, split by kind, so a mid-pass
    // session invalidation can roll back BOTH brand-new schedules and
    // replacements — not only the new ones. (The save-failure rollback below
    // still uses only [newlyScheduledIds]: a replaced ID remains tracked by the
    // intact previous manifest, so it must not be cancelled there.)
    final newlyScheduledIds = <int>{};
    final replacedIds = <int>{};

    // 3a. Schedule newly-desired reminders.
    for (final id in newIds) {
      if (!isCurrent()) {
        return _rollbackInvalidated(
          newlyScheduledIds,
          replacedIds,
          eventsFetched: events.length,
          eligibleCandidates: candidates.length,
          collisionsResolved: collisionsResolved,
          idAllocationFailures: idAllocationFailures,
          at: at,
        );
      }
      final ok = await scheduleReminder(desiredById[id]!);
      if (ok) {
        scheduled++;
        newlyScheduledIds.add(id);
        keptEntries[id] = CalendarReminderManifestEntry(
          notificationId: id,
          fingerprint: desiredFingerprint[id],
          ownerKey: effectiveOwner,
        );
      } else {
        failed++;
      }
      if (!isCurrent()) {
        return _rollbackInvalidated(
          newlyScheduledIds,
          replacedIds,
          eventsFetched: events.length,
          eligibleCandidates: candidates.length,
          collisionsResolved: collisionsResolved,
          idAllocationFailures: idAllocationFailures,
          at: at,
        );
      }
    }

    // 3b. Re-schedule changed reminders. Scheduling the same ID replaces the
    //     platform notification, so no separate cancel is needed.
    for (final id in changedIds) {
      if (!isCurrent()) {
        return _rollbackInvalidated(
          newlyScheduledIds,
          replacedIds,
          eventsFetched: events.length,
          eligibleCandidates: candidates.length,
          collisionsResolved: collisionsResolved,
          idAllocationFailures: idAllocationFailures,
          at: at,
        );
      }
      final ok = await scheduleReminder(desiredById[id]!);
      if (ok) {
        updated++;
        replacedIds.add(id);
        keptEntries[id] = CalendarReminderManifestEntry(
          notificationId: id,
          fingerprint: desiredFingerprint[id],
          ownerKey: effectiveOwner,
        );
      } else {
        // Replacement failed: the previous notification is still on the device
        // and still owned. Keep the PREVIOUS entry so it is retried next pass.
        failed++;
        keptEntries[id] = previousById[id]!;
      }
      if (!isCurrent()) {
        return _rollbackInvalidated(
          newlyScheduledIds,
          replacedIds,
          eventsFetched: events.length,
          eligibleCandidates: candidates.length,
          collisionsResolved: collisionsResolved,
          idAllocationFailures: idAllocationFailures,
          at: at,
        );
      }
    }

    // 4. Cancel only stale calendar reminder IDs, individually.
    for (final id in staleIds) {
      if (!isCurrent()) {
        return _rollbackInvalidated(
          newlyScheduledIds,
          replacedIds,
          eventsFetched: events.length,
          eligibleCandidates: candidates.length,
          collisionsResolved: collisionsResolved,
          idAllocationFailures: idAllocationFailures,
          at: at,
        );
      }
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
      if (!isCurrent()) {
        return _rollbackInvalidated(
          newlyScheduledIds,
          replacedIds,
          eventsFetched: events.length,
          eligibleCandidates: candidates.length,
          collisionsResolved: collisionsResolved,
          idAllocationFailures: idAllocationFailures,
          at: at,
        );
      }
    }

    // 5. Before persisting, re-check validity one last time so a stale session
    //    can never write its manifest after a new session begins.
    if (!isCurrent()) {
      return _rollbackInvalidated(
        newlyScheduledIds,
        replacedIds,
        eventsFetched: events.length,
        eligibleCandidates: candidates.length,
        collisionsResolved: collisionsResolved,
        idAllocationFailures: idAllocationFailures,
        at: at,
      );
    }

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
        ownerKey: effectiveOwner,
        isCurrent: isCurrent,
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
      collisionsResolved: collisionsResolved,
      idAllocationFailures: idAllocationFailures,
      rollback: rollback,
      completedAt: at,
    );
    _debugLog('reconcile complete: $result');
    if (result.isFullySuccessful) {
      // Log-safe pending/tracked counts after a clean pass. Non-destructive and
      // never allowed to affect the reconciliation outcome.
      await _logReconciliationDiagnostics();
    }
    return result;
  }

  /// Cancels every notification a now-invalidated pass had scheduled — both
  /// brand-new IDs and replacements of existing (changed) IDs — and returns a
  /// [sessionInvalidated] result carrying a structured
  /// [CalendarReminderInvalidationRollbackResult].
  ///
  /// Never writes the manifest: the previous stored manifest is left intact for
  /// the new session, whose serialized cleanup/reconcile repairs device state
  /// afterwards. A rollback cancel that itself fails is represented structurally
  /// (a count), not merely debug-logged, so a stale schedule that could not be
  /// undone is observable rather than silent.
  Future<CalendarReconciliationResult> _rollbackInvalidated(
    Set<int> newlyScheduledIds,
    Set<int> replacedIds, {
    required int eventsFetched,
    required int eligibleCandidates,
    required int collisionsResolved,
    required int idAllocationFailures,
    required DateTime at,
  }) async {
    var newCancelled = 0;
    var replacedCancelled = 0;
    var cancellationFailures = 0;
    for (final id in newlyScheduledIds) {
      try {
        await cancelNotification(id);
        newCancelled++;
      } catch (e) {
        cancellationFailures++;
        _debugLog(
          'invalidation rollback cancel failed for new id=$id '
          '(${_errorCategory(e)})',
        );
      }
    }
    for (final id in replacedIds) {
      try {
        await cancelNotification(id);
        replacedCancelled++;
      } catch (e) {
        cancellationFailures++;
        _debugLog(
          'invalidation rollback cancel failed for replaced id=$id '
          '(${_errorCategory(e)})',
        );
      }
    }
    // Only attach a rollback record when the stale pass had actually scheduled
    // something; a pass invalidated before any successful schedule has nothing
    // to undo.
    final invalidationRollback =
        (newlyScheduledIds.isEmpty && replacedIds.isEmpty)
        ? null
        : CalendarReminderInvalidationRollbackResult(
            newIdsCancelled: newCancelled,
            replacedIdsCancelled: replacedCancelled,
            cancellationFailures: cancellationFailures,
          );
    _debugLog('reconcile aborted: session invalidated mid-pass');
    return CalendarReconciliationResult(
      eventsFetched: eventsFetched,
      eligibleCandidates: eligibleCandidates,
      scheduledCount: 0,
      updatedCount: 0,
      cancelledCount: 0,
      unchangedCount: 0,
      failedCount: 0,
      manifestPersisted: false,
      sessionInvalidated: true,
      collisionsResolved: collisionsResolved,
      idAllocationFailures: idAllocationFailures,
      invalidationRollback: invalidationRollback,
      completedAt: at,
    );
  }

  CalendarReconciliationResult _invalidatedResult(
    int eventsFetched,
    int eligibleCandidates,
    int collisionsResolved,
    int idAllocationFailures,
    DateTime at,
  ) {
    _debugLog('reconcile skipped: session invalidated before mutation');
    return CalendarReconciliationResult(
      eventsFetched: eventsFetched,
      eligibleCandidates: eligibleCandidates,
      scheduledCount: 0,
      updatedCount: 0,
      cancelledCount: 0,
      unchangedCount: 0,
      failedCount: 0,
      manifestPersisted: false,
      sessionInvalidated: true,
      collisionsResolved: collisionsResolved,
      idAllocationFailures: idAllocationFailures,
      completedAt: at,
    );
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
  /// IDs) is attempted — but only while the session is still current, so a stale
  /// session never writes after a new one begins.
  Future<CalendarReminderRollbackResult> _rollbackAfterSaveFailure({
    required CaleePreferences prefs,
    required CalendarReminderManifest previous,
    required Set<int> newlyScheduledIds,
    required Map<int, String> desiredFingerprint,
    required String? ownerKey,
    required bool Function() isCurrent,
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
    // ONE recovery write re-establishing tracking — but never after the session
    // was invalidated, so a stale session cannot overwrite the new one.
    if (!isCurrent()) {
      _debugLog('recovery write skipped: session invalidated');
      return CalendarReminderRollbackResult(
        rollbackCancelledCount: rolledBack,
        rollbackFailedCount: failedRollback.length,
      );
    }
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

  /// Targeted, owner-scoped cleanup of the calendar reminders this app scheduled
  /// for a single account.
  ///
  /// Runs serialized against all other mutations (see [runSerialized]).
  ///
  /// Only manifest entries owned by [ownerKey] are cancelled — entries owned by
  /// other accounts on the same device are preserved, and `cancelAll()` is never
  /// used. Pass [includeLegacyOwnerless] to also cancel ownerless legacy (v1/v2/
  /// v3-migrated) entries during a first-migration cleanup. Retry-safe: an ID
  /// whose cancellation fails stays owned for a later retry, and the manifest is
  /// only cleared when nothing remains owned by anyone. Storage failures are
  /// reported, never swallowed. A corrupt manifest is left untouched and
  /// reported as an incomplete cleanup.
  Future<CalendarReminderDisableResult> disableCalendarReminders({
    required String ownerKey,
    bool includeLegacyOwnerless = false,
  }) => runSerialized(
    () => _disableLocked(
      ownerKey: ownerKey,
      includeLegacyOwnerless: includeLegacyOwnerless,
    ),
  );

  Future<CalendarReminderDisableResult> _disableLocked({
    required String ownerKey,
    required bool includeLegacyOwnerless,
  }) async {
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
    var failedCancellations = 0;
    final retained = <CalendarReminderManifestEntry>[];
    for (final entry in manifest.entries) {
      final owned =
          entry.ownerKey == ownerKey ||
          (includeLegacyOwnerless && entry.ownerKey == null);
      if (!owned) {
        // Foreign-owner (or excluded legacy) entry — preserve it untouched.
        retained.add(entry);
        continue;
      }
      try {
        await cancelNotification(entry.notificationId);
        cancelled++;
      } catch (e) {
        // Keep the failed-cancel ID owned for a later retry.
        retained.add(entry);
        failedCancellations++;
        _debugLog(
          'disable cancel failed for id=${entry.notificationId} '
          '(${_errorCategory(e)})',
        );
      }
    }

    var manifestPersisted = true;
    // Only persist when the manifest content actually changed (something was
    // cancelled). Failed cancellations and foreign entries stay in place, so if
    // nothing was cancelled there is nothing to write.
    if (cancelled > 0) {
      try {
        if (retained.isEmpty) {
          await prefs.clearCalendarReminderManifest();
        } else {
          // Retain foreign-owner entries and any failed cancellations. Never
          // clear the whole manifest while foreign entries remain.
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
    }

    final result = CalendarReminderDisableResult(
      cancelledCount: cancelled,
      failedCount: failedCancellations,
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
        // Use the dedicated monochrome status-bar icon, not the launcher icon.
        icon: androidNotificationIcon,
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

  // ── Diagnostics ───────────────────────────────────────────────────────────

  /// The payload `type` all Calee calendar reminders carry, used to match only
  /// Calee reminders among the platform's pending requests.
  static const _reminderPayloadType = 'calendar_event_reminder';

  /// Fetches pending platform notification requests. Overridable so diagnostics
  /// can be tested without platform channels.
  @visibleForTesting
  Future<List<PendingNotificationRequest>> pendingNotificationRequests() =>
      _plugin.pendingNotificationRequests();

  /// Collects a log-safe [LocalNotificationDiagnostics] snapshot comparing the
  /// platform's pending Calee reminders to the persisted manifest.
  ///
  /// Purely observational: never schedules, cancels (never `cancelAll()`),
  /// writes the manifest, or otherwise alters reminders. Any failure is
  /// captured as a sanitized [LocalNotificationDiagnostics.errorCategory]; it
  /// never throws and never mutates reminder state. Only Calee calendar-reminder
  /// payloads are counted, and only counts/booleans/status names are exposed —
  /// no titles, bodies, event/occurrence/calendar IDs, owner keys, tokens, or
  /// URLs.
  Future<LocalNotificationDiagnostics> collectDiagnostics() async {
    final initialized = await ensureInitialized();
    const scheduleMode = 'inexactAllowWhileIdle';
    final timezoneName = _safeTimezoneName();
    try {
      final pending = await pendingNotificationRequests();
      final pendingCalendarIds = <int>{};
      for (final request in pending) {
        if (_isCalendarReminderPayload(request.payload)) {
          pendingCalendarIds.add(request.id);
        }
      }

      final loadResult = await preferences.loadCalendarReminderManifestResult();
      // A corrupt manifest yields no known tracked IDs; report zero tracked
      // rather than guessing, and never overwrite the stored value here.
      final trackedIds = loadResult.isCorrupt
          ? <int>{}
          : {
              for (final entry in loadResult.manifest.entries)
                entry.notificationId,
            };

      final trackedButNotPending = trackedIds
          .difference(pendingCalendarIds)
          .length;
      final pendingButUntracked = pendingCalendarIds
          .difference(trackedIds)
          .length;

      return LocalNotificationDiagnostics(
        initialized: initialized,
        pendingPlatformCount: pendingCalendarIds.length,
        trackedManifestCount: trackedIds.length,
        trackedButNotPendingCount: trackedButNotPending,
        pendingButUntrackedCalendarCount: pendingButUntracked,
        scheduleMode: scheduleMode,
        timezoneName: timezoneName,
      );
    } catch (e) {
      // A diagnostics failure is non-destructive: report a sanitized category
      // and leave all reminder state untouched.
      _debugLog('diagnostics failed (${_errorCategory(e)})');
      return LocalNotificationDiagnostics(
        initialized: initialized,
        pendingPlatformCount: 0,
        trackedManifestCount: 0,
        trackedButNotPendingCount: 0,
        pendingButUntrackedCalendarCount: 0,
        scheduleMode: scheduleMode,
        timezoneName: timezoneName,
        errorCategory: _errorCategory(e),
      );
    }
  }

  /// The local timezone name, or `'unknown'` if the timezone database has not
  /// been initialized. Never throws.
  String _safeTimezoneName() {
    try {
      return tz.local.name;
    } catch (_) {
      return 'unknown';
    }
  }

  /// Whether [payload] is a Calee calendar-reminder payload. Only the payload
  /// `type` is inspected; no event content is read or retained.
  bool _isCalendarReminderPayload(String? payload) {
    if (payload == null || payload.isEmpty) return false;
    try {
      final decoded = jsonDecode(payload);
      return decoded is Map && decoded['type'] == _reminderPayloadType;
    } catch (_) {
      return false;
    }
  }

  /// Emits a debug log of safe diagnostic counts after a successful
  /// reconciliation. Never throws and never alters reminders.
  Future<void> _logReconciliationDiagnostics() async {
    if (!kDebugMode) return;
    try {
      final diagnostics = await collectDiagnostics();
      _debugLog('post-reconcile diagnostics: $diagnostics');
    } catch (e) {
      _debugLog('post-reconcile diagnostics skipped (${_errorCategory(e)})');
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

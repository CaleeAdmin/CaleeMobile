// ignore_for_file: prefer_initializing_formals
import 'dart:async';

import 'package:flutter/foundation.dart' show kDebugMode;
import 'package:flutter/material.dart';

import '../config/calee_environment.dart';
import '../data/api/calee_hub_client.dart';
import '../data/auth/calee_preferences.dart';
import '../data/auth/session_store.dart';
import '../features/auth/auth_repository.dart';
import '../features/auth/create_account_page.dart';
import '../features/auth/login_page.dart';
import '../features/auth/post_registration_profile_defaults.dart';
import '../features/auth/session_controller.dart';
import '../data/device/device_profile_defaults_provider.dart';
import '../features/calendar_follow/calendar_follow_intent.dart';
import '../features/calendar_follow/calendar_follow_link_controller.dart';
import '../features/calendar_follow/follow_calendar_page.dart';
import '../features/calendar_onboarding/calendar_onboarding_page.dart';
import '../features/calendar_onboarding/provider_guides/google_calendar_selection_page.dart';
import '../data/models/external_calendar_connection.dart';
import '../features/external_calendar/external_calendar_connected_intent.dart';
import '../features/external_calendar/external_calendar_connected_link_controller.dart';
import '../features/calendar_onboarding/calendar_onboarding_status.dart';
import '../features/display_setup/display_activation_controller.dart';
import '../features/display_setup/display_activation_success_page.dart';
import '../features/display_setup/connect_display_page.dart';
import '../features/display_setup/display_setup_confirmation_page.dart';
import '../features/display_setup/display_setup_intent.dart';
import '../features/display_setup/display_setup_landing_page.dart';
import '../features/display_setup/display_setup_repository.dart';
import '../features/display_setup/display_setup_link_controller.dart';
import '../features/local_subscriber/local_calendar_subscription.dart';
import '../features/notifications/calendar_reminder_coordinator.dart';
import '../features/onboarding/welcome_page.dart';
import '../features/local_subscriber/local_calendar_subscription_repository.dart';
import '../features/local_subscriber/local_subscriber_calendar_page.dart';
import '../features/settings/calendar_collections_page.dart';
import '../features/shopping/shopping_link_controller.dart';
import '../features/shopping/shopping_link_intent.dart';
import '../features/shopping/shopping_link_landing_page.dart';
import '../features/shopping/shopping_page.dart';
import '../ui/calee_design.dart';
import 'calee_home_page.dart';

// Home-page tab indices for CaleeHomePage's bottom navigation bar.
const _kCalendarTabIndex = 1;

/// Overrides injected by tests to avoid platform channels and network calls.
@visibleForTesting
class CaleeAppTestDependencies {
  const CaleeAppTestDependencies({
    required this.hubClient,
    required this.sessionController,
    required this.displaySetupLinkController,
    required this.followLinkController,
    required this.displayActivationController,
    required this.localSubscriptionRepo,
    this.externalCalendarConnectedLinkController,
    this.shoppingLinkController,
    this.deviceProfileDefaultsProvider,
    this.reminderCoordinator,
  });

  final CaleeHubClient hubClient;
  final SessionController sessionController;
  final DisplaySetupLinkController displaySetupLinkController;
  final CalendarFollowLinkController followLinkController;
  final DisplayActivationController displayActivationController;
  final LocalCalendarSubscriptionRepository localSubscriptionRepo;
  final ExternalCalendarConnectedLinkController?
  externalCalendarConnectedLinkController;
  final ShoppingLinkController? shoppingLinkController;
  final DeviceProfileDefaultsProvider? deviceProfileDefaultsProvider;
  final CalendarReminderCoordinator? reminderCoordinator;
}

class CaleeApp extends StatefulWidget {
  const CaleeApp({super.key}) : _testDeps = null;

  @visibleForTesting
  const CaleeApp.forTesting({
    required CaleeAppTestDependencies testDeps,
    super.key,
  }) : _testDeps = testDeps;

  final CaleeAppTestDependencies? _testDeps;

  @override
  State<CaleeApp> createState() => _CaleeAppState();
}

class _CaleeAppState extends State<CaleeApp> with WidgetsBindingObserver {
  late final CaleeHubClient _hubClient;
  late final SessionController _sessionController;
  late final CalendarFollowLinkController _followLinkController;
  late final DisplaySetupLinkController _displaySetupLinkController;
  late final ExternalCalendarConnectedLinkController
  _externalCalendarConnectedLinkController;
  late final ShoppingLinkController _shoppingLinkController;
  late final DisplayActivationController _displayActivationController;
  late final LocalCalendarSubscriptionRepository _localSubscriptionRepo;
  late final CalendarReminderCoordinator _reminderCoordinator;
  final _navigatorKey = GlobalKey<NavigatorState>();

  // Set to true when the app goes to background; cleared and transport reset on resume.
  bool _transportMayBeStale = false;

  // Account whose reminder session is currently active in the coordinator, or
  // null while signed out. Drives the once-per-signed-in-session reminder
  // refresh (a restored or freshly signed-in session schedules reminders
  // exactly once) and detects the sign-in → sign-out and account-switch
  // transitions that begin/end the coordinator's reminder session.
  String? _reminderSessionAccountId;

  // Calendar follow state
  bool _showingFollowSignIn = false;
  bool _processingFollowLink = false;

  // Shopping link state (signed-out sign-in/create-account sub-screens,
  // shown from ShoppingLinkLandingPage).
  bool _showingShoppingSignIn = false;
  bool _showingShoppingCreateAccount = false;
  // Dedup guard so the same shopping target (e.g. redelivered by the
  // platform, delivered via both the HTTPS app-link and the calee://
  // custom scheme, or observed by more than one listener in the same tick)
  // isn't pushed onto the navigator twice in quick succession. Keyed by
  // ShoppingLinkIntent.canonicalKey rather than the exact source URI so the
  // HTTPS and custom-scheme forms of the same weekStart dedup together.
  String? _lastOpenedShoppingKey;
  DateTime? _lastOpenedShoppingAt;
  // True while a confirmed-but-not-yet-pushed ShoppingPage navigation is
  // being retried (waiting for the navigator to attach) — guards against
  // scheduling a second, overlapping retry loop for the same intent.
  bool _shoppingPushInFlight = false;

  // Display setup state
  //
  // _displaySetupFromLoggedOut: intent arrived when app was definitely not
  // signed in (not merely mid-restore). Shows the landing page.
  // _displaySetupThroughLandingPage: user tapped a button on the landing page,
  // so after sign-in we auto-activate without a second confirmation prompt.
  bool _displaySetupFromLoggedOut = false;
  bool _displaySetupThroughLandingPage = false;
  bool _showingDisplaySetupCreateAccount = false;
  bool _showingDisplaySetupSignIn = false;
  bool _justRegistered = false;
  // Guards for the signed-in display confirmation route. The same pending
  // intent is observed by both _onDisplaySetupLinkChanged and
  // _onSessionChanged (a QR link landing around session restore makes both
  // fire close together), and it stays pending while the confirmation page
  // is shown — so without these guards any later session notification
  // pushes a second identical page.
  //
  // _displayConfirmationPushInFlight: a post-frame push has been scheduled
  // but not yet issued. Set *before* scheduling, so two notifications in the
  // same frame cannot both schedule a callback.
  // _activeDisplayConfirmationToken: token whose confirmation route is
  // currently scheduled or sitting on the navigator; released when that
  // route pops.
  bool _displayConfirmationPushInFlight = false;
  String? _activeDisplayConfirmationToken;

  // Welcome screen state (first-run signed-out, no pending intent)
  bool _showingSignInFromWelcome = false;
  bool _showingCreateAccountFromWelcome = false;
  bool _showingConnectDisplayAfterAuth = false;

  // Onboarding gate state (only active after fresh sign-in, not session restore)
  bool _checkingOnboarding = false;
  bool _showingOnboarding = false;
  int? _initialHomeTab;
  bool _openingGoogleCalendarSelection = false;
  String? _lastExternalCalendarIntentKey;
  DateTime? _lastExternalCalendarIntentAt;

  List<LocalCalendarSubscription> _localSubscriptions = [];
  bool _localSubscriptionsLoaded = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    GoogleCalendarSelectionGate.reset();
    final testDeps = widget._testDeps;
    if (testDeps != null) {
      _hubClient = testDeps.hubClient;
      _sessionController = testDeps.sessionController;
      _followLinkController = testDeps.followLinkController;
      _displaySetupLinkController = testDeps.displaySetupLinkController;
      _externalCalendarConnectedLinkController =
          testDeps.externalCalendarConnectedLinkController ??
          ExternalCalendarConnectedLinkController();
      _shoppingLinkController =
          testDeps.shoppingLinkController ?? ShoppingLinkController();
      _displayActivationController = testDeps.displayActivationController;
      _localSubscriptionRepo = testDeps.localSubscriptionRepo;
    } else {
      _hubClient = CaleeHubClient(baseUri: CaleeEnvironment.apiBaseUri);
      final repository = AuthRepository(
        hubClient: _hubClient,
        sessionStore: SessionStore(),
      );
      _sessionController = SessionController(repository: repository);
      _hubClient.onUnauthorized = _sessionController.handleUnauthorized;
      _followLinkController = CalendarFollowLinkController();
      _displaySetupLinkController = DisplaySetupLinkController();
      _externalCalendarConnectedLinkController =
          ExternalCalendarConnectedLinkController();
      _shoppingLinkController = ShoppingLinkController();
      _displayActivationController = DisplayActivationController(
        repository: DisplaySetupRepository(hubClient: _hubClient),
      );
      _localSubscriptionRepo = LocalCalendarSubscriptionRepository();
    }

    // App-level reminder coordinator: schedules device reminders from an
    // independent 30-day upcoming-event window, never from the visible month.
    _reminderCoordinator =
        testDeps?.reminderCoordinator ??
        CalendarReminderCoordinator(hubClient: _hubClient);

    // Listeners must be attached before any controller's init() can deliver
    // an intent, so a notification fired mid-init is never missed.
    _followLinkController.addListener(_onFollowLinkChanged);
    _displaySetupLinkController.addListener(_onDisplaySetupLinkChanged);
    _externalCalendarConnectedLinkController.addListener(
      _onExternalCalendarConnectedLinkChanged,
    );
    _shoppingLinkController.addListener(_onShoppingLinkChanged);
    _sessionController.addListener(_onSessionChanged);
    _sessionController.addListener(_onSessionChangedForReminders);

    // DisplaySetupLinkController.init() is idempotent and, in tests, always
    // backed by a fake (see CaleeAppTestDependencies), so it's called
    // unconditionally — this lets tests exercise the same post-init safety
    // net production relies on.
    unawaited(
      _displaySetupLinkController.init().then((_) {
        // Safety net in case init() resolved a pending intent before this
        // listener was attached above (or before the session/navigator
        // state needed to act on it was ready).
        if (mounted) _onDisplaySetupLinkChanged();
      }),
    );

    if (testDeps == null) {
      unawaited(_followLinkController.init());
      unawaited(_externalCalendarConnectedLinkController.init());
      unawaited(
        _shoppingLinkController.init().then((_) {
          // Safety net in case init() resolved a pending intent before this
          // listener was attached above.
          if (mounted) _maybeOpenPendingShoppingLink();
        }),
      );
    }

    _sessionController.restoreSession();
    unawaited(_loadLocalSubscriptions());
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _followLinkController.removeListener(_onFollowLinkChanged);
    _displaySetupLinkController.removeListener(_onDisplaySetupLinkChanged);
    _externalCalendarConnectedLinkController.removeListener(
      _onExternalCalendarConnectedLinkChanged,
    );
    _shoppingLinkController.removeListener(_onShoppingLinkChanged);
    _sessionController.removeListener(_onSessionChanged);
    _sessionController.removeListener(_onSessionChangedForReminders);
    _followLinkController.dispose();
    _displaySetupLinkController.dispose();
    _externalCalendarConnectedLinkController.dispose();
    _shoppingLinkController.dispose();
    _displayActivationController.dispose();
    _sessionController.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.inactive ||
        state == AppLifecycleState.detached) {
      _transportMayBeStale = true;
    }
    if (state == AppLifecycleState.resumed && _transportMayBeStale) {
      _transportMayBeStale = false;
      _hubClient.resetTransport();
      if (_sessionController.isSignedIn) {
        unawaited(_sessionController.refreshBootstrap());
        // Reconcile reminders against the independent 30-day window on resume
        // (throttled) — an event may have changed while backgrounded.
        _fireReminderRefresh(CalendarReminderRefreshReason.appResumed);
      }
    }
  }

  /// Drives the coordinator's reminder session across sign-in/out transitions:
  /// begins a session (and fires a once-per-session refresh) when a signed-in
  /// session appears, and ends it — invalidating in-flight work and running
  /// targeted cleanup of the signed-out account's reminders — when it goes away.
  /// Never runs reminder work while signed out.
  void _onSessionChangedForReminders() {
    if (_sessionController.isRestoringSession) return;

    if (!_sessionController.isSignedIn) {
      final endedAccountId = _reminderSessionAccountId;
      _reminderSessionAccountId = null;
      if (endedAccountId != null) {
        // Signed-in → signed-out (explicit sign-out or unauthorized automatic
        // sign-out): invalidate all in-flight/queued reminder work and clean up
        // the previous account's reminders. Never blocks or fails sign-out.
        _fireReminderSignOutCleanup();
      }
      return;
    }

    final accountId = _sessionController.bootstrap?.account.id ?? '';
    final previousAccountId = _reminderSessionAccountId;
    if (previousAccountId == accountId) return;

    // A new signed-in session (restore, fresh sign-in, or account switch).
    // Transition the coordinator's reminder session — invalidating any old-
    // session work and cleaning the previous owner through the serialized
    // mutation queue before beginning the new generation — then fire the
    // once-per-session refresh for the new account.
    _reminderSessionAccountId = accountId;
    _fireReminderTransition(
      previousAccountId: previousAccountId,
      nextAccountId: accountId,
    );
    _fireReminderRefresh(CalendarReminderRefreshReason.sessionRestored);
  }

  /// Transitions the coordinator's reminder session to [nextAccountId] without
  /// ever blocking the UI. [CalendarReminderCoordinator.transitionSession]
  /// begins the new session synchronously (so the refresh fired next belongs to
  /// the new account); only the previous owner's cleanup is async and
  /// best-effort. Failures are swallowed: a session transition must never crash
  /// the app or block navigation.
  void _fireReminderTransition({
    required String? previousAccountId,
    required String nextAccountId,
  }) {
    final cleanup = _reminderCoordinator.transitionSession(
      previousAccountId: previousAccountId,
      nextAccountId: nextAccountId,
    );
    unawaited(cleanup.catchError((Object _) {}));
  }

  /// Invalidates and cleans up reminders for the signed-out account without ever
  /// blocking sign-out, using a network-free targeted cleanup (never
  /// `cancelAll()`). Failures are swallowed: sign-out must always complete.
  void _fireReminderSignOutCleanup() {
    unawaited(() async {
      try {
        await _reminderCoordinator.endSession();
      } catch (_) {
        // Sign-out reminder cleanup is best-effort and must never crash the app
        // or block sign-out.
      }
    }());
  }

  /// Requests an upcoming-reminder refresh without ever blocking startup or
  /// navigation, and without surfacing failures. No-op while signed out.
  void _fireReminderRefresh(CalendarReminderRefreshReason reason) {
    final token = _sessionController.accessToken;
    if (token == null || !_sessionController.isSignedIn) return;
    unawaited(() async {
      try {
        await _reminderCoordinator.refresh(accessToken: token, reason: reason);
      } catch (_) {
        // Reminder scheduling is best-effort and must never crash the app.
      }
    }());
  }

  Future<void> _loadLocalSubscriptions() async {
    final subs = await _localSubscriptionRepo.list();
    if (!mounted) return;
    setState(() {
      _localSubscriptions = subs;
      _localSubscriptionsLoaded = true;
    });
  }

  void _onSessionChanged() {
    // Display setup intent must be checked before the signed-out early return
    // so that a pending intent from session-restore is routed correctly even
    // when the user is not signed in.
    final displayIntent = _displaySetupLinkController.pendingIntent;
    if (displayIntent != null) {
      if (_sessionController.isSignedIn) {
        if (_displaySetupThroughLandingPage) {
          // State 2: user came through the landing page, auto-activate.
          _displaySetupThroughLandingPage = false;
          _displaySetupFromLoggedOut = false;
          _displaySetupLinkController.clearPending();
          setState(() {
            _showingDisplaySetupCreateAccount = false;
            _showingDisplaySetupSignIn = false;
          });
          unawaited(_activateDisplayAndShowSuccess(displayIntent.token));
        } else {
          // Intent arrived during session restore (or after sign-in from
          // default login page): treat as state 3 and show confirmation.
          _maybeOpenDisplaySetupConfirmation(displayIntent);
        }
        return;
      } else if (!_sessionController.isRestoringSession) {
        // State 2: session restore finished with no session — show landing page.
        setState(() {
          _displaySetupFromLoggedOut = true;
          _showingDisplaySetupCreateAccount = false;
          _showingDisplaySetupSignIn = false;
        });
        return;
      }
      // Still restoring — wait for the next notification.
      return;
    }

    if (!_sessionController.isSignedIn) return;

    // Fresh registration/sign-in with no display context: offer display connection.
    if (_justRegistered) {
      _justRegistered = false;
      setState(() {
        _showingDisplaySetupCreateAccount = false;
        _showingConnectDisplayAfterAuth = true;
      });
      return;
    }

    // External calendar connected intent (e.g. from Google OAuth deep link).
    final calendarIntent =
        _externalCalendarConnectedLinkController.pendingIntent;
    if (calendarIntent != null) {
      _externalCalendarConnectedLinkController.clearPending();
      if (!calendarIntent.isError && calendarIntent.isGoogle) {
        unawaited(_openGoogleCalendarSelectionFromDeepLink(calendarIntent));
      }
      return;
    }

    // Shopping list intent (e.g. from the tablet's "Open on phone" link).
    if (_shoppingLinkController.pendingIntent != null) {
      if (kDebugMode) {
        debugPrint('[CaleeApp] _onSessionChanged shopping branch called');
      }
      _maybeOpenPendingShoppingLink();
      return;
    }

    // Calendar follow intent.
    final followIntent = _followLinkController.pendingIntent;
    if (followIntent != null) {
      _followLinkController.clearPending();
      _openSubscribeFlowForIntent(followIntent);
    }
  }

  void _onDisplaySetupLinkChanged() {
    final error = _displaySetupLinkController.pendingError;
    if (error != null) {
      _displaySetupLinkController.clearError();
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        final ctx = _navigatorKey.currentContext;
        if (ctx != null) {
          ScaffoldMessenger.of(
            ctx,
          ).showSnackBar(SnackBar(content: Text(error)));
        }
      });
      return;
    }

    final intent = _displaySetupLinkController.pendingIntent;
    if (intent == null) return;

    if (_sessionController.isSignedIn) {
      // State 3: already signed in — push confirmation page.
      _displaySetupFromLoggedOut = false;
      _maybeOpenDisplaySetupConfirmation(intent);
    } else if (!_sessionController.isRestoringSession) {
      // State 2: definitely not signed in — show landing page.
      setState(() => _displaySetupFromLoggedOut = true);
    }
    // If still restoring session, _onSessionChanged will handle it once
    // the session outcome is known.
  }

  void _onFollowLinkChanged() {
    if (_processingFollowLink) return;
    _processingFollowLink = true;

    try {
      final error = _followLinkController.pendingError;
      if (error != null) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!mounted) return;
          _followLinkController.clearError();
          final ctx = _navigatorKey.currentContext;
          if (ctx != null) {
            ScaffoldMessenger.of(
              ctx,
            ).showSnackBar(SnackBar(content: Text(error)));
          }
        });
        return;
      }

      final intent = _followLinkController.pendingIntent;
      if (intent != null) {
        if (_sessionController.isSignedIn) {
          _followLinkController.clearPending();
          _openSubscribeFlowForIntent(intent);
        } else {
          setState(() => _showingFollowSignIn = false);
        }
      }
    } finally {
      _processingFollowLink = false;
    }
  }

  void _onShoppingLinkChanged() {
    if (kDebugMode) debugPrint('[CaleeApp] _onShoppingLinkChanged called');
    _maybeOpenPendingShoppingLink();
  }

  /// Single entry point for reacting to a pending shopping-link intent,
  /// called from [_onShoppingLinkChanged], from the shopping branch of
  /// [_onSessionChanged] (after session restore/sign-in), and as a safety
  /// net right after [ShoppingLinkController.init] resolves.
  ///
  /// - No pending intent: no-op.
  /// - Session still restoring: no-op; whichever of the above call sites
  ///   fires next once the session outcome is known will re-evaluate.
  /// - Signed in: hands off to [_openShoppingListForIntent], which only
  ///   consumes the pending intent once the push is actually confirmed —
  ///   see that method's doc for why.
  /// - Definitely signed out: resets any stale sign-in/create-account
  ///   sub-screen so the build() method's pending-intent check shows a
  ///   fresh [ShoppingLinkLandingPage].
  void _maybeOpenPendingShoppingLink() {
    final intent = _shoppingLinkController.pendingIntent;
    if (kDebugMode) {
      debugPrint(
        '[CaleeApp] _maybeOpenPendingShoppingLink: pendingIntent=$intent, '
        'isSignedIn=${_sessionController.isSignedIn}, '
        'isRestoringSession=${_sessionController.isRestoringSession}',
      );
    }
    if (intent == null) return;

    if (_sessionController.isRestoringSession) {
      // Wait — re-evaluated once restore finishes and notifies listeners.
      return;
    }

    if (!_sessionController.isSignedIn) {
      // Reset any stale sub-screen so a fresh link always starts back at
      // the landing page rather than a leftover sign-in/create-account form.
      setState(() {
        _showingShoppingSignIn = false;
        _showingShoppingCreateAccount = false;
      });
      return;
    }

    final key = intent.canonicalKey;
    final now = DateTime.now();
    if (_lastOpenedShoppingKey == key &&
        _lastOpenedShoppingAt != null &&
        now.difference(_lastOpenedShoppingAt!) < const Duration(seconds: 5)) {
      // Same shopping target (regardless of HTTPS vs. calee:// scheme)
      // already opened moments ago — discard the redelivery.
      _shoppingLinkController.clearPending();
      return;
    }

    setState(() {
      _showingShoppingSignIn = false;
      _showingShoppingCreateAccount = false;
    });

    if (_shoppingPushInFlight) {
      // A retry loop for this same intent is already chasing a navigator
      // attach; don't start a second, overlapping one.
      return;
    }
    _shoppingPushInFlight = true;
    _openShoppingListForIntent(intent, key);
  }

  void _onExternalCalendarConnectedLinkChanged() {
    final intent = _externalCalendarConnectedLinkController.pendingIntent;
    if (intent == null) return;

    if (intent.isError) {
      _externalCalendarConnectedLinkController.clearPending();
      _showSnackBar('Google Calendar was not connected. Please try again.');
      return;
    }

    if (!intent.isGoogle) {
      _externalCalendarConnectedLinkController.clearPending();
      return;
    }

    if (!_sessionController.isSignedIn) {
      // Leave pendingIntent in place; _onSessionChanged will process it after restore.
      return;
    }

    // App-level dedup: ignore the same intent key within 5 seconds.
    final intentKey = [
      intent.providerKey ?? '',
      intent.connectionId ?? '',
    ].join('|');
    final now = DateTime.now();
    if (_lastExternalCalendarIntentKey == intentKey &&
        _lastExternalCalendarIntentAt != null &&
        now.difference(_lastExternalCalendarIntentAt!) <
            const Duration(seconds: 5)) {
      _externalCalendarConnectedLinkController.clearPending();
      return;
    }
    _lastExternalCalendarIntentKey = intentKey;
    _lastExternalCalendarIntentAt = now;

    _externalCalendarConnectedLinkController.clearPending();
    unawaited(_openGoogleCalendarSelectionFromDeepLink(intent));
  }

  Future<void> _openGoogleCalendarSelectionFromDeepLink(
    ExternalCalendarConnectedIntent intent,
  ) async {
    if (_openingGoogleCalendarSelection) return;
    _openingGoogleCalendarSelection = true;
    debugPrint(
      '[CaleeApp] external-calendar-connected: '
      'providerKey=${intent.providerKey}, connectionId=${intent.connectionId}',
    );
    debugPrint(
      '[CaleeApp] external-calendar-connected: about to load connections; '
      'isSignedIn=${_sessionController.isSignedIn}, '
      'isRestoringSession=${_sessionController.isRestoringSession}, '
      'hasAccessToken=${_sessionController.accessToken != null}, '
      'hasBootstrap=${_sessionController.bootstrap != null}',
    );

    try {
      final connections = await _loadConnectionsAfterOAuth();

      if (!mounted) {
        _openingGoogleCalendarSelection = false;
        return;
      }

      debugPrint(
        '[CaleeApp] external-calendar-connected: '
        'loaded ${connections.length} connections',
      );

      // Prefer the connection matching the deep-link connectionId; fall back to
      // the first active Google connection.
      final connectionId = intent.connectionId;
      ExternalCalendarConnection? connection;
      if (connectionId != null && connectionId.isNotEmpty) {
        connection = connections
            .where((c) => c.isGoogle && c.isActive && c.id == connectionId)
            .firstOrNull;
      }
      connection ??= connections
          .where((c) => c.isGoogle && c.isActive)
          .firstOrNull;

      if (connection == null) {
        debugPrint(
          '[CaleeApp] external-calendar-connected: '
          'no active Google connection found',
        );
        _openingGoogleCalendarSelection = false;
        _showSnackBar(
          'Google Calendar connection not found. Please try again.',
        );
        return;
      }

      debugPrint(
        '[CaleeApp] external-calendar-connected: '
        'found connection id=${connection.id}',
      );
      if (!GoogleCalendarSelectionGate.tryOpen()) {
        debugPrint(
          '[CaleeApp] external-calendar-connected: selection page already '
          'opened elsewhere; skipping duplicate navigation',
        );
        _openingGoogleCalendarSelection = false;
        return;
      }
      final resolvedConnection = connection;
      await CaleePreferences().saveCalendarOnboardingStatus(
        _sessionController.bootstrap!.account.id,
        CalendarOnboardingStatus.dismissedForever,
      );
      if (!mounted) {
        _openingGoogleCalendarSelection = false;
        return;
      }
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _openingGoogleCalendarSelection = false;
        if (!mounted) return;
        debugPrint(
          '[CaleeApp] external-calendar-connected: '
          'opening GoogleCalendarSelectionPage',
        );
        _navigatorKey.currentState?.push(
          MaterialPageRoute<void>(
            builder: (_) => GoogleCalendarSelectionPage(
              hubClient: _hubClient,
              accessToken: _sessionController.accessToken!,
              connection: resolvedConnection,
              onViewCalendar: _onOnboardingViewCalendar,
              onDone: () {
                _navigatorKey.currentState?.popUntil((r) => r.isFirst);
              },
            ),
          ),
        );
      });
    } on CaleeHubException catch (error, stackTrace) {
      _openingGoogleCalendarSelection = false;
      debugPrint(
        '[CaleeApp] external-calendar-connected failed: ${error.debugSummary}',
      );
      debugPrintStack(
        label: '[CaleeApp] external-calendar-connected stack',
        stackTrace: stackTrace,
      );
      if (!mounted) return;
      _showSnackBar(
        'Could not load Google Calendar connection. Please try again.',
      );
    } catch (error, stackTrace) {
      _openingGoogleCalendarSelection = false;
      debugPrint('[CaleeApp] external-calendar-connected failed: $error');
      debugPrintStack(
        label: '[CaleeApp] external-calendar-connected stack',
        stackTrace: stackTrace,
      );
      if (!mounted) return;
      _showSnackBar(
        'Could not load Google Calendar connection. Please try again.',
      );
    }
  }

  /// Loads external calendar connections after an OAuth return, with a
  /// transport reset before the first attempt and up to 3 attempts total on
  /// transient transport failures (e.g. stale HttpClient after returning from
  /// Chrome).
  Future<List<ExternalCalendarConnection>> _loadConnectionsAfterOAuth() async {
    const maxAttempts = 3;
    final delays = [Duration(milliseconds: 300), Duration(milliseconds: 800)];

    for (var attempt = 1; attempt <= maxAttempts; attempt++) {
      debugPrint(
        '[CaleeApp] _loadConnectionsAfterOAuth: '
        'attempt $attempt/$maxAttempts, resetting transport',
      );
      _hubClient.resetTransport();
      try {
        return await _hubClient.externalCalendarConnections(
          accessToken: _sessionController.accessToken!,
        );
      } catch (error) {
        final transient = _isTransientPostOAuthError(error);
        debugPrint(
          '[CaleeApp] _loadConnectionsAfterOAuth: '
          'attempt $attempt failed '
          '(transient=$transient, error=$error)',
        );
        if (!transient || attempt == maxAttempts) rethrow;
        await Future<void>.delayed(delays[attempt - 1]);
      }
    }
    // Unreachable: the loop either returns or rethrows.
    throw StateError('unreachable');
  }

  bool _isTransientPostOAuthError(Object error) {
    if (error is CaleeHubException) {
      return error.statusCode == 0 &&
          (error.code == 'NETWORK_ERROR' || error.code == 'TIMEOUT');
    }
    return false;
  }

  /// Single entry point for opening the signed-in display confirmation page,
  /// used by both [_onDisplaySetupLinkChanged] and [_onSessionChanged].
  ///
  /// Those listeners can fire for the same pending intent within one frame
  /// (link delivered while session restore finishes), and the intent stays
  /// pending while the page is shown, so every navigation goes through the
  /// guards here: at most one confirmation route may exist per token.
  void _maybeOpenDisplaySetupConfirmation(DisplaySetupIntent intent) {
    if (_activeDisplayConfirmationToken == intent.token) {
      // A confirmation route (or scheduled push) for this token already
      // exists — collapse the duplicate notification.
      return;
    }
    if (_displayConfirmationPushInFlight) {
      // A push for another token is mid-flight; its post-frame callback
      // re-reads pendingIntent and re-dispatches here, so a newer token
      // is picked up rather than lost.
      return;
    }
    // Claim the guards before scheduling the callback so a second
    // notification arriving in the same frame cannot schedule another one.
    _displayConfirmationPushInFlight = true;
    _activeDisplayConfirmationToken = intent.token;
    _pushDisplaySetupConfirmation(intent);
  }

  void _pushDisplaySetupConfirmation(DisplaySetupIntent intent) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) {
        _displayConfirmationPushInFlight = false;
        return;
      }
      // Re-validate: the intent may have been cancelled, consumed, or
      // replaced — and the session may have changed — between scheduling
      // and this frame firing.
      final pending = _displaySetupLinkController.pendingIntent;
      if (!_sessionController.isSignedIn ||
          pending == null ||
          pending.token != intent.token) {
        _displayConfirmationPushInFlight = false;
        if (_activeDisplayConfirmationToken == intent.token) {
          _activeDisplayConfirmationToken = null;
        }
        if (_sessionController.isSignedIn &&
            pending != null &&
            pending.token != intent.token) {
          // A different token replaced this one before the frame fired —
          // process it instead of dropping it.
          _maybeOpenDisplaySetupConfirmation(pending);
        }
        return;
      }
      final navigator = _navigatorKey.currentState;
      if (navigator == null) {
        // Very early cold-start frame before the Navigator attached — keep
        // the guards claimed and retry next frame (mirrors the shopping-link
        // retry) rather than dropping the link.
        WidgetsBinding.instance.scheduleFrame();
        _pushDisplaySetupConfirmation(intent);
        return;
      }

      _displayConfirmationPushInFlight = false;
      // Capture the account details now: the route's builder can re-run while
      // the page animates out (e.g. after "Use a different account" signs out
      // and clears accessToken), so reading _sessionController state inside the
      // builder would force-unwrap a stale/null value and crash.
      final accessToken = _sessionController.accessToken!;
      final accountEmail =
          _sessionController.bootstrap?.account.primaryEmail ?? '';
      unawaited(
        navigator
            .push(
              MaterialPageRoute<DisplaySetupConfirmationResult>(
                builder: (_) => DisplaySetupConfirmationPage(
                  token: intent.token,
                  accountEmail: accountEmail,
                  activationController: _displayActivationController,
                  accessToken: accessToken,
                ),
              ),
            )
            .then(
              (result) => _onDisplaySetupConfirmationClosed(intent, result),
            ),
      );
    });
  }

  /// Single authoritative cleanup path for a confirmation route closing,
  /// whether through an explicit button (typed result) or an implicit
  /// dismissal — Android system Back, [Navigator.maybePop], the iOS
  /// interactive back gesture, or any other pop with no result (`null`),
  /// all of which are treated as a cancellation.
  ///
  /// Cleanup is token-scoped so an older route closing can never disturb a
  /// newer pending intent: a token B that replaced token A while route A was
  /// still open must survive route A's teardown and be processed normally.
  Future<void> _onDisplaySetupConfirmationClosed(
    DisplaySetupIntent intent,
    DisplaySetupConfirmationResult? result,
  ) async {
    // Release the navigation guard — but only if it still belongs to this
    // route's token; a newer token may already own it.
    if (_activeDisplayConfirmationToken == intent.token) {
      _activeDisplayConfirmationToken = null;
    }

    // Null == implicit dismissal (system Back / maybePop / iOS swipe-back).
    final effective = result ?? DisplaySetupConfirmationResult.cancelled;

    switch (effective) {
      case DisplaySetupConfirmationResult.cancelled:
        // Clear the pending intent so a later session/link notification
        // cannot re-open the page — but only when it still matches this
        // route's token. If a newer token became pending while this route
        // was open, leave it untouched so it can be processed normally.
        final pending = _displaySetupLinkController.pendingIntent;
        if (pending != null && pending.token == intent.token) {
          _displaySetupLinkController.clearPending();
        }
      case DisplaySetupConfirmationResult.useDifferentAccount:
        // Keep the pending tablet token: after sign-out the landing page
        // picks it up so another account can finish activating this display.
        _displaySetupFromLoggedOut = true;
        _displaySetupThroughLandingPage = false;
        unawaited(_sessionController.signOut());
      case DisplaySetupConfirmationResult.activated:
        // The activation path consumes the matching token here. Do not clear
        // a newer intent that may have arrived meanwhile.
        final pending = _displaySetupLinkController.pendingIntent;
        if (pending != null && pending.token == intent.token) {
          _displaySetupLinkController.clearPending();
        }
        await _sessionController.refreshBootstrap();
        if (!mounted) return;
        _openDisplayActivationSuccess();
    }
  }

  Future<void> _activateDisplayAndShowSuccess(String token) async {
    final success = await _displayActivationController.activate(
      accessToken: _sessionController.accessToken!,
      token: token,
    );
    if (!mounted) return;
    if (!success) {
      _showSnackBar(
        _displayActivationController.errorMessage ??
            'Unable to connect the display. Please try again.',
      );
      return;
    }
    await _sessionController.refreshBootstrap();
    if (!mounted) return;
    _openDisplayActivationSuccess();
  }

  void _openDisplayActivationSuccess() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _navigatorKey.currentState?.push(
        MaterialPageRoute<void>(
          builder: (_) => DisplayActivationSuccessPage(
            hubClient: _hubClient,
            accessToken: _sessionController.accessToken!,
            services: _sessionController.bootstrap!.services,
            accountId: _sessionController.bootstrap!.account.id,
            onDone: () {
              Navigator.of(
                _navigatorKey.currentContext!,
              ).popUntil((r) => r.isFirst);
              unawaited(
                _checkAndShowOnboarding(
                  _sessionController.bootstrap!.account.id,
                ),
              );
            },
          ),
        ),
      );
    });
  }

  void _openSubscribeFlowForIntent(ResolvedCalendarFollowIntent intent) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _navigatorKey.currentState?.push(
        MaterialPageRoute<void>(
          builder: (_) => CalendarCollectionsPage(
            hubClient: _hubClient,
            accessToken: _sessionController.accessToken!,
            services: _sessionController.bootstrap!.services,
            accountId: _sessionController.bootstrap!.account.id,
            isFamilyUxContext: _sessionController.bootstrap!.isFamilyUxContext,
            autoOpenSubscribeForm: true,
            initialSubscriptionUrl: intent.url,
            initialSubscriptionName: intent.title,
          ),
        ),
      );
    });
  }

  /// Pushes [ShoppingPage] for [intent], but only *consumes* the pending
  /// intent (clearing it and recording [key] as opened) once the navigator
  /// is actually confirmed available and the push is issued.
  ///
  /// If `_navigatorKey.currentState` is still null when the post-frame
  /// callback fires (e.g. a very early cold-start frame before the
  /// `Navigator` has attached), the pending intent is left untouched and
  /// this retries on the next frame rather than silently dropping the
  /// link — clearing the intent before a confirmed push was the root cause
  /// of the original intermittent failures.
  void _openShoppingListForIntent(ShoppingLinkIntent intent, String key) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) {
        _shoppingPushInFlight = false;
        return;
      }
      final navigator = _navigatorKey.currentState;
      if (navigator == null) {
        if (kDebugMode) {
          debugPrint(
            '[CaleeApp] _openShoppingListForIntent: navigator not yet '
            'attached, retrying next frame',
          );
        }
        WidgetsBinding.instance.scheduleFrame();
        _openShoppingListForIntent(intent, key);
        return;
      }

      _lastOpenedShoppingKey = key;
      _lastOpenedShoppingAt = DateTime.now();
      _shoppingLinkController.clearPending();
      _shoppingPushInFlight = false;

      if (kDebugMode) {
        debugPrint(
          '[CaleeApp] pushing ShoppingPage: '
          'initialWeekStart=${intent.weekStart}, autoGenerate=false',
        );
      }
      navigator.push(
        MaterialPageRoute<void>(
          builder: (_) => ShoppingPage(
            hubClient: _hubClient,
            accessToken: _sessionController.accessToken!,
            initialWeekStart: intent.weekStart,
            autoGenerate: false,
          ),
        ),
      );
    });
  }

  Future<void> _checkAndShowOnboarding(String accountId) async {
    setState(() {
      _checkingOnboarding = true;
      _showingOnboarding = false;
    });
    final status = await CaleePreferences().loadCalendarOnboardingStatus(
      accountId,
    );
    if (!mounted) return;
    setState(() {
      _checkingOnboarding = false;
      _showingOnboarding = shouldShowCalendarOnboarding(
        status: status,
        hasPendingCalendarFollowIntent:
            _followLinkController.pendingIntent != null,
      );
    });
  }

  void _onOnboardingDone() {
    setState(() {
      _showingOnboarding = false;
      _checkingOnboarding = false;
      _initialHomeTab = null;
    });
  }

  void _onOnboardingViewCalendar() {
    setState(() {
      _showingOnboarding = false;
      _checkingOnboarding = false;
      _initialHomeTab = _kCalendarTabIndex;
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _navigatorKey.currentState?.popUntil((route) => route.isFirst);
    });
  }

  void _showSnackBar(String message) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final context = _navigatorKey.currentContext;
      if (context == null) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(message)));
    });
  }

  Future<void> _handleFollowLocally(ResolvedCalendarFollowIntent intent) async {
    try {
      await _localSubscriptionRepo.add(
        title: intent.title,
        url: intent.url,
        source: intent.source,
      );
    } catch (_) {
      if (!mounted) return;
      _showSnackBar('This calendar could not be added on this phone.');
      return;
    }

    _followLinkController.clearPending();
    final updated = await _localSubscriptionRepo.list();
    if (!mounted) return;
    setState(() {
      _localSubscriptions = updated;
      _showingFollowSignIn = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Calee',
      debugShowCheckedModeBanner: false,
      navigatorKey: _navigatorKey,
      theme: CaleeTheme.buildThemeData(),
      home: AnimatedBuilder(
        animation: Listenable.merge([
          _sessionController,
          _followLinkController,
          _displaySetupLinkController,
          _shoppingLinkController,
        ]),
        builder: (context, _) => _buildHome(),
      ),
      // app_links is the sole ingress path for deep links (including
      // native-login display-setup links) now that Flutter's built-in deep
      // link handling is disabled — see FlutterDeepLinkingEnabled/
      // flutter_deeplinking_enabled in the platform manifests. This fallback
      // only prevents a crash if Flutter's navigator is ever asked to
      // resolve an unrecognised route name; it must not independently parse
      // or accept display-setup links.
      onUnknownRoute: (settings) => MaterialPageRoute<void>(
        settings: const RouteSettings(name: '/'),
        builder: (_) => AnimatedBuilder(
          animation: Listenable.merge([
            _sessionController,
            _followLinkController,
            _displaySetupLinkController,
            _shoppingLinkController,
          ]),
          builder: (context, _) => _buildHome(),
        ),
      ),
    );
  }

  Widget _buildHome() {
    if (_sessionController.isRestoringSession || !_localSubscriptionsLoaded) {
      return const _SessionRestorePage();
    }

    if (!_sessionController.isSignedIn) {
      // ── Display setup flows (state 2) ───────────────────────────────────────────────────────

      // Create account from display setup landing.
      if (_showingDisplaySetupCreateAccount) {
        return CreateAccountPage(
          authRepository: _sessionController.repository,
          onCancel: () =>
              setState(() => _showingDisplaySetupCreateAccount = false),
          onAccountCreated: (result) async {
            final hasPendingDisplayIntent =
                _displaySetupLinkController.pendingIntent != null;
            setState(() {
              _showingDisplaySetupCreateAccount = false;
              // Only show QR scan (state 4) when there is no display intent to activate.
              _justRegistered = !hasPendingDisplayIntent;
            });
            await _sessionController.completeSignIn(result);
            unawaited(_sessionController.refreshBootstrap());
            unawaited(
              applyPostRegistrationProfileDefaults(
                hubClient: _hubClient,
                accessToken: result.accessToken,
                provider:
                    widget._testDeps?.deviceProfileDefaultsProvider ??
                    DeviceProfileDefaultsProvider(),
              ),
            );
          },
        );
      }

      // Sign-in from display setup landing (intent preserved).
      if (_showingDisplaySetupSignIn &&
          _displaySetupLinkController.pendingIntent != null) {
        return LoginPage(
          authRepository: _sessionController.repository,
          onCancel: () => setState(() => _showingDisplaySetupSignIn = false),
          onSignedIn: (result) async {
            setState(() => _showingDisplaySetupSignIn = false);
            await _sessionController.completeSignIn(result);
            unawaited(_sessionController.refreshBootstrap());
          },
        );
      }

      // Display setup landing (intent arrived while definitely logged out).
      if (_displaySetupLinkController.pendingIntent != null &&
          _displaySetupFromLoggedOut) {
        return DisplaySetupLandingPage(
          onCreateAccount: () => setState(() {
            _displaySetupThroughLandingPage = true;
            _showingDisplaySetupCreateAccount = true;
          }),
          onSignIn: () => setState(() {
            _displaySetupThroughLandingPage = true;
            _showingDisplaySetupSignIn = true;
          }),
          onCancel: () {
            setState(() {
              _displaySetupFromLoggedOut = false;
              _displaySetupThroughLandingPage = false;
            });
            _displaySetupLinkController.clearPending();
          },
        );
      }

      // ── Calendar follow flows ─────────────────────────────────────────────────────────────────────

      // User chose "Add to Calee" → show login (pending intent present, skip onboarding)
      if (_showingFollowSignIn) {
        return LoginPage(
          authRepository: _sessionController.repository,
          onCancel: () => setState(() => _showingFollowSignIn = false),
          onSignedIn: (result) async {
            setState(() => _showingFollowSignIn = false);
            await _sessionController.completeSignIn(result);
            unawaited(_sessionController.refreshBootstrap());
          },
        );
      }

      // Pending follow intent → show follow page
      final pendingFollowIntent = _followLinkController.pendingIntent;
      if (pendingFollowIntent != null) {
        final normalizedIntentUrl =
            pendingFollowIntent.url.startsWith('webcal://')
            ? 'https://${pendingFollowIntent.url.substring('webcal://'.length)}'
            : pendingFollowIntent.url;
        final alreadyFollowed = _localSubscriptions.any(
          (s) => s.url == normalizedIntentUrl,
        );

        return FollowCalendarPage(
          intent: pendingFollowIntent,
          alreadyFollowed: alreadyFollowed,
          onSignIn: () => setState(() => _showingFollowSignIn = true),
          onFollowLocally: alreadyFollowed
              ? () {
                  _followLinkController.clearPending();
                  WidgetsBinding.instance.addPostFrameCallback((_) {
                    if (!mounted) return;
                    final ctx = _navigatorKey.currentContext;
                    if (ctx != null) {
                      ScaffoldMessenger.of(ctx).showSnackBar(
                        const SnackBar(
                          content: Text(
                            'This calendar is already added on this phone.',
                          ),
                        ),
                      );
                    }
                  });
                }
              : () => _handleFollowLocally(pendingFollowIntent),
          onCancel: () {
            _followLinkController.clearPending();
          },
        );
      }

      // ── Shopping link flows ───────────────────────────────────────────────────────────────

      // Create account from shopping link landing.
      if (_showingShoppingCreateAccount) {
        return CreateAccountPage(
          authRepository: _sessionController.repository,
          onCancel: () => setState(() => _showingShoppingCreateAccount = false),
          onAccountCreated: (result) async {
            setState(() => _showingShoppingCreateAccount = false);
            await _sessionController.completeSignIn(result);
            unawaited(_sessionController.refreshBootstrap());
          },
        );
      }

      // Sign-in from shopping link landing (intent preserved).
      if (_showingShoppingSignIn) {
        return LoginPage(
          authRepository: _sessionController.repository,
          onCancel: () => setState(() => _showingShoppingSignIn = false),
          onSignedIn: (result) async {
            setState(() => _showingShoppingSignIn = false);
            await _sessionController.completeSignIn(result);
            unawaited(_sessionController.refreshBootstrap());
          },
        );
      }

      // Pending shopping intent → ask the user to sign in before opening it.
      if (_shoppingLinkController.pendingIntent != null) {
        return ShoppingLinkLandingPage(
          onCreateAccount: () =>
              setState(() => _showingShoppingCreateAccount = true),
          onSignIn: () => setState(() => _showingShoppingSignIn = true),
          onCancel: () => _shoppingLinkController.clearPending(),
        );
      }

      // Has local subscriptions → show local subscriber screen
      if (_localSubscriptions.isNotEmpty) {
        return LocalSubscriberCalendarPage(
          subscriptions: _localSubscriptions,
          repository: _localSubscriptionRepo,
          onSignIn: () => setState(() => _showingFollowSignIn = true),
          onSubscriptionsChanged: (updated) {
            setState(() => _localSubscriptions = updated);
          },
        );
      }

      // Welcome → "I already have an account" path
      if (_showingSignInFromWelcome) {
        return LoginPage(
          authRepository: _sessionController.repository,
          onCancel: () => setState(() => _showingSignInFromWelcome = false),
          onSignedIn: (result) async {
            final hasPendingIntent =
                _followLinkController.pendingIntent != null;
            setState(() {
              _showingSignInFromWelcome = false;
              _showingFollowSignIn = false;
            });
            await _sessionController.completeSignIn(result);
            unawaited(_sessionController.refreshBootstrap());
            if (!hasPendingIntent) {
              setState(() => _showingConnectDisplayAfterAuth = true);
            }
          },
        );
      }

      // Welcome → "Create account" path
      if (_showingCreateAccountFromWelcome) {
        return CreateAccountPage(
          authRepository: _sessionController.repository,
          onCancel: () =>
              setState(() => _showingCreateAccountFromWelcome = false),
          onAccountCreated: (result) async {
            setState(() {
              _showingCreateAccountFromWelcome = false;
              _justRegistered = true;
            });
            await _sessionController.completeSignIn(result);
            unawaited(_sessionController.refreshBootstrap());
            unawaited(
              applyPostRegistrationProfileDefaults(
                hubClient: _hubClient,
                accessToken: result.accessToken,
                provider:
                    widget._testDeps?.deviceProfileDefaultsProvider ??
                    DeviceProfileDefaultsProvider(),
              ),
            );
          },
        );
      }

      // Default first-run screen for signed-out users with no pending intent
      return WelcomePage(
        onCreateAccount: () =>
            setState(() => _showingCreateAccountFromWelcome = true),
        onSignIn: () => setState(() => _showingSignInFromWelcome = true),
      );
    }

    // ── Signed-in flows ────────────────────────────────────────────────────────────────

    // Show loading spinner while checking onboarding status after fresh sign-in
    if (_checkingOnboarding) return const _SessionRestorePage();

    if (_showingConnectDisplayAfterAuth) {
      return ConnectDisplayPage(
        hubClient: _hubClient,
        accessToken: _sessionController.accessToken!,
        services: _sessionController.bootstrap!.services,
        accountId: _sessionController.bootstrap!.account.id,
        onDone: () {
          setState(() => _showingConnectDisplayAfterAuth = false);
          unawaited(
            _checkAndShowOnboarding(_sessionController.bootstrap!.account.id),
          );
        },
      );
    }

    if (_showingOnboarding) {
      return CalendarOnboardingPage(
        hubClient: _hubClient,
        accessToken: _sessionController.accessToken!,
        services: _sessionController.bootstrap!.services,
        accountId: _sessionController.bootstrap!.account.id,
        onDismissed: _onOnboardingDone,
        onViewCalendar: _onOnboardingViewCalendar,
      );
    }

    return CaleeHomePage(
      hubClient: _hubClient,
      accessToken: _sessionController.accessToken!,
      bootstrap: _sessionController.bootstrap!,
      onSignOut: () => _sessionController.signOut(),
      onBootstrapRefreshed: _sessionController.updateBootstrap,
      reminderCoordinator: _reminderCoordinator,
      initialSelectedIndex: _initialHomeTab ?? 0,
      onInitialTabConsumed: _initialHomeTab != null
          ? () => setState(() => _initialHomeTab = null)
          : null,
    );
  }
}

class _SessionRestorePage extends StatelessWidget {
  const _SessionRestorePage();

  @override
  Widget build(BuildContext context) {
    return const Scaffold(
      body: SafeArea(child: Center(child: CircularProgressIndicator())),
    );
  }
}

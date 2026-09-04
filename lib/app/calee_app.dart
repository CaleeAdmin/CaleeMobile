// ignore_for_file: prefer_initializing_formals
import 'dart:async';

import 'package:flutter/foundation.dart' show kDebugMode;
import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart' as url_launcher;

import '../config/calee_environment.dart';
import '../config/calee_links.dart';
import '../data/api/calee_hub_client.dart';
import '../data/auth/calee_preferences.dart';
import '../data/auth/session_store.dart';
import '../data/models/client_bootstrap.dart';
import '../features/auth/auth_repository.dart';
import '../features/auth/create_account_page.dart';
import '../features/auth/login_page.dart';
import '../features/auth/post_registration_profile_defaults.dart';
import '../features/auth/session_controller.dart';
import '../data/account_deletion/account_deletion_recovery_store.dart';
import '../features/account_deletion/account_deletion_controller.dart';
import '../features/account_deletion/account_deletion_status_page.dart';
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
import '../features/local_subscriber/local_calendar_limit_page.dart';
import '../features/local_subscriber/local_calendar_subscription.dart';
import '../features/notifications/calendar_notification_candidates.dart';
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
    this.accountDeletionController,
    this.launchExternalUrl,
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

  /// Replaces the Account Deletion V1 lifecycle (#556) so widget tests can
  /// drive deletion phases without the secure store or the Hub. Null in
  /// production and in the many tests that do not exercise deletion, where the
  /// real controller is built and simply finds no pending operation.
  final AccountDeletionController? accountDeletionController;

  /// Replaces `url_launcher`'s launchUrl so tests can observe external
  /// navigation (e.g. the Calee-for-home marketing page) without platform
  /// channels. Returns whether the URL was opened.
  final Future<bool> Function(Uri url)? launchExternalUrl;
}

/// A deletion recovery store that holds nothing and answers immediately.
///
/// Used ONLY when [CaleeApp.forTesting] is given no
/// [CaleeAppTestDependencies.accountDeletionController]. An unmocked
/// `flutter_secure_storage` channel never replies under
/// `TestDefaultBinaryMessenger`, so a widget test that has nothing to do with
/// deletion would otherwise hang on the startup read. Tests that DO exercise
/// deletion inject their own controller, with their own store.
///
/// Never reachable from production: the const [AccountDeletionRecoveryStore]
/// default keeps the real platform secure store there.
class _EmptyAccountDeletionStorage implements AccountDeletionSecureStorage {
  const _EmptyAccountDeletionStorage();

  @override
  Future<String?> read(String key) async => null;

  @override
  Future<void> write(String key, String value) async {}

  @override
  Future<void> delete(String key) async {}
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
  late final AccountDeletionController _accountDeletionController;
  final _navigatorKey = GlobalKey<NavigatorState>();

  // Whether the one local read that decides deletion precedence has happened.
  // Startup shows the restore spinner until it has: an operation that may
  // exist must never be hidden, even for one frame, behind login/onboarding.
  bool _accountDeletionRestored = false;

  // Whether the deletion lifecycle owned the whole app surface at the last
  // notification. Used to detect the moment it takes over, which is when any
  // pushed route (Settings, the delete-account flow) has to come off the
  // navigator — switching `home` alone would leave them sitting on top.
  bool _accountDeletionOwnedSurface = false;

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

  // Non-null while the sixth-unique-calendar conversion experience is shown.
  // Set only from the typed LocalCalendarSubscriptionLimitException, never
  // from a parser/storage/network failure, and never itself a mutation: the
  // five stored calendars are untouched for as long as it is set. The pending
  // follow intent deliberately stays pending underneath, so opening the
  // marketing page and returning restores this same screen.
  LocalCalendarSubscriptionLimitException? _localCalendarLimit;

  // True while the user is managing their local calendars *as a step inside*
  // a pending calendar-follow attempt — entered from the limit screen's
  // "Manage my calendars" action.
  //
  // The pending follow intent deliberately stays pending for the whole
  // session: it remains the single source of truth for which calendar the
  // user was trying to follow, so no second copy of the URL exists. Closing
  // the management sheet ends the session and hands the user back to the
  // decision page for that same calendar, where they confirm the add
  // themselves — nothing is ever added behind their back.
  //
  // Only meaningful while a follow intent is pending; every path that
  // releases the intent also clears this (see _abandonPendingFollowAttempt
  // and _onFollowLinkChanged).
  bool _managingLocalCalendarsForFollowIntent = false;

  // Sign-in initiated from the local-calendar page's app-bar action.
  // Deliberately distinct from _showingFollowSignIn: there is no pending
  // calendar-follow intent to preserve, and signing in must never migrate,
  // link, or clear the locally stored subscriptions.
  bool _showingLocalCalendarSignIn = false;

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

    // Account Deletion V1 (#556). `endOrdinarySession` is deliberately the
    // app's EXISTING sign-out, not a second auth mechanism: it clears the Hub
    // access/refresh tokens and the auth cache, and leaves the deletion
    // recovery record — which lives outside SessionStore precisely so it
    // survives this — untouched.
    _accountDeletionController =
        testDeps?.accountDeletionController ??
        AccountDeletionController(
          hubClient: _hubClient,
          endOrdinarySession: _sessionController.signOut,
          recoveryStore: testDeps == null
              ? const AccountDeletionRecoveryStore()
              : const AccountDeletionRecoveryStore(
                  storage: _EmptyAccountDeletionStorage(),
                ),
        );

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
    _accountDeletionController.addListener(_onAccountDeletionChanged);

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

    unawaited(_startup());
    unawaited(_loadLocalSubscriptions());
  }

  /// Startup, in the order precedence requires.
  ///
  /// The deletion recovery read comes FIRST and is local-only, so a pending
  /// operation is never hidden behind ordinary session restoration — and a
  /// device with no recovery material never pays for a status read. Ordinary
  /// restoration is skipped entirely when a deletion owns the launch: normal
  /// Hub credentials must not reopen the signed-in app merely to watch it.
  Future<void> _startup() async {
    await _accountDeletionController.restore();
    if (!mounted) return;
    setState(() => _accountDeletionRestored = true);

    if (_accountDeletionController.ownsAppSurface) {
      // Off the startup path: the network read must not gate the first frame.
      unawaited(_accountDeletionController.refreshStatus());
      return;
    }

    await _sessionController.restoreSession();
  }

  /// Rebuilds for a deletion phase change, and clears the navigator the moment
  /// the deletion lifecycle takes over the whole app.
  void _onAccountDeletionChanged() {
    if (!mounted) return;
    final ownsSurface = _accountDeletionController.ownsAppSurface;
    if (ownsSurface && !_accountDeletionOwnedSurface) {
      // Settings and the delete-account flow were pushed above `home`, so
      // changing `home` would leave them on screen over the recovery surface.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _navigatorKey.currentState?.popUntil((route) => route.isFirst);
      });
    }
    _accountDeletionOwnedSurface = ownsSurface;
    setState(() {});
  }

  /// Hands the app back to ordinary signed-out Calee after a terminal
  /// deletion outcome.
  ///
  /// The Hub tokens are already gone, so this lands on the normal signed-out
  /// experience — the Guest/local calendar screen when this device has
  /// subscriptions, the welcome screen when it does not. Neither was touched
  /// by the deletion.
  Future<void> _onAccountDeletionFinished() async {
    await _sessionController.restoreSession();
    if (mounted) setState(() {});
  }

  /// Retries the deletion recovery read after the secure store was unreachable
  /// at launch. An unreadable Keychain is not evidence of a deletion, so
  /// ordinary UX continued — but it must not be assumed empty forever.
  Future<void> _retryAccountDeletionRestore() async {
    await _accountDeletionController.restore();
    if (!mounted) return;
    if (_accountDeletionController.ownsAppSurface) {
      unawaited(_accountDeletionController.refreshStatus());
    }
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
    _accountDeletionController.removeListener(_onAccountDeletionChanged);
    _followLinkController.dispose();
    _displaySetupLinkController.dispose();
    _externalCalendarConnectedLinkController.dispose();
    _shoppingLinkController.dispose();
    _displayActivationController.dispose();
    _accountDeletionController.dispose();
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
      if (_accountDeletionController.restoreDeferred) {
        unawaited(_retryAccountDeletionRestore());
      } else if (_accountDeletionController.ownsAppSurface) {
        // A deletion may have advanced (or finished) while backgrounded.
        unawaited(_accountDeletionController.refreshStatus());
      }
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

    // Signed in, but the bootstrap (hence the account ID) may not be available
    // yet, or may be momentarily blank. Never substitute an empty string: an
    // invalid identity must not begin a session, store an empty owner, or fire a
    // refresh — and, critically, must NOT invalidate an already-valid session
    // (a duplicate transient callback without bootstrap is a no-op here). A
    // later notification carrying a valid bootstrap starts the session normally.
    final accountId = _sessionController.bootstrap?.account.id;
    if (!isValidReminderAccountId(accountId)) return;
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
      nextAccountId: accountId!,
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
  /// navigation, and without surfacing failures.
  ///
  /// No-op unless there is BOTH a signed-in session with an access token AND an
  /// active account-owned reminder session in the coordinator. Being signed in
  /// is not sufficient: on resume (or restore) before the bootstrap/account
  /// identity is available there is no valid reminder session yet, and firing
  /// would run the null-owner legacy path. The session listener begins the
  /// reminder session and fires the initial refresh once a valid account
  /// arrives.
  void _fireReminderRefresh(CalendarReminderRefreshReason reason) {
    final token = _sessionController.accessToken;
    if (token == null || !_sessionController.isSignedIn) return;
    if (!_reminderCoordinator.hasActiveSession) return;
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
          // A newly arrived intent supersedes any attempt still in progress.
          // The controller has already replaced pendingIntent, so the old
          // attempt's screens must not be left standing over the new one:
          // both the limit screen (which would show a stale calendar name)
          // and any open calendar-management session are ended here, and the
          // new intent gets its own decision page.
          final wasManagingCalendars = _managingLocalCalendarsForFollowIntent;
          setState(() {
            _showingFollowSignIn = false;
            _localCalendarLimit = null;
            _managingLocalCalendarsForFollowIntent = false;
          });
          if (wasManagingCalendars) {
            // The management sheet is a route pushed over the declarative
            // home, so rebuilding home does not remove it. Dismiss it
            // explicitly, or it would sit on top of the new decision page.
            _dismissRoutesAboveHome();
          }
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

  /// Pops anything sitting above the declarative home route (the calendar
  /// management sheet, and any dialog over it).
  ///
  /// `_buildHome` swaps the *content* of the home route, which leaves pushed
  /// routes untouched — so a state change that replaces the screen underneath
  /// an open sheet has to dismiss that sheet itself. Deferred to after the
  /// frame because this runs from controller notifications, which can arrive
  /// mid-build.
  void _dismissRoutesAboveHome() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _navigatorKey.currentState?.popUntil((route) => route.isFirst);
    });
  }

  /// Abandons the sixth-calendar attempt entirely: drops the limit screen,
  /// ends any calendar-management session opened for it, and releases the
  /// pending follow intent.
  ///
  /// Never touches stored subscriptions — the calendars already on the phone
  /// are exactly as they were.
  void _abandonPendingFollowAttempt() {
    setState(() {
      _localCalendarLimit = null;
      _managingLocalCalendarsForFollowIntent = false;
    });
    _followLinkController.clearPending();
  }

  Future<void> _handleFollowLocally(ResolvedCalendarFollowIntent intent) async {
    try {
      await _localSubscriptionRepo.add(
        title: intent.title,
        url: intent.url,
        source: intent.source,
      );
    } on LocalCalendarSubscriptionLimitException catch (limit) {
      // The local allowance is full and this is a genuinely new calendar —
      // a product condition, not a failure, so it gets the contextual
      // conversion experience instead of the error snackbar. Nothing was
      // stored, nothing was removed, and the pending intent is deliberately
      // left in place.
      if (!mounted) return;
      setState(() => _localCalendarLimit = limit);
      return;
    } catch (_) {
      if (!mounted) return;
      _showSnackBar('This calendar could not be added on this phone.');
      return;
    }

    // Only a successfully stored subscription consumes the pending intent.
    _followLinkController.clearPending();
    final updated = await _localSubscriptionRepo.list();
    if (!mounted) return;
    setState(() {
      _localSubscriptions = updated;
      _showingFollowSignIn = false;
    });
    // Post-frame via _showSnackBar, so the local calendar page's Scaffold is
    // mounted before the temporary confirmation appears.
    _showSnackBar('Calendar added to this phone');
  }

  /// Low-level sign-in completion shared by the existing-customer entry
  /// points: establishes the session and starts the existing background
  /// bootstrap refresh. Never decides what is shown next — each entry point
  /// owns its own post-login routing — and never marks the user as newly
  /// registered or touches locally stored calendar subscriptions.
  Future<void> _completeSignInSession(ClientLoginResult result) async {
    await _sessionController.completeSignIn(result);
    unawaited(_sessionController.refreshBootstrap());
  }

  /// Welcome-page "I already have an account" completion.
  ///
  /// Preserves the historical behaviour of this entry point: unless a pending
  /// calendar-follow intent is about to be processed, the user is offered the
  /// connect-display step after authenticating.
  Future<void> _completeWelcomeSignIn(ClientLoginResult result) async {
    final hasPendingIntent = _followLinkController.pendingIntent != null;
    setState(() {
      _showingSignInFromWelcome = false;
      _showingFollowSignIn = false;
    });
    await _completeSignInSession(result);
    if (!mounted) return;
    if (!hasPendingIntent) {
      setState(() => _showingConnectDisplayAfterAuth = true);
    }
  }

  /// Local-calendar page Sign in completion, for an existing Calee Home
  /// customer who already has a display at home.
  ///
  /// Deliberately does NOT offer the connect-display step: this customer is
  /// signing in to reach their existing household, so authentication must
  /// land them in the normal signed-in Calee experience rather than routing
  /// them through display setup. It also leaves the phone-only calendar
  /// subscriptions completely untouched — no migration, account-linking, or
  /// removal — so they are still there after a later sign-out.
  Future<void> _completeLocalCalendarSignIn(ClientLoginResult result) async {
    setState(() => _showingLocalCalendarSignIn = false);
    await _completeSignInSession(result);
    // No _showingConnectDisplayAfterAuth, no follow-intent or local
    // subscription changes: the normal signed-in build path now renders.
  }

  /// Opens the Calee-for-home marketing site in the external browser. Never
  /// consumes a pending calendar-follow intent and never touches the session,
  /// so returning to the app restores the same decision state.
  Future<void> _openCaleeForHome() async {
    final launch =
        widget._testDeps?.launchExternalUrl ??
        (Uri url) => url_launcher.launchUrl(
          url,
          mode: url_launcher.LaunchMode.externalApplication,
        );
    var opened = false;
    try {
      opened = await launch(Uri.parse(kCaleeForHomeUrl));
    } catch (_) {
      opened = false;
    }
    if (!opened && mounted) {
      _showSnackBar('Could not open Calee for your home. Please try again.');
    }
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
          _accountDeletionController,
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
            _accountDeletionController,
          ]),
          builder: (context, _) => _buildHome(),
        ),
      ),
    );
  }

  Widget _buildHome() {
    // ── Account deletion (#556) ─────────────────────────────────────────────
    //
    // Ahead of EVERY other surface: session restoration, ordinary sign-in,
    // onboarding, and the Guest/local-calendar experience. An operation that
    // may exist must not be hidden behind login, and normal Hub credentials
    // must not reopen the signed-in app merely to view deletion status.
    //
    // Guest/device-local state is only hidden, never touched: once the
    // deletion reaches a terminal state the signed-out experience returns with
    // the same local calendars it had.
    if (!_accountDeletionRestored) return const _SessionRestorePage();
    if (_accountDeletionController.ownsAppSurface) {
      return AccountDeletionStatusPage(
        controller: _accountDeletionController,
        onFinished: () => unawaited(_onAccountDeletionFinished()),
      );
    }

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

      // Sixth unique calendar attempted while the local allowance is full.
      // Checked ahead of the decision page because the pending intent is
      // still pending underneath: leaving the marketing site returns the
      // user to this same screen rather than silently re-adding anything.
      final localCalendarLimit = _localCalendarLimit;
      if (localCalendarLimit != null) {
        return LocalCalendarLimitPage(
          limit: localCalendarLimit,
          // Marketing only: no intent consumed, no sign-in, no change to the
          // stored calendars.
          onSeeCaleeForHome: () => unawaited(_openCaleeForHome()),
          // Into the existing local-calendar management UI with its
          // "Calendars on this phone" sheet already open, so a calendar can
          // be removed to make room. The attempt is *not* abandoned: the
          // pending intent stays pending, and closing the sheet returns the
          // user to this calendar's decision page to confirm the add.
          onManageCalendars: () => setState(() {
            _localCalendarLimit = null;
            _managingLocalCalendarsForFollowIntent = true;
          }),
          // "Not now": abandon the attempt and return to the calendars
          // already on this phone, all five untouched.
          onDismiss: _abandonPendingFollowAttempt,
        );
      }

      // Managing local calendars as a step inside a pending follow attempt.
      // Sits ahead of the decision page for as long as the session lasts, and
      // is guarded on the intent so it can never outlive it. Closing the
      // sheet ends the session and falls through to the decision page below,
      // for the same calendar the user was originally trying to follow.
      if (_managingLocalCalendarsForFollowIntent &&
          _followLinkController.pendingIntent != null) {
        return LocalSubscriberCalendarPage(
          subscriptions: _localSubscriptions,
          repository: _localSubscriptionRepo,
          onSignIn: () => setState(() => _showingLocalCalendarSignIn = true),
          onLearnAboutHome: () => unawaited(_openCaleeForHome()),
          onSubscriptionsChanged: (updated) {
            setState(() => _localSubscriptions = updated);
          },
          openCalendarsSheetOnStart: true,
          onCalendarsSheetClosed: () =>
              setState(() => _managingLocalCalendarsForFollowIntent = false),
        );
      }

      // User chose "Already have Calee at home? Sign in" → show login. The
      // pending follow intent stays untouched so the account-backed
      // subscription flow can process it after authentication.
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
          onAddToPhone: () =>
              unawaited(_handleFollowLocally(pendingFollowIntent)),
          // Releasing the pending intent reveals the existing local calendar
          // page; the repository already de-duplicates, so no second
          // subscription can be created from this state.
          onOpenLocalCalendar: _abandonPendingFollowAttempt,
          onLearnAboutHome: () => unawaited(_openCaleeForHome()),
          onExistingCustomerSignIn: () =>
              setState(() => _showingFollowSignIn = true),
          onCancel: _abandonPendingFollowAttempt,
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

      // Sign-in requested from the local-calendar page (existing Calee Home
      // customers). No follow intent is involved, and the locally stored
      // subscriptions are left exactly as they are: cancel returns to the
      // local calendar page, success continues into the normal signed-in
      // Calee Home experience.
      if (_showingLocalCalendarSignIn) {
        return LoginPage(
          authRepository: _sessionController.repository,
          onCancel: () => setState(() => _showingLocalCalendarSignIn = false),
          onSignedIn: _completeLocalCalendarSignIn,
        );
      }

      // Has local subscriptions → show local subscriber screen
      if (_localSubscriptions.isNotEmpty) {
        return LocalSubscriberCalendarPage(
          subscriptions: _localSubscriptions,
          repository: _localSubscriptionRepo,
          onSignIn: () => setState(() => _showingLocalCalendarSignIn = true),
          onLearnAboutHome: () => unawaited(_openCaleeForHome()),
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
          onSignedIn: _completeWelcomeSignIn,
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
      accountDeletionController: _accountDeletionController,
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

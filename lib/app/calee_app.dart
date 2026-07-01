// ignore_for_file: prefer_initializing_formals
import 'dart:async';

import 'package:flutter/material.dart';

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
import '../features/onboarding/welcome_page.dart';
import '../features/local_subscriber/local_calendar_subscription_repository.dart';
import '../features/local_subscriber/local_subscriber_calendar_page.dart';
import '../features/settings/calendar_collections_page.dart';
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
    this.deviceProfileDefaultsProvider,
  });

  final CaleeHubClient hubClient;
  final SessionController sessionController;
  final DisplaySetupLinkController displaySetupLinkController;
  final CalendarFollowLinkController followLinkController;
  final DisplayActivationController displayActivationController;
  final LocalCalendarSubscriptionRepository localSubscriptionRepo;
  final ExternalCalendarConnectedLinkController?
  externalCalendarConnectedLinkController;
  final DeviceProfileDefaultsProvider? deviceProfileDefaultsProvider;
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
  late final DisplayActivationController _displayActivationController;
  late final LocalCalendarSubscriptionRepository _localSubscriptionRepo;
  final _navigatorKey = GlobalKey<NavigatorState>();

  // Set to true when the app goes to background; cleared and transport reset on resume.
  bool _transportMayBeStale = false;

  // Calendar follow state
  bool _showingFollowSignIn = false;
  bool _processingFollowLink = false;

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
    final testDeps = widget._testDeps;
    if (testDeps != null) {
      _hubClient = testDeps.hubClient;
      _sessionController = testDeps.sessionController;
      _followLinkController = testDeps.followLinkController;
      _displaySetupLinkController = testDeps.displaySetupLinkController;
      _externalCalendarConnectedLinkController =
          testDeps.externalCalendarConnectedLinkController ??
          ExternalCalendarConnectedLinkController();
      _displayActivationController = testDeps.displayActivationController;
      _localSubscriptionRepo = testDeps.localSubscriptionRepo;
    } else {
      _hubClient = CaleeHubClient();
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
      _displayActivationController = DisplayActivationController(
        repository: DisplaySetupRepository(hubClient: _hubClient),
      );
      _localSubscriptionRepo = LocalCalendarSubscriptionRepository();
      unawaited(_followLinkController.init());
      unawaited(_displaySetupLinkController.init());
      unawaited(_externalCalendarConnectedLinkController.init());
    }

    _followLinkController.addListener(_onFollowLinkChanged);
    _displaySetupLinkController.addListener(_onDisplaySetupLinkChanged);
    _externalCalendarConnectedLinkController.addListener(
      _onExternalCalendarConnectedLinkChanged,
    );
    _sessionController.addListener(_onSessionChanged);

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
    _sessionController.removeListener(_onSessionChanged);
    _followLinkController.dispose();
    _displaySetupLinkController.dispose();
    _externalCalendarConnectedLinkController.dispose();
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
      }
    }
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
          _openDisplaySetupConfirmation(displayIntent);
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
      _openDisplaySetupConfirmation(intent);
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
      final connections = await _hubClient.externalCalendarConnections(
        accessToken: _sessionController.accessToken!,
      );

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
      final resolvedConnection = connection;
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

  void _openDisplaySetupConfirmation(DisplaySetupIntent intent) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _navigatorKey.currentState?.push(
        MaterialPageRoute<void>(
          builder: (_) => DisplaySetupConfirmationPage(
            token: intent.token,
            accountEmail:
                _sessionController.bootstrap?.account.primaryEmail ?? '',
            activationController: _displayActivationController,
            accessToken: _sessionController.accessToken!,
            onActivated: () async {
              _displaySetupLinkController.clearPending();
              await _sessionController.refreshBootstrap();
              if (!mounted) return;
              Navigator.of(_navigatorKey.currentContext!).pop();
              _openDisplayActivationSuccess();
            },
            onUseDifferentAccount: () {
              _displaySetupFromLoggedOut = true;
              _displaySetupThroughLandingPage = false;
              Navigator.of(_navigatorKey.currentContext!).pop();
              unawaited(_sessionController.signOut());
            },
          ),
        ),
      );
    });
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
            autoOpenSubscribeForm: true,
            initialSubscriptionUrl: intent.url,
            initialSubscriptionName: intent.title,
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
        ]),
        builder: (context, _) => _buildHome(),
      ),
      onUnknownRoute: (settings) {
        final intent = DisplaySetupLinkController.parseDisplaySetupRouteName(
          settings.name,
        );
        if (intent != null) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (!mounted) return;
            _displaySetupLinkController.handleDisplaySetupIntent(intent);
          });
        }
        return MaterialPageRoute<void>(
          settings: const RouteSettings(name: '/'),
          builder: (_) => AnimatedBuilder(
            animation: Listenable.merge([
              _sessionController,
              _followLinkController,
              _displaySetupLinkController,
            ]),
            builder: (context, _) => _buildHome(),
          ),
        );
      },
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

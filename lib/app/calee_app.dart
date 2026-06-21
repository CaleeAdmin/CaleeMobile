import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../data/api/calee_hub_client.dart';
import '../data/auth/calee_preferences.dart';
import '../data/auth/session_store.dart';
import '../features/auth/auth_repository.dart';
import '../features/auth/create_account_page.dart';
import '../features/auth/login_page.dart';
import '../features/auth/session_controller.dart';
import '../features/calendar_follow/calendar_follow_intent.dart';
import '../features/calendar_follow/calendar_follow_link_controller.dart';
import '../features/calendar_follow/follow_calendar_page.dart';
import '../features/calendar_onboarding/calendar_onboarding_page.dart';
import '../features/calendar_onboarding/calendar_onboarding_status.dart';
import '../features/display_setup/display_activation_controller.dart';
import '../features/display_setup/display_activation_success_page.dart';
import '../features/display_setup/display_setup_confirmation_page.dart';
import '../features/display_setup/display_setup_intent.dart';
import '../features/display_setup/display_setup_landing_page.dart';
import '../features/display_setup/display_setup_repository.dart';
import '../features/display_setup/display_setup_scan_page.dart';
import '../features/display_setup/display_setup_link_controller.dart';
import '../features/local_subscriber/local_calendar_subscription.dart';
import '../features/local_subscriber/local_calendar_subscription_repository.dart';
import '../features/local_subscriber/local_subscriber_calendar_page.dart';
import '../features/settings/calendar_collections_page.dart';
import '../ui/calee_design.dart';
import 'calee_home_page.dart';

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
  });

  final CaleeHubClient hubClient;
  final SessionController sessionController;
  final DisplaySetupLinkController displaySetupLinkController;
  final CalendarFollowLinkController followLinkController;
  final DisplayActivationController displayActivationController;
  final LocalCalendarSubscriptionRepository localSubscriptionRepo;
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

class _CaleeAppState extends State<CaleeApp> {
  late final CaleeHubClient _hubClient;
  late final SessionController _sessionController;
  late final CalendarFollowLinkController _followLinkController;
  late final DisplaySetupLinkController _displaySetupLinkController;
  late final DisplayActivationController _displayActivationController;
  late final LocalCalendarSubscriptionRepository _localSubscriptionRepo;
  final _navigatorKey = GlobalKey<NavigatorState>();

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

  // Onboarding gate state (only active after fresh sign-in, not session restore)
  bool _checkingOnboarding = false;
  bool _showingOnboarding = false;
  int? _initialHomeTab;

  List<LocalCalendarSubscription> _localSubscriptions = [];
  bool _localSubscriptionsLoaded = false;

  @override
  void initState() {
    super.initState();
    final testDeps = widget._testDeps;
    if (testDeps != null) {
      _hubClient = testDeps.hubClient;
      _sessionController = testDeps.sessionController;
      _followLinkController = testDeps.followLinkController;
      _displaySetupLinkController = testDeps.displaySetupLinkController;
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
      _displayActivationController = DisplayActivationController(
        repository: DisplaySetupRepository(hubClient: _hubClient),
      );
      _localSubscriptionRepo = LocalCalendarSubscriptionRepository();
      unawaited(_followLinkController.init());
      unawaited(_displaySetupLinkController.init());
    }

    _followLinkController.addListener(_onFollowLinkChanged);
    _displaySetupLinkController.addListener(_onDisplaySetupLinkChanged);
    _sessionController.addListener(_onSessionChanged);

    _sessionController.restoreSession();
    unawaited(_loadLocalSubscriptions());
  }

  @override
  void dispose() {
    _followLinkController.removeListener(_onFollowLinkChanged);
    _displaySetupLinkController.removeListener(_onDisplaySetupLinkChanged);
    _sessionController.removeListener(_onSessionChanged);
    _followLinkController.dispose();
    _displaySetupLinkController.dispose();
    _displayActivationController.dispose();
    _sessionController.dispose();
    super.dispose();
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

    // Fresh registration with no display context (state 4): offer QR scan.
    if (_justRegistered) {
      _justRegistered = false;
      setState(() => _showingDisplaySetupCreateAccount = false);
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        _navigatorKey.currentState?.push(
          MaterialPageRoute<void>(
            builder: (_) => DisplaySetupScanPage(
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
            onActivated: () {
              _displaySetupLinkController.clearPending();
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
      _initialHomeTab = 1; // Calendar tab
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
      // ── Display setup flows (state 2) ─────────────────────────────────────

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

      // ── Calendar follow flows ──────────────────────────────────────────────

      // User chose "Add to Calee" → show login (pending intent present, skip onboarding)
      if (_showingFollowSignIn) {
        return LoginPage(
          authRepository: _sessionController.repository,
          onSignedIn: (result) async {
            setState(() => _showingFollowSignIn = false);
            await _sessionController.completeSignIn(result);
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

      // Default → login; on success check if onboarding should be shown
      return LoginPage(
        authRepository: _sessionController.repository,
        onSignedIn: (result) async {
          final hasPendingIntent = _followLinkController.pendingIntent != null;
          setState(() => _showingFollowSignIn = false);
          await _sessionController.completeSignIn(result);
          if (!hasPendingIntent) {
            unawaited(_checkAndShowOnboarding(result.bootstrap.account.id));
          }
        },
      );
    }

    // ── Signed-in flows ────────────────────────────────────────────────────

    // Show loading spinner while checking onboarding status after fresh sign-in
    if (_checkingOnboarding) return const _SessionRestorePage();

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

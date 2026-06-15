import 'dart:async';

import 'package:flutter/material.dart';

import '../data/api/calee_hub_client.dart';
import '../data/auth/calee_preferences.dart';
import '../data/auth/session_store.dart';
import '../features/auth/auth_repository.dart';
import '../features/auth/login_page.dart';
import '../features/auth/session_controller.dart';
import '../features/calendar_follow/calendar_follow_intent.dart';
import '../features/calendar_follow/calendar_follow_link_controller.dart';
import '../features/calendar_follow/follow_calendar_page.dart';
import '../features/calendar_onboarding/calendar_onboarding_page.dart';
import '../features/calendar_onboarding/calendar_onboarding_status.dart';
import '../features/local_subscriber/local_calendar_subscription.dart';
import '../features/local_subscriber/local_calendar_subscription_repository.dart';
import '../features/local_subscriber/local_subscriber_calendar_page.dart';
import '../features/settings/calendar_collections_page.dart';
import '../ui/calee_design.dart';
import 'calee_home_page.dart';

class CaleeApp extends StatefulWidget {
  const CaleeApp({super.key});

  @override
  State<CaleeApp> createState() => _CaleeAppState();
}

class _CaleeAppState extends State<CaleeApp> {
  late final CaleeHubClient _hubClient;
  late final SessionController _sessionController;
  late final CalendarFollowLinkController _followLinkController;
  late final LocalCalendarSubscriptionRepository _localSubscriptionRepo;
  final _navigatorKey = GlobalKey<NavigatorState>();

  // true while the user has tapped "Add to Calee"
  bool _showingFollowSignIn = false;
  bool _processingFollowLink = false;

  // Onboarding gate state (only active after fresh sign-in, not session restore)
  bool _checkingOnboarding = false;
  bool _showingOnboarding = false;

  List<LocalCalendarSubscription> _localSubscriptions = [];
  bool _localSubscriptionsLoaded = false;

  @override
  void initState() {
    super.initState();
    _hubClient = CaleeHubClient();
    final repository = AuthRepository(
      hubClient: _hubClient,
      sessionStore: SessionStore(),
    );
    _sessionController = SessionController(repository: repository);
    _hubClient.onUnauthorized = _sessionController.handleUnauthorized;

    _followLinkController = CalendarFollowLinkController();
    _followLinkController.addListener(_onFollowLinkChanged);
    _sessionController.addListener(_onSessionChanged);

    _localSubscriptionRepo = LocalCalendarSubscriptionRepository();

    _sessionController.restoreSession();
    unawaited(_followLinkController.init());
    unawaited(_loadLocalSubscriptions());
  }

  @override
  void dispose() {
    _followLinkController.removeListener(_onFollowLinkChanged);
    _sessionController.removeListener(_onSessionChanged);
    _followLinkController.dispose();
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
    if (_sessionController.isSignedIn) {
      final intent = _followLinkController.pendingIntent;
      if (intent != null) {
        _followLinkController.clearPending();
        _openSubscribeFlowForIntent(intent);
      }
    }
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

  void _openSubscribeFlowForIntent(ResolvedCalendarFollowIntent intent) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _navigatorKey.currentState?.push(
        MaterialPageRoute<void>(
          builder: (_) => CalendarCollectionsPage(
            hubClient: _hubClient,
            accessToken: _sessionController.accessToken!,
            services: _sessionController.bootstrap!.services,
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
    final status =
        await CaleePreferences().loadCalendarOnboardingStatus(accountId);
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
        ]),
        builder: (context, _) => _buildHome(),
      ),
    );
  }

  Widget _buildHome() {
    if (_sessionController.isRestoringSession || !_localSubscriptionsLoaded) {
      return const _SessionRestorePage();
    }

    if (!_sessionController.isSignedIn) {
      final pendingIntent = _followLinkController.pendingIntent;

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
      if (pendingIntent != null) {
        final normalizedIntentUrl = pendingIntent.url.startsWith('webcal://')
            ? 'https://${pendingIntent.url.substring('webcal://'.length)}'
            : pendingIntent.url;
        final alreadyFollowed = _localSubscriptions.any(
          (s) => s.url == normalizedIntentUrl,
        );

        return FollowCalendarPage(
          intent: pendingIntent,
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
                            "This calendar is already added on this phone.",
                          ),
                        ),
                      );
                    }
                  });
                }
              : () => _handleFollowLocally(pendingIntent),
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
          // Capture pending intent state before completeSignIn clears it
          final hasPendingIntent =
              _followLinkController.pendingIntent != null;
          setState(() => _showingFollowSignIn = false);
          await _sessionController.completeSignIn(result);
          // Only check onboarding when there is no pending calendar-follow link
          if (!hasPendingIntent) {
            unawaited(
              _checkAndShowOnboarding(result.bootstrap.account.id),
            );
          }
        },
      );
    }

    // Show loading spinner while checking onboarding status after fresh sign-in
    if (_checkingOnboarding) return const _SessionRestorePage();

    if (_showingOnboarding) {
      return CalendarOnboardingPage(
        hubClient: _hubClient,
        accessToken: _sessionController.accessToken!,
        services: _sessionController.bootstrap!.services,
        accountId: _sessionController.bootstrap!.account.id,
        onDismissed: _onOnboardingDone,
      );
    }

    return CaleeHomePage(
      hubClient: _hubClient,
      accessToken: _sessionController.accessToken!,
      bootstrap: _sessionController.bootstrap!,
      onSignOut: () => _sessionController.signOut(),
      onBootstrapRefreshed: _sessionController.updateBootstrap,
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

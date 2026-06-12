import 'dart:async';

import 'package:flutter/material.dart';

import '../data/api/calee_hub_client.dart';
import '../data/auth/session_store.dart';
import '../features/auth/auth_repository.dart';
import '../features/auth/login_page.dart';
import '../features/auth/session_controller.dart';
import '../features/calendar_follow/calendar_follow_intent.dart';
import '../features/calendar_follow/calendar_follow_link_controller.dart';
import '../features/calendar_follow/follow_calendar_page.dart';
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
  final _navigatorKey = GlobalKey<NavigatorState>();

  // true while the user has tapped "Sign in" from the FollowCalendarPage
  bool _showingFollowSignIn = false;
  bool _processingFollowLink = false;

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

    _sessionController.restoreSession();
    unawaited(_followLinkController.init());
  }

  @override
  void dispose() {
    _followLinkController.removeListener(_onFollowLinkChanged);
    _sessionController.removeListener(_onSessionChanged);
    _followLinkController.dispose();
    _sessionController.dispose();
    super.dispose();
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

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Calee',
      debugShowCheckedModeBanner: false,
      navigatorKey: _navigatorKey,
      theme: CaleeTheme.buildThemeData(),
      home: AnimatedBuilder(
        animation: Listenable.merge([_sessionController, _followLinkController]),
        builder: (context, _) => _buildHome(),
      ),
    );
  }

  Widget _buildHome() {
    if (_sessionController.isRestoringSession) {
      return const _SessionRestorePage();
    }

    if (!_sessionController.isSignedIn) {
      final pendingIntent = _followLinkController.pendingIntent;
      if (pendingIntent != null && !_showingFollowSignIn) {
        return FollowCalendarPage(
          intent: pendingIntent,
          onSignIn: () => setState(() => _showingFollowSignIn = true),
          onCancel: () {
            _followLinkController.clearPending();
            setState(() => _showingFollowSignIn = false);
          },
        );
      }

      return LoginPage(
        authRepository: _sessionController.repository,
        onSignedIn: (result) async {
          setState(() => _showingFollowSignIn = false);
          await _sessionController.completeSignIn(result);
        },
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

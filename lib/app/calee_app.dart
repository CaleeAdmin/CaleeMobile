import 'package:flutter/material.dart';

import '../data/api/calee_hub_client.dart';
import '../data/auth/session_store.dart';
import '../features/auth/auth_repository.dart';
import '../features/auth/login_page.dart';
import '../features/auth/session_controller.dart';
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
    _sessionController.restoreSession();
  }

  @override
  void dispose() {
    _sessionController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Calee',
      debugShowCheckedModeBanner: false,
      theme: CaleeTheme.buildThemeData(),
      home: AnimatedBuilder(
        animation: _sessionController,
        builder: (context, _) => _buildHome(),
      ),
    );
  }

  Widget _buildHome() {
    if (_sessionController.isRestoringSession) {
      return const _SessionRestorePage();
    }

    if (!_sessionController.isSignedIn) {
      return LoginPage(
        authRepository: _sessionController.repository,
        onSignedIn: _sessionController.completeSignIn,
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

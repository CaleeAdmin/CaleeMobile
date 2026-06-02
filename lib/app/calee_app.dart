import 'package:flutter/material.dart';

import '../data/api/calee_hub_client.dart';
import '../data/auth/session_store.dart';
import '../data/models/client_bootstrap.dart';
import '../features/auth/login_page.dart';
import '../ui/calee_design.dart';
import 'calee_home_page.dart';

class CaleeApp extends StatefulWidget {
  const CaleeApp({super.key});

  @override
  State<CaleeApp> createState() => _CaleeAppState();
}

class _CaleeAppState extends State<CaleeApp> {
  final _hubClient = CaleeHubClient();
  final _sessionStore = SessionStore();

  String? _accessToken;
  String? _refreshToken;
  ClientBootstrap? _bootstrap;
  bool _isRestoringSession = true;

  @override
  void initState() {
    super.initState();
    _hubClient.onUnauthorized = _handleUnauthorized;
    _restoreSession();
  }

  // Called transparently by CaleeHubClient when any authenticated request
  // receives a 401. Refreshes once, saves the new token, and returns it.
  // Returns null and signs the user out if refresh fails.
  Future<String?> _handleUnauthorized() async {
    final storedRefreshToken = _refreshToken;
    if (storedRefreshToken == null) {
      await _signOut();
      return null;
    }

    try {
      final refreshed =
          await _hubClient.refresh(refreshToken: storedRefreshToken);
      final newToken = refreshed.accessToken;
      await _sessionStore.saveAccessToken(newToken);
      if (mounted) {
        setState(() => _accessToken = newToken);
      }
      return newToken;
    } catch (_) {
      await _sessionStore.clear();
      if (mounted) {
        setState(() {
          _accessToken = null;
          _refreshToken = null;
          _bootstrap = null;
        });
      }
      return null;
    }
  }

  Future<void> _restoreSession() async {
    try {
      final session = await _sessionStore.loadSession();

      if (session == null) {
        _finishRestoreWithoutSession();
        return;
      }

      await _loadBootstrapWithSession(
        accessToken: session.accessToken,
        refreshToken: session.refreshToken,
      );
    } catch (_) {
      await _sessionStore.clear();
      _finishRestoreWithoutSession();
    }
  }

  Future<void> _loadBootstrapWithSession({
    required String accessToken,
    required String refreshToken,
  }) async {
    // Set refresh token early so _handleUnauthorized can transparently refresh
    // a 401 from bootstrap() — it reads _refreshToken synchronously.
    _refreshToken = refreshToken;
    _hubClient.clearAuthCache();

    final bootstrap = await _hubClient.bootstrap(accessToken: accessToken);

    if (!mounted) return;

    setState(() {
      // _accessToken may already have been updated by _handleUnauthorized
      // during a transparent retry, so keep the refreshed value if present.
      _accessToken ??= accessToken;
      _refreshToken = refreshToken;
      _bootstrap = bootstrap;
      _isRestoringSession = false;
    });
  }

  void _finishRestoreWithoutSession() {
    if (!mounted) {
      return;
    }

    setState(() {
      _accessToken = null;
      _refreshToken = null;
      _bootstrap = null;
      _isRestoringSession = false;
    });
  }

  Future<void> _onSignedIn(
    String accessToken,
    String refreshToken,
    ClientBootstrap bootstrap,
  ) async {
    _hubClient.clearAuthCache();
    await _sessionStore.saveSession(
      accessToken: accessToken,
      refreshToken: refreshToken,
    );

    if (!mounted) {
      return;
    }

    setState(() {
      _accessToken = accessToken;
      _refreshToken = refreshToken;
      _bootstrap = bootstrap;
    });
  }

  Future<void> _signOut() async {
    _hubClient.clearAuthCache();
    await _sessionStore.clear();

    if (!mounted) {
      return;
    }

    setState(() {
      _accessToken = null;
      _refreshToken = null;
      _bootstrap = null;
    });
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Calee',
      debugShowCheckedModeBanner: false,
      theme: CaleeTheme.buildThemeData(),
      home: _buildHome(),
    );
  }

  Widget _buildHome() {
    if (_isRestoringSession) {
      return const _SessionRestorePage();
    }

    if (_accessToken == null || _bootstrap == null) {
      return LoginPage(
        hubClient: _hubClient,
        onSignedIn: _onSignedIn,
      );
    }

    return CaleeHomePage(
      hubClient: _hubClient,
      accessToken: _accessToken!,
      bootstrap: _bootstrap!,
      onSignOut: _signOut,
    );
  }
}

class _SessionRestorePage extends StatelessWidget {
  const _SessionRestorePage();

  @override
  Widget build(BuildContext context) {
    return const Scaffold(
      body: SafeArea(
        child: Center(
          child: CircularProgressIndicator(),
        ),
      ),
    );
  }
}

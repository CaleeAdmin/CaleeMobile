import 'package:flutter/material.dart';

import '../data/api/calee_hub_client.dart';
import '../data/auth/session_store.dart';
import '../data/models/client_bootstrap.dart';
import '../features/auth/login_page.dart';
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
  ClientBootstrap? _bootstrap;
  bool _isRestoringSession = true;

  @override
  void initState() {
    super.initState();
    _restoreSession();
  }

  Future<void> _restoreSession() async {
    try {
      final accessToken = await _sessionStore.loadAccessToken();

      if (accessToken == null || accessToken.trim().isEmpty) {
        if (!mounted) {
          return;
        }

        setState(() {
          _isRestoringSession = false;
        });
        return;
      }

      final bootstrap = await _hubClient.bootstrap(accessToken: accessToken);

      if (!mounted) {
        return;
      }

      setState(() {
        _accessToken = accessToken;
        _bootstrap = bootstrap;
        _isRestoringSession = false;
      });
    } catch (_) {
      await _sessionStore.clear();

      if (!mounted) {
        return;
      }

      setState(() {
        _accessToken = null;
        _bootstrap = null;
        _isRestoringSession = false;
      });
    }
  }

  Future<void> _onSignedIn(
    String accessToken,
    ClientBootstrap bootstrap,
  ) async {
    await _sessionStore.saveAccessToken(accessToken);

    if (!mounted) {
      return;
    }

    setState(() {
      _accessToken = accessToken;
      _bootstrap = bootstrap;
    });
  }

  Future<void> _signOut() async {
    await _sessionStore.clear();

    if (!mounted) {
      return;
    }

    setState(() {
      _accessToken = null;
      _bootstrap = null;
    });
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Calee',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: Colors.lightGreen,
          brightness: Brightness.light,
        ),
        scaffoldBackgroundColor: const Color(0xFFF3FAF3),
        appBarTheme: const AppBarTheme(
          backgroundColor: Color(0xFFF3FAF3),
          foregroundColor: Color(0xFF1B5E20),
        ),
        inputDecorationTheme: const InputDecorationTheme(
          filled: true,
          fillColor: Colors.white,
        ),
        cardColor: Colors.white,
        useMaterial3: true,
      ),
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

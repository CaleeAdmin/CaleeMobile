import 'package:flutter/material.dart';

import '../data/api/calee_hub_client.dart';
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

  String? _accessToken;
  ClientBootstrap? _bootstrap;

  void _onSignedIn(String accessToken, ClientBootstrap bootstrap) {
    setState(() {
      _accessToken = accessToken;
      _bootstrap = bootstrap;
    });
  }

  void _signOut() {
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
      home: _accessToken == null || _bootstrap == null
          ? LoginPage(
              hubClient: _hubClient,
              onSignedIn: _onSignedIn,
            )
          : CaleeHomePage(
              bootstrap: _bootstrap!,
              onSignOut: _signOut,
            ),
    );
  }
}

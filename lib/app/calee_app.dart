import 'package:flutter/material.dart';

import 'calee_home_page.dart';

class CaleeApp extends StatelessWidget {
  const CaleeApp({super.key});

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
        cardColor: Colors.white,
        useMaterial3: true,
      ),
      home: const CaleeHomePage(),
    );
  }
}

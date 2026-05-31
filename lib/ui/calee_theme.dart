import 'package:flutter/material.dart';

abstract final class CaleeColors {
  // Scaffold / page backgrounds
  static const scaffoldBackground = Color(0xFFF2F2F7);
  static const groupedBackground = Color(0xFFF2F2F7);

  // Surface (cards, sheets)
  static const surface = Colors.white;

  // Primary brand
  static const primary = Color(0xFF3A7D44);
  static const primaryLight = Color(0xFF5A9A5F);

  // Text
  static const textPrimary = Color(0xFF1C1C1E);
  static const textSecondary = Color(0xFF6C6C70);
  static const textTertiary = Color(0xFFAEAEB2);

  // Separator / divider
  static const separator = Color(0xFFE5E5EA);
  static const separatorOpaque = Color(0xFFC6C6C8);

  // Destructive
  static const destructive = Color(0xFFFF3B30);

  // Calendar-style palette for collection dots
  static const dotRed = Color(0xFFFF3B30);
  static const dotOrange = Color(0xFFFF9500);
  static const dotYellow = Color(0xFFFFCC00);
  static const dotGreen = Color(0xFF34C759);
  static const dotTeal = Color(0xFF5AC8FA);
  static const dotBlue = Color(0xFF007AFF);
  static const dotPurple = Color(0xFFAF52DE);
  static const dotPink = Color(0xFFFF2D55);
  static const dotGray = Color(0xFF8E8E93);
}

abstract final class CaleeSpacing {
  static const double xs = 4;
  static const double sm = 8;
  static const double md = 16;
  static const double lg = 24;
  static const double xl = 32;
  static const double pagePadding = 16;
  static const double sectionSpacing = 20;
  static const double rowHeight = 44;
}

abstract final class CaleeRadius {
  static const double card = 10;
  static const double sheet = 16;
  static const double button = 10;
  static const double dot = 100;
}

abstract final class CaleeTheme {
  static ThemeData buildThemeData() {
    final colorScheme = ColorScheme.fromSeed(
      seedColor: CaleeColors.primary,
      brightness: Brightness.light,
      surface: CaleeColors.surface,
    );

    return ThemeData(
      useMaterial3: true,
      colorScheme: colorScheme,
      scaffoldBackgroundColor: CaleeColors.scaffoldBackground,
      cardTheme: CardTheme(
        color: CaleeColors.surface,
        elevation: 0,
        margin: EdgeInsets.zero,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(CaleeRadius.card),
        ),
      ),
      listTileTheme: const ListTileThemeData(
        minVerticalPadding: 12,
        contentPadding: EdgeInsets.symmetric(
          horizontal: CaleeSpacing.md,
          vertical: 2,
        ),
      ),
      appBarTheme: const AppBarTheme(
        backgroundColor: CaleeColors.scaffoldBackground,
        foregroundColor: CaleeColors.textPrimary,
        scrolledUnderElevation: 0,
        titleTextStyle: TextStyle(
          color: CaleeColors.textPrimary,
          fontSize: 17,
          fontWeight: FontWeight.w600,
        ),
      ),
      navigationBarTheme: NavigationBarThemeData(
        backgroundColor: CaleeColors.surface,
        indicatorColor: CaleeColors.primary.withAlpha(26),
        labelTextStyle: WidgetStateProperty.all(
          const TextStyle(fontSize: 11, fontWeight: FontWeight.w500),
        ),
      ),
      dividerTheme: const DividerThemeData(
        color: CaleeColors.separator,
        thickness: 0.5,
        space: 0,
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: CaleeColors.surface,
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(CaleeRadius.button),
          borderSide: const BorderSide(color: CaleeColors.separator),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(CaleeRadius.button),
          borderSide: const BorderSide(color: CaleeColors.separator),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(CaleeRadius.button),
          borderSide:
              const BorderSide(color: CaleeColors.primary, width: 1.5),
        ),
        contentPadding: const EdgeInsets.symmetric(
          horizontal: CaleeSpacing.md,
          vertical: CaleeSpacing.sm + 4,
        ),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          backgroundColor: CaleeColors.primary,
          foregroundColor: Colors.white,
          minimumSize: const Size.fromHeight(44),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(CaleeRadius.button),
          ),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          foregroundColor: CaleeColors.primary,
          side: const BorderSide(color: CaleeColors.separator),
          minimumSize: const Size.fromHeight(44),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(CaleeRadius.button),
          ),
        ),
      ),
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(
          foregroundColor: CaleeColors.primary,
        ),
      ),
      snackBarTheme: SnackBarThemeData(
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(CaleeRadius.button),
        ),
      ),
    );
  }
}

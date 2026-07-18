import 'package:flutter/material.dart';

abstract final class CaleeColors {
  // Neutral application backgrounds. Family-specific warm surfaces can be
  // introduced later without changing the shared Calee brand colour.
  static const scaffoldBackground = Color(0xFFF3F7F6);
  static const groupedBackground = Color(0xFFF3F7F6);

  // Surfaces (cards, sheets, selected rows)
  static const surface = Colors.white;
  static const surfaceSubtle = Color(0xFFF0F7F5);

  // Shared Calee brand
  static const primary = Color(0xFF1F6F66);
  static const primaryDark = Color(0xFF195B55);
  static const primaryDeep = Color(0xFF163F3B);
  static const primaryLight = Color(0xFF4F9188);
  static const primarySoft = Color(0xFFDDEFEA);

  // Warm secondary accent for family, onboarding, and premium highlights.
  // It must not replace the primary colour on core controls.
  static const secondary = Color(0xFFA35F2A);
  static const secondarySoft = Color(0xFFF4E4D5);

  // Text
  static const textPrimary = Color(0xFF163330);
  static const textSecondary = Color(0xFF4F625F);
  static const textTertiary = Color(0xFF7D8E8A);

  // Separator / divider
  static const separator = Color(0xFFD5E1DE);
  static const separatorOpaque = Color(0xFFB7C8C4);

  // Semantic states. These remain independent from brand and calendar colours.
  static const success = Color(0xFF2E7D5A);
  static const warning = Color(0xFFA86300);
  static const information = Color(0xFF2F80ED);
  static const destructive = Color(0xFFC23B32);

  // Calendar collection colours are functional data colours, not brand tokens.
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

abstract final class CaleeAlpha {
  // Named 0-255 alpha values for withAlpha() calls.
  static const int pct6 = 15;
  static const int pct8 = 20;
  static const int pct10 = 26;
  static const int pct12 = 30;
  static const int pct24 = 60;
}

abstract final class CaleeTheme {
  static ThemeData buildThemeData() {
    final colorScheme = ColorScheme.fromSeed(
      seedColor: CaleeColors.primary,
      brightness: Brightness.light,
      surface: CaleeColors.surface,
    ).copyWith(
      primary: CaleeColors.primary,
      onPrimary: Colors.white,
      primaryContainer: CaleeColors.primarySoft,
      onPrimaryContainer: CaleeColors.primaryDeep,
      secondary: CaleeColors.secondary,
      onSecondary: Colors.white,
      secondaryContainer: CaleeColors.secondarySoft,
      onSecondaryContainer: CaleeColors.textPrimary,
      error: CaleeColors.destructive,
      onError: Colors.white,
      surface: CaleeColors.surface,
      onSurface: CaleeColors.textPrimary,
      outline: CaleeColors.separatorOpaque,
      outlineVariant: CaleeColors.separator,
    );

    return ThemeData(
      useMaterial3: true,
      colorScheme: colorScheme,
      scaffoldBackgroundColor: CaleeColors.scaffoldBackground,
      cardTheme: CardThemeData(
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
        indicatorColor: CaleeColors.primarySoft,
        labelTextStyle: WidgetStateProperty.all(
          const TextStyle(fontSize: 11, fontWeight: FontWeight.w500),
        ),
      ),
      dividerTheme: const DividerThemeData(
        color: CaleeColors.separator,
        thickness: 0.5,
        space: 0,
      ),
      textSelectionTheme: const TextSelectionThemeData(
        cursorColor: CaleeColors.primary,
        selectionColor: CaleeColors.primarySoft,
        selectionHandleColor: CaleeColors.primary,
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
          borderSide: const BorderSide(color: CaleeColors.primary, width: 1.5),
        ),
        errorBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(CaleeRadius.button),
          borderSide: const BorderSide(color: CaleeColors.destructive),
        ),
        focusedErrorBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(CaleeRadius.button),
          borderSide: const BorderSide(
            color: CaleeColors.destructive,
            width: 1.5,
          ),
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
          side: const BorderSide(color: CaleeColors.separatorOpaque),
          minimumSize: const Size.fromHeight(44),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(CaleeRadius.button),
          ),
        ),
      ),
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(foregroundColor: CaleeColors.primary),
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

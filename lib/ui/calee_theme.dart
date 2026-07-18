import 'package:flutter/material.dart';

abstract final class CaleeColors {
  // Scaffold / page backgrounds (cool business neutral)
  static const scaffoldBackground = Color(0xFFF3F7F6);
  static const groupedBackground = Color(0xFFF3F7F6);

  // Surface (cards, sheets)
  static const surface = Colors.white;
  static const surfaceSoft = Color(0xFFF8FBFA);

  // Primary brand (Calee teal)
  static const primary = Color(0xFF1F6F66);
  static const primaryDark = Color(0xFF195B55);
  static const primaryDeep = Color(0xFF163F3B);
  static const primarySoft = Color(0xFFDDEFEA);
  static const primarySubtle = Color(0xFFF0F7F5);

  // Text
  static const textPrimary = Color(0xFF163330);
  static const textSecondary = Color(0xFF4F625F);
  static const textTertiary = Color(0xFF667874);
  static const textInverse = Color(0xFFFFFFFF);

  // Separator / divider / border
  static const separator = Color(0xFFD5E1DE);
  static const separatorOpaque = Color(0xFFB7C8C4);

  // Semantic status
  static const success = Color(0xFF2F7D4A);
  static const warning = Color(0xFFA96316);
  static const danger = Color(0xFFC44235);
  static const info = Color(0xFF2368B4);

  // Backwards-compatible alias for error/destructive actions.
  // New code should use [danger].
  static const destructive = danger;

  // Calendar-style palette for collection dots (independent of brand — unchanged)
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
    // Start from a seed for the derived tones, then explicitly override the
    // important roles so widgets render the approved Calee values rather than
    // uncontrolled generated tones (which can drift toward unrelated hues).
    final colorScheme =
        ColorScheme.fromSeed(
          seedColor: CaleeColors.primary,
          brightness: Brightness.light,
        ).copyWith(
          primary: CaleeColors.primary,
          onPrimary: CaleeColors.textInverse,
          primaryContainer: CaleeColors.primarySoft,
          onPrimaryContainer: CaleeColors.primaryDeep,
          secondary: CaleeColors.primaryDark,
          onSecondary: CaleeColors.textInverse,
          surface: CaleeColors.surface,
          onSurface: CaleeColors.textPrimary,
          surfaceContainerHighest: CaleeColors.surfaceSoft,
          error: CaleeColors.danger,
          onError: CaleeColors.textInverse,
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
        indicatorColor: CaleeColors.primary.withAlpha(CaleeAlpha.pct10),
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
          borderSide: const BorderSide(color: CaleeColors.primary, width: 1.5),
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

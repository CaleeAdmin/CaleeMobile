import 'package:calee_mobile/ui/calee_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('Calee colour theme', () {
    test('uses the canonical shared brand tokens', () {
      expect(CaleeColors.primary, const Color(0xFF1F6F66));
      expect(CaleeColors.primaryDark, const Color(0xFF195B55));
      expect(CaleeColors.primarySoft, const Color(0xFFDDEFEA));
      expect(CaleeColors.secondary, const Color(0xFFA35F2A));
      expect(CaleeColors.scaffoldBackground, const Color(0xFFF3F7F6));
    });

    test('maps semantic colours into Material theme roles', () {
      final theme = CaleeTheme.buildThemeData();

      expect(theme.colorScheme.primary, CaleeColors.primary);
      expect(theme.colorScheme.onPrimary, Colors.white);
      expect(theme.colorScheme.primaryContainer, CaleeColors.primarySoft);
      expect(theme.colorScheme.secondary, CaleeColors.secondary);
      expect(theme.colorScheme.error, CaleeColors.destructive);
      expect(theme.scaffoldBackgroundColor, CaleeColors.scaffoldBackground);
      expect(
        theme.navigationBarTheme.indicatorColor,
        CaleeColors.primarySoft,
      );
    });

    test('keeps calendar data colours independent from the brand', () {
      expect(CaleeColors.dotTeal, isNot(CaleeColors.primary));
      expect(CaleeColors.dotBlue, isNot(CaleeColors.primary));
      expect(CaleeColors.dotGreen, isNot(CaleeColors.primary));
    });
  });
}

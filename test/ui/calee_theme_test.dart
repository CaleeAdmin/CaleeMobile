import 'package:calee_mobile/ui/calee_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('CaleeColors canonical teal tokens', () {
    test('brand tokens use the canonical teal values', () {
      expect(CaleeColors.primary, const Color(0xFF1F6F66));
      expect(CaleeColors.primaryDark, const Color(0xFF195B55));
      expect(CaleeColors.primaryDeep, const Color(0xFF163F3B));
      expect(CaleeColors.primarySoft, const Color(0xFFDDEFEA));
      expect(CaleeColors.primarySubtle, const Color(0xFFF0F7F5));
    });

    test('surface and text tokens are canonical', () {
      expect(CaleeColors.scaffoldBackground, const Color(0xFFF3F7F6));
      expect(CaleeColors.groupedBackground, const Color(0xFFF3F7F6));
      expect(CaleeColors.surface, const Color(0xFFFFFFFF));
      expect(CaleeColors.surfaceSoft, const Color(0xFFF8FBFA));
      expect(CaleeColors.textPrimary, const Color(0xFF163330));
      expect(CaleeColors.textSecondary, const Color(0xFF4F625F));
      expect(CaleeColors.textTertiary, const Color(0xFF667874));
      expect(CaleeColors.separator, const Color(0xFFD5E1DE));
      expect(CaleeColors.separatorOpaque, const Color(0xFFB7C8C4));
    });

    test('semantic status tokens are canonical and not brand teal', () {
      expect(CaleeColors.success, const Color(0xFF2F7D4A));
      expect(CaleeColors.warning, const Color(0xFFA96316));
      expect(CaleeColors.danger, const Color(0xFFC44235));
      expect(CaleeColors.info, const Color(0xFF2368B4));
      // Success must remain green, never recoloured to the teal brand.
      expect(CaleeColors.success, isNot(CaleeColors.primary));
    });

    test('destructive is a backwards-compatible alias for danger', () {
      expect(CaleeColors.destructive, CaleeColors.danger);
    });

    test('calendar collection dots are unchanged (independent of brand)', () {
      expect(CaleeColors.dotRed, const Color(0xFFFF3B30));
      expect(CaleeColors.dotOrange, const Color(0xFFFF9500));
      expect(CaleeColors.dotYellow, const Color(0xFFFFCC00));
      expect(CaleeColors.dotGreen, const Color(0xFF34C759));
      expect(CaleeColors.dotTeal, const Color(0xFF5AC8FA));
      expect(CaleeColors.dotBlue, const Color(0xFF007AFF));
      expect(CaleeColors.dotPurple, const Color(0xFFAF52DE));
      expect(CaleeColors.dotPink, const Color(0xFFFF2D55));
      expect(CaleeColors.dotGray, const Color(0xFF8E8E93));
    });
  });

  group('CaleeTheme.buildThemeData effective colours', () {
    final theme = CaleeTheme.buildThemeData();

    test('key ColorScheme roles resolve to the approved values', () {
      expect(theme.colorScheme.primary, CaleeColors.primary);
      expect(theme.colorScheme.onPrimary, CaleeColors.textInverse);
      expect(theme.colorScheme.primaryContainer, CaleeColors.primarySoft);
      expect(theme.colorScheme.onPrimaryContainer, CaleeColors.primaryDeep);
      expect(theme.colorScheme.secondary, CaleeColors.primaryDark);
      expect(theme.colorScheme.surface, CaleeColors.surface);
      expect(theme.colorScheme.onSurface, CaleeColors.textPrimary);
      expect(theme.colorScheme.error, CaleeColors.danger);
      expect(theme.colorScheme.onError, CaleeColors.textInverse);
      expect(theme.colorScheme.outline, CaleeColors.separatorOpaque);
      expect(theme.colorScheme.outlineVariant, CaleeColors.separator);
    });

    test('scaffold background uses the cool business neutral', () {
      expect(theme.scaffoldBackgroundColor, CaleeColors.scaffoldBackground);
    });

    test('primary filled buttons render white text on teal', () {
      final style = theme.filledButtonTheme.style!;
      const states = <WidgetState>{};
      expect(style.backgroundColor!.resolve(states), CaleeColors.primary);
      expect(style.foregroundColor!.resolve(states), Colors.white);
    });
  });
}

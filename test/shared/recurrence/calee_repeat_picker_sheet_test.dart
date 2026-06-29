import 'package:calee_mobile/shared/recurrence/calee_repeat_picker_sheet.dart';
import 'package:calee_mobile/shared/recurrence/calee_repeat_rule.dart';
import 'package:calee_mobile/ui/calee_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

// ── Helpers ───────────────────────────────────────────────────────────────────

// 2026-06-29 is a Monday.
final _anchor = DateTime(2026, 6, 29);

Widget _buildPicker({
  CaleeRepeatRule current = CaleeRepeatRule.none,
  required ValueChanged<CaleeRepeatRule> onSelected,
}) {
  return MaterialApp(
    theme: CaleeTheme.buildThemeData(),
    home: Scaffold(
      body: CaleeRepeatPickerSheet(
        current: current,
        anchorDate: _anchor,
        onSelected: onSelected,
      ),
    ),
  );
}

Future<void> _tapOption(WidgetTester tester, String label) async {
  await tester.tap(find.text(label));
  await tester.pumpAndSettle();
}

// ── Tests ─────────────────────────────────────────────────────────────────────

void main() {
  group('CaleeRepeatPickerSheet', () {
    testWidgets('shows all standard options', (tester) async {
      await tester.pumpWidget(_buildPicker(onSelected: (_) {}));
      await tester.pumpAndSettle();

      expect(find.text('Does not repeat'), findsOneWidget);
      expect(find.text('Daily'), findsOneWidget);
      expect(find.text('Weekdays'), findsOneWidget);
      expect(find.text('Every Monday'), findsOneWidget);
      expect(find.text('Every 2 weeks on Monday'), findsOneWidget);
      expect(find.text('Monthly'), findsOneWidget);
      expect(find.text('Yearly'), findsOneWidget);
      expect(find.text('Custom days'), findsOneWidget);
    });

    testWidgets('Done button enabled for standard options', (tester) async {
      await tester.pumpWidget(_buildPicker(onSelected: (_) {}));
      await tester.pumpAndSettle();

      final done = tester.widget<FilledButton>(find.byType(FilledButton));
      expect(done.onPressed, isNotNull);
    });

    testWidgets('selecting Custom days shows weekday pills', (tester) async {
      await tester.pumpWidget(_buildPicker(onSelected: (_) {}));
      await tester.pumpAndSettle();

      await _tapOption(tester, 'Custom days');

      expect(find.text('Mon'), findsOneWidget);
      expect(find.text('Tue'), findsOneWidget);
      expect(find.text('Wed'), findsOneWidget);
      expect(find.text('Thu'), findsOneWidget);
      expect(find.text('Fri'), findsOneWidget);
      expect(find.text('Sat'), findsOneWidget);
      expect(find.text('Sun'), findsOneWidget);
    });

    testWidgets('Done is disabled when Custom days has no weekdays selected', (
      tester,
    ) async {
      await tester.pumpWidget(_buildPicker(onSelected: (_) {}));
      await tester.pumpAndSettle();

      await _tapOption(tester, 'Custom days');

      final done = tester.widget<FilledButton>(find.byType(FilledButton));
      expect(done.onPressed, isNull);
    });

    testWidgets('Done is enabled after selecting at least one weekday', (
      tester,
    ) async {
      await tester.pumpWidget(_buildPicker(onSelected: (_) {}));
      await tester.pumpAndSettle();

      await _tapOption(tester, 'Custom days');
      await tester.tap(find.text('Mon'));
      await tester.pumpAndSettle();

      final done = tester.widget<FilledButton>(find.byType(FilledButton));
      expect(done.onPressed, isNotNull);
    });

    testWidgets('custom Mon/Wed/Fri produces FREQ=WEEKLY;BYDAY=MO,WE,FR', (
      tester,
    ) async {
      CaleeRepeatRule? result;
      await tester.pumpWidget(
        _buildPicker(onSelected: (r) => result = r),
      );
      await tester.pumpAndSettle();

      await _tapOption(tester, 'Custom days');
      await tester.tap(find.text('Mon'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Wed'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Fri'));
      await tester.pumpAndSettle();

      await tester.tap(find.text('Done'));
      await tester.pumpAndSettle();

      expect(result, isNotNull);
      expect(
        result!.toRrule(anchorDate: _anchor),
        'FREQ=WEEKLY;BYDAY=MO,WE,FR',
      );
    });

    testWidgets('custom Sat/Sun label is Every weekend', (tester) async {
      CaleeRepeatRule? result;
      await tester.pumpWidget(
        _buildPicker(onSelected: (r) => result = r),
      );
      await tester.pumpAndSettle();

      await _tapOption(tester, 'Custom days');
      await tester.tap(find.text('Sat'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Sun'));
      await tester.pumpAndSettle();

      await tester.tap(find.text('Done'));
      await tester.pumpAndSettle();

      expect(result, isNotNull);
      expect(result!.label(anchorDate: _anchor), 'Every weekend');
    });

    testWidgets('selecting Weekdays emits weekdaysOnly rule', (tester) async {
      CaleeRepeatRule? result;
      await tester.pumpWidget(
        _buildPicker(onSelected: (r) => result = r),
      );
      await tester.pumpAndSettle();

      await _tapOption(tester, 'Weekdays');
      await tester.tap(find.text('Done'));
      await tester.pumpAndSettle();

      expect(result, CaleeRepeatRule.weekdaysOnly);
      expect(result!.toRrule(), 'FREQ=WEEKLY;BYDAY=MO,TU,WE,TH,FR');
    });

    testWidgets('selecting Every Monday emits weekly rule', (tester) async {
      CaleeRepeatRule? result;
      await tester.pumpWidget(
        _buildPicker(onSelected: (r) => result = r),
      );
      await tester.pumpAndSettle();

      await _tapOption(tester, 'Every Monday');
      await tester.tap(find.text('Done'));
      await tester.pumpAndSettle();

      expect(result, const CaleeRepeatRule(kind: CaleeRepeatKind.weekly));
      expect(
        result!.toRrule(anchorDate: _anchor),
        'FREQ=WEEKLY;BYDAY=MO',
      );
    });

    testWidgets('fortnightly rule emits correct RRULE', (tester) async {
      CaleeRepeatRule? result;
      await tester.pumpWidget(
        _buildPicker(onSelected: (r) => result = r),
      );
      await tester.pumpAndSettle();

      await _tapOption(tester, 'Every 2 weeks on Monday');
      await tester.tap(find.text('Done'));
      await tester.pumpAndSettle();

      expect(
        result!.toRrule(anchorDate: _anchor),
        'FREQ=WEEKLY;INTERVAL=2;BYDAY=MO',
      );
    });
  });
}

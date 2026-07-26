import 'package:calee_mobile/ui/calee_theme.dart';
import 'package:calee_mobile/ui/calee_widgets.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('CaleeColors.swatchPalette', () {
    test('pairs each canonical dot colour with its hex string', () {
      expect(CaleeColors.swatchPalette, hasLength(9));
      expect(CaleeColors.swatchPalette.first, ('#FF3B30', CaleeColors.dotRed));
      expect(CaleeColors.swatchPalette[2], ('#FFCC00', CaleeColors.dotYellow));
      expect(CaleeColors.swatchPalette.last, ('#8E8E93', CaleeColors.dotGray));
    });
  });

  group('CaleeColorPalettePicker', () {
    Widget wrap(Widget child) => MaterialApp(home: Scaffold(body: child));

    testWidgets('renders one swatch per palette entry', (tester) async {
      await tester.pumpWidget(
        wrap(CaleeColorPalettePicker(selectedHex: null, onSelected: (_) {})),
      );

      expect(
        find.byType(CaleeColorSwatch),
        findsNWidgets(CaleeColors.swatchPalette.length),
      );
    });

    testWidgets('tapping a swatch reports its canonical hex', (tester) async {
      String? picked;
      await tester.pumpWidget(
        wrap(
          CaleeColorPalettePicker(
            selectedHex: null,
            onSelected: (hex) => picked = hex,
          ),
        ),
      );

      // Tap the yellow swatch (#FFCC00), matching the person avatar example.
      await tester.tap(
        find.byWidgetPredicate(
          (widget) =>
              widget is CaleeColorSwatch &&
              widget.color == CaleeColors.dotYellow,
        ),
      );
      await tester.pump();

      expect(picked, '#FFCC00');
    });

    testWidgets('highlights the swatch matching selectedHex', (tester) async {
      // Case-insensitive match: lowercase hex still highlights the swatch.
      await tester.pumpWidget(
        wrap(
          CaleeColorPalettePicker(selectedHex: '#ffcc00', onSelected: (_) {}),
        ),
      );

      final selected = tester
          .widgetList<CaleeColorSwatch>(find.byType(CaleeColorSwatch))
          .where((swatch) => swatch.isSelected)
          .toList();

      expect(selected, hasLength(1));
      expect(selected.single.color, CaleeColors.dotYellow);
    });
  });
}

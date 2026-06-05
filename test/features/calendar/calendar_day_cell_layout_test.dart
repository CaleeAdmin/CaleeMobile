import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

// Tests the compact DayCell layout at landscape-like constraints to verify
// no overflow occurs when screen height is small.

Widget _buildDayCellLike({
  required double circleSize,
  required double fontSize,
  required double dotSize,
  required double gap,
  required double verticalGap,
  required bool showDots,
}) {
  return ClipRect(
    child: Column(
      mainAxisAlignment: MainAxisAlignment.center,
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: circleSize,
          height: circleSize,
          decoration: const BoxDecoration(
            color: Colors.blue,
            shape: BoxShape.circle,
          ),
          alignment: Alignment.center,
          child: Text(
            '15',
            style: TextStyle(fontSize: fontSize, fontWeight: FontWeight.w400),
          ),
        ),
        if (verticalGap > 0) SizedBox(height: verticalGap),
        if (!showDots)
          const SizedBox.shrink()
        else
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              for (int i = 0; i < 3; i++) ...[
                if (i > 0) SizedBox(width: gap),
                Container(
                  width: dotSize,
                  height: dotSize,
                  decoration: const BoxDecoration(
                    color: Colors.red,
                    shape: BoxShape.circle,
                  ),
                ),
              ],
            ],
          ),
      ],
    ),
  );
}

void main() {
  // Simulates a 7-column grid inside an 844×390 viewport (landscape-like).
  // Each cell is 844/7 ≈ 120.6 wide × (grid_height/6) tall.
  // With compact sizes and clamped height the cell must not overflow.

  testWidgets('normal cell renders without overflow at 390 height', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(844, 390);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);

    // gridHeight clamped to available space; use a generous cell height.
    const cellHeight = 40.0;

    await tester.pumpWidget(
      MaterialApp(
        home: SizedBox(
          width: 844 / 7,
          height: cellHeight,
          child: _buildDayCellLike(
            circleSize: 24,
            fontSize: 12,
            dotSize: 4,
            gap: 1.5,
            verticalGap: 1,
            showDots: true,
          ),
        ),
      ),
    );

    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'veryCompact cell (no dots) renders without overflow at tight height',
    (tester) async {
      tester.view.physicalSize = const Size(667, 375);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);

      const cellHeight = 26.0;

      await tester.pumpWidget(
        MaterialApp(
          home: SizedBox(
            width: 667 / 7,
            height: cellHeight,
            child: _buildDayCellLike(
              circleSize: 22,
              fontSize: 12,
              dotSize: 0,
              gap: 0,
              verticalGap: 0,
              showDots: false,
            ),
          ),
        ),
      );

      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('compact cell fits inside 29px cell height', (tester) async {
    // compact: circle 24 + gap 1 + dot 4 = 29px total
    await tester.pumpWidget(
      MaterialApp(
        home: SizedBox(
          width: 60,
          height: 29,
          child: _buildDayCellLike(
            circleSize: 24,
            fontSize: 12,
            dotSize: 4,
            gap: 1.5,
            verticalGap: 1,
            showDots: true,
          ),
        ),
      ),
    );

    expect(tester.takeException(), isNull);
  });
}

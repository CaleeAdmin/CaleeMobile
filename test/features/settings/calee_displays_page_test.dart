// Widget tests for CaleeDisplaysPage and the Settings row that navigates to it.

import 'package:calee_mobile/features/settings/calee_displays_page.dart';
import 'package:calee_mobile/ui/calee_design.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

Widget _wrap(Widget child) => MaterialApp(
  theme: CaleeTheme.buildThemeData(),
  home: child,
);

void main() {
  group('CaleeDisplaysPage', () {
    testWidgets('shows "No Calee displays linked yet" empty state',
        (tester) async {
      await tester.pumpWidget(_wrap(const CaleeDisplaysPage()));
      await tester.pump();

      expect(find.text('No Calee displays linked yet.'), findsOneWidget);
    });

    testWidgets('shows "Link a Calee display" row', (tester) async {
      await tester.pumpWidget(_wrap(const CaleeDisplaysPage()));
      await tester.pump();

      expect(find.text('Link a Calee display'), findsOneWidget);
    });

    testWidgets('shows "Coming soon" subtitle on link row', (tester) async {
      await tester.pumpWidget(_wrap(const CaleeDisplaysPage()));
      await tester.pump();

      expect(find.text('Coming soon'), findsOneWidget);
    });

    testWidgets(
      'tapping "Link a Calee display" shows a coming-soon snackbar',
      (tester) async {
        await tester.pumpWidget(
          _wrap(const Scaffold(body: CaleeDisplaysPage())),
        );
        await tester.pump();

        await tester.tap(find.text('Link a Calee display'));
        await tester.pump();

        expect(find.text('Display linking is coming soon.'), findsOneWidget);
      },
    );

    testWidgets('page header reads "Calee displays"', (tester) async {
      await tester.pumpWidget(_wrap(const CaleeDisplaysPage()));
      await tester.pump();

      expect(find.text('Calee displays'), findsOneWidget);
    });
  });

  group('Settings → Calee displays navigation', () {
    testWidgets(
      'tapping Calee displays row opens CaleeDisplaysPage',
      (tester) async {
        // Build a minimal widget that mimics the settings row tap: a
        // ListTile that pushes CaleeDisplaysPage, matching the real
        // settings_page.dart pattern.
        await tester.pumpWidget(
          MaterialApp(
            theme: CaleeTheme.buildThemeData(),
            home: Scaffold(
              body: Builder(
                builder:
                    (ctx) => ListTile(
                      title: const Text('Calee displays'),
                      onTap: () => Navigator.push(
                        ctx,
                        MaterialPageRoute<void>(
                          builder: (_) => const CaleeDisplaysPage(),
                        ),
                      ),
                    ),
              ),
            ),
          ),
        );

        await tester.tap(find.text('Calee displays'));
        await tester.pumpAndSettle();

        expect(find.byType(CaleeDisplaysPage), findsOneWidget);
        expect(find.text('No Calee displays linked yet.'), findsOneWidget);
      },
    );
  });
}

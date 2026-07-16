// Focused tests for the two structural, additive selector-support changes
// in lib/ui/calee_widgets.dart: CaleeAction.testId and
// CaleeSectionSwitchRow.switchKey. Both are optional and must not change
// default behaviour -- these tests prove the default path still works
// unchanged, and that the new key, when supplied, actually resolves to
// the interactive widget test automation needs to find.

import 'package:calee_mobile/ui/calee_widgets.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('CaleeAction.testId', () {
    testWidgets(
      'without testId: action sheet still opens and onTap still fires',
      (tester) async {
        var tapped = false;
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: Builder(
                builder: (context) => ElevatedButton(
                  onPressed: () => CaleeActionSheet.show(
                    context: context,
                    actions: [
                      CaleeAction(
                        label: 'Do thing',
                        onTap: () => tapped = true,
                      ),
                    ],
                  ),
                  child: const Text('open'),
                ),
              ),
            ),
          ),
        );

        await tester.tap(find.text('open'));
        await tester.pumpAndSettle();

        expect(find.text('Do thing'), findsOneWidget);
        await tester.tap(find.text('Do thing'));
        await tester.pumpAndSettle();

        expect(tapped, isTrue);
      },
    );

    testWidgets(
      'with testId: action row is findable by key and onTap still fires',
      (tester) async {
        var tapped = false;
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: Builder(
                builder: (context) => ElevatedButton(
                  onPressed: () => CaleeActionSheet.show(
                    context: context,
                    actions: [
                      CaleeAction(
                        label: 'Do thing',
                        testId: 'my_test_action',
                        onTap: () => tapped = true,
                      ),
                    ],
                  ),
                  child: const Text('open'),
                ),
              ),
            ),
          ),
        );

        await tester.tap(find.text('open'));
        await tester.pumpAndSettle();

        final actionFinder = find.byKey(const Key('my_test_action'));
        expect(actionFinder, findsOneWidget);

        await tester.tap(actionFinder);
        await tester.pumpAndSettle();

        expect(tapped, isTrue);
      },
    );
  });

  group('CaleeSectionSwitchRow.switchKey', () {
    testWidgets(
      'without switchKey: the inner Switch is still reachable and onChanged still fires',
      (tester) async {
        bool? newValue;
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: CaleeSectionSwitchRow(
                label: 'Enabled',
                value: false,
                onChanged: (v) => newValue = v,
              ),
            ),
          ),
        );

        final switchFinder = find.byType(Switch);
        expect(switchFinder, findsOneWidget);

        await tester.tap(switchFinder);
        await tester.pump();

        expect(newValue, isTrue);
      },
    );

    testWidgets(
      'with switchKey: the inner Switch is findable by key and onChanged still fires',
      (tester) async {
        bool? newValue;
        const key = Key('my_switch_key');
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: CaleeSectionSwitchRow(
                label: 'Enabled',
                value: false,
                switchKey: key,
                onChanged: (v) => newValue = v,
              ),
            ),
          ),
        );

        final switchFinder = find.byKey(key);
        expect(switchFinder, findsOneWidget);
        expect(tester.widget(switchFinder), isA<Switch>());

        await tester.tap(switchFinder);
        await tester.pump();

        expect(newValue, isTrue);
      },
    );
  });
}

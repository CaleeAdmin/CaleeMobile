import 'package:calee_mobile/data/models/client_meal.dart';
import 'package:calee_mobile/features/meals/meal_suggestion_resolver.dart';
import 'package:calee_mobile/features/meals/meal_suggestion_section.dart';
import 'package:calee_mobile/ui/calee_design.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

ClientMealTemplate _saved(int id) => ClientMealTemplate(
  id: id,
  householdId: 'h1',
  name: 'Meal $id',
  defaultMealType: 'dinner',
  kidFriendly: false,
  freezerFriendly: false,
  lunchboxFriendly: false,
  isFavourite: true,
  usageCount: id,
);

void main() {
  testWidgets('shows three meals initially and More reveals three at a time', (
    tester,
  ) async {
    final suggestions = List.generate(
      7,
      (index) => MealSuggestion.saved(_saved(index + 1)),
    );

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: MealSuggestionSection(
              sectionId: 'family_favourites',
              title: MealSuggestionLabels.familyFavourites,
              suggestions: suggestions,
              emptyText: 'No family favourites yet',
              itemBuilder: (suggestion) => CaleeListRow(title: suggestion.name),
            ),
          ),
        ),
      ),
    );

    expect(find.text('Meal 1'), findsOneWidget);
    expect(find.text('Meal 3'), findsOneWidget);
    expect(find.text('Meal 4'), findsNothing);
    expect(find.text('More'), findsOneWidget);

    await tester.tap(find.text('More'));
    await tester.pump();

    expect(find.text('Meal 6'), findsOneWidget);
    expect(find.text('Meal 7'), findsNothing);
    expect(find.text('More'), findsOneWidget);

    await tester.tap(find.text('More'));
    await tester.pump();

    expect(find.text('Meal 7'), findsOneWidget);
    expect(find.text('More'), findsNothing);
  });
}

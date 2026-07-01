// Widget tests for MealsPage and MealFormSheet.
//
// Covers: list shows a meal from the current week; edit sheet pre-fills
// existing data; clearing notes during edit sends an empty string so the
// backend can clear the field.

import 'package:calee_mobile/data/api/calee_hub_client.dart';
import 'package:calee_mobile/data/models/client_meal.dart';
import 'package:calee_mobile/features/meals/meals_controller.dart';
import 'package:calee_mobile/features/meals/meals_page.dart';
import 'package:calee_mobile/features/meals/meals_repository.dart';
import 'package:calee_mobile/ui/calee_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

// ── Date helpers ──────────────────────────────────────────────────────────────

String _fmt(DateTime d) {
  final y = d.year.toString().padLeft(4, '0');
  final m = d.month.toString().padLeft(2, '0');
  final day = d.day.toString().padLeft(2, '0');
  return '$y-$m-$day';
}

DateTime _mondayOf(DateTime date) =>
    DateTime(date.year, date.month, date.day - (date.weekday - 1));

// ── Stubs ─────────────────────────────────────────────────────────────────────

class _StubHub extends CaleeHubClient {
  _StubHub({List<ClientMeal> meals = const []})
    : _meals = meals,
      super();

  final List<ClientMeal> _meals;
  bool updateCalled = false;
  String? lastUpdateNotes = 'NOT_CALLED';

  @override
  Future<ClientMealList> meals({
    required String accessToken,
    required String from,
    required String to,
  }) async =>
      ClientMealList(householdId: 'h1', from: from, to: to, meals: _meals);

  @override
  Future<ClientMeal> updateMeal({
    required String accessToken,
    required int mealId,
    String? mealDate,
    String? mealType,
    String? title,
    String? notes,
    String? status,
  }) async {
    updateCalled = true;
    lastUpdateNotes = notes;
    return _meals.isNotEmpty
        ? _meals.first
        : ClientMeal(
            id: mealId,
            householdId: 'h1',
            mealDate: mealDate ?? '',
            mealType: mealType ?? 'dinner',
            title: title ?? '',
            status: 'planned',
            source: 'manual',
          );
  }
}

// ── Constants ─────────────────────────────────────────────────────────────────

const _kExistingMeal = ClientMeal(
  id: 7,
  householdId: 'h1',
  mealDate: '2024-01-15',
  mealType: 'dinner',
  title: 'Spaghetti Bolognese',
  status: 'planned',
  source: 'manual',
  notes: 'Use whole wheat pasta',
);

// ── Build helpers ─────────────────────────────────────────────────────────────

Widget _buildMealsPage(CaleeHubClient hub) {
  return MaterialApp(
    theme: CaleeTheme.buildThemeData(),
    home: MealsPage(hubClient: hub, accessToken: 'tok'),
  );
}

Widget _buildFormSheet({
  required MealsController controller,
  required ClientMeal existingMeal,
}) {
  return MaterialApp(
    theme: CaleeTheme.buildThemeData(),
    home: Scaffold(
      body: MealFormSheet(
        date: existingMeal.mealDate,
        mealType: existingMeal.mealType,
        controller: controller,
        existingMeal: existingMeal,
      ),
    ),
  );
}

// ── Tests ──────────────────────────────────────────────────────────────────────

void main() {
  group('MealsPage — list', () {
    testWidgets('shows meal title in weekly list', (tester) async {
      final monday = _mondayOf(DateTime.now());
      final meal = ClientMeal(
        id: 1,
        householdId: 'h1',
        mealDate: _fmt(monday),
        mealType: 'breakfast',
        title: 'Scrambled Eggs',
        status: 'planned',
        source: 'manual',
      );

      final hub = _StubHub(meals: [meal]);
      await tester.pumpWidget(_buildMealsPage(hub));
      await tester.pump();
      await tester.pump();

      // Day sections exist with Breakfast/Lunch/Dinner rows for each day.
      expect(find.text('Breakfast'), findsWidgets);
      expect(find.text('Lunch'), findsWidgets);
      expect(find.text('Dinner'), findsWidgets);
      // Existing meal title appears in the Breakfast row.
      expect(find.text('Scrambled Eggs'), findsOneWidget);
      // Empty meal slots show 'Not planned'.
      expect(find.text('Not planned'), findsWidgets);
    });
  });

  group('MealFormSheet — show existing meal', () {
    testWidgets('shows existing meal title and notes', (tester) async {
      final hub = _StubHub(meals: const [_kExistingMeal]);
      final controller = MealsController(
        repository: MealsRepository(hubClient: hub, accessToken: 'tok'),
      );

      await tester.pumpWidget(
        _buildFormSheet(
          controller: controller,
          existingMeal: _kExistingMeal,
        ),
      );

      expect(find.text('Spaghetti Bolognese'), findsOneWidget);
      expect(find.text('Use whole wheat pasta'), findsOneWidget);
    });
  });

  group('MealFormSheet — edit notes to blank', () {
    testWidgets('sends empty string notes so backend can clear field', (
      tester,
    ) async {
      final hub = _StubHub(meals: const [_kExistingMeal]);
      final controller = MealsController(
        repository: MealsRepository(hubClient: hub, accessToken: 'tok'),
      );

      await tester.pumpWidget(
        _buildFormSheet(
          controller: controller,
          existingMeal: _kExistingMeal,
        ),
      );

      // Clear the notes field (second TextFormField — title is first).
      await tester.enterText(find.byType(TextFormField).at(1), '');
      await tester.pump();

      await tester.tap(find.text('Save'));
      await tester.pump();
      await tester.pump();

      expect(hub.updateCalled, isTrue);
      expect(hub.lastUpdateNotes, '');
    });
  });
}

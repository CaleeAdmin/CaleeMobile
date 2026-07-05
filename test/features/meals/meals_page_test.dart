// Widget tests for MealsPage, PickDinnerSheet and MealFormSheet.
//
// Covers: the dinner-first weekly list (planned dinners with inline notes,
// "Pick dinner" for empty days, breakfast/lunch hidden until expanded); the
// Pick dinner sheet's Family favourites / Quick dinner ideas / Create new
// meal flows; and the existing MealFormSheet edit/save behaviour.

import 'package:calee_mobile/data/api/calee_hub_client.dart';
import 'package:calee_mobile/data/models/client_meal.dart';
import 'package:calee_mobile/data/models/client_shopping_list.dart';
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

/// The dinner-first Meals page is taller than the default 800x600 test
/// surface, and a plain (non-builder) ListView only lays out slivers near
/// the viewport — rows below the fold exist in the widget tree but are
/// "offstage" to finders. Growing the surface keeps everything reachable
/// without scrolling in every test.
void _useTallViewport(WidgetTester tester) {
  tester.view.physicalSize = const Size(800, 4000);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
}

// ── Stubs ─────────────────────────────────────────────────────────────────────

class _StubHub extends CaleeHubClient {
  _StubHub({
    this._meals = const [],
    this._favourites = const [],
    this._quickIdeas = const [],
  }) : super();

  final List<ClientMeal> _meals;
  final List<ClientMealTemplate> _favourites;
  final List<ClientStarterMealTemplate> _quickIdeas;

  bool updateCalled = false;
  String? lastUpdateNotes = 'NOT_CALLED';
  bool createCalled = false;
  String? lastCreateTitle;
  String? lastCreateNotes;
  bool deleteCalled = false;
  String? lastGenerateFrom;
  String? lastGenerateTo;

  @override
  Future<ClientMealList> meals({
    required String accessToken,
    required String from,
    required String to,
  }) async =>
      ClientMealList(householdId: 'h1', from: from, to: to, meals: _meals);

  @override
  Future<ClientMeal> createMeal({
    required String accessToken,
    required String mealDate,
    required String mealType,
    required String title,
    String? notes,
  }) async {
    createCalled = true;
    lastCreateTitle = title;
    lastCreateNotes = notes;
    return ClientMeal(
      id: 99,
      householdId: 'h1',
      mealDate: mealDate,
      mealType: mealType,
      title: title,
      status: 'planned',
      source: 'manual',
      notes: notes,
    );
  }

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

  @override
  Future<void> deleteMeal({
    required String accessToken,
    required int mealId,
  }) async {
    deleteCalled = true;
  }

  @override
  Future<ClientMealTemplateList> mealTemplates({
    required String accessToken,
    String? mealType,
  }) async => ClientMealTemplateList(templates: _favourites);

  @override
  Future<List<ClientStarterMealTemplate>> mealStarterTemplates({
    required String accessToken,
    String? mealType,
    String? pack,
  }) async => _quickIdeas;

  @override
  Future<ClientShoppingList> generateShoppingList({
    required String accessToken,
    required String from,
    required String to,
    String mode = 'merge',
  }) async {
    lastGenerateFrom = from;
    lastGenerateTo = to;
    return ClientShoppingList(
      id: 1,
      householdId: 'h1',
      title: 'Shopping list',
      fromDate: from,
      toDate: to,
      status: 'active',
      items: const [],
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

ClientMealTemplate _favourite({
  required int id,
  required String name,
  String? icon,
  String? notes,
}) => ClientMealTemplate(
  id: id,
  householdId: 'h1',
  name: name,
  defaultMealType: 'dinner',
  icon: icon,
  notes: notes,
  kidFriendly: false,
  freezerFriendly: false,
  lunchboxFriendly: false,
  isFavourite: true,
  usageCount: 0,
);

ClientStarterMealTemplate _quickIdea({
  required int id,
  required String name,
  String? icon,
}) => ClientStarterMealTemplate(
  id: id,
  slug: name.toLowerCase().replaceAll(' ', '-'),
  name: name,
  defaultMealType: 'dinner',
  icon: icon,
  kidFriendly: false,
  freezerFriendly: false,
  lunchboxFriendly: false,
  sortOrder: 0,
  version: 1,
  active: true,
  ingredients: const [],
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
  group('MealsPage — dinner-first list', () {
    testWidgets('shows a planned dinner with icon and inline note', (
      tester,
    ) async {
      _useTallViewport(tester);
      final monday = _mondayOf(DateTime.now());
      final meal = ClientMeal(
        id: 1,
        householdId: 'h1',
        mealDate: _fmt(monday),
        mealType: 'dinner',
        title: 'Fried Rice',
        status: 'planned',
        source: 'manual',
        notes: 'extra veggies',
      );

      final hub = _StubHub(meals: [meal]);
      await tester.pumpWidget(_buildMealsPage(hub));
      await tester.pump();
      await tester.pump();

      // CaleeSection upper-cases its title.
      expect(find.text("THIS WEEK'S DINNERS"), findsOneWidget);
      expect(find.text('🍚 Fried Rice · extra veggies'), findsOneWidget);
      // 6 remaining days have no dinner planned.
      expect(find.text('Pick dinner'), findsNWidgets(6));
      expect(find.text('1 of 7 dinners planned'), findsOneWidget);
    });

    testWidgets('shows "All 7 dinners planned" when every day has one', (
      tester,
    ) async {
      _useTallViewport(tester);
      final monday = _mondayOf(DateTime.now());
      final meals = List.generate(
        7,
        (i) => ClientMeal(
          id: i + 1,
          householdId: 'h1',
          mealDate: _fmt(DateTime(monday.year, monday.month, monday.day + i)),
          mealType: 'dinner',
          title: 'Meal $i',
          status: 'planned',
          source: 'manual',
        ),
      );

      final hub = _StubHub(meals: meals);
      await tester.pumpWidget(_buildMealsPage(hub));
      await tester.pump();
      await tester.pump();

      expect(find.text('All 7 dinners planned'), findsOneWidget);
      expect(find.text('Pick dinner'), findsNothing);
    });

    testWidgets(
      'breakfast and lunch are hidden until "Show breakfast & lunch" is tapped',
      (tester) async {
        _useTallViewport(tester);
        final hub = _StubHub();
        await tester.pumpWidget(_buildMealsPage(hub));
        await tester.pump();
        await tester.pump();

        expect(find.text('Show breakfast & lunch'), findsOneWidget);
        expect(find.text('Breakfast'), findsNothing);
        expect(find.text('Lunch'), findsNothing);

        await tester.tap(find.text('Show breakfast & lunch'));
        await tester.pump();

        expect(find.text('Hide breakfast & lunch'), findsOneWidget);
        expect(find.text('Breakfast'), findsWidgets);
        expect(find.text('Lunch'), findsWidgets);
      },
    );
  });

  group('MealsPage — Pick dinner sheet', () {
    testWidgets(
      'tapping "Pick dinner" opens favourites and quick dinner ideas',
      (tester) async {
        _useTallViewport(tester);
        final hub = _StubHub(
          favourites: [_favourite(id: 1, name: 'Taco Night', icon: 'taco')],
          quickIdeas: [
            _quickIdea(id: 2, name: 'Butter Chicken', icon: 'curry'),
          ],
        );
        await tester.pumpWidget(_buildMealsPage(hub));
        await tester.pump();
        await tester.pump();

        await tester.tap(find.text('Pick dinner').first);
        await tester.pumpAndSettle();

        // The sheet's own title plus the still-mounted "Pick dinner" rows
        // behind it for the other unplanned days.
        expect(find.text('Pick dinner'), findsWidgets);
        // CaleeSection upper-cases its title.
        expect(find.text('FAMILY FAVOURITES'), findsOneWidget);
        expect(find.text('QUICK DINNER IDEAS'), findsOneWidget);
        expect(find.text('Taco Night'), findsOneWidget);
        expect(find.text('Butter Chicken'), findsOneWidget);
        expect(find.text('Create new meal'), findsOneWidget);
      },
    );

    testWidgets('selecting a family favourite creates the meal', (
      tester,
    ) async {
      _useTallViewport(tester);
      final hub = _StubHub(
        favourites: [
          _favourite(id: 1, name: 'Taco Night', icon: 'taco', notes: 'mild'),
        ],
      );
      await tester.pumpWidget(_buildMealsPage(hub));
      await tester.pump();
      await tester.pump();

      await tester.tap(find.text('Pick dinner').first);
      await tester.pumpAndSettle();

      await tester.tap(find.text('Taco Night'));
      await tester.pumpAndSettle();

      expect(hub.createCalled, isTrue);
      expect(hub.lastCreateTitle, 'Taco Night');
      expect(hub.lastCreateNotes, 'mild');
    });

    testWidgets('"Create new meal" opens the plain meal form', (tester) async {
      _useTallViewport(tester);
      final hub = _StubHub();
      await tester.pumpWidget(_buildMealsPage(hub));
      await tester.pump();
      await tester.pump();

      await tester.tap(find.text('Pick dinner').first);
      await tester.pumpAndSettle();

      await tester.tap(find.text('Create new meal'));
      await tester.pumpAndSettle();

      expect(find.text('Add Dinner'), findsOneWidget);
    });
  });

  group('MealFormSheet — show existing meal', () {
    testWidgets('shows existing meal title and notes', (tester) async {
      final hub = _StubHub(meals: const [_kExistingMeal]);
      final controller = MealsController(
        repository: MealsRepository(hubClient: hub, accessToken: 'tok'),
      );

      await tester.pumpWidget(
        _buildFormSheet(controller: controller, existingMeal: _kExistingMeal),
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
        _buildFormSheet(controller: controller, existingMeal: _kExistingMeal),
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

  group('MealsPage — grocery list navigation', () {
    testWidgets(
      'passes the visible Meals week into ShoppingPage instead of the '
      'current calendar week',
      (tester) async {
        _useTallViewport(tester);
        final hub = _StubHub();
        await tester.pumpWidget(_buildMealsPage(hub));
        await tester.pump();
        await tester.pump();

        // Move to the previous week so the visible week differs from today.
        await tester.tap(find.byIcon(Icons.chevron_left));
        await tester.pump();
        await tester.pump();

        final monday = _mondayOf(DateTime.now());
        final expectedStart = DateTime(
          monday.year,
          monday.month,
          monday.day - 7,
        );
        final expectedEnd = DateTime(
          expectedStart.year,
          expectedStart.month,
          expectedStart.day + 6,
        );

        await tester.tap(find.text('Build grocery list'));
        await tester.pumpAndSettle();

        expect(hub.lastGenerateFrom, _fmt(expectedStart));
        expect(hub.lastGenerateTo, _fmt(expectedEnd));
      },
    );
  });
}

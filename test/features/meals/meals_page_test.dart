// Widget tests for MealsPage, PickDinnerSheet and MealFormSheet.
//
// Covers: the day-based weekly meal sections (breakfast/lunch/dinner rows
// per day, with inline notes on planned meals and "Add <meal type>" for
// empty slots); the compact actions row (grocery list / copy week); the
// Pick dinner sheet's Family favourites / Recently used / Quick dinner ideas /
// Create new meal flows; and the existing MealFormSheet edit/save behaviour.

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

/// The day-sectioned Meals page is taller than the default 800x600 test
/// surface, and a plain (non-builder) ListView only lays out slivers near
/// the viewport — rows below the fold exist in the widget tree but are
/// "offstage" to finders. Growing the surface keeps everything reachable
/// without scrolling in every test.
void _useTallViewport(WidgetTester tester) {
  tester.view.physicalSize = const Size(800, 6000);
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
    this.failSuggestions = false,
  }) : super();

  final List<ClientMeal> _meals;
  final List<ClientMealTemplate> _favourites;
  final List<ClientStarterMealTemplate> _quickIdeas;
  final bool failSuggestions;

  bool updateCalled = false;
  String? lastUpdateNotes = 'NOT_CALLED';
  bool createCalled = false;
  String? lastCreateTitle;
  String? lastCreateNotes;
  int? lastCreateTemplateId;
  int? lastCreateStarterTemplateId;
  bool deleteCalled = false;
  String? lastGenerateFrom;
  String? lastGenerateTo;
  bool currentShoppingListCalled = false;

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
    int? templateId,
    int? starterTemplateId,
  }) async {
    createCalled = true;
    lastCreateTitle = title;
    lastCreateNotes = notes;
    lastCreateTemplateId = templateId;
    lastCreateStarterTemplateId = starterTemplateId;
    return ClientMeal(
      id: 99,
      householdId: 'h1',
      mealDate: mealDate,
      mealType: mealType,
      title: title,
      status: 'planned',
      source: 'manual',
      notes: notes,
      templateId: templateId,
      starterTemplateId: starterTemplateId,
    );
  }

  @override
  Future<ClientShoppingList> currentShoppingList({
    required String accessToken,
    required String from,
    required String to,
  }) async {
    currentShoppingListCalled = true;
    throw const CaleeHubException(statusCode: 404, message: 'Not found');
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
  }) async {
    if (failSuggestions) throw StateError('suggestions unavailable');
    return ClientMealTemplateList(templates: _favourites);
  }

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
  bool isFavourite = true,
  int usageCount = 0,
  String? lastUsedAt,
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
  isFavourite: isFavourite,
  usageCount: usageCount,
  lastUsedAt: lastUsedAt,
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
  group('MealsPage — regression-suite contract', () {
    // The regression suite scrolls the meal plan by this key. Resolving the
    // scroll container positionally instead (Scrollable.first/.last) picks the
    // wrong one and throws while the list rebuilds, so the key must exist and
    // must resolve to exactly one widget.
    testWidgets('exposes exactly one meals-list scroll container', (
      tester,
    ) async {
      _useTallViewport(tester);
      await tester.pumpWidget(_buildMealsPage(_StubHub()));
      await tester.pump();
      await tester.pump();

      expect(find.byKey(mealsListKey), findsOneWidget);
      expect(
        find.descendant(
          of: find.byKey(mealsListKey),
          matching: find.byType(Scrollable),
        ),
        findsOneWidget,
      );
    });

    testWidgets('the meals list stays mounted while a week load is in flight', (
      tester,
    ) async {
      _useTallViewport(tester);
      await tester.pumpWidget(_buildMealsPage(_StubHub()));
      // Deliberately not settled: this is the rebuild window the old
      // scrollUntilVisible path raced against.
      await tester.pump();

      expect(find.byKey(mealsListKey), findsOneWidget);
    });
  });

  group('MealsPage — day sections', () {
    testWidgets('shows a Today section with breakfast, lunch and dinner rows', (
      tester,
    ) async {
      _useTallViewport(tester);
      final hub = _StubHub();
      await tester.pumpWidget(_buildMealsPage(hub));
      await tester.pump();
      await tester.pump();

      expect(find.text('TODAY'), findsOneWidget);
      expect(find.text('Breakfast'), findsWidgets);
      expect(find.text('Lunch'), findsWidgets);
      expect(find.text('Dinner'), findsWidgets);
      expect(find.text('Add breakfast'), findsWidgets);
      expect(find.text('Add lunch'), findsWidgets);
      expect(find.text('Add dinner'), findsWidgets);
    });

    testWidgets(
      'shows a planned dinner with title and inline note in its day section',
      (tester) async {
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

        // Only the title is shown inline; notes stay inside the edit sheet.
        expect(find.text('Fried Rice'), findsOneWidget);
        expect(find.text('Fried Rice · extra veggies'), findsNothing);
        // The dinner-hero summary rows ("Tonight" / "N of 7 planned") no
        // longer exist.
        expect(find.textContaining('dinners planned'), findsNothing);
        expect(find.textContaining('Tonight'), findsNothing);
      },
    );

    testWidgets(
      'does not render the old dinner-hero "This week\'s dinners" heading',
      (tester) async {
        _useTallViewport(tester);
        final hub = _StubHub();
        await tester.pumpWidget(_buildMealsPage(hub));
        await tester.pump();
        await tester.pump();

        expect(find.text("THIS WEEK'S DINNERS"), findsNothing);
        expect(find.text('Pick dinner'), findsNothing);
      },
    );

    testWidgets('tapping a missing breakfast row opens the add meal sheet', (
      tester,
    ) async {
      _useTallViewport(tester);
      final hub = _StubHub();
      await tester.pumpWidget(_buildMealsPage(hub));
      await tester.pump();
      await tester.pump();

      await tester.tap(find.text('Add breakfast').first);
      await tester.pumpAndSettle();

      expect(find.text('Add Breakfast'), findsOneWidget);
    });

    testWidgets('tapping a planned meal row opens the edit meal sheet', (
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
      );

      final hub = _StubHub(meals: [meal]);
      await tester.pumpWidget(_buildMealsPage(hub));
      await tester.pump();
      await tester.pump();

      await tester.tap(find.text('Fried Rice'));
      await tester.pumpAndSettle();

      expect(find.text('Edit Dinner'), findsOneWidget);
    });
  });

  group('MealsPage — Pick dinner sheet', () {
    testWidgets(
      'tapping "Add dinner" opens favourites and quick dinner ideas',
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

        await tester.tap(find.text('Add dinner').first);
        await tester.pumpAndSettle();

        expect(find.text('Pick dinner'), findsOneWidget);
        // CaleeSection upper-cases its title.
        expect(find.text('FAMILY FAVOURITES'), findsOneWidget);
        expect(find.text('QUICK DINNER IDEAS'), findsOneWidget);
        expect(find.text('Taco Night'), findsOneWidget);
        expect(find.text('Butter Chicken'), findsOneWidget);
        expect(find.text('Create new meal'), findsOneWidget);
      },
    );

    testWidgets('shows only explicit favourites and separates recent meals', (
      tester,
    ) async {
      _useTallViewport(tester);
      final hub = _StubHub(
        favourites: [
          _favourite(id: 1, name: 'Taco Night'),
          _favourite(
            id: 2,
            name: 'Recent Pasta',
            isFavourite: false,
            usageCount: 2,
          ),
          _favourite(id: 3, name: 'Unused Soup', isFavourite: false),
        ],
      );
      await tester.pumpWidget(_buildMealsPage(hub));
      await tester.pumpAndSettle();

      await tester.tap(find.text('Add dinner').first);
      await tester.pumpAndSettle();

      expect(find.text('FAMILY FAVOURITES'), findsOneWidget);
      expect(find.text('RECENTLY USED'), findsOneWidget);
      expect(find.text('Taco Night'), findsOneWidget);
      expect(find.text('Recent Pasta'), findsOneWidget);
      expect(find.text('Unused Soup'), findsNothing);
    });

    testWidgets('shows three choices per group until More is tapped', (
      tester,
    ) async {
      _useTallViewport(tester);
      final hub = _StubHub(
        favourites: List.generate(
          4,
          (index) => _favourite(id: index + 1, name: 'Favourite ${index + 1}'),
        ),
      );
      await tester.pumpWidget(_buildMealsPage(hub));
      await tester.pumpAndSettle();

      await tester.tap(find.text('Add dinner').first);
      await tester.pumpAndSettle();

      expect(find.text('Favourite 3'), findsOneWidget);
      expect(find.text('Favourite 4'), findsNothing);
      await tester.tap(find.text('More'));
      await tester.pump();
      expect(find.text('Favourite 4'), findsOneWidget);
    });

    testWidgets('load failure still offers Create new meal', (tester) async {
      _useTallViewport(tester);
      final hub = _StubHub(failSuggestions: true);
      await tester.pumpWidget(_buildMealsPage(hub));
      await tester.pumpAndSettle();

      await tester.tap(find.text('Add dinner').first);
      await tester.pumpAndSettle();

      expect(
        find.text('Could not load saved or suggested meals'),
        findsOneWidget,
      );
      expect(find.text('Create new meal'), findsOneWidget);
    });

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

      await tester.tap(find.text('Add dinner').first);
      await tester.pumpAndSettle();

      await tester.tap(find.text('Taco Night'));
      await tester.pumpAndSettle();

      expect(hub.createCalled, isTrue);
      expect(hub.lastCreateTitle, 'Taco Night');
      expect(hub.lastCreateNotes, 'mild');
      // The favourite's identity is attached so the backend can still find
      // its ingredients when generating a grocery list.
      expect(hub.lastCreateTemplateId, 1);
      expect(hub.lastCreateStarterTemplateId, isNull);
    });

    testWidgets('selecting a quick dinner idea creates the meal with its '
        'starter template id', (tester) async {
      _useTallViewport(tester);
      final hub = _StubHub(
        quickIdeas: [_quickIdea(id: 5, name: 'Butter Chicken')],
      );
      await tester.pumpWidget(_buildMealsPage(hub));
      await tester.pump();
      await tester.pump();

      await tester.tap(find.text('Add dinner').first);
      await tester.pumpAndSettle();

      await tester.tap(find.text('Butter Chicken'));
      await tester.pumpAndSettle();

      expect(hub.createCalled, isTrue);
      expect(hub.lastCreateTitle, 'Butter Chicken');
      expect(hub.lastCreateStarterTemplateId, 5);
      expect(hub.lastCreateTemplateId, isNull);
    });

    testWidgets('"Create new meal" opens the plain meal form', (tester) async {
      _useTallViewport(tester);
      final hub = _StubHub();
      await tester.pumpWidget(_buildMealsPage(hub));
      await tester.pump();
      await tester.pump();

      await tester.tap(find.text('Add dinner').first);
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

  group('MealsPage — top bar actions', () {
    testWidgets(
      'top bar shows search, saved meals, shopping, copy and add icons',
      (tester) async {
        _useTallViewport(tester);
        final hub = _StubHub();
        await tester.pumpWidget(_buildMealsPage(hub));
        await tester.pump();
        await tester.pump();

        expect(find.byTooltip('Search meals'), findsOneWidget);
        expect(find.byTooltip('Saved meals'), findsOneWidget);
        expect(find.byTooltip('Shopping'), findsOneWidget);
        expect(find.byTooltip('Copy last week'), findsOneWidget);
        expect(find.byTooltip('Add meal'), findsOneWidget);
      },
    );

    testWidgets('saved meals icon opens the Saved meals screen', (
      tester,
    ) async {
      _useTallViewport(tester);
      final hub = _StubHub(
        favourites: [_favourite(id: 1, name: 'Spaghetti Bolognese')],
        quickIdeas: [_quickIdea(id: 2, name: 'Tacos')],
      );
      await tester.pumpWidget(_buildMealsPage(hub));
      await tester.pump();
      await tester.pump();

      await tester.tap(find.byTooltip('Saved meals'));
      await tester.pumpAndSettle();

      expect(find.text('Saved meals'), findsOneWidget);
      expect(find.text('FAMILY FAVOURITES'), findsOneWidget);
      expect(find.text('Spaghetti Bolognese'), findsWidgets);
      expect(find.text('QUICK DINNER IDEAS'), findsOneWidget);
      expect(find.text('Tacos'), findsOneWidget);
    });

    testWidgets(
      'shopping icon always offers "Build grocery list" and "Open shopping '
      'list" without probing whether a list exists',
      (tester) async {
        _useTallViewport(tester);
        final hub = _StubHub();
        await tester.pumpWidget(_buildMealsPage(hub));
        await tester.pump();
        await tester.pump();

        await tester.tap(find.byTooltip('Shopping'));
        await tester.pumpAndSettle();

        expect(find.text('Build grocery list'), findsOneWidget);
        expect(find.text('Open shopping list'), findsOneWidget);
        // The only non-mutating way to check "does a list exist" would be
        // to call currentShoppingList(), which get-or-creates on the
        // backend — so the sheet must never call it just to decide what to
        // show.
        expect(hub.currentShoppingListCalled, isFalse);
      },
    );

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

        await tester.tap(find.byTooltip('Shopping'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Build grocery list'));
        await tester.pumpAndSettle();

        expect(hub.lastGenerateFrom, _fmt(expectedStart));
        expect(hub.lastGenerateTo, _fmt(expectedEnd));
      },
    );

    testWidgets('copy icon opens the copy previous week sheet', (tester) async {
      _useTallViewport(tester);
      final hub = _StubHub();
      await tester.pumpWidget(_buildMealsPage(hub));
      await tester.pump();
      await tester.pump();

      await tester.tap(find.byTooltip('Copy last week'));
      await tester.pumpAndSettle();

      expect(find.text('Copy previous week?'), findsOneWidget);
    });

    testWidgets(
      '+ opens the Add meal sheet with date, meal type, title and notes',
      (tester) async {
        _useTallViewport(tester);
        final hub = _StubHub();
        await tester.pumpWidget(_buildMealsPage(hub));
        await tester.pump();
        await tester.pump();

        await tester.tap(find.byTooltip('Add meal'));
        await tester.pumpAndSettle();

        expect(find.text('Add meal'), findsOneWidget);
        expect(find.text('Meal type'), findsOneWidget);
        expect(find.text('Choose saved or suggested meal'), findsOneWidget);
        expect(find.text('Meal title'), findsOneWidget);
        expect(find.text('Notes (optional)'), findsOneWidget);
      },
    );

    testWidgets('+ sheet saves a meal via createMeal for the chosen type', (
      tester,
    ) async {
      _useTallViewport(tester);
      final hub = _StubHub();
      await tester.pumpWidget(_buildMealsPage(hub));
      await tester.pump();
      await tester.pump();

      await tester.tap(find.byTooltip('Add meal'));
      await tester.pumpAndSettle();

      await tester.enterText(find.byType(TextFormField).first, 'Pancakes');
      await tester.tap(find.text('Save'));
      await tester.pump();
      await tester.pump();

      expect(hub.createCalled, isTrue);
      expect(hub.lastCreateTitle, 'Pancakes');
    });

    testWidgets('+ can reuse a saved meal without losing template linkage', (
      tester,
    ) async {
      _useTallViewport(tester);
      final hub = _StubHub(
        favourites: [
          _favourite(id: 7, name: 'Family Lasagne', notes: 'Extra vegetables'),
        ],
      );
      await tester.pumpWidget(_buildMealsPage(hub));
      await tester.pumpAndSettle();

      await tester.tap(find.byTooltip('Add meal'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Choose saved or suggested meal'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Family Lasagne'));
      await tester.pumpAndSettle();

      expect(
        find.widgetWithText(TextFormField, 'Family Lasagne'),
        findsOneWidget,
      );
      expect(
        find.widgetWithText(TextFormField, 'Extra vegetables'),
        findsOneWidget,
      );

      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();

      expect(hub.lastCreateTemplateId, 7);
      expect(hub.lastCreateStarterTemplateId, isNull);
    });

    testWidgets(
      '+ can reuse a Quick dinner idea without losing starter linkage',
      (tester) async {
        _useTallViewport(tester);
        final hub = _StubHub(
          quickIdeas: [_quickIdea(id: 11, name: 'Quick Noodles')],
        );
        await tester.pumpWidget(_buildMealsPage(hub));
        await tester.pumpAndSettle();

        await tester.tap(find.byTooltip('Add meal'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Choose saved or suggested meal'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Quick Noodles'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Save'));
        await tester.pumpAndSettle();

        expect(hub.lastCreateStarterTemplateId, 11);
        expect(hub.lastCreateTemplateId, isNull);
      },
    );

    testWidgets('+ chooser keeps Create new visible above a long list', (
      tester,
    ) async {
      final hub = _StubHub(
        favourites: List.generate(
          4,
          (index) => _favourite(id: index + 1, name: 'Saved ${index + 1}'),
        ),
        quickIdeas: List.generate(
          4,
          (index) => _quickIdea(id: index + 10, name: 'Idea ${index + 1}'),
        ),
      );
      await tester.pumpWidget(_buildMealsPage(hub));
      await tester.pumpAndSettle();

      await tester.tap(find.byTooltip('Add meal'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Choose saved or suggested meal'));
      await tester.pumpAndSettle();

      final createNew = find.byKey(const Key('meal_suggestions_create_new'));
      expect(createNew, findsOneWidget);
      expect(tester.getRect(createNew).bottom, lessThanOrEqualTo(600));
    });

    testWidgets('search finds a saved meal by notes outside the visible week', (
      tester,
    ) async {
      _useTallViewport(tester);
      final hub = _StubHub(
        favourites: [
          _favourite(
            id: 8,
            name: 'Vegetable Curry',
            notes: 'Uses coconut milk',
          ),
        ],
      );
      await tester.pumpWidget(_buildMealsPage(hub));
      await tester.pumpAndSettle();

      await tester.tap(find.byTooltip('Search meals'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), 'coconut');
      await tester.pumpAndSettle();

      expect(find.text('FAMILY FAVOURITES'), findsOneWidget);
      expect(find.text('Vegetable Curry'), findsOneWidget);
      expect(find.text('Create new meal'), findsOneWidget);
    });

    testWidgets('search finds a Quick dinner idea not planned this week', (
      tester,
    ) async {
      _useTallViewport(tester);
      final hub = _StubHub(
        quickIdeas: [_quickIdea(id: 9, name: 'Quick Teriyaki')],
      );
      await tester.pumpWidget(_buildMealsPage(hub));
      await tester.pumpAndSettle();

      await tester.tap(find.byTooltip('Search meals'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), 'teriyaki');
      await tester.pumpAndSettle();

      expect(find.text('QUICK DINNER IDEAS'), findsOneWidget);
      expect(find.text('Quick Teriyaki'), findsOneWidget);

      await tester.tap(find.text('Quick Teriyaki'));
      await tester.pumpAndSettle();

      expect(find.text('Quick dinner idea'), findsOneWidget);
      expect(find.text('Add to this week'), findsOneWidget);
      expect(find.text('Save'), findsNothing);
      expect(find.text('Delete'), findsNothing);
    });

    testWidgets('search keeps existing visible-week meal results', (
      tester,
    ) async {
      _useTallViewport(tester);
      final monday = _mondayOf(DateTime.now());
      final hub = _StubHub(
        meals: [
          ClientMeal(
            id: 12,
            householdId: 'h1',
            mealDate: _fmt(monday),
            mealType: 'dinner',
            title: 'Current Week Pizza',
            status: 'planned',
            source: 'manual',
          ),
        ],
      );
      await tester.pumpWidget(_buildMealsPage(hub));
      await tester.pumpAndSettle();

      await tester.tap(find.byTooltip('Search meals'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), 'pizza');
      await tester.pumpAndSettle();

      expect(find.text('THIS WEEK'), findsOneWidget);
      expect(find.text('Current Week Pizza'), findsWidgets);
    });
  });
}

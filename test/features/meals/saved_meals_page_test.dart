// Widget tests for SavedMealsPage, ManageSavedMealSheet and
// QuickDinnerIdeaSheet.
//
// Covers: Family favourites / Recent meals / Quick dinner ideas sections;
// renaming, favouriting and deleting a household saved meal; and adding a
// saved meal or quick dinner idea to the current week via the existing
// createMeal(templateId/starterTemplateId) path so grocery ingredient
// linkage is preserved.

import 'package:calee_mobile/data/api/calee_hub_client.dart';
import 'package:calee_mobile/data/models/client_meal.dart';
import 'package:calee_mobile/data/models/client_shopping_list.dart';
import 'package:calee_mobile/features/meals/meals_controller.dart';
import 'package:calee_mobile/features/meals/meals_repository.dart';
import 'package:calee_mobile/features/meals/saved_meals_page.dart';
import 'package:calee_mobile/ui/calee_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

class _StubHub extends CaleeHubClient {
  _StubHub({
    this._templates = const [],
    this._quickIdeas = const [],
    Map<int, List<ClientTemplateIngredient>>? ingredientsByTemplateId,
  }) : _ingredientsByTemplateId = ingredientsByTemplateId ?? {},
       super();

  List<ClientMealTemplate> _templates;
  final List<ClientStarterMealTemplate> _quickIdeas;
  final Map<int, List<ClientTemplateIngredient>> _ingredientsByTemplateId;
  int _nextIngredientId = 1000;

  bool addIngredientCalled = false;
  int? lastAddIngredientTemplateId;
  String? lastAddIngredientName;
  String? lastAddIngredientQuantityText;
  String? lastAddIngredientCategory;

  bool updateIngredientCalled = false;
  int? lastUpdateIngredientId;

  bool deleteIngredientCalled = false;
  int? lastDeleteIngredientId;

  bool createMealCalled = false;
  String? lastCreateTitle;
  int? lastCreateTemplateId;
  int? lastCreateStarterTemplateId;

  bool updateTemplateCalled = false;
  int? lastUpdateTemplateId;
  String? lastUpdateName;
  bool? lastUpdateIsFavourite;

  bool deleteTemplateCalled = false;
  int? lastDeleteTemplateId;

  bool createTemplateCalled = false;
  String? lastCreateTemplateName;
  String? lastCreateTemplateDefaultMealType;
  String? lastCreateTemplateNotes;
  bool? lastCreateTemplateIsFavourite;

  @override
  Future<ClientMealList> meals({
    required String accessToken,
    required String from,
    required String to,
  }) async =>
      ClientMealList(householdId: 'h1', from: from, to: to, meals: const []);

  @override
  Future<ClientMealTemplateList> mealTemplates({
    required String accessToken,
    String? mealType,
  }) async => ClientMealTemplateList(templates: _templates);

  @override
  Future<List<ClientStarterMealTemplate>> mealStarterTemplates({
    required String accessToken,
    String? mealType,
    String? pack,
  }) async => _quickIdeas;

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
    createMealCalled = true;
    lastCreateTitle = title;
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
  Future<ClientMealTemplate> updateMealTemplate({
    required String accessToken,
    required int templateId,
    String? name,
    String? notes,
    bool? isFavourite,
  }) async {
    updateTemplateCalled = true;
    lastUpdateTemplateId = templateId;
    lastUpdateName = name;
    lastUpdateIsFavourite = isFavourite;
    final existing = _templates.firstWhere((t) => t.id == templateId);
    return ClientMealTemplate(
      id: existing.id,
      householdId: existing.householdId,
      name: name ?? existing.name,
      defaultMealType: existing.defaultMealType,
      icon: existing.icon,
      notes: notes ?? existing.notes,
      kidFriendly: existing.kidFriendly,
      freezerFriendly: existing.freezerFriendly,
      lunchboxFriendly: existing.lunchboxFriendly,
      isFavourite: isFavourite ?? existing.isFavourite,
      usageCount: existing.usageCount,
    );
  }

  @override
  Future<void> deleteMealTemplate({
    required String accessToken,
    required int templateId,
  }) async {
    deleteTemplateCalled = true;
    lastDeleteTemplateId = templateId;
    _templates = _templates.where((t) => t.id != templateId).toList();
  }

  @override
  Future<ClientMealTemplate> createMealTemplate({
    required String accessToken,
    required String name,
    required String defaultMealType,
    String? notes,
    String? icon,
    bool? isFavourite,
  }) async {
    createTemplateCalled = true;
    lastCreateTemplateName = name;
    lastCreateTemplateDefaultMealType = defaultMealType;
    lastCreateTemplateNotes = notes;
    lastCreateTemplateIsFavourite = isFavourite;
    final created = ClientMealTemplate(
      id: 999,
      householdId: 'h1',
      name: name,
      defaultMealType: defaultMealType,
      notes: notes,
      kidFriendly: false,
      freezerFriendly: false,
      lunchboxFriendly: false,
      isFavourite: isFavourite ?? false,
      usageCount: 0,
    );
    _templates = [..._templates, created];
    return created;
  }

  @override
  Future<List<ClientTemplateIngredient>> mealTemplateIngredients({
    required String accessToken,
    required int templateId,
  }) async => _ingredientsByTemplateId[templateId] ?? const [];

  @override
  Future<ClientTemplateIngredient> addMealTemplateIngredient({
    required String accessToken,
    required int templateId,
    required String name,
    String? quantityText,
    String? unit,
    String? category,
  }) async {
    addIngredientCalled = true;
    lastAddIngredientTemplateId = templateId;
    lastAddIngredientName = name;
    lastAddIngredientQuantityText = quantityText;
    lastAddIngredientCategory = category;
    final created = ClientTemplateIngredient(
      id: _nextIngredientId++,
      templateId: templateId,
      name: name,
      normalizedName: name.toLowerCase(),
      quantityText: quantityText,
      category: category,
      optional: false,
      sortOrder: (_ingredientsByTemplateId[templateId]?.length ?? 0),
    );
    _ingredientsByTemplateId[templateId] = [
      ...?_ingredientsByTemplateId[templateId],
      created,
    ];
    return created;
  }

  @override
  Future<ClientTemplateIngredient> updateMealTemplateIngredient({
    required String accessToken,
    required int templateId,
    required int ingredientId,
    String? name,
    String? quantityText,
    String? unit,
    String? category,
  }) async {
    updateIngredientCalled = true;
    lastUpdateIngredientId = ingredientId;
    final existing = _ingredientsByTemplateId[templateId]!.firstWhere(
      (i) => i.id == ingredientId,
    );
    final updated = ClientTemplateIngredient(
      id: existing.id,
      templateId: existing.templateId,
      name: name ?? existing.name,
      normalizedName: (name ?? existing.name).toLowerCase(),
      quantityText: quantityText ?? existing.quantityText,
      category: category ?? existing.category,
      optional: existing.optional,
      sortOrder: existing.sortOrder,
    );
    _ingredientsByTemplateId[templateId] = [
      for (final i in _ingredientsByTemplateId[templateId]!)
        i.id == ingredientId ? updated : i,
    ];
    return updated;
  }

  @override
  Future<void> deleteMealTemplateIngredient({
    required String accessToken,
    required int templateId,
    required int ingredientId,
  }) async {
    deleteIngredientCalled = true;
    lastDeleteIngredientId = ingredientId;
    _ingredientsByTemplateId[templateId] = _ingredientsByTemplateId[templateId]!
        .where((i) => i.id != ingredientId)
        .toList();
  }
}

ClientMealTemplate _template({
  required int id,
  required String name,
  bool isFavourite = false,
  int usageCount = 0,
  String? notes,
  String? lastUsedAt,
}) => ClientMealTemplate(
  id: id,
  householdId: 'h1',
  name: name,
  defaultMealType: 'dinner',
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
  List<ClientTemplateIngredient> ingredients = const [],
}) => ClientStarterMealTemplate(
  id: id,
  slug: name.toLowerCase().replaceAll(' ', '-'),
  name: name,
  defaultMealType: 'dinner',
  kidFriendly: false,
  freezerFriendly: false,
  lunchboxFriendly: false,
  sortOrder: 0,
  version: 1,
  active: true,
  ingredients: ingredients,
);

ClientTemplateIngredient _ingredient({
  required int id,
  required String name,
  String? quantityText,
  String? category,
}) => ClientTemplateIngredient(
  id: id,
  name: name,
  normalizedName: name.toLowerCase(),
  quantityText: quantityText,
  category: category,
  optional: false,
  sortOrder: 0,
);

MealsController _controllerFor(CaleeHubClient hub) => MealsController(
  repository: MealsRepository(hubClient: hub, accessToken: 'tok'),
);

Widget _buildSavedMealsPage(CaleeHubClient hub, MealsController controller) {
  return MaterialApp(
    theme: CaleeTheme.buildThemeData(),
    home: SavedMealsPage(
      hubClient: hub,
      accessToken: 'tok',
      controller: controller,
    ),
  );
}

void main() {
  group('SavedMealsPage — sections', () {
    testWidgets('shows favourites, recent meals and quick dinner ideas', (
      tester,
    ) async {
      final hub = _StubHub(
        templates: [
          _template(
            id: 1,
            name: 'Spaghetti Bolognese',
            isFavourite: true,
            usageCount: 4,
          ),
          _template(id: 2, name: 'Pizza Night', usageCount: 2),
        ],
        quickIdeas: [_quickIdea(id: 10, name: 'Tacos')],
      );
      await tester.pumpWidget(_buildSavedMealsPage(hub, _controllerFor(hub)));
      await tester.pumpAndSettle();

      expect(find.text('FAMILY FAVOURITES'), findsOneWidget);
      expect(find.text('Spaghetti Bolognese'), findsOneWidget);
      expect(find.text('Used 4 times'), findsOneWidget);

      expect(find.text('RECENT MEALS'), findsOneWidget);
      expect(find.text('Pizza Night'), findsOneWidget);

      expect(find.text('QUICK DINNER IDEAS'), findsOneWidget);
      expect(find.text('Tacos'), findsOneWidget);

      // Product principle: never say "template" in the UI.
      expect(find.textContaining('template', findRichText: true), findsNothing);
      expect(find.textContaining('Template', findRichText: true), findsNothing);
    });

    testWidgets('shows empty states when nothing is saved yet', (tester) async {
      final hub = _StubHub();
      await tester.pumpWidget(_buildSavedMealsPage(hub, _controllerFor(hub)));
      await tester.pumpAndSettle();

      expect(find.text('No family favourites yet'), findsOneWidget);
      expect(find.text('No recent meals yet'), findsOneWidget);
      expect(find.text('No quick dinner ideas yet'), findsOneWidget);
    });
  });

  group('ManageSavedMealSheet', () {
    testWidgets('renaming and saving updates the template name', (
      tester,
    ) async {
      final hub = _StubHub(
        templates: [
          _template(id: 1, name: 'Spaghetti Bolognese', isFavourite: true),
        ],
      );
      await tester.pumpWidget(_buildSavedMealsPage(hub, _controllerFor(hub)));
      await tester.pumpAndSettle();

      await tester.tap(find.text('Spaghetti Bolognese'));
      await tester.pumpAndSettle();

      final nameField = find.widgetWithText(
        TextFormField,
        'Spaghetti Bolognese',
      );
      expect(nameField, findsOneWidget);
      await tester.enterText(nameField, 'Spaghetti Bolognese v2');
      await tester.tap(find.widgetWithText(FilledButton, 'Save'));
      await tester.pumpAndSettle();

      expect(hub.updateTemplateCalled, isTrue);
      expect(hub.lastUpdateTemplateId, 1);
      expect(hub.lastUpdateName, 'Spaghetti Bolognese v2');
      expect(hub.lastUpdateIsFavourite, isTrue);
    });

    testWidgets('unfavouriting a saved meal calls updateMealTemplate', (
      tester,
    ) async {
      final hub = _StubHub(
        templates: [
          _template(id: 1, name: 'Spaghetti Bolognese', isFavourite: true),
        ],
      );
      await tester.pumpWidget(_buildSavedMealsPage(hub, _controllerFor(hub)));
      await tester.pumpAndSettle();

      await tester.tap(find.text('Spaghetti Bolognese'));
      await tester.pumpAndSettle();

      await tester.tap(find.byType(Switch));
      await tester.tap(find.widgetWithText(FilledButton, 'Save'));
      await tester.pumpAndSettle();

      expect(hub.lastUpdateIsFavourite, isFalse);
    });

    testWidgets(
      'deleting a saved meal confirms then calls deleteMealTemplate',
      (tester) async {
        final hub = _StubHub(
          templates: [
            _template(id: 1, name: 'Spaghetti Bolognese', isFavourite: true),
          ],
        );
        await tester.pumpWidget(_buildSavedMealsPage(hub, _controllerFor(hub)));
        await tester.pumpAndSettle();

        await tester.tap(find.text('Spaghetti Bolognese'));
        await tester.pumpAndSettle();

        await tester.tap(find.widgetWithText(OutlinedButton, 'Delete'));
        await tester.pumpAndSettle();

        // Confirmation dialog blocks the delete until confirmed.
        expect(hub.deleteTemplateCalled, isFalse);
        await tester.tap(find.widgetWithText(TextButton, 'Delete'));
        await tester.pumpAndSettle();

        expect(hub.deleteTemplateCalled, isTrue);
        expect(hub.lastDeleteTemplateId, 1);
      },
    );

    testWidgets('adding to this week creates a planned meal with templateId', (
      tester,
    ) async {
      final hub = _StubHub(
        templates: [
          _template(id: 1, name: 'Spaghetti Bolognese', isFavourite: true),
        ],
      );
      await tester.pumpWidget(_buildSavedMealsPage(hub, _controllerFor(hub)));
      await tester.pumpAndSettle();

      await tester.tap(find.text('Spaghetti Bolognese'));
      await tester.pumpAndSettle();

      await tester.tap(find.widgetWithText(OutlinedButton, 'Add to this week'));
      await tester.pumpAndSettle();

      await tester.tap(find.widgetWithText(FilledButton, 'Add to this week'));
      await tester.pumpAndSettle();

      expect(hub.createMealCalled, isTrue);
      expect(hub.lastCreateTitle, 'Spaghetti Bolognese');
      expect(hub.lastCreateTemplateId, 1);
      expect(hub.lastCreateStarterTemplateId, isNull);
    });
  });

  group('ManageSavedMealSheet — ingredients', () {
    testWidgets('shows an empty state when there are no ingredients yet', (
      tester,
    ) async {
      final hub = _StubHub(
        templates: [
          _template(id: 1, name: 'Spaghetti Bolognese', isFavourite: true),
        ],
      );
      await tester.pumpWidget(_buildSavedMealsPage(hub, _controllerFor(hub)));
      await tester.pumpAndSettle();

      await tester.tap(find.text('Spaghetti Bolognese'));
      await tester.pumpAndSettle();

      expect(find.text('INGREDIENTS'), findsOneWidget);
      expect(find.text('No ingredients yet'), findsOneWidget);
    });

    testWidgets('shows ingredient name, quantity and category', (tester) async {
      final hub = _StubHub(
        templates: [
          _template(id: 1, name: 'Spaghetti Bolognese', isFavourite: true),
        ],
        ingredientsByTemplateId: {
          1: [
            _ingredient(
              id: 5,
              name: 'Beef mince',
              quantityText: '500g',
              category: 'Meat',
            ),
          ],
        },
      );
      await tester.pumpWidget(_buildSavedMealsPage(hub, _controllerFor(hub)));
      await tester.pumpAndSettle();

      await tester.tap(find.text('Spaghetti Bolognese'));
      await tester.pumpAndSettle();

      expect(find.text('Beef mince'), findsOneWidget);
      expect(find.text('500g · Meat'), findsOneWidget);
    });

    testWidgets('add ingredient calls the API and shows it in the list', (
      tester,
    ) async {
      final hub = _StubHub(
        templates: [
          _template(id: 1, name: 'Spaghetti Bolognese', isFavourite: true),
        ],
      );
      await tester.pumpWidget(_buildSavedMealsPage(hub, _controllerFor(hub)));
      await tester.pumpAndSettle();

      await tester.tap(find.text('Spaghetti Bolognese'));
      await tester.pumpAndSettle();

      await tester.tap(find.text('Add ingredient'));
      await tester.pumpAndSettle();

      expect(find.text('Quantity optional'), findsOneWidget);
      expect(find.text('Category optional'), findsOneWidget);

      await tester.enterText(
        find.widgetWithText(TextFormField, 'Ingredient name'),
        'Rice',
      );
      await tester.enterText(
        find.widgetWithText(TextFormField, 'Quantity optional'),
        '1 cup',
      );
      await tester.tap(find.widgetWithText(FilledButton, 'Save').last);
      await tester.pumpAndSettle();

      expect(hub.addIngredientCalled, isTrue);
      expect(hub.lastAddIngredientTemplateId, 1);
      expect(hub.lastAddIngredientName, 'Rice');
      expect(hub.lastAddIngredientQuantityText, '1 cup');
      expect(find.text('Rice'), findsOneWidget);
    });

    testWidgets('editing an ingredient calls updateMealTemplateIngredient', (
      tester,
    ) async {
      final hub = _StubHub(
        templates: [
          _template(id: 1, name: 'Spaghetti Bolognese', isFavourite: true),
        ],
        ingredientsByTemplateId: {
          1: [_ingredient(id: 5, name: 'Beef mince', quantityText: '500g')],
        },
      );
      await tester.pumpWidget(_buildSavedMealsPage(hub, _controllerFor(hub)));
      await tester.pumpAndSettle();

      await tester.tap(find.text('Spaghetti Bolognese'));
      await tester.pumpAndSettle();

      await tester.tap(find.text('Beef mince'));
      await tester.pumpAndSettle();

      await tester.enterText(
        find.widgetWithText(TextFormField, '500g'),
        '600g',
      );
      await tester.tap(find.widgetWithText(FilledButton, 'Save').last);
      await tester.pumpAndSettle();

      expect(hub.updateIngredientCalled, isTrue);
      expect(hub.lastUpdateIngredientId, 5);
      expect(find.text('600g'), findsOneWidget);
    });

    testWidgets('blocks saving an ingredient with a blank name', (
      tester,
    ) async {
      final hub = _StubHub(
        templates: [
          _template(id: 1, name: 'Spaghetti Bolognese', isFavourite: true),
        ],
      );
      await tester.pumpWidget(_buildSavedMealsPage(hub, _controllerFor(hub)));
      await tester.pumpAndSettle();

      await tester.tap(find.text('Spaghetti Bolognese'));
      await tester.pumpAndSettle();

      await tester.tap(find.text('Add ingredient'));
      await tester.pumpAndSettle();

      await tester.enterText(
        find.widgetWithText(TextFormField, 'Ingredient name'),
        '   ',
      );
      await tester.tap(find.widgetWithText(FilledButton, 'Save').last);
      await tester.pumpAndSettle();

      expect(find.text('Please enter an ingredient name'), findsOneWidget);
      expect(hub.addIngredientCalled, isFalse);
    });

    testWidgets('deleting an ingredient calls deleteMealTemplateIngredient', (
      tester,
    ) async {
      final hub = _StubHub(
        templates: [
          _template(id: 1, name: 'Spaghetti Bolognese', isFavourite: true),
        ],
        ingredientsByTemplateId: {
          1: [_ingredient(id: 5, name: 'Beef mince')],
        },
      );
      await tester.pumpWidget(_buildSavedMealsPage(hub, _controllerFor(hub)));
      await tester.pumpAndSettle();

      await tester.tap(find.text('Spaghetti Bolognese'));
      await tester.pumpAndSettle();

      expect(find.text('Beef mince'), findsOneWidget);

      await tester.tap(find.byIcon(Icons.close).last);
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(TextButton, 'Delete'));
      await tester.pumpAndSettle();

      expect(hub.deleteIngredientCalled, isTrue);
      expect(hub.lastDeleteIngredientId, 5);
      expect(find.text('Beef mince'), findsNothing);
      expect(find.text('No ingredients yet'), findsOneWidget);
    });
  });

  group('QuickDinnerIdeaSheet', () {
    testWidgets('is read-only and adds to the week with starterTemplateId', (
      tester,
    ) async {
      final hub = _StubHub(quickIdeas: [_quickIdea(id: 10, name: 'Tacos')]);
      await tester.pumpWidget(_buildSavedMealsPage(hub, _controllerFor(hub)));
      await tester.pumpAndSettle();

      await tester.tap(find.text('Tacos'));
      await tester.pumpAndSettle();

      // No rename/delete affordances for Calee's starter ideas.
      expect(find.byType(TextFormField), findsNothing);
      expect(find.widgetWithText(OutlinedButton, 'Delete'), findsNothing);

      await tester.tap(
        find.widgetWithText(FilledButton, 'Add to this week').first,
      );
      await tester.pumpAndSettle();

      await tester.tap(
        find.widgetWithText(FilledButton, 'Add to this week').last,
      );
      await tester.pumpAndSettle();

      expect(hub.createMealCalled, isTrue);
      expect(hub.lastCreateTitle, 'Tacos');
      expect(hub.lastCreateStarterTemplateId, 10);
      expect(hub.lastCreateTemplateId, isNull);
    });

    testWidgets('shows ingredients read-only when the API returns them', (
      tester,
    ) async {
      final hub = _StubHub(
        quickIdeas: [
          _quickIdea(
            id: 10,
            name: 'Tacos',
            ingredients: [_ingredient(id: 1, name: 'Taco shells')],
          ),
        ],
      );
      await tester.pumpWidget(_buildSavedMealsPage(hub, _controllerFor(hub)));
      await tester.pumpAndSettle();

      await tester.tap(find.text('Tacos'));
      await tester.pumpAndSettle();

      expect(find.text('INGREDIENTS'), findsOneWidget);
      expect(find.text('Taco shells'), findsOneWidget);
      // No edit/delete affordances for starter ingredients (only the sheet's
      // own dismiss button uses this icon).
      expect(find.byIcon(Icons.close), findsOneWidget);
      expect(find.text('Add ingredient'), findsNothing);
    });
  });

  group('CreateSavedMealSheet', () {
    testWidgets('Saved meals page shows a + action', (tester) async {
      final hub = _StubHub();
      await tester.pumpWidget(_buildSavedMealsPage(hub, _controllerFor(hub)));
      await tester.pumpAndSettle();

      expect(find.byTooltip('Create saved meal'), findsOneWidget);
    });

    testWidgets('+ opens the Create saved meal sheet', (tester) async {
      final hub = _StubHub();
      await tester.pumpWidget(_buildSavedMealsPage(hub, _controllerFor(hub)));
      await tester.pumpAndSettle();

      await tester.tap(find.byTooltip('Create saved meal'));
      await tester.pumpAndSettle();

      expect(find.text('Create saved meal'), findsOneWidget);
      expect(find.widgetWithText(TextFormField, 'Meal name'), findsOneWidget);

      // Product principle: never say "template" in the UI.
      expect(find.textContaining('template', findRichText: true), findsNothing);
      expect(find.textContaining('Template', findRichText: true), findsNothing);
    });

    testWidgets(
      'saving calls createMealTemplate with name, defaultMealType, notes, isFavourite',
      (tester) async {
        final hub = _StubHub();
        await tester.pumpWidget(_buildSavedMealsPage(hub, _controllerFor(hub)));
        await tester.pumpAndSettle();

        await tester.tap(find.byTooltip('Create saved meal'));
        await tester.pumpAndSettle();

        await tester.enterText(
          find.widgetWithText(TextFormField, 'Meal name'),
          'Taco Tuesday',
        );
        await tester.enterText(
          find.widgetWithText(TextFormField, 'Notes (optional)'),
          'Kids love this one',
        );
        await tester.tap(find.byType(Switch));
        await tester.tap(find.widgetWithText(FilledButton, 'Save'));
        await tester.pumpAndSettle();

        expect(hub.createTemplateCalled, isTrue);
        expect(hub.lastCreateTemplateName, 'Taco Tuesday');
        expect(hub.lastCreateTemplateDefaultMealType, 'dinner');
        expect(hub.lastCreateTemplateNotes, 'Kids love this one');
        expect(hub.lastCreateTemplateIsFavourite, isTrue);
      },
    );
  });

  group('AddSavedMealToWeekSheet — week-aware defaults', () {
    testWidgets('defaults to the visible Meals week when today is outside it', (
      tester,
    ) async {
      final hub = _StubHub(
        templates: [
          _template(id: 1, name: 'Spaghetti Bolognese', isFavourite: true),
        ],
      );
      final controller = _controllerFor(hub);
      // Move the visible week two weeks back so "today" is outside it.
      controller.previousWeek();
      controller.previousWeek();
      final expectedDate = controller.weekStartStr;

      await tester.pumpWidget(_buildSavedMealsPage(hub, controller));
      await tester.pumpAndSettle();

      await tester.tap(find.text('Spaghetti Bolognese'));
      await tester.pumpAndSettle();

      await tester.tap(find.widgetWithText(OutlinedButton, 'Add to this week'));
      await tester.pumpAndSettle();

      expect(find.text(expectedDate), findsOneWidget);
    });
  });

  group('Recent meals ordering', () {
    testWidgets(
      'sorts by lastUsedAt desc, then usageCount desc, then name asc',
      (tester) async {
        final hub = _StubHub(
          templates: [
            _template(
              id: 1,
              name: 'Zucchini Bake',
              usageCount: 1,
              lastUsedAt: '2026-06-01T00:00:00Z',
            ),
            _template(
              id: 2,
              name: 'Beef Stew',
              usageCount: 5,
              lastUsedAt: '2026-07-01T00:00:00Z',
            ),
            _template(id: 3, name: 'Apple Crumble', usageCount: 3),
            _template(id: 4, name: 'Banana Bread', usageCount: 3),
          ],
        );
        await tester.pumpWidget(_buildSavedMealsPage(hub, _controllerFor(hub)));
        await tester.pumpAndSettle();

        final names = tester
            .widgetList<Text>(find.byType(Text))
            .map((t) => t.data)
            .whereType<String>()
            .where(
              (t) => [
                'Zucchini Bake',
                'Beef Stew',
                'Apple Crumble',
                'Banana Bread',
              ].contains(t),
            )
            .toList();

        // Beef Stew (most recently used) first, then Zucchini Bake (only
        // other with a lastUsedAt), then the two without lastUsedAt ordered
        // by usageCount desc (tied, so alphabetical): Apple before Banana.
        expect(names, [
          'Beef Stew',
          'Zucchini Bake',
          'Apple Crumble',
          'Banana Bread',
        ]);
      },
    );
  });
}

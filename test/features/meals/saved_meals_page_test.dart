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
  _StubHub({this._templates = const [], this._quickIdeas = const []}) : super();

  List<ClientMealTemplate> _templates;
  final List<ClientStarterMealTemplate> _quickIdeas;

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
}

ClientMealTemplate _template({
  required int id,
  required String name,
  bool isFavourite = false,
  int usageCount = 0,
  String? notes,
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
);

ClientStarterMealTemplate _quickIdea({required int id, required String name}) =>
    ClientStarterMealTemplate(
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
      ingredients: const [],
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
  });
}

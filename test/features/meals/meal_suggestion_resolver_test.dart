import 'package:calee_mobile/data/models/client_meal.dart';
import 'package:calee_mobile/data/models/client_shopping_list.dart';
import 'package:calee_mobile/features/meals/meal_suggestion_resolver.dart';
import 'package:flutter_test/flutter_test.dart';

ClientMealTemplate saved({
  required int id,
  required String name,
  String? notes,
  bool favourite = false,
  int usageCount = 0,
  String? lastUsedAt,
}) {
  return ClientMealTemplate(
    id: id,
    householdId: 'household',
    name: name,
    defaultMealType: 'dinner',
    notes: notes,
    kidFriendly: false,
    freezerFriendly: false,
    lunchboxFriendly: false,
    isFavourite: favourite,
    usageCount: usageCount,
    lastUsedAt: lastUsedAt,
  );
}

ClientStarterMealTemplate starter({
  required int id,
  required String name,
  required int sortOrder,
  String? notes,
}) {
  return ClientStarterMealTemplate(
    id: id,
    slug: 'starter-$id',
    name: name,
    defaultMealType: 'dinner',
    notes: notes,
    kidFriendly: false,
    freezerFriendly: false,
    lunchboxFriendly: false,
    sortOrder: sortOrder,
    version: 1,
    active: true,
    ingredients: const [],
  );
}

void main() {
  group('MealSuggestionResolver', () {
    test('keeps only explicit favourites and excludes them from recent', () {
      final groups = MealSuggestionResolver.resolve(
        savedTemplates: [
          saved(id: 1, name: 'Favourite', favourite: true, usageCount: 9),
          saved(id: 2, name: 'Recent', usageCount: 2),
          saved(id: 3, name: 'Never used'),
        ],
        starterTemplates: const [],
      );

      expect(groups.familyFavourites.map((item) => item.name), ['Favourite']);
      expect(groups.recentlyUsed.map((item) => item.name), ['Recent']);
    });

    test('orders recent meals by date, usage count, then name', () {
      final groups = MealSuggestionResolver.resolve(
        savedTemplates: [
          saved(
            id: 1,
            name: 'Zulu',
            usageCount: 1,
            lastUsedAt: '2026-06-01T00:00:00Z',
          ),
          saved(
            id: 2,
            name: 'Beta',
            usageCount: 2,
            lastUsedAt: '2026-07-01T00:00:00Z',
          ),
          saved(id: 3, name: 'Charlie', usageCount: 3),
          saved(id: 4, name: 'Alpha', usageCount: 3),
        ],
        starterTemplates: const [],
      );

      expect(groups.recentlyUsed.map((item) => item.name), [
        'Beta',
        'Zulu',
        'Alpha',
        'Charlie',
      ]);
    });

    test('searches every saved meal by notes and starter ideas by name', () {
      final groups = MealSuggestionResolver.resolve(
        savedTemplates: [
          saved(id: 1, name: 'Hidden family recipe', notes: 'Uses tahini'),
        ],
        starterTemplates: [starter(id: 10, name: 'Quick tacos', sortOrder: 2)],
      );

      final noteResults = groups.search('tahini');
      expect(noteResults.savedMeals.single.templateId, 1);
      final starterResults = groups.search('tacos');
      expect(starterResults.quickDinnerIdeas.single.starterTemplateId, 10);
    });

    test('uses starter sort order and retains linkage identity', () {
      final groups = MealSuggestionResolver.resolve(
        savedTemplates: [saved(id: 7, name: 'Saved')],
        starterTemplates: [
          starter(id: 12, name: 'Second', sortOrder: 20),
          starter(id: 11, name: 'First', sortOrder: 10),
        ],
      );

      expect(groups.allSaved.single.templateId, 7);
      expect(groups.allSaved.single.starterTemplateId, isNull);
      expect(groups.quickDinnerIdeas.map((item) => item.id), [11, 12]);
      expect(groups.quickDinnerIdeas.first.templateId, isNull);
      expect(groups.quickDinnerIdeas.first.starterTemplateId, 11);
    });
  });
}

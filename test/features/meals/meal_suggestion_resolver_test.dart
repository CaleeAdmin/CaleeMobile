import 'package:calee_mobile/data/models/client_meal.dart';
import 'package:calee_mobile/data/models/client_shopping_list.dart';
import 'package:calee_mobile/features/meals/meal_suggestion_resolver.dart';
import 'package:flutter_test/flutter_test.dart';

ClientMealTemplate _saved({
  required int id,
  required String name,
  bool isFavourite = false,
  int usageCount = 0,
  String? lastUsedAt,
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
  lastUsedAt: lastUsedAt,
);

ClientStarterMealTemplate _starter({
  required int id,
  required String name,
  required int sortOrder,
  String? notes,
}) => ClientStarterMealTemplate(
  id: id,
  slug: name.toLowerCase().replaceAll(' ', '-'),
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

void main() {
  group('MealSuggestionResolver.resolve', () {
    test('keeps favourites separate from recently used meals', () {
      final groups = MealSuggestionResolver.resolve(
        savedTemplates: [
          _saved(
            id: 1,
            name: 'Favourite curry',
            isFavourite: true,
            usageCount: 9,
          ),
          _saved(id: 2, name: 'Recent pasta', usageCount: 2),
          _saved(id: 3, name: 'Unused soup'),
        ],
        starterTemplates: const [],
      );

      expect(groups.familyFavourites.map((item) => item.name), [
        'Favourite curry',
      ]);
      expect(groups.recentlyUsed.map((item) => item.name), ['Recent pasta']);
      expect(groups.otherSaved.map((item) => item.name), ['Unused soup']);
    });

    test('orders recent meals by last use, usage count, then name', () {
      final groups = MealSuggestionResolver.resolve(
        savedTemplates: [
          _saved(
            id: 1,
            name: 'Zucchini bake',
            usageCount: 1,
            lastUsedAt: '2026-06-01T00:00:00Z',
          ),
          _saved(
            id: 2,
            name: 'Beef stew',
            usageCount: 2,
            lastUsedAt: '2026-07-01T00:00:00Z',
          ),
          _saved(id: 3, name: 'Banana bread', usageCount: 3),
          _saved(id: 4, name: 'Apple crumble', usageCount: 3),
        ],
        starterTemplates: const [],
      );

      expect(groups.recentlyUsed.map((item) => item.name), [
        'Beef stew',
        'Zucchini bake',
        'Apple crumble',
        'Banana bread',
      ]);
    });

    test('orders quick dinner ideas by server sort order, then name', () {
      final groups = MealSuggestionResolver.resolve(
        savedTemplates: const [],
        starterTemplates: [
          _starter(id: 1, name: 'Zucchini pasta', sortOrder: 2),
          _starter(id: 2, name: 'Tacos', sortOrder: 1),
          _starter(id: 3, name: 'Curry', sortOrder: 1),
        ],
      );

      expect(groups.quickDinnerIdeas.map((item) => item.name), [
        'Curry',
        'Tacos',
        'Zucchini pasta',
      ]);
    });
  });

  group('MealSuggestionGroups.search', () {
    final groups = MealSuggestionResolver.resolve(
      savedTemplates: [
        _saved(
          id: 1,
          name: 'Family tacos',
          isFavourite: true,
          notes: 'Serve mild',
        ),
        _saved(
          id: 2,
          name: 'Pasta bake',
          usageCount: 3,
          notes: 'Contains spinach',
        ),
        _saved(id: 3, name: 'Pumpkin soup', notes: 'Freezer friendly'),
      ],
      starterTemplates: [
        _starter(
          id: 10,
          name: 'Quick curry',
          sortOrder: 1,
          notes: 'Twenty minutes',
        ),
      ],
    );

    test('finds saved meals by name and notes without duplicating groups', () {
      expect(groups.search('mild').familyFavourites.map((item) => item.name), [
        'Family tacos',
      ]);
      expect(groups.search('spinach').recentlyUsed.map((item) => item.name), [
        'Pasta bake',
      ]);
      expect(groups.search('freezer').otherSaved.map((item) => item.name), [
        'Pumpkin soup',
      ]);
    });

    test('finds Quick dinner ideas and preserves source linkage', () {
      final saved = groups.search('tacos').familyFavourites.single;
      final starter = groups.search('twenty').quickDinnerIdeas.single;

      expect(saved.templateId, 1);
      expect(saved.starterTemplateId, isNull);
      expect(starter.templateId, isNull);
      expect(starter.starterTemplateId, 10);
    });
  });
}

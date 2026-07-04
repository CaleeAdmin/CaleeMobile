import 'package:calee_mobile/data/models/client_shopping_list.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('ClientTemplateIngredient.fromJson', () {
    test('parses full object', () {
      final ingredient = ClientTemplateIngredient.fromJson({
        'id': 1,
        'templateId': null,
        'starterTemplateId': 12,
        'householdId': null,
        'name': 'Taco shells',
        'normalizedName': 'taco shells',
        'quantityText': null,
        'unit': null,
        'category': 'Pantry',
        'optional': false,
        'sortOrder': 0,
        'createdAt': '2026-07-04 00:00:00',
        'updatedAt': '2026-07-04 00:00:00',
      });

      expect(ingredient.id, 1);
      expect(ingredient.templateId, isNull);
      expect(ingredient.starterTemplateId, 12);
      expect(ingredient.name, 'Taco shells');
      expect(ingredient.normalizedName, 'taco shells');
      expect(ingredient.category, 'Pantry');
      expect(ingredient.optional, isFalse);
      expect(ingredient.sortOrder, 0);
      expect(ingredient.createdAt, '2026-07-04 00:00:00');
    });

    test('defensively parses missing fields', () {
      final ingredient = ClientTemplateIngredient.fromJson(const {});

      expect(ingredient.id, 0);
      expect(ingredient.name, '');
      expect(ingredient.normalizedName, '');
      expect(ingredient.optional, isFalse);
      expect(ingredient.sortOrder, 0);
      expect(ingredient.category, isNull);
    });
  });

  group('ClientStarterMealTemplate.fromJson', () {
    test('parses full object including nested ingredients', () {
      final template = ClientStarterMealTemplate.fromJson({
        'id': 12,
        'slug': 'tacos',
        'name': 'Tacos',
        'defaultMealType': 'dinner',
        'icon': 'taco',
        'imageAssetKey': null,
        'notes': null,
        'difficulty': 'easy',
        'prepMinutes': 25,
        'servings': 4,
        'kidFriendly': true,
        'freezerFriendly': false,
        'lunchboxFriendly': false,
        'tagsJson': null,
        'recipeUrl': null,
        'recipeNote': null,
        'region': null,
        'pack': null,
        'sortOrder': 2,
        'version': 1,
        'active': true,
        'ingredients': [
          {
            'id': 1,
            'templateId': null,
            'starterTemplateId': 12,
            'householdId': null,
            'name': 'Taco shells',
            'normalizedName': 'taco shells',
            'quantityText': null,
            'unit': null,
            'category': 'Pantry',
            'optional': false,
            'sortOrder': 0,
            'createdAt': '2026-07-04 00:00:00',
            'updatedAt': '2026-07-04 00:00:00',
          },
        ],
      });

      expect(template.id, 12);
      expect(template.slug, 'tacos');
      expect(template.name, 'Tacos');
      expect(template.defaultMealType, 'dinner');
      expect(template.icon, 'taco');
      expect(template.difficulty, 'easy');
      expect(template.prepMinutes, 25);
      expect(template.servings, 4);
      expect(template.kidFriendly, isTrue);
      expect(template.freezerFriendly, isFalse);
      expect(template.lunchboxFriendly, isFalse);
      expect(template.sortOrder, 2);
      expect(template.version, 1);
      expect(template.active, isTrue);
      expect(template.ingredients, hasLength(1));
      expect(template.ingredients.single.name, 'Taco shells');
    });

    test('defensively parses missing fields', () {
      final template = ClientStarterMealTemplate.fromJson(const {});

      expect(template.id, 0);
      expect(template.slug, '');
      expect(template.name, '');
      expect(template.kidFriendly, isFalse);
      expect(template.active, isTrue);
      expect(template.version, 1);
      expect(template.ingredients, isEmpty);
    });
  });

  group('ClientShoppingListItem.fromJson', () {
    test('parses full object', () {
      final item = ClientShoppingListItem.fromJson({
        'id': 9,
        'shoppingListId': 3,
        'householdId': 'hh_abc',
        'sourceType': 'meal_template',
        'sourceMealItemId': 5,
        'sourceTemplateId': 7,
        'sourceStarterTemplateId': null,
        'name': 'Taco shells',
        'normalizedName': 'taco shells',
        'quantityText': null,
        'unit': null,
        'category': 'Pantry',
        'checked': false,
        'checkedAt': null,
        'manuallyAdded': false,
        'manuallyRemoved': false,
        'sortOrder': 0,
        'createdAt': '2026-07-04 00:00:00',
        'updatedAt': '2026-07-04 00:00:00',
        'deletedAt': null,
      });

      expect(item.id, 9);
      expect(item.shoppingListId, 3);
      expect(item.householdId, 'hh_abc');
      expect(item.sourceType, 'meal_template');
      expect(item.sourceMealItemId, 5);
      expect(item.sourceTemplateId, 7);
      expect(item.sourceStarterTemplateId, isNull);
      expect(item.name, 'Taco shells');
      expect(item.category, 'Pantry');
      expect(item.checked, isFalse);
      expect(item.manuallyAdded, isFalse);
      expect(item.manuallyRemoved, isFalse);
      expect(item.sortOrder, 0);
    });

    test('defensively parses missing fields', () {
      final item = ClientShoppingListItem.fromJson(const {});

      expect(item.id, 0);
      expect(item.shoppingListId, 0);
      expect(item.householdId, '');
      expect(item.name, '');
      expect(item.checked, isFalse);
      expect(item.manuallyAdded, isFalse);
      expect(item.manuallyRemoved, isFalse);
      expect(item.sortOrder, 0);
    });

    test('checked true is parsed correctly', () {
      final item = ClientShoppingListItem.fromJson(const {
        'id': 1,
        'checked': true,
      });

      expect(item.checked, isTrue);
    });

    group('displayCategory', () {
      test('returns the trimmed category when present', () {
        final item = ClientShoppingListItem.fromJson(const {
          'id': 1,
          'category': '  Pantry  ',
        });

        expect(item.displayCategory, 'Pantry');
      });

      test('falls back to Other when category is null', () {
        final item = ClientShoppingListItem.fromJson(const {'id': 1});

        expect(item.displayCategory, 'Other');
      });

      test('falls back to Other when category is blank', () {
        final item = ClientShoppingListItem.fromJson(const {
          'id': 1,
          'category': '   ',
        });

        expect(item.displayCategory, 'Other');
      });
    });
  });

  group('ClientShoppingList.fromJson', () {
    test('parses full object including nested items', () {
      final list = ClientShoppingList.fromJson({
        'id': 3,
        'householdId': 'hh_abc',
        'title': 'Shopping list 2026-07-06 to 2026-07-12',
        'fromDate': '2026-07-06',
        'toDate': '2026-07-12',
        'status': 'active',
        'createdByAccountId': null,
        'createdAt': '2026-07-06 00:00:00',
        'updatedAt': '2026-07-06 00:00:00',
        'archivedAt': null,
        'items': [
          {
            'id': 9,
            'shoppingListId': 3,
            'householdId': 'hh_abc',
            'sourceType': 'meal_template',
            'sourceMealItemId': 5,
            'sourceTemplateId': 7,
            'sourceStarterTemplateId': null,
            'name': 'Taco shells',
            'normalizedName': 'taco shells',
            'quantityText': null,
            'unit': null,
            'category': 'Pantry',
            'checked': false,
            'checkedAt': null,
            'manuallyAdded': false,
            'manuallyRemoved': false,
            'sortOrder': 0,
            'createdAt': '2026-07-04 00:00:00',
            'updatedAt': '2026-07-04 00:00:00',
            'deletedAt': null,
          },
        ],
      });

      expect(list.id, 3);
      expect(list.householdId, 'hh_abc');
      expect(list.title, 'Shopping list 2026-07-06 to 2026-07-12');
      expect(list.fromDate, '2026-07-06');
      expect(list.toDate, '2026-07-12');
      expect(list.status, 'active');
      expect(list.items, hasLength(1));
      expect(list.items.single.name, 'Taco shells');
    });

    test('defensively parses missing fields to an empty item list', () {
      final list = ClientShoppingList.fromJson(const {});

      expect(list.id, 0);
      expect(list.householdId, '');
      expect(list.status, 'active');
      expect(list.items, isEmpty);
    });

    test('items list is growable so items can be spliced in place', () {
      final list = ClientShoppingList.fromJson(const {
        'id': 1,
        'items': [
          {'id': 1, 'name': 'Milk'},
        ],
      });

      // ShoppingController relies on being able to mutate this list directly
      // (add/removeAt/index assignment) for optimistic updates, since the
      // model intentionally has no copyWith.
      list.items.add(
        ClientShoppingListItem.fromJson(const {'id': 2, 'name': 'Bread'}),
      );

      expect(list.items, hasLength(2));
      expect(list.items.last.name, 'Bread');
    });
  });
}

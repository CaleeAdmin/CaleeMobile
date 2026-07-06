// Unit tests for CaleeHubClient meals endpoint methods.
// Verifies path/query construction and request body shapes.

import 'dart:convert';
import 'dart:io';

import 'package:calee_mobile/data/api/calee_hub_client.dart';
import 'package:flutter_test/flutter_test.dart';

const _kMealJson = <String, dynamic>{
  'id': 1,
  'householdId': 'h1',
  'mealDate': '2024-01-15',
  'mealType': 'dinner',
  'title': 'Pasta',
  'status': 'planned',
  'source': 'manual',
};

const _kMealTemplateJson = <String, dynamic>{
  'id': 7,
  'householdId': 'h1',
  'name': 'Spaghetti Bolognese',
  'defaultMealType': 'dinner',
  'kidFriendly': true,
  'freezerFriendly': false,
  'lunchboxFriendly': false,
  'isFavourite': true,
  'usageCount': 4,
};

void main() {
  late HttpServer server;
  late List<String> capturedPaths;
  late List<String> capturedMethods;
  late List<Map<String, dynamic>> capturedBodies;

  setUp(() {
    capturedPaths = [];
    capturedMethods = [];
    capturedBodies = [];
  });

  tearDown(() async {
    await server.close(force: true);
  });

  Future<CaleeHubClient> startServer(Map<String, dynamic> responseBody) async {
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((req) async {
      capturedPaths.add(req.uri.toString());
      capturedMethods.add(req.method);
      final body = await utf8.decoder.bind(req).join();
      if (body.isNotEmpty) {
        capturedBodies.add(jsonDecode(body) as Map<String, dynamic>);
      }
      req.response.headers.contentType = ContentType.json;
      req.response.statusCode = HttpStatus.ok;
      req.response.write(jsonEncode(responseBody));
      await req.response.close();
    });
    return CaleeHubClient(
      baseUri: Uri.parse('http://127.0.0.1:${server.port}'),
    );
  }

  group('CaleeHubClient.meals()', () {
    test('sends GET to /client/v1/meals with from/to query params', () async {
      final client = await startServer({
        'data': {
          'householdId': 'h1',
          'from': '2024-01-15',
          'to': '2024-01-15',
          'meals': <dynamic>[],
        },
      });

      await client.meals(
        accessToken: 'tok',
        from: '2024-01-15',
        to: '2024-01-15',
      );

      expect(capturedMethods.single, 'GET');
      expect(capturedPaths.single, contains('/client/v1/meals'));
      expect(capturedPaths.single, contains('from=2024-01-15'));
      expect(capturedPaths.single, contains('to=2024-01-15'));
    });
  });

  group('CaleeHubClient.createMeal()', () {
    test('sends POST to /client/v1/meals with required fields', () async {
      final client = await startServer({
        'data': {'meal': _kMealJson},
      });

      await client.createMeal(
        accessToken: 'tok',
        mealDate: '2024-01-15',
        mealType: 'dinner',
        title: 'Pasta',
      );

      expect(capturedMethods.single, 'POST');
      expect(capturedPaths.single, '/client/v1/meals');
      expect(capturedBodies.single['mealDate'], '2024-01-15');
      expect(capturedBodies.single['mealType'], 'dinner');
      expect(capturedBodies.single['title'], 'Pasta');
    });

    test('omits empty notes from POST body', () async {
      final client = await startServer({
        'data': {'meal': _kMealJson},
      });

      await client.createMeal(
        accessToken: 'tok',
        mealDate: '2024-01-15',
        mealType: 'dinner',
        title: 'Pasta',
        notes: '',
      );

      expect(capturedBodies.single.containsKey('notes'), isFalse);
    });

    test('includes templateId when creating from a family favourite', () async {
      final client = await startServer({
        'data': {'meal': _kMealJson},
      });

      await client.createMeal(
        accessToken: 'tok',
        mealDate: '2024-01-15',
        mealType: 'dinner',
        title: 'Pasta',
        templateId: 7,
      );

      expect(capturedBodies.single['templateId'], 7);
      expect(capturedBodies.single.containsKey('starterTemplateId'), isFalse);
    });

    test(
      'includes starterTemplateId when creating from a quick dinner idea',
      () async {
        final client = await startServer({
          'data': {'meal': _kMealJson},
        });

        await client.createMeal(
          accessToken: 'tok',
          mealDate: '2024-01-15',
          mealType: 'dinner',
          title: 'Pasta',
          starterTemplateId: 42,
        );

        expect(capturedBodies.single['starterTemplateId'], 42);
        expect(capturedBodies.single.containsKey('templateId'), isFalse);
      },
    );
  });

  group('CaleeHubClient.updateMeal()', () {
    test('sends PATCH to /client/v1/meals/:id', () async {
      final client = await startServer({
        'data': {'meal': _kMealJson},
      });

      await client.updateMeal(
        accessToken: 'tok',
        mealId: 1,
        title: 'Pasta Updated',
      );

      expect(capturedMethods.single, 'PATCH');
      expect(capturedPaths.single, '/client/v1/meals/1');
    });

    test('empty string notes included in PATCH body for clearing', () async {
      final client = await startServer({
        'data': {'meal': _kMealJson},
      });

      await client.updateMeal(
        accessToken: 'tok',
        mealId: 1,
        title: 'Pasta',
        notes: '',
      );

      expect(capturedBodies.single.containsKey('notes'), isTrue);
      expect(capturedBodies.single['notes'], '');
    });

    test('omits null notes from PATCH body', () async {
      final client = await startServer({
        'data': {'meal': _kMealJson},
      });

      await client.updateMeal(accessToken: 'tok', mealId: 1, title: 'Pasta');

      expect(capturedBodies.single.containsKey('notes'), isFalse);
    });
  });

  group('CaleeHubClient.deleteMeal()', () {
    test('sends DELETE to /client/v1/meals/:id', () async {
      final client = await startServer({'data': <String, dynamic>{}});

      await client.deleteMeal(accessToken: 'tok', mealId: 42);

      expect(capturedMethods.single, 'DELETE');
      expect(capturedPaths.single, '/client/v1/meals/42');
    });
  });

  group('CaleeHubClient.createMealTemplate()', () {
    test(
      'sends POST to /client/v1/meal-templates with required fields',
      () async {
        final client = await startServer({
          'data': {'template': _kMealTemplateJson},
        });

        final result = await client.createMealTemplate(
          accessToken: 'tok',
          name: 'Spaghetti Bolognese',
          defaultMealType: 'dinner',
        );

        expect(capturedMethods.single, 'POST');
        expect(capturedPaths.single, '/client/v1/meal-templates');
        expect(capturedBodies.single['name'], 'Spaghetti Bolognese');
        expect(capturedBodies.single['defaultMealType'], 'dinner');
        expect(result.id, 7);
        expect(result.isFavourite, isTrue);
      },
    );

    test(
      'includes optional notes, icon and isFavourite when provided',
      () async {
        final client = await startServer({
          'data': {'template': _kMealTemplateJson},
        });

        await client.createMealTemplate(
          accessToken: 'tok',
          name: 'Spaghetti Bolognese',
          defaultMealType: 'dinner',
          notes: 'Kids love this one',
          icon: 'pasta',
          isFavourite: true,
        );

        expect(capturedBodies.single['notes'], 'Kids love this one');
        expect(capturedBodies.single['icon'], 'pasta');
        expect(capturedBodies.single['isFavourite'], isTrue);
      },
    );
  });

  group('CaleeHubClient.updateMealTemplate()', () {
    test('sends PATCH to /client/v1/meal-templates/:id', () async {
      final client = await startServer({
        'data': {'template': _kMealTemplateJson},
      });

      await client.updateMealTemplate(
        accessToken: 'tok',
        templateId: 7,
        name: 'Spaghetti Bolognese Updated',
      );

      expect(capturedMethods.single, 'PATCH');
      expect(capturedPaths.single, '/client/v1/meal-templates/7');
      expect(capturedBodies.single['name'], 'Spaghetti Bolognese Updated');
    });

    test('can toggle isFavourite without changing name or notes', () async {
      final client = await startServer({
        'data': {'template': _kMealTemplateJson},
      });

      await client.updateMealTemplate(
        accessToken: 'tok',
        templateId: 7,
        isFavourite: false,
      );

      expect(capturedBodies.single['isFavourite'], isFalse);
      expect(capturedBodies.single.containsKey('name'), isFalse);
      expect(capturedBodies.single.containsKey('notes'), isFalse);
    });

    test('throws when no update fields are provided', () async {
      final client = await startServer({
        'data': {'template': _kMealTemplateJson},
      });

      expect(
        () => client.updateMealTemplate(accessToken: 'tok', templateId: 7),
        throwsA(isA<CaleeHubException>()),
      );
    });
  });

  group('CaleeHubClient.deleteMealTemplate()', () {
    test('sends DELETE to /client/v1/meal-templates/:id', () async {
      final client = await startServer({'data': <String, dynamic>{}});

      await client.deleteMealTemplate(accessToken: 'tok', templateId: 7);

      expect(capturedMethods.single, 'DELETE');
      expect(capturedPaths.single, '/client/v1/meal-templates/7');
    });
  });

  group('CaleeHubClient.mealTemplateIngredients()', () {
    test('sends GET to /client/v1/meal-templates/:id/ingredients', () async {
      final client = await startServer({
        'data': {
          'ingredients': [
            {
              'id': 1,
              'templateId': 7,
              'name': 'Beef mince',
              'normalizedName': 'beef mince',
              'quantityText': '500g',
              'category': 'Meat',
              'optional': false,
              'sortOrder': 0,
            },
          ],
        },
      });

      final result = await client.mealTemplateIngredients(
        accessToken: 'tok',
        templateId: 7,
      );

      expect(capturedMethods.single, 'GET');
      expect(capturedPaths.single, '/client/v1/meal-templates/7/ingredients');
      expect(result.single.name, 'Beef mince');
      expect(result.single.quantityText, '500g');
      expect(result.single.category, 'Meat');
    });
  });

  group('CaleeHubClient.addMealTemplateIngredient()', () {
    test('sends POST to /client/v1/meal-templates/:id/ingredients', () async {
      final client = await startServer({
        'data': {
          'ingredient': {
            'id': 1,
            'templateId': 7,
            'name': 'Rice',
            'normalizedName': 'rice',
            'optional': false,
            'sortOrder': 0,
          },
        },
      });

      final result = await client.addMealTemplateIngredient(
        accessToken: 'tok',
        templateId: 7,
        name: 'Rice',
        quantityText: '1 cup',
      );

      expect(capturedMethods.single, 'POST');
      expect(capturedPaths.single, '/client/v1/meal-templates/7/ingredients');
      expect(capturedBodies.single['name'], 'Rice');
      expect(capturedBodies.single['quantityText'], '1 cup');
      expect(result.name, 'Rice');
    });
  });

  group('CaleeHubClient.updateMealTemplateIngredient()', () {
    test(
      'sends PATCH to /client/v1/meal-templates/:id/ingredients/:id',
      () async {
        final client = await startServer({
          'data': {
            'ingredient': {
              'id': 1,
              'templateId': 7,
              'name': 'Rice',
              'normalizedName': 'rice',
              'quantityText': '2 cups',
              'optional': false,
              'sortOrder': 0,
            },
          },
        });

        final result = await client.updateMealTemplateIngredient(
          accessToken: 'tok',
          templateId: 7,
          ingredientId: 1,
          quantityText: '2 cups',
        );

        expect(capturedMethods.single, 'PATCH');
        expect(
          capturedPaths.single,
          '/client/v1/meal-templates/7/ingredients/1',
        );
        expect(capturedBodies.single['quantityText'], '2 cups');
        expect(result.quantityText, '2 cups');
      },
    );

    test('throws when no update fields are provided', () async {
      final client = await startServer({
        'data': {
          'ingredient': {
            'id': 1,
            'templateId': 7,
            'name': 'Rice',
            'normalizedName': 'rice',
            'optional': false,
            'sortOrder': 0,
          },
        },
      });

      expect(
        () => client.updateMealTemplateIngredient(
          accessToken: 'tok',
          templateId: 7,
          ingredientId: 1,
        ),
        throwsA(isA<CaleeHubException>()),
      );
    });
  });

  group('CaleeHubClient.deleteMealTemplateIngredient()', () {
    test(
      'sends DELETE to /client/v1/meal-templates/:id/ingredients/:id',
      () async {
        final client = await startServer({'data': <String, dynamic>{}});

        await client.deleteMealTemplateIngredient(
          accessToken: 'tok',
          templateId: 7,
          ingredientId: 1,
        );

        expect(capturedMethods.single, 'DELETE');
        expect(
          capturedPaths.single,
          '/client/v1/meal-templates/7/ingredients/1',
        );
      },
    );
  });

  group('CaleeHubClient.copyMealWeek()', () {
    test('POSTs to /client/v1/meals/copy-week with required fields', () async {
      final client = await startServer({
        'data': {
          'householdId': 'h1',
          'sourceFrom': '2024-01-08',
          'targetFrom': '2024-01-15',
          'mode': 'skip_existing',
          'mealTypes': ['breakfast', 'lunch', 'dinner'],
          'copiedMeals': <dynamic>[],
          'count': 0,
          'skippedCount': 0,
        },
      });

      await client.copyMealWeek(
        accessToken: 'tok',
        sourceFrom: '2024-01-08',
        sourceTo: '2024-01-14',
        targetFrom: '2024-01-15',
      );

      expect(capturedMethods.single, 'POST');
      expect(capturedPaths.single, '/client/v1/meals/copy-week');
      expect(capturedBodies.single['sourceFrom'], '2024-01-08');
      expect(capturedBodies.single['sourceTo'], '2024-01-14');
      expect(capturedBodies.single['targetFrom'], '2024-01-15');
      expect(capturedBodies.single['mode'], 'skip_existing');
    });

    test('sends overwrite_existing mode when specified', () async {
      final client = await startServer({
        'data': {
          'householdId': 'h1',
          'sourceFrom': '2024-01-08',
          'targetFrom': '2024-01-15',
          'mode': 'overwrite_existing',
          'mealTypes': ['breakfast', 'lunch', 'dinner'],
          'copiedMeals': <dynamic>[],
          'count': 0,
          'skippedCount': 0,
        },
      });

      await client.copyMealWeek(
        accessToken: 'tok',
        sourceFrom: '2024-01-08',
        sourceTo: '2024-01-14',
        targetFrom: '2024-01-15',
        mode: 'overwrite_existing',
      );

      expect(capturedBodies.single['mode'], 'overwrite_existing');
    });

    test('parses count and skippedCount from response', () async {
      final client = await startServer({
        'data': {
          'householdId': 'h1',
          'sourceFrom': '2024-01-08',
          'targetFrom': '2024-01-15',
          'mode': 'skip_existing',
          'mealTypes': ['breakfast', 'lunch', 'dinner'],
          'copiedMeals': <dynamic>[_kMealJson],
          'count': 3,
          'skippedCount': 2,
        },
      });

      final result = await client.copyMealWeek(
        accessToken: 'tok',
        sourceFrom: '2024-01-08',
        sourceTo: '2024-01-14',
        targetFrom: '2024-01-15',
      );

      expect(result.count, 3);
      expect(result.skippedCount, 2);
    });
  });
}

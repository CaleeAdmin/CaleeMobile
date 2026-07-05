// Unit tests for CaleeHubClient shopping-list endpoint methods.
// Verifies path/query construction and request body shapes.

import 'dart:convert';
import 'dart:io';

import 'package:calee_mobile/data/api/calee_hub_client.dart';
import 'package:flutter_test/flutter_test.dart';

const _kShoppingListJson = <String, dynamic>{
  'id': 3,
  'householdId': 'hh_abc',
  'title': 'Shopping list 2024-01-15 to 2024-01-21',
  'fromDate': '2024-01-15',
  'toDate': '2024-01-21',
  'status': 'active',
  'items': <dynamic>[],
};

const _kShoppingListItemJson = <String, dynamic>{
  'id': 9,
  'shoppingListId': 3,
  'householdId': 'hh_abc',
  'name': 'Taco shells',
  'category': 'Pantry',
  'checked': false,
  'manuallyAdded': false,
  'manuallyRemoved': false,
  'sortOrder': 0,
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

  Future<CaleeHubClient> startServer(
    Map<String, dynamic> responseBody, {
    int statusCode = HttpStatus.ok,
  }) async {
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((req) async {
      capturedPaths.add(req.uri.toString());
      capturedMethods.add(req.method);
      final body = await utf8.decoder.bind(req).join();
      if (body.isNotEmpty) {
        capturedBodies.add(jsonDecode(body) as Map<String, dynamic>);
      }
      req.response.headers.contentType = ContentType.json;
      req.response.statusCode = statusCode;
      req.response.write(jsonEncode(responseBody));
      await req.response.close();
    });
    return CaleeHubClient(
      baseUri: Uri.parse('http://127.0.0.1:${server.port}'),
    );
  }

  group('CaleeHubClient.mealStarterTemplates()', () {
    test('sends GET to /client/v1/meal-starter-templates with no query '
        'params when omitted', () async {
      final client = await startServer({
        'data': {'templates': <dynamic>[]},
      });

      await client.mealStarterTemplates(accessToken: 'tok');

      expect(capturedMethods.single, 'GET');
      expect(capturedPaths.single, '/client/v1/meal-starter-templates');
    });

    test('sends mealType and pack as query params when provided', () async {
      final client = await startServer({
        'data': {'templates': <dynamic>[]},
      });

      await client.mealStarterTemplates(
        accessToken: 'tok',
        mealType: 'dinner',
        pack: 'family-favourites',
      );

      expect(capturedPaths.single, contains('mealType=dinner'));
      expect(capturedPaths.single, contains('pack=family-favourites'));
    });

    test('parses templates list from response', () async {
      final client = await startServer({
        'data': {
          'templates': [
            {'id': 12, 'slug': 'tacos', 'name': 'Tacos'},
          ],
        },
      });

      final templates = await client.mealStarterTemplates(accessToken: 'tok');

      expect(templates, hasLength(1));
      expect(templates.single.name, 'Tacos');
    });
  });

  group('CaleeHubClient.currentShoppingList()', () {
    test('sends GET to /client/v1/shopping-lists/current with from/to '
        'query params', () async {
      final client = await startServer({
        'data': {'shoppingList': _kShoppingListJson},
      });

      await client.currentShoppingList(
        accessToken: 'tok',
        from: '2024-01-15',
        to: '2024-01-21',
      );

      expect(capturedMethods.single, 'GET');
      expect(
        capturedPaths.single,
        contains('/client/v1/shopping-lists/current'),
      );
      expect(capturedPaths.single, contains('from=2024-01-15'));
      expect(capturedPaths.single, contains('to=2024-01-21'));
    });

    test('parses the returned shopping list', () async {
      final client = await startServer({
        'data': {'shoppingList': _kShoppingListJson},
      });

      final list = await client.currentShoppingList(
        accessToken: 'tok',
        from: '2024-01-15',
        to: '2024-01-21',
      );

      expect(list.id, 3);
      expect(list.householdId, 'hh_abc');
    });
  });

  group('CaleeHubClient.getShoppingList()', () {
    test('sends GET to /client/v1/shopping-lists/:listId', () async {
      final client = await startServer({
        'data': {'shoppingList': _kShoppingListJson},
      });

      await client.getShoppingList(accessToken: 'tok', listId: 3);

      expect(capturedMethods.single, 'GET');
      expect(capturedPaths.single, '/client/v1/shopping-lists/3');
    });

    test('parses the returned shopping list', () async {
      final client = await startServer({
        'data': {'shoppingList': _kShoppingListJson},
      });

      final list = await client.getShoppingList(accessToken: 'tok', listId: 3);

      expect(list.id, 3);
      expect(list.householdId, 'hh_abc');
    });
  });

  group('CaleeHubClient.generateShoppingList()', () {
    test('sends POST to /client/v1/shopping-lists/generate with from/to '
        'and default mode', () async {
      final client = await startServer({
        'data': {'shoppingList': _kShoppingListJson},
      });

      await client.generateShoppingList(
        accessToken: 'tok',
        from: '2024-01-15',
        to: '2024-01-21',
      );

      expect(capturedMethods.single, 'POST');
      expect(capturedPaths.single, '/client/v1/shopping-lists/generate');
      expect(capturedBodies.single['from'], '2024-01-15');
      expect(capturedBodies.single['to'], '2024-01-21');
      expect(capturedBodies.single['mode'], 'merge');
    });

    test('sends replace mode when specified', () async {
      final client = await startServer({
        'data': {'shoppingList': _kShoppingListJson},
      });

      await client.generateShoppingList(
        accessToken: 'tok',
        from: '2024-01-15',
        to: '2024-01-21',
        mode: 'replace',
      );

      expect(capturedBodies.single['mode'], 'replace');
    });
  });

  group('CaleeHubClient.addShoppingListItem()', () {
    test('sends POST to /client/v1/shopping-lists/:listId/items', () async {
      final client = await startServer({
        'data': {'item': _kShoppingListItemJson},
      });

      await client.addShoppingListItem(
        accessToken: 'tok',
        listId: 3,
        name: 'Milk',
        category: 'Dairy',
      );

      expect(capturedMethods.single, 'POST');
      expect(capturedPaths.single, '/client/v1/shopping-lists/3/items');
      expect(capturedBodies.single['name'], 'Milk');
      expect(capturedBodies.single['category'], 'Dairy');
    });

    test('omits category from the body when not provided', () async {
      final client = await startServer({
        'data': {'item': _kShoppingListItemJson},
      });

      await client.addShoppingListItem(
        accessToken: 'tok',
        listId: 3,
        name: 'Milk',
      );

      expect(capturedBodies.single.containsKey('category'), isFalse);
    });

    test('parses the returned item', () async {
      final client = await startServer({
        'data': {'item': _kShoppingListItemJson},
      });

      final item = await client.addShoppingListItem(
        accessToken: 'tok',
        listId: 3,
        name: 'Taco shells',
      );

      expect(item.id, 9);
      expect(item.name, 'Taco shells');
    });
  });

  group('CaleeHubClient.updateShoppingListItem()', () {
    test('sends PATCH to /client/v1/shopping-lists/:listId/items/:itemId '
        'with checked', () async {
      final client = await startServer({
        'data': {'item': _kShoppingListItemJson},
      });

      await client.updateShoppingListItem(
        accessToken: 'tok',
        listId: 3,
        itemId: 9,
        checked: true,
      );

      expect(capturedMethods.single, 'PATCH');
      expect(capturedPaths.single, '/client/v1/shopping-lists/3/items/9');
      expect(capturedBodies.single['checked'], true);
    });
  });

  group('CaleeHubClient.deleteShoppingListItem()', () {
    test(
      'sends DELETE to /client/v1/shopping-lists/:listId/items/:itemId',
      () async {
        final client = await startServer({
          'data': {'id': 9, 'deleted': true},
        });

        await client.deleteShoppingListItem(
          accessToken: 'tok',
          listId: 3,
          itemId: 9,
        );

        expect(capturedMethods.single, 'DELETE');
        expect(capturedPaths.single, '/client/v1/shopping-lists/3/items/9');
      },
    );
  });
}

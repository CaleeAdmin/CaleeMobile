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
    Map<String, dynamic> responseBody,
  ) async {
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

      await client.updateMeal(
        accessToken: 'tok',
        mealId: 1,
        title: 'Pasta',
      );

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
}

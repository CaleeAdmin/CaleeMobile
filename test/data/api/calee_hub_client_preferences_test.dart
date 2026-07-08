// Unit tests for CaleeHubClient.preferences() and updatePreferences() JSON
// parsing/serialization.
//
// The backend wraps preferences under data.preferences. These tests verify
// the client extracts the nested object correctly and sends explicit nulls
// to clear defaultCalendarId/defaultTaskListId.

import 'dart:convert';
import 'dart:io';

import 'package:calee_mobile/data/api/calee_hub_client.dart';
import 'package:calee_mobile/data/auth/calee_preferences.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late HttpServer server;
  List<Map<String, dynamic>> capturedBodies = [];

  setUp(() {
    capturedBodies = [];
  });

  tearDown(() async {
    await server.close(force: true);
  });

  Future<CaleeHubClient> startServer(Map<String, dynamic> responseBody) async {
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((req) async {
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

  group('CaleeHubClient.preferences()', () {
    test('parses data.preferences correctly', () async {
      final client = await startServer({
        'data': {
          'preferences': {
            'firstDayOfWeek': 'monday',
            'timeFormat': 'h24',
            'defaultCalendarId': 'cal-1',
            'defaultTaskListId': 'list-1',
            'version': 3,
            'updatedAt': '2026-07-08T00:00:00.000Z',
          },
        },
      });

      final prefs = await client.preferences(accessToken: 'tok');

      expect(prefs.firstDayOfWeek, FirstDayOfWeek.monday);
      expect(prefs.timeFormat, TimeFormatPref.h24);
      expect(prefs.defaultCalendarId, 'cal-1');
      expect(prefs.defaultTaskListId, 'list-1');
      expect(prefs.version, 3);
      expect(prefs.updatedAt, isNotNull);
    });

    test(
      'defaults null defaultCalendarId/defaultTaskListId to Automatic',
      () async {
        final client = await startServer({
          'data': {
            'preferences': {
              'firstDayOfWeek': 'sunday',
              'timeFormat': 'system',
            },
          },
        });

        final prefs = await client.preferences(accessToken: 'tok');

        expect(prefs.defaultCalendarId, isNull);
        expect(prefs.defaultTaskListId, isNull);
      },
    );

    test('throws CaleeHubException when data.preferences is missing', () async {
      final client = await startServer({
        'data': {'other': 'field'},
      });

      await expectLater(
        client.preferences(accessToken: 'tok'),
        throwsA(
          isA<CaleeHubException>().having(
            (e) => e.message,
            'message',
            contains('Could not load your preferences'),
          ),
        ),
      );
    });
  });

  group('CaleeHubClient.updatePreferences()', () {
    test('parses data.preferences correctly', () async {
      final client = await startServer({
        'data': {
          'preferences': {
            'firstDayOfWeek': 'monday',
            'timeFormat': 'system',
            'version': 2,
          },
        },
      });

      final prefs = await client.updatePreferences(
        accessToken: 'tok',
        firstDayOfWeek: FirstDayOfWeek.monday,
      );

      expect(prefs.firstDayOfWeek, FirstDayOfWeek.monday);
      expect(prefs.version, 2);
    });

    test('sends only firstDayOfWeek when only that changes', () async {
      final client = await startServer({
        'data': {
          'preferences': {'firstDayOfWeek': 'monday', 'timeFormat': 'system'},
        },
      });

      await client.updatePreferences(
        accessToken: 'tok',
        firstDayOfWeek: FirstDayOfWeek.monday,
      );

      expect(capturedBodies, hasLength(1));
      final sent = capturedBodies.first;
      expect(sent['firstDayOfWeek'], 'monday');
      expect(sent.containsKey('timeFormat'), isFalse);
      expect(sent.containsKey('defaultCalendarId'), isFalse);
      expect(sent.containsKey('defaultTaskListId'), isFalse);
    });

    test('sends explicit null to clear defaultCalendarId', () async {
      final client = await startServer({
        'data': {
          'preferences': {
            'firstDayOfWeek': 'sunday',
            'timeFormat': 'system',
            'defaultCalendarId': null,
          },
        },
      });

      final prefs = await client.updatePreferences(
        accessToken: 'tok',
        clearDefaultCalendarId: true,
      );

      expect(capturedBodies, hasLength(1));
      final sent = capturedBodies.first;
      expect(sent.containsKey('defaultCalendarId'), isTrue);
      expect(sent['defaultCalendarId'], isNull);
      expect(prefs.defaultCalendarId, isNull);
    });

    test('sends explicit null to clear defaultTaskListId', () async {
      final client = await startServer({
        'data': {
          'preferences': {
            'firstDayOfWeek': 'sunday',
            'timeFormat': 'system',
            'defaultTaskListId': null,
          },
        },
      });

      await client.updatePreferences(
        accessToken: 'tok',
        clearDefaultTaskListId: true,
      );

      expect(capturedBodies, hasLength(1));
      final sent = capturedBodies.first;
      expect(sent.containsKey('defaultTaskListId'), isTrue);
      expect(sent['defaultTaskListId'], isNull);
    });

    test('throws CaleeHubException when no fields provided', () async {
      final client = await startServer({'data': {}});

      expect(
        () => client.updatePreferences(accessToken: 'tok'),
        throwsA(
          isA<CaleeHubException>().having(
            (e) => e.message,
            'message',
            contains('No preference updates provided'),
          ),
        ),
      );
    });

    test('throws CaleeHubException when data.preferences is missing', () async {
      final client = await startServer({
        'data': {'other': 'field'},
      });

      await expectLater(
        client.updatePreferences(
          accessToken: 'tok',
          timeFormat: TimeFormatPref.h12,
        ),
        throwsA(
          isA<CaleeHubException>().having(
            (e) => e.message,
            'message',
            contains('Could not load your preferences'),
          ),
        ),
      );
    });
  });
}

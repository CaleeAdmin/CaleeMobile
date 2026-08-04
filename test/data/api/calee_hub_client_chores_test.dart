// Unit tests for CaleeHubClient chore endpoints.
//
// Chore sections are calendar-day decisions ("due today", "completed today"),
// and the backend resolves them in the timezone the client sends. A request
// that omits the timezone silently falls back to the server's UTC day, which
// is a different calendar day than the user's for part of every day — so these
// tests pin the timezone onto every chore request path, including the
// /completion/today alias that carries no explicit date.

import 'dart:convert';
import 'dart:io';

import 'package:calee_mobile/data/api/calee_hub_client.dart';
import 'package:flutter_test/flutter_test.dart';

const _kCompletedChoreJson = <String, dynamic>{
  'id': 'portal:calee-chore-log-abc',
  'calendarId': 'cal-1',
  'serviceId': 'portal',
  'serviceName': 'Portal',
  'title': 'Take out bins',
  'scheduledAt': '2026-08-04',
  'scheduledDate': '2026-08-04',
  'source': 'nextcloud_portal',
  'kind': 'completionLog',
  'choreUid': 'uid-1',
  'parentChoreUid': 'uid-1',
  'baseChoreId': 'portal:uid-1',
  'occurrenceDate': '2026-08-04',
  'completionLogId': 'portal:calee-chore-log-abc',
  'completedToday': true,
  'section': 'doneToday',
  'recurrence': 'FREQ=WEEKLY',
  'points': 2,
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

  group('CaleeHubClient.chores()', () {
    test('sends the timezone as a query parameter', () async {
      final client = await startServer({
        'data': {
          'from': '2026-08-04',
          'to': '2026-08-04',
          'chores': <dynamic>[],
        },
      });

      await client.chores(
        accessToken: 'tok',
        from: '2026-08-04',
        to: '2026-08-04',
        timezone: 'Australia/Perth',
      );

      expect(capturedMethods.single, 'GET');
      expect(capturedPaths.single, contains('timezone=Australia%2FPerth'));
    });

    test('omits the timezone when none is available', () async {
      final client = await startServer({
        'data': {
          'from': '2026-08-04',
          'to': '2026-08-04',
          'chores': <dynamic>[],
        },
      });

      await client.chores(
        accessToken: 'tok',
        from: '2026-08-04',
        to: '2026-08-04',
      );

      expect(capturedPaths.single, isNot(contains('timezone')));
    });
  });

  group('CaleeHubClient.completeChore()', () {
    test(
      'sends the date and timezone, and parses the returned occurrence',
      () async {
        final client = await startServer({
          'data': {
            'completed': true,
            'alreadyCompleted': false,
            'choreId': 'portal:uid-1',
            'completionLogId': 'portal:calee-chore-log-abc',
            'completedDate': '2026-08-04',
            'today': '2026-08-04',
            'chore': _kCompletedChoreJson,
          },
        });

        final result = await client.completeChore(
          accessToken: 'tok',
          choreId: 'portal:uid-1',
          date: '2026-08-04',
          timezone: 'Australia/Perth',
        );

        expect(capturedMethods.single, 'POST');
        expect(
          capturedPaths.single,
          contains('/client/v1/chores/portal%3Auid-1/complete'),
        );
        expect(capturedBodies.single['date'], '2026-08-04');
        expect(capturedBodies.single['timezone'], 'Australia/Perth');

        expect(result.completed, isTrue);
        expect(result.alreadyCompleted, isFalse);
        expect(result.completedDate, '2026-08-04');

        // The authoritative occurrence is parsed, not merely acknowledged.
        final chore = result.chore;
        expect(chore, isNotNull);
        expect(chore!.section, 'doneToday');
        expect(chore.completedToday, isTrue);
        expect(chore.occurrenceDate, '2026-08-04');
        expect(chore.baseChoreId, 'portal:uid-1');
        expect(chore.completionLogId, 'portal:calee-chore-log-abc');
        expect(chore.recurrence, 'FREQ=WEEKLY');
        expect(chore.serviceId, 'portal');
        expect(chore.calendarId, 'cal-1');
        expect(chore.points, 2);
      },
    );

    test('tolerates a backend that returns no occurrence', () async {
      final client = await startServer({
        'data': {
          'completed': true,
          'alreadyCompleted': false,
          'choreId': 'portal:uid-1',
          'completionLogId': 'portal:log',
          'completedDate': '2026-08-04',
        },
      });

      final result = await client.completeChore(
        accessToken: 'tok',
        choreId: 'portal:uid-1',
        date: '2026-08-04',
      );

      expect(result.completed, isTrue);
      expect(result.chore, isNull);
    });
  });

  group('CaleeHubClient.undoChoreCompletion()', () {
    test('sends date and timezone on the dated endpoint', () async {
      final client = await startServer({
        'data': {
          'completed': false,
          'choreId': 'portal:uid-1',
          'completionLogId': 'portal:log',
          'completedDate': '2026-08-04',
          'today': '2026-08-04',
          'chore': {
            ..._kCompletedChoreJson,
            'kind': 'baseChore',
            'completedToday': false,
            'section': 'todoToday',
            'completionLogId': null,
          },
        },
      });

      final result = await client.undoChoreCompletion(
        accessToken: 'tok',
        choreId: 'portal:uid-1',
        date: '2026-08-04',
        timezone: 'Australia/Perth',
      );

      expect(capturedMethods.single, 'DELETE');
      expect(capturedPaths.single, contains('/completion?'));
      expect(capturedPaths.single, contains('date=2026-08-04'));
      expect(capturedPaths.single, contains('timezone=Australia%2FPerth'));

      expect(result.completed, isFalse);
      expect(result.chore, isNotNull);
      expect(result.chore!.section, 'todoToday');
      expect(result.chore!.completedToday, isFalse);
    });

    // The alias resolves "today" server-side, so it needs the zone even though
    // it carries no date. Without it the backend resolves today on its own UTC
    // day, which can be a different calendar day than the one the completion
    // was recorded under — and then finds no log to undo.
    test('sends the timezone on the /completion/today alias', () async {
      final client = await startServer({
        'data': {
          'completed': false,
          'choreId': 'portal:uid-1',
          'completionLogId': null,
          'completedDate': '2026-08-04',
        },
      });

      await client.undoChoreCompletion(
        accessToken: 'tok',
        choreId: 'portal:uid-1',
        timezone: 'Australia/Perth',
      );

      expect(capturedMethods.single, 'DELETE');
      expect(capturedPaths.single, contains('/completion/today?'));
      expect(capturedPaths.single, contains('timezone=Australia%2FPerth'));
    });

    test('leaves the alias path bare when no timezone is available', () async {
      final client = await startServer({
        'data': {
          'completed': false,
          'choreId': 'portal:uid-1',
          'completionLogId': null,
          'completedDate': '2026-08-04',
        },
      });

      await client.undoChoreCompletion(
        accessToken: 'tok',
        choreId: 'portal:uid-1',
      );

      expect(capturedPaths.single, endsWith('/completion/today'));
      expect(capturedPaths.single, isNot(contains('?')));
    });
  });
}

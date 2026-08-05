// Read-only regression verification (no production code changes) for how
// CaleeHubClient/CaleeHubException handle the two calendar-concurrency error
// responses introduced by calee-hub-core's ETag-safe CalDAV mutation work:
//
//   409 CALENDAR_OBJECT_CONFLICT       (an existing-object write was rejected
//                                        because a newer version exists)
//   503 CALENDAR_CONCURRENCY_UNAVAILABLE (an existing-object write was
//                                        refused because no ETag was available
//                                        to protect it safely)
//
// Uses the same local-loopback HttpServer harness already established in
// calee_hub_client_calendar_test.dart -- no real network access, and no
// change to lib/data/api/calee_hub_client.dart was needed to write this:
// _readJsonResponse() already parses error.code/error.message with
// type-safe casts (`as String?`), so it was already immune to the raw-JSON
// stringification bug found and fixed on the Calee tablet (Kotlin) side.
// This file exists to prove that conclusion against the real parsing path
// rather than only by source review.
import 'dart:convert';
import 'dart:io';

import 'package:calee_mobile/data/api/calee_hub_client.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late HttpServer server;

  tearDown(() async {
    await server.close(force: true);
  });

  Future<CaleeHubClient> startServerReturning(
    int statusCode,
    Map<String, dynamic> responseBody,
  ) async {
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((req) async {
      req.response.headers.contentType = ContentType.json;
      req.response.statusCode = statusCode;
      req.response.write(jsonEncode(responseBody));
      await req.response.close();
    });
    return CaleeHubClient(
      baseUri: Uri.parse('http://127.0.0.1:${server.port}'),
    );
  }

  test(
    '409 CALENDAR_OBJECT_CONFLICT parses code, message and status safely',
    () async {
      final client = await startServerReturning(409, {
        'error': {
          'code': 'CALENDAR_OBJECT_CONFLICT',
          'message':
              'This event changed on another device. Refresh it and try again.',
        },
        'meta': {},
      });

      try {
        await client.updateCalendar(
          accessToken: 'tok',
          calendarId: 'portal:family-cal',
          name: 'Family',
        );
        fail('Expected CaleeHubException');
      } on CaleeHubException catch (e) {
        expect(e.statusCode, 409);
        expect(e.code, 'CALENDAR_OBJECT_CONFLICT');
        expect(
          e.message,
          'This event changed on another device. Refresh it and try again.',
        );
        expect(e.message.contains('{'), isFalse);
      }
    },
  );

  test(
    '503 CALENDAR_CONCURRENCY_UNAVAILABLE parses code, message and status safely',
    () async {
      final client = await startServerReturning(503, {
        'error': {
          'code': 'CALENDAR_CONCURRENCY_UNAVAILABLE',
          'message':
              'This item could not be safely updated. Refresh and try again.',
        },
        'meta': {},
      });

      try {
        await client.updateCalendar(
          accessToken: 'tok',
          calendarId: 'portal:family-cal',
          name: 'Family',
        );
        fail('Expected CaleeHubException');
      } on CaleeHubException catch (e) {
        expect(e.statusCode, 503);
        expect(e.code, 'CALENDAR_CONCURRENCY_UNAVAILABLE');
        expect(
          e.message,
          'This item could not be safely updated. Refresh and try again.',
        );
        expect(e.message.contains('{'), isFalse);
      }
    },
  );

  test(
    'an unrecognized future concurrency-style code still parses safely, no crash',
    () async {
      final client = await startServerReturning(409, {
        'error': {
          'code': 'SOME_FUTURE_CONCURRENCY_CODE',
          'message': 'Something changed, please retry.',
        },
        'meta': {},
      });

      try {
        await client.updateCalendar(
          accessToken: 'tok',
          calendarId: 'portal:family-cal',
          name: 'Family',
        );
        fail('Expected CaleeHubException');
      } on CaleeHubException catch (e) {
        expect(e.statusCode, 409);
        expect(e.code, 'SOME_FUTURE_CONCURRENCY_CODE');
        expect(e.message, 'Something changed, please retry.');
      }
    },
  );

  test(
    'a 503 response never leaks the raw envelope through debugSummary either',
    () async {
      final client = await startServerReturning(503, {
        'error': {
          'code': 'CALENDAR_CONCURRENCY_UNAVAILABLE',
          'message':
              'This item could not be safely updated. Refresh and try again.',
        },
        'meta': {'requestId': 'req-123'},
      });

      try {
        await client.updateCalendar(
          accessToken: 'tok',
          calendarId: 'portal:family-cal',
          name: 'Family',
        );
        fail('Expected CaleeHubException');
      } on CaleeHubException catch (e) {
        // debugSummary is only ever shown in debug builds (see
        // lib/features/calendar/calendar_page.dart), but must still never
        // contain a raw JSON object body even there.
        expect(e.debugSummary.contains('{"'), isFalse);
        expect(e.debugSummary, contains('HTTP 503'));
        expect(e.debugSummary, contains('CALENDAR_CONCURRENCY_UNAVAILABLE'));
      }
    },
  );
}

// Unit tests for CaleeHubClient.updateCalendar()/updateCalendarAppearance().
//
// updateCalendarAppearance() is the new appearance-only (name/colour) edit
// endpoint introduced alongside ClientCalendar.capabilities/appearanceMode.
// These tests confirm: it PATCHes a distinct /appearance path (never the
// plain updateCalendar() path), it sends a sparse body, and ClientCalendar
// parsing of the new sourceName/sourceColor/appearanceMode/capabilities
// fields — including the old-server fallback when they're absent — behaves
// per the finalized backend contract.

import 'dart:convert';
import 'dart:io';

import 'package:calee_mobile/data/api/calee_hub_client.dart';
import 'package:flutter_test/flutter_test.dart';

Map<String, dynamic> _calendarJson({
  String id = 'portal:family-cal',
  String name = 'Family',
  String? color = '#FF9500',
  bool readOnly = false,
  bool isSubscription = false,
  Map<String, dynamic>? capabilities,
  String? sourceName,
  Object? sourceColor = _unset,
  String? appearanceMode,
}) {
  return {
    'id': id,
    'serviceId': 'portal',
    'serviceName': 'Calee Portal',
    'name': name,
    'color': color,
    'components': ['VEVENT'],
    'primaryKind': 'calendar',
    'supportsEvents': true,
    'supportsTasks': false,
    'supportsChores': false,
    'readOnly': readOnly,
    'isSubscription': isSubscription,
    'source': 'calee',
    if (capabilities != null) 'capabilities': capabilities,
    if (sourceName != null) 'sourceName': sourceName,
    if (!identical(sourceColor, _unset)) 'sourceColor': sourceColor,
    if (appearanceMode != null) 'appearanceMode': appearanceMode,
  };
}

// Sentinel distinguishing "sourceColor key omitted" from "sourceColor: null".
const _unset = Object();

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

  group('CaleeHubClient.updateCalendar()', () {
    test('sends PATCH to /client/v1/calendars/:id (not /appearance)', () async {
      final client = await startServer({
        'data': {'calendar': _calendarJson()},
      });

      await client.updateCalendar(
        accessToken: 'tok',
        calendarId: 'portal:family-cal',
        name: 'Family',
      );

      expect(capturedMethods.single, 'PATCH');
      expect(capturedPaths.single, '/client/v1/calendars/portal%3Afamily-cal');
    });
  });

  group('CaleeHubClient.updateCalendarAppearance()', () {
    test('sends PATCH to the distinct /appearance path', () async {
      final client = await startServer({
        'data': {'calendar': _calendarJson()},
      });

      await client.updateCalendarAppearance(
        accessToken: 'tok',
        calendarId: 'portal:family-cal',
        name: 'Family',
        color: '#FF9500',
      );

      expect(capturedMethods.single, 'PATCH');
      expect(
        capturedPaths.single,
        '/client/v1/calendars/portal%3Afamily-cal/appearance',
      );
      // Never the plain (non-appearance) update path.
      expect(
        capturedPaths.single,
        isNot('/client/v1/calendars/portal%3Afamily-cal'),
      );
    });

    test('URL-encodes the calendar id', () async {
      final client = await startServer({
        'data': {'calendar': _calendarJson(id: 'external:abc-123')},
      });

      await client.updateCalendarAppearance(
        accessToken: 'tok',
        calendarId: 'external:abc-123',
        name: 'Holidays',
      );

      expect(
        capturedPaths.single,
        '/client/v1/calendars/external%3Aabc-123/appearance',
      );
    });

    test('sends name and color when both provided', () async {
      final client = await startServer({
        'data': {'calendar': _calendarJson()},
      });

      await client.updateCalendarAppearance(
        accessToken: 'tok',
        calendarId: 'cal1',
        name: 'School',
        color: '#FF9500',
      );

      expect(capturedBodies.single, {'name': 'School', 'color': '#FF9500'});
    });

    test('name-only update sends exactly {"name": ...}', () async {
      final client = await startServer({
        'data': {'calendar': _calendarJson()},
      });

      await client.updateCalendarAppearance(
        accessToken: 'tok',
        calendarId: 'cal1',
        name: 'School',
      );

      expect(capturedBodies.single, {'name': 'School'});
      expect(capturedBodies.single.containsKey('color'), isFalse);
    });

    test('colour-only update sends exactly {"color": ...}', () async {
      final client = await startServer({
        'data': {'calendar': _calendarJson()},
      });

      await client.updateCalendarAppearance(
        accessToken: 'tok',
        calendarId: 'cal1',
        color: '#FF9500',
      );

      expect(capturedBodies.single, {'color': '#FF9500'});
      expect(capturedBodies.single.containsKey('name'), isFalse);
    });

    test('an empty update is rejected locally without any request', () async {
      final client = await startServer({
        'data': {'calendar': _calendarJson()},
      });

      await expectLater(
        client.updateCalendarAppearance(accessToken: 'tok', calendarId: 'cal1'),
        throwsA(isA<CaleeHubException>()),
      );

      expect(capturedPaths, isEmpty);
      expect(capturedMethods, isEmpty);
      expect(capturedBodies, isEmpty);
    });

    test('never sends a null-valued key in the body', () async {
      final client = await startServer({
        'data': {'calendar': _calendarJson()},
      });

      await client.updateCalendarAppearance(
        accessToken: 'tok',
        calendarId: 'cal1',
        name: 'School',
        color: null,
      );

      for (final value in capturedBodies.single.values) {
        expect(value, isNotNull);
      }
    });

    test('returns the parsed ClientCalendar from data.calendar', () async {
      final client = await startServer({
        'data': {'calendar': _calendarJson(id: 'cal1', name: 'School Updated')},
      });

      final result = await client.updateCalendarAppearance(
        accessToken: 'tok',
        calendarId: 'cal1',
        name: 'School Updated',
      );

      expect(result.id, 'cal1');
      expect(result.name, 'School Updated');
    });
  });

  group('ClientCalendar.fromJson — new capability/appearance fields', () {
    test(
      'parses sourceName, sourceColor, appearanceMode and capabilities',
      () async {
        final client = await startServer({
          'data': {
            'calendar': _calendarJson(
              name: 'Family',
              color: '#FF9500',
              sourceName: 'Original provider calendar name',
              sourceColor: '#4285F4',
              appearanceMode: 'subscription_mapping',
              capabilities: {
                'canEditAppearance': true,
                'canEditEvents': false,
                'canEditSourceMetadata': false,
                'canRemoveFromCalee': true,
                'canDeleteSource': false,
              },
            ),
          },
        });

        final result = await client.updateCalendarAppearance(
          accessToken: 'tok',
          calendarId: 'cal1',
          name: 'Family',
        );

        expect(result.name, 'Family');
        expect(result.color, '#FF9500');
        expect(result.sourceName, 'Original provider calendar name');
        expect(result.sourceColor, '#4285F4');
        expect(result.appearanceMode, 'subscription_mapping');
        expect(result.capabilities.canEditAppearance, isTrue);
        expect(result.capabilities.canEditEvents, isFalse);
        expect(result.capabilities.canEditSourceMetadata, isFalse);
        expect(result.capabilities.canRemoveFromCalee, isTrue);
        expect(result.capabilities.canDeleteSource, isFalse);
        // A capabilities key in the payload marks the new server contract,
        // which is what authorises the /appearance route.
        expect(result.hasServerAppearanceContract, isTrue);
      },
    );

    test(
      'external_calendar mode: sourceColor is parsed as null, not the effective color',
      () async {
        final client = await startServer({
          'data': {
            'calendar': _calendarJson(
              color: '#4285F4',
              sourceName: 'My Google calendar',
              sourceColor: null,
              appearanceMode: 'external_calendar',
              capabilities: {
                'canEditAppearance': true,
                'canEditEvents': true,
                'canEditSourceMetadata': false,
                'canRemoveFromCalee': true,
                'canDeleteSource': false,
              },
            ),
          },
        });

        final result = await client.updateCalendarAppearance(
          accessToken: 'tok',
          calendarId: 'cal1',
          name: 'Family',
        );

        expect(result.color, '#4285F4');
        expect(result.sourceColor, isNull);
        expect(result.appearanceMode, 'external_calendar');
      },
    );

    test(
      'unsupported mode: capabilities are all false except none required true',
      () async {
        final client = await startServer({
          'data': {
            'calendar': _calendarJson(
              readOnly: true,
              appearanceMode: 'unsupported',
              capabilities: {
                'canEditAppearance': false,
                'canEditEvents': false,
                'canEditSourceMetadata': false,
                'canRemoveFromCalee': true,
                'canDeleteSource': false,
              },
            ),
          },
        });

        final result = await client.updateCalendarAppearance(
          accessToken: 'tok',
          calendarId: 'cal1',
          name: 'Shared calendar',
        );

        expect(result.appearanceMode, 'unsupported');
        expect(result.capabilities.canEditAppearance, isFalse);
        expect(result.capabilities.canRemoveFromCalee, isTrue);
      },
    );

    test(
      'missing capability keys inside a present capabilities map default to false',
      () async {
        final client = await startServer({
          'data': {
            'calendar': _calendarJson(capabilities: <String, dynamic>{}),
          },
        });

        final result = await client.updateCalendarAppearance(
          accessToken: 'tok',
          calendarId: 'cal1',
          name: 'Family',
        );

        expect(result.capabilities.canEditAppearance, isFalse);
        expect(result.capabilities.canEditEvents, isFalse);
        expect(result.capabilities.canEditSourceMetadata, isFalse);
        expect(result.capabilities.canRemoveFromCalee, isFalse);
        expect(result.capabilities.canDeleteSource, isFalse);
      },
    );
  });

  group('ClientCalendar.fromJson — old-server fallback (no new keys sent)', () {
    test(
      'writable, non-subscription calendar falls back to canEditAppearance true / source_metadata',
      () async {
        final client = await startServer({
          'data': {
            'calendar': _calendarJson(
              name: 'Family',
              color: '#FF9500',
              readOnly: false,
              isSubscription: false,
            ),
          },
        });

        final result = await client.updateCalendarAppearance(
          accessToken: 'tok',
          calendarId: 'cal1',
          name: 'Family',
        );

        expect(result.capabilities.canEditAppearance, isTrue);
        expect(result.capabilities.canEditEvents, isFalse);
        expect(result.capabilities.canEditSourceMetadata, isFalse);
        expect(result.capabilities.canRemoveFromCalee, isFalse);
        expect(result.capabilities.canDeleteSource, isFalse);
        expect(result.appearanceMode, 'source_metadata');
        // sourceName/sourceColor default to the effective name/color.
        expect(result.sourceName, 'Family');
        expect(result.sourceColor, '#FF9500');
        // No capabilities key means an old backend: canEditAppearance came
        // from the conservative fallback, so callers must not assume the
        // /appearance route exists.
        expect(result.hasServerAppearanceContract, isFalse);
      },
    );

    test(
      'a subscription calendar with no capabilities key still comes back with '
      'canEditAppearance == false (subscriptions never become appearance-editable '
      'against an old backend)',
      () async {
        final client = await startServer({
          'data': {
            'calendar': _calendarJson(readOnly: true, isSubscription: true),
          },
        });

        final result = await client.updateCalendarAppearance(
          accessToken: 'tok',
          calendarId: 'cal1',
          name: 'Shared calendar',
        );

        expect(result.capabilities.canEditAppearance, isFalse);
        expect(result.appearanceMode, 'unsupported');
      },
    );

    test(
      'a read-only, non-subscription calendar falls back to canEditAppearance false',
      () async {
        final client = await startServer({
          'data': {
            'calendar': _calendarJson(readOnly: true, isSubscription: false),
          },
        });

        final result = await client.updateCalendarAppearance(
          accessToken: 'tok',
          calendarId: 'cal1',
          name: 'Read only calendar',
        );

        expect(result.capabilities.canEditAppearance, isFalse);
        expect(result.appearanceMode, 'unsupported');
      },
    );

    test('a writable calendar (readOnly false, isSubscription false) matches '
        "today's pre-existing editable behaviour", () async {
      final client = await startServer({
        'data': {
          'calendar': _calendarJson(readOnly: false, isSubscription: false),
        },
      });

      final result = await client.updateCalendarAppearance(
        accessToken: 'tok',
        calendarId: 'cal1',
        name: 'Family',
      );

      // Matches the pre-existing `!readOnly || isSubscription` editability
      // this calendar would have had before capabilities existed.
      expect(result.capabilities.canEditAppearance, isTrue);
    });
  });
}

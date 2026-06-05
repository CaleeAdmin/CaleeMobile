import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:calee_mobile/data/api/calee_hub_client.dart';

// ── Helpers ──────────────────────────────────────────────────────────────────

Map<String, dynamic> _householdPayload({
  String id = 'h1',
  String name = 'My Family',
  String type = 'household',
}) => {
  'data': {
    'household': {
      'id': id,
      'type': type,
      'name': name,
      'role': 'admin',
      'status': 'active',
    },
  },
};

Map<String, dynamic> _contextPayload({
  String id = 'h1',
  String name = 'My Family',
  String type = 'household',
}) => {
  'data': {
    'context': {
      'id': id,
      'type': type,
      'name': name,
      'role': 'admin',
      'status': 'active',
    },
  },
};

Map<String, dynamic> _flatPayload({
  String id = 'h1',
  String name = 'My Family',
  String type = 'household',
}) => {
  'data': {
    'id': id,
    'type': type,
    'name': name,
    'role': 'admin',
    'status': 'active',
  },
};

void main() {
  group('CaleeHubClient.ensureDefaultFamily', () {
    late HttpServer server;

    tearDown(() async {
      await server.close(force: true);
    });

    test(
      'uses /households/default first and returns household from data.household',
      () async {
        final paths = <String>[];

        server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        server.listen((req) async {
          paths.add(req.uri.path);
          req.response.statusCode = HttpStatus.ok;
          req.response.headers.contentType = ContentType.json;
          req.response.write(jsonEncode(_householdPayload()));
          await req.response.close();
        });

        final client = CaleeHubClient(
          baseUri: Uri.parse('http://127.0.0.1:${server.port}'),
        );

        final result = await client.ensureDefaultFamily(accessToken: 'tok');

        expect(paths, [
          '/client/v1/households/default',
        ], reason: 'Should try idempotent endpoint first');
        expect(result.id, 'h1');
        expect(result.name, 'My Family');
      },
    );

    test(
      'falls back to /households when /households/default returns 404',
      () async {
        int callCount = 0;
        final paths = <String>[];

        server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        server.listen((req) async {
          callCount++;
          paths.add(req.uri.path);
          req.response.headers.contentType = ContentType.json;

          if (callCount == 1) {
            req.response.statusCode = HttpStatus.notFound;
            req.response.write(
              jsonEncode({
                'error': {'message': 'Not found'},
              }),
            );
          } else {
            req.response.statusCode = HttpStatus.ok;
            req.response.write(jsonEncode(_householdPayload(id: 'h2')));
          }

          await req.response.close();
        });

        final client = CaleeHubClient(
          baseUri: Uri.parse('http://127.0.0.1:${server.port}'),
        );

        final result = await client.ensureDefaultFamily(accessToken: 'tok');

        expect(paths, [
          '/client/v1/households/default',
          '/client/v1/households',
        ], reason: 'Should fall back to create endpoint on 404');
        expect(result.id, 'h2');
      },
    );

    test(
      'falls back to /households when /households/default returns 405',
      () async {
        int callCount = 0;

        server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        server.listen((req) async {
          callCount++;
          req.response.headers.contentType = ContentType.json;

          if (callCount == 1) {
            req.response.statusCode = HttpStatus.methodNotAllowed;
            req.response.write(
              jsonEncode({
                'error': {'message': 'Not allowed'},
              }),
            );
          } else {
            req.response.statusCode = HttpStatus.ok;
            req.response.write(jsonEncode(_householdPayload(id: 'h3')));
          }

          await req.response.close();
        });

        final client = CaleeHubClient(
          baseUri: Uri.parse('http://127.0.0.1:${server.port}'),
        );

        final result = await client.ensureDefaultFamily(accessToken: 'tok');

        expect(callCount, 2);
        expect(result.id, 'h3');
      },
    );

    test('accepts data.context response shape', () async {
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      server.listen((req) async {
        req.response.statusCode = HttpStatus.ok;
        req.response.headers.contentType = ContentType.json;
        req.response.write(jsonEncode(_contextPayload(id: 'h4')));
        await req.response.close();
      });

      final client = CaleeHubClient(
        baseUri: Uri.parse('http://127.0.0.1:${server.port}'),
      );

      final result = await client.ensureDefaultFamily(accessToken: 'tok');

      expect(result.id, 'h4');
    });

    test(
      'accepts flat data response shape (no household/context key)',
      () async {
        server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        server.listen((req) async {
          req.response.statusCode = HttpStatus.ok;
          req.response.headers.contentType = ContentType.json;
          req.response.write(jsonEncode(_flatPayload(id: 'h5')));
          await req.response.close();
        });

        final client = CaleeHubClient(
          baseUri: Uri.parse('http://127.0.0.1:${server.port}'),
        );

        final result = await client.ensureDefaultFamily(accessToken: 'tok');

        expect(result.id, 'h5');
      },
    );

    test(
      'rethrows non-404/405 errors from /households/default without falling back',
      () async {
        server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        server.listen((req) async {
          req.response.statusCode = HttpStatus.internalServerError;
          req.response.headers.contentType = ContentType.json;
          req.response.write(
            jsonEncode({
              'error': {'message': 'Internal error'},
            }),
          );
          await req.response.close();
        });

        final client = CaleeHubClient(
          baseUri: Uri.parse('http://127.0.0.1:${server.port}'),
        );

        await expectLater(
          client.ensureDefaultFamily(accessToken: 'tok'),
          throwsA(
            isA<CaleeHubException>().having(
              (e) => e.statusCode,
              'statusCode',
              500,
            ),
          ),
        );
      },
    );

    test(
      'throws CaleeHubException when response data is not a valid context',
      () async {
        server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        server.listen((req) async {
          req.response.statusCode = HttpStatus.ok;
          req.response.headers.contentType = ContentType.json;
          // Return a list instead of a map in data — invalid shape
          req.response.write(jsonEncode({'data': []}));
          await req.response.close();
        });

        final client = CaleeHubClient(
          baseUri: Uri.parse('http://127.0.0.1:${server.port}'),
        );

        await expectLater(
          client.ensureDefaultFamily(accessToken: 'tok'),
          throwsA(isA<CaleeHubException>()),
        );
      },
    );
  });
}

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:calee_mobile/data/api/calee_hub_client.dart';

void main() {
  group('CaleeHubClient auth retry', () {
    late HttpServer server;

    tearDown(() async {
      await server.close(force: true);
    });

    test('retries once on 401 and succeeds with new token', () async {
      int requestCount = 0;

      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      server.listen((req) async {
        requestCount++;
        req.response.headers.contentType = ContentType.json;

        if (requestCount == 1) {
          // First call: access token is stale → 401
          req.response.statusCode = HttpStatus.unauthorized;
          req.response.write(
            jsonEncode({'error': 'Unauthorized', 'message': 'Token expired'}),
          );
        } else {
          // Retry with fresh token: return minimal valid calendars response
          req.response.statusCode = HttpStatus.ok;
          req.response.write(
            jsonEncode({
              'data': {'calendars': []},
            }),
          );
        }

        await req.response.close();
      });

      int onUnauthorizedCount = 0;

      final client = CaleeHubClient(
        baseUri: Uri.parse('http://127.0.0.1:${server.port}'),
      );
      client.onUnauthorized = () async {
        onUnauthorizedCount++;
        return 'fresh-token';
      };

      final result = await client.calendars(accessToken: 'stale-token');

      expect(
        requestCount,
        2,
        reason: 'Should make exactly 2 requests: one 401, one retry',
      );
      expect(
        onUnauthorizedCount,
        1,
        reason: 'onUnauthorized should be called exactly once',
      );
      expect(result.calendars, isEmpty);
    });

    test('sends Authorization Bearer access token on Hub API calls', () async {
      String? authorization;

      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      server.listen((req) async {
        authorization = req.headers.value(HttpHeaders.authorizationHeader);
        req.response.statusCode = HttpStatus.ok;
        req.response.headers.contentType = ContentType.json;
        req.response.write(
          jsonEncode({
            'data': {'calendars': []},
          }),
        );
        await req.response.close();
      });

      final client = CaleeHubClient(
        baseUri: Uri.parse('http://127.0.0.1:${server.port}'),
      );

      await client.calendars(accessToken: 'access-token');

      expect(authorization, 'Bearer access-token');
    });

    test('does not retry when onUnauthorized is null', () async {
      int requestCount = 0;

      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      server.listen((req) async {
        requestCount++;
        req.response.statusCode = HttpStatus.unauthorized;
        req.response.headers.contentType = ContentType.json;
        req.response.write(
          jsonEncode({'error': 'Unauthorized', 'message': 'No auth'}),
        );
        await req.response.close();
      });

      final client = CaleeHubClient(
        baseUri: Uri.parse('http://127.0.0.1:${server.port}'),
      );
      // onUnauthorized is not set

      await expectLater(
        client.calendars(accessToken: 'bad-token'),
        throwsA(
          isA<CaleeHubException>().having(
            (e) => e.statusCode,
            'statusCode',
            401,
          ),
        ),
      );
      expect(
        requestCount,
        1,
        reason: 'Only one request should be made with no retry callback',
      );
    });

    test(
      'rethrows 401 when onUnauthorized returns null (refresh failed)',
      () async {
        server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        server.listen((req) async {
          req.response.statusCode = HttpStatus.unauthorized;
          req.response.headers.contentType = ContentType.json;
          req.response.write(
            jsonEncode({'error': 'Unauthorized', 'message': 'Token expired'}),
          );
          await req.response.close();
        });

        final client = CaleeHubClient(
          baseUri: Uri.parse('http://127.0.0.1:${server.port}'),
        );
        client.onUnauthorized = () async => null; // refresh failed

        await expectLater(
          client.calendars(accessToken: 'stale-token'),
          throwsA(
            isA<CaleeHubException>().having(
              (e) => e.statusCode,
              'statusCode',
              401,
            ),
          ),
        );
      },
    );

    test('uses cached refreshed token for subsequent requests', () async {
      int requestCount = 0;
      final receivedTokens = <String>[];

      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      server.listen((req) async {
        requestCount++;
        final auth = req.headers.value(HttpHeaders.authorizationHeader) ?? '';
        receivedTokens.add(auth);

        if (requestCount == 1) {
          // First call with stale token → 401
          req.response.statusCode = HttpStatus.unauthorized;
          req.response.headers.contentType = ContentType.json;
          req.response.write(
            jsonEncode({'error': 'Unauthorized', 'message': 'Token expired'}),
          );
        } else {
          req.response.statusCode = HttpStatus.ok;
          req.response.headers.contentType = ContentType.json;
          req.response.write(
            jsonEncode({
              'data': {'calendars': []},
            }),
          );
        }
        await req.response.close();
      });

      final client = CaleeHubClient(
        baseUri: Uri.parse('http://127.0.0.1:${server.port}'),
      );
      client.onUnauthorized = () async => 'fresh-token';

      await client.calendars(accessToken: 'stale-token');

      // A second call should use the cached fresh token without triggering 401 again.
      await client.calendars(accessToken: 'stale-token');

      expect(requestCount, 3);
      // Retry request and subsequent call both use the fresh token.
      expect(receivedTokens[1], 'Bearer fresh-token');
      expect(receivedTokens[2], 'Bearer fresh-token');
    });

    test(
      'clearAuthCache discards cached token so next call uses the passed token',
      () async {
        int requestCount = 0;
        final receivedTokens = <String>[];

        server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        server.listen((req) async {
          requestCount++;
          final auth = req.headers.value(HttpHeaders.authorizationHeader) ?? '';
          receivedTokens.add(auth);

          if (requestCount == 1) {
            req.response.statusCode = HttpStatus.unauthorized;
            req.response.headers.contentType = ContentType.json;
            req.response.write(
              jsonEncode({'error': 'Unauthorized', 'message': 'Token expired'}),
            );
          } else {
            req.response.statusCode = HttpStatus.ok;
            req.response.headers.contentType = ContentType.json;
            req.response.write(
              jsonEncode({
                'data': {'calendars': []},
              }),
            );
          }
          await req.response.close();
        });

        final client = CaleeHubClient(
          baseUri: Uri.parse('http://127.0.0.1:${server.port}'),
        );
        client.onUnauthorized = () async => 'fresh-token';

        // First call triggers refresh and caches 'fresh-token'.
        await client.calendars(accessToken: 'stale-token');

        // Clear the cache (simulates sign-out / sign-in).
        client.clearAuthCache();

        // Next call with a brand-new token should use 'new-token', not 'fresh-token'.
        await client.calendars(accessToken: 'new-token');

        expect(requestCount, 3);
        expect(receivedTokens[2], 'Bearer new-token');
      },
    );
  });

  group('CaleeHubClient transport retry', () {
    // Uses ServerSocket so we can close connections before sending HTTP headers,
    // simulating a stale keep-alive connection (the real-world failure mode).

    test(
      'GET retries once on HttpException (stale connection) and succeeds',
      () async {
        int connectionCount = 0;
        const body = '{"data":{"connections":[]}}';

        final serverSocket = await ServerSocket.bind(
          InternetAddress.loopbackIPv4,
          0,
        );
        final sub = serverSocket.listen((socket) async {
          connectionCount++;
          if (connectionCount == 1) {
            // Simulate stale keep-alive: close without sending HTTP headers.
            await socket.close();
          } else {
            // Respond with a minimal valid HTTP 200.
            socket.write(
              'HTTP/1.1 200 OK\r\n'
              'Content-Type: application/json\r\n'
              'Content-Length: ${body.length}\r\n'
              'Connection: close\r\n'
              '\r\n'
              '$body',
            );
            await socket.flush();
            await socket.close();
          }
        });

        final client = CaleeHubClient(
          baseUri: Uri.parse('http://127.0.0.1:${serverSocket.port}'),
        );

        final result = await client.externalCalendarConnections(
          accessToken: 'test-token',
        );

        expect(result, isEmpty);
        expect(
          connectionCount,
          2,
          reason: 'original attempt + one retry after transport reset',
        );

        await sub.cancel();
        await serverSocket.close();
      },
    );

    test(
      'GET does not retry more than once on repeated transport failure',
      () async {
        int connectionCount = 0;

        final serverSocket = await ServerSocket.bind(
          InternetAddress.loopbackIPv4,
          0,
        );
        final sub = serverSocket.listen((socket) async {
          connectionCount++;
          await socket.close(); // Always close without responding.
        });

        final client = CaleeHubClient(
          baseUri: Uri.parse('http://127.0.0.1:${serverSocket.port}'),
        );

        await expectLater(
          client.externalCalendarConnections(accessToken: 'test-token'),
          throwsA(anything),
        );

        expect(
          connectionCount,
          2,
          reason: 'original attempt + exactly one retry, then error propagates',
        );

        await sub.cancel();
        await serverSocket.close();
      },
    );

    test('POST does not retry on transport failure', () async {
      int connectionCount = 0;

      final serverSocket = await ServerSocket.bind(
        InternetAddress.loopbackIPv4,
        0,
      );
      final sub = serverSocket.listen((socket) async {
        connectionCount++;
        await socket.close();
      });

      final client = CaleeHubClient(
        baseUri: Uri.parse('http://127.0.0.1:${serverSocket.port}'),
      );

      await expectLater(
        client.approveDisplayLogin(
          accessToken: 'tok',
          token: 'display-tok',
        ),
        throwsA(anything),
      );

      expect(
        connectionCount,
        1,
        reason: 'POST must not be retried on transport failure',
      );

      await sub.cancel();
      await serverSocket.close();
    });

    test('resetTransport is no-op for injected HttpClient', () {
      final injected = HttpClient();
      final client = CaleeHubClient(
        baseUri: Uri.parse('http://localhost'),
        httpClient: injected,
      );

      // Must not throw and must not replace the injected client.
      expect(() => client.resetTransport(), returnsNormally);

      injected.close();
    });

    test(
      'GET transport retry preserves 401 refresh behaviour on the retry attempt',
      () async {
        // Sequence: stale connection → retry → 401 on retry → refresh → success.
        int connectionCount = 0;
        const body = '{"data":{"connections":[]}}';

        final serverSocket = await ServerSocket.bind(
          InternetAddress.loopbackIPv4,
          0,
        );
        final sub = serverSocket.listen((socket) async {
          connectionCount++;
          if (connectionCount == 1) {
            // Stale connection: close without headers.
            await socket.close();
          } else if (connectionCount == 2) {
            // Retry arrives with stale token → respond 401.
            const err =
                '{"error":{"message":"Token expired"},"meta":{}}';
            socket.write(
              'HTTP/1.1 401 Unauthorized\r\n'
              'Content-Type: application/json\r\n'
              'Content-Length: ${err.length}\r\n'
              'Connection: close\r\n'
              '\r\n'
              '$err',
            );
            await socket.flush();
            await socket.close();
          } else {
            // Auth-retry with fresh token → success.
            socket.write(
              'HTTP/1.1 200 OK\r\n'
              'Content-Type: application/json\r\n'
              'Content-Length: ${body.length}\r\n'
              'Connection: close\r\n'
              '\r\n'
              '$body',
            );
            await socket.flush();
            await socket.close();
          }
        });

        int onUnauthorizedCount = 0;
        final client = CaleeHubClient(
          baseUri: Uri.parse('http://127.0.0.1:${serverSocket.port}'),
        );
        client.onUnauthorized = () async {
          onUnauthorizedCount++;
          return 'fresh-token';
        };

        final result = await client.externalCalendarConnections(
          accessToken: 'stale-token',
        );

        expect(result, isEmpty);
        expect(connectionCount, 3);
        expect(onUnauthorizedCount, 1);

        await sub.cancel();
        await serverSocket.close();
      },
    );
  });
}

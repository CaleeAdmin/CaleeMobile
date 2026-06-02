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
              jsonEncode({'error': 'Unauthorized', 'message': 'Token expired'}));
        } else {
          // Retry with fresh token: return minimal valid calendars response
          req.response.statusCode = HttpStatus.ok;
          req.response.write(
              jsonEncode({'data': {'calendars': []}}));
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

      expect(requestCount, 2,
          reason: 'Should make exactly 2 requests: one 401, one retry');
      expect(onUnauthorizedCount, 1,
          reason: 'onUnauthorized should be called exactly once');
      expect(result.calendars, isEmpty);
    });

    test('does not retry when onUnauthorized is null', () async {
      int requestCount = 0;

      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      server.listen((req) async {
        requestCount++;
        req.response.statusCode = HttpStatus.unauthorized;
        req.response.headers.contentType = ContentType.json;
        req.response
            .write(jsonEncode({'error': 'Unauthorized', 'message': 'No auth'}));
        await req.response.close();
      });

      final client = CaleeHubClient(
        baseUri: Uri.parse('http://127.0.0.1:${server.port}'),
      );
      // onUnauthorized is not set

      await expectLater(
        client.calendars(accessToken: 'bad-token'),
        throwsA(
          isA<CaleeHubException>().having((e) => e.statusCode, 'statusCode', 401),
        ),
      );
      expect(requestCount, 1,
          reason: 'Only one request should be made with no retry callback');
    });

    test('rethrows 401 when onUnauthorized returns null (refresh failed)',
        () async {
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      server.listen((req) async {
        req.response.statusCode = HttpStatus.unauthorized;
        req.response.headers.contentType = ContentType.json;
        req.response.write(
            jsonEncode({'error': 'Unauthorized', 'message': 'Token expired'}));
        await req.response.close();
      });

      final client = CaleeHubClient(
        baseUri: Uri.parse('http://127.0.0.1:${server.port}'),
      );
      client.onUnauthorized = () async => null; // refresh failed

      await expectLater(
        client.calendars(accessToken: 'stale-token'),
        throwsA(
          isA<CaleeHubException>().having((e) => e.statusCode, 'statusCode', 401),
        ),
      );
    });

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
          req.response.write(jsonEncode({'error': 'Unauthorized', 'message': 'Token expired'}));
        } else {
          req.response.statusCode = HttpStatus.ok;
          req.response.headers.contentType = ContentType.json;
          req.response.write(jsonEncode({'data': {'calendars': []}}));
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
      expect(receivedTokens[1], contains('fresh-token'));
      expect(receivedTokens[2], contains('fresh-token'));
    });
  });
}

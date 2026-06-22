import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:calee_mobile/data/api/calee_hub_client.dart';

void main() {
  group('CaleeHubClient.requestPasswordReset', () {
    late HttpServer server;

    tearDown(() async {
      await server.close(force: true);
    });

    test('sends POST to /client/v1/auth/password-resets/request', () async {
      String? requestPath;

      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      server.listen((req) async {
        requestPath = req.uri.path;
        req.response.statusCode = HttpStatus.ok;
        req.response.headers.contentType = ContentType.json;
        req.response.write(jsonEncode({}));
        await req.response.close();
      });

      final client = CaleeHubClient(
        baseUri: Uri.parse('http://127.0.0.1:${server.port}'),
      );

      await client.requestPasswordReset(email: 'user@example.com');

      expect(requestPath, '/client/v1/auth/password-resets/request');
    });

    test('request body contains trimmed email', () async {
      Map<String, dynamic>? requestBody;

      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      server.listen((req) async {
        final body = await utf8.decodeStream(req);
        requestBody = jsonDecode(body) as Map<String, dynamic>;
        req.response.statusCode = HttpStatus.ok;
        req.response.headers.contentType = ContentType.json;
        req.response.write(jsonEncode({}));
        await req.response.close();
      });

      final client = CaleeHubClient(
        baseUri: Uri.parse('http://127.0.0.1:${server.port}'),
      );

      await client.requestPasswordReset(email: '  user@example.com  ');

      expect(requestBody, {'email': 'user@example.com'});
    });

    test('does not send Authorization header', () async {
      String? authHeader;

      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      server.listen((req) async {
        authHeader = req.headers.value(HttpHeaders.authorizationHeader);
        req.response.statusCode = HttpStatus.ok;
        req.response.headers.contentType = ContentType.json;
        req.response.write(jsonEncode({}));
        await req.response.close();
      });

      final client = CaleeHubClient(
        baseUri: Uri.parse('http://127.0.0.1:${server.port}'),
      );

      await client.requestPasswordReset(email: 'user@example.com');

      expect(authHeader, isNull);
    });

    test('backend error maps to CaleeHubException', () async {
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      server.listen((req) async {
        req.response.statusCode = HttpStatus.internalServerError;
        req.response.headers.contentType = ContentType.json;
        req.response.write(
          jsonEncode({'message': 'Internal server error'}),
        );
        await req.response.close();
      });

      final client = CaleeHubClient(
        baseUri: Uri.parse('http://127.0.0.1:${server.port}'),
      );

      await expectLater(
        client.requestPasswordReset(email: 'user@example.com'),
        throwsA(isA<CaleeHubException>()),
      );
    });
  });
}

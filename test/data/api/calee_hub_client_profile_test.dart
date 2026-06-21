// Unit tests for CaleeHubClient.profile() and updateProfile() JSON parsing.
//
// The backend wraps the profile under data.profile, and updateProfile can
// return top-level warnings alongside data.profile. These tests verify the
// client extracts the nested object correctly.

import 'dart:convert';
import 'dart:io';

import 'package:calee_mobile/data/api/calee_hub_client.dart';
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

  Future<CaleeHubClient> _startServer(
    Map<String, dynamic> responseBody,
  ) async {
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

  group('CaleeHubClient.profile()', () {
    test('parses data.profile correctly', () async {
      final client = await _startServer({
        'data': {
          'profile': {
            'accountId': 'acct-1',
            'email': 'alice@example.com',
            'firstName': 'Alice',
            'lastName': 'Smith',
            'displayName': 'Alice S',
            'timeZone': 'Australia/Perth',
            'postalCode': '6000',
          },
        },
      });

      final profile = await client.profile(accessToken: 'tok');

      expect(profile.accountId, equals('acct-1'));
      expect(profile.email, equals('alice@example.com'));
      expect(profile.firstName, equals('Alice'));
      expect(profile.lastName, equals('Smith'));
      expect(profile.displayName, equals('Alice S'));
      expect(profile.timeZone, equals('Australia/Perth'));
      expect(profile.postalCode, equals('6000'));
    });

    test('throws CaleeHubException when data.profile is missing', () async {
      final client = await _startServer({
        'data': {'other': 'field'},
      });

      expect(
        () => client.profile(accessToken: 'tok'),
        throwsA(
          isA<CaleeHubException>().having(
            (e) => e.message,
            'message',
            contains('Could not load your profile'),
          ),
        ),
      );
    });
  });

  group('CaleeHubClient.updateProfile()', () {
    test('parses data.profile correctly', () async {
      final client = await _startServer({
        'data': {
          'profile': {
            'accountId': 'acct-1',
            'email': 'alice@example.com',
            'firstName': 'Alice',
            'lastName': 'Smith',
          },
        },
      });

      final profile = await client.updateProfile(
        accessToken: 'tok',
        firstName: 'Alice',
        lastName: 'Smith',
      );

      expect(profile.firstName, equals('Alice'));
      expect(profile.lastName, equals('Smith'));
      expect(profile.email, equals('alice@example.com'));
    });

    test('preserves top-level warnings into ClientProfile.warnings', () async {
      final client = await _startServer({
        'data': {
          'profile': {
            'accountId': 'acct-1',
            'email': 'alice@example.com',
            'firstName': 'Alice',
            'lastName': 'Smith',
          },
          'warnings': ['CALDAV_SYNC_PENDING', 'TIMEZONE_MISMATCH'],
        },
      });

      final profile = await client.updateProfile(
        accessToken: 'tok',
        firstName: 'Alice',
        lastName: 'Smith',
      );

      expect(profile.warnings, containsAll(['CALDAV_SYNC_PENDING', 'TIMEZONE_MISMATCH']));
    });

    test('returns empty warnings when none present', () async {
      final client = await _startServer({
        'data': {
          'profile': {
            'accountId': 'acct-1',
            'email': 'alice@example.com',
            'firstName': 'Alice',
            'lastName': 'Smith',
          },
        },
      });

      final profile = await client.updateProfile(
        accessToken: 'tok',
        firstName: 'Alice',
        lastName: 'Smith',
      );

      expect(profile.warnings, isEmpty);
    });

    test('throws CaleeHubException when data.profile is missing', () async {
      final client = await _startServer({
        'data': {'other': 'field'},
      });

      expect(
        () => client.updateProfile(
          accessToken: 'tok',
          firstName: 'Alice',
          lastName: 'Smith',
        ),
        throwsA(
          isA<CaleeHubException>().having(
            (e) => e.message,
            'message',
            contains('Could not load your profile'),
          ),
        ),
      );
    });

    test('does not require firstName or lastName (partial update)', () async {
      final client = await _startServer({
        'data': {
          'profile': {
            'accountId': 'acct-1',
            'email': 'alice@example.com',
            'firstName': 'Alice',
            'lastName': 'Smith',
            'timeZone': 'Australia/Perth',
            'locale': 'en-AU',
            'countryCode': 'AU',
          },
        },
      });

      final profile = await client.updateProfile(
        accessToken: 'tok',
        timeZone: 'Australia/Perth',
        locale: 'en-AU',
        countryCode: 'AU',
      );

      expect(profile.timeZone, equals('Australia/Perth'));
      expect(profile.locale, equals('en-AU'));
      expect(profile.countryCode, equals('AU'));
    });

    test('sends only timeZone/locale/countryCode when no firstName/lastName', () async {
      final client = await _startServer({
        'data': {
          'profile': {
            'accountId': 'acct-1',
            'email': 'alice@example.com',
            'firstName': 'Alice',
            'lastName': 'Smith',
          },
        },
      });

      await client.updateProfile(
        accessToken: 'tok',
        timeZone: 'Australia/Perth',
        locale: 'en-AU',
        countryCode: 'AU',
      );

      expect(capturedBodies, hasLength(1));
      final sent = capturedBodies.first;
      expect(sent.containsKey('firstName'), isFalse);
      expect(sent.containsKey('lastName'), isFalse);
      expect(sent['timeZone'], equals('Australia/Perth'));
      expect(sent['locale'], equals('en-AU'));
      expect(sent['countryCode'], equals('AU'));
    });

    test('does not send email or postalCode in partial update', () async {
      final client = await _startServer({
        'data': {
          'profile': {
            'accountId': 'acct-1',
            'email': 'alice@example.com',
            'firstName': 'Alice',
            'lastName': 'Smith',
          },
        },
      });

      await client.updateProfile(
        accessToken: 'tok',
        timeZone: 'Australia/Perth',
        locale: 'en-AU',
        countryCode: 'AU',
      );

      expect(capturedBodies, hasLength(1));
      final sent = capturedBodies.first;
      expect(sent.containsKey('email'), isFalse);
      expect(sent.containsKey('primaryEmail'), isFalse);
      expect(sent.containsKey('postalCode'), isFalse);
    });

    test('throws CaleeHubException when no fields provided', () async {
      final client = await _startServer({'data': {}});

      expect(
        () => client.updateProfile(accessToken: 'tok'),
        throwsA(
          isA<CaleeHubException>().having(
            (e) => e.message,
            'message',
            contains('No profile updates provided'),
          ),
        ),
      );
    });
  });
}

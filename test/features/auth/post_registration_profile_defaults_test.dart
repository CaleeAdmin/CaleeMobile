import 'dart:convert';
import 'dart:io';

import 'package:calee_mobile/data/api/calee_hub_client.dart';
import 'package:calee_mobile/data/device/device_profile_defaults_provider.dart';
import 'package:calee_mobile/data/models/device_profile_defaults.dart';
import 'package:calee_mobile/features/auth/post_registration_profile_defaults.dart';
import 'package:flutter_test/flutter_test.dart';

class _FakeProvider extends DeviceProfileDefaultsProvider {
  _FakeProvider(this._result);

  final DeviceProfileDefaults _result;
  int callCount = 0;

  @override
  Future<DeviceProfileDefaults> load() async {
    callCount++;
    return _result;
  }
}

class _ThrowingProvider extends DeviceProfileDefaultsProvider {
  @override
  Future<DeviceProfileDefaults> load() async {
    throw Exception('platform channel unavailable');
  }
}

void main() {
  late HttpServer server;
  final patchRequests = <Map<String, dynamic>>[];

  setUp(() {
    patchRequests.clear();
  });

  tearDown(() async {
    await server.close(force: true);
  });

  Future<CaleeHubClient> startServer({int statusCode = 200}) async {
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((req) async {
      final body = await utf8.decoder.bind(req).join();
      if (body.isNotEmpty) {
        patchRequests.add(jsonDecode(body) as Map<String, dynamic>);
      }
      req.response.headers.contentType = ContentType.json;
      req.response.statusCode = statusCode;
      if (statusCode == 200) {
        req.response.write(
          jsonEncode({
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
          }),
        );
      } else {
        req.response.write(
          jsonEncode({
            'error': {'message': 'Server error'},
          }),
        );
      }
      await req.response.close();
    });
    return CaleeHubClient(
      baseUri: Uri.parse('http://127.0.0.1:${server.port}'),
    );
  }

  test(
    'calls PATCH /client/v1/profile with timezone, locale, countryCode',
    () async {
      final client = await startServer();
      final provider = _FakeProvider(
        const DeviceProfileDefaults(
          timeZone: 'Australia/Perth',
          locale: 'en-AU',
          countryCode: 'AU',
        ),
      );

      await applyPostRegistrationProfileDefaults(
        hubClient: client,
        accessToken: 'tok',
        provider: provider,
      );

      expect(patchRequests, hasLength(1));
      final sent = patchRequests.first;
      expect(sent['timeZone'], equals('Australia/Perth'));
      expect(sent['locale'], equals('en-AU'));
      expect(sent['countryCode'], equals('AU'));
      expect(sent.containsKey('email'), isFalse);
      expect(sent.containsKey('postalCode'), isFalse);
    },
  );

  test('does nothing when provider returns no defaults', () async {
    final client = await startServer();
    final provider = _FakeProvider(const DeviceProfileDefaults());

    await applyPostRegistrationProfileDefaults(
      hubClient: client,
      accessToken: 'tok',
      provider: provider,
    );

    expect(patchRequests, isEmpty);
  });

  test('swallows provider errors without rethrowing', () async {
    final client = await startServer();

    await expectLater(
      applyPostRegistrationProfileDefaults(
        hubClient: client,
        accessToken: 'tok',
        provider: _ThrowingProvider(),
      ),
      completes,
    );
    expect(patchRequests, isEmpty);
  });

  test('swallows API errors without rethrowing', () async {
    final client = await startServer(statusCode: 500);
    final provider = _FakeProvider(
      const DeviceProfileDefaults(timeZone: 'Australia/Perth'),
    );

    await expectLater(
      applyPostRegistrationProfileDefaults(
        hubClient: client,
        accessToken: 'tok',
        provider: provider,
      ),
      completes,
    );
  });
}

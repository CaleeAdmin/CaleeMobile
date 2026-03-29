import 'dart:convert';

import 'package:caleesync/common/app_constant.dart';
import 'package:caleesync/common/utils/mmkv_utils.dart';
import 'package:caleesync/services/calendar_share_alias_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;

import 'test_bootstrap.dart';

class _RecordingClient extends http.BaseClient {
  final Future<http.Response> Function(http.BaseRequest request) _handler;
  http.BaseRequest? lastRequest;

  _RecordingClient(this._handler);

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    lastRequest = request;
    final response = await _handler(request);
    return http.StreamedResponse(
      Stream.value(response.bodyBytes),
      response.statusCode,
      request: request,
      headers: response.headers,
      reasonPhrase: response.reasonPhrase,
    );
  }
}

void main() {
  setUpAll(() async {
    await bootstrapTestStorage();
  });

  setUp(() {
    MMKVUtils.instance.setString(AppConstant.loginNameKey, 'tester');
    MMKVUtils.instance.setString(AppConstant.appPasswordKey, 'app-password');
    MMKVUtils.instance.setString(AppConstant.serverKey, 'portal.calee.com.au');
  });

  test('fetchCurrentAlias() sends GET to api.calee.com.au alias endpoint', () async {
    final client = _RecordingClient((request) async {
      return http.Response(jsonEncode({'alias': 'alias-1'}), 200);
    });
    final service = CalendarShareAliasService(client: client);

    await service.fetchCurrentAlias();

    expect(client.lastRequest, isNotNull);
    expect(client.lastRequest!.method, 'GET');
    expect(
      client.lastRequest!.url.toString(),
      'https://api.calee.com.au/v1/me/calendar-share-alias',
    );
  });

  test('rotateAlias() sends POST to api.calee.com.au rotate endpoint', () async {
    final client = _RecordingClient((request) async {
      return http.Response(jsonEncode({'old_alias': 'alias-1', 'new_alias': 'alias-2'}), 200);
    });
    final service = CalendarShareAliasService(client: client);

    await service.rotateAlias();

    expect(client.lastRequest, isNotNull);
    expect(client.lastRequest!.method, 'POST');
    expect(
      client.lastRequest!.url.toString(),
      'https://api.calee.com.au/v1/me/calendar-share-alias/rotate',
    );
  });

  test('saved serverKey does not affect alias endpoint host', () async {
    MMKVUtils.instance.setString(AppConstant.serverKey, 'portal.calee.com.au');
    final client = _RecordingClient((request) async {
      return http.Response(jsonEncode({'alias': 'alias-1'}), 200);
    });
    final service = CalendarShareAliasService(client: client);

    await service.fetchCurrentAlias();

    expect(client.lastRequest, isNotNull);
    expect(client.lastRequest!.url.host, AppConstant.caleeApiServer);
    expect(client.lastRequest!.url.host, isNot('portal.calee.com.au'));
  });

  test('auth header still uses saved login name + app password', () async {
    MMKVUtils.instance.setString(AppConstant.loginNameKey, 'alice');
    MMKVUtils.instance.setString(AppConstant.appPasswordKey, 'pw-123');
    final client = _RecordingClient((request) async {
      return http.Response(jsonEncode({'alias': 'alias-1'}), 200);
    });
    final service = CalendarShareAliasService(client: client);

    await service.fetchCurrentAlias();

    final authorization = client.lastRequest!.headers['authorization'];
    final expectedToken = base64Encode(utf8.encode('alice:pw-123'));
    expect(authorization, 'Basic $expectedToken');
  });
}

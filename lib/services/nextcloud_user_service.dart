import 'dart:convert';

import 'package:caleesync/common/app_constant.dart';
import 'package:caleesync/common/utils/mmkv_utils.dart';
import 'package:http/http.dart' as http;

class NextcloudUserService {
  final http.Client _client;

  NextcloudUserService({http.Client? client}) : _client = client ?? http.Client();

  String get _serverUrl {
    final stored = MMKVUtils.instance.getString(AppConstant.Server);
    final raw = (stored == null || stored.isEmpty) ? AppConstant.nextcloudServer : stored;

    if (raw.startsWith('http://') || raw.startsWith('https://')) {
      return raw.endsWith('/') ? raw.substring(0, raw.length - 1) : raw;
    }
    return 'https://${raw.endsWith('/') ? raw.substring(0, raw.length - 1) : raw}';
  }

  String get _userId => MMKVUtils.instance.getString(AppConstant.loginName) ?? '';
  String get _appPassword => MMKVUtils.instance.getString(AppConstant.password) ?? '';

  Map<String, String> get _jsonHeaders => {
    'Authorization': 'Basic ${base64Encode(utf8.encode('$_userId:$_appPassword'))}',
    'OCS-APIRequest': 'true',
    'Accept': 'application/json',
  };

  Map<String, String> get _formHeaders => {
    'Authorization': 'Basic ${base64Encode(utf8.encode('$_userId:$_appPassword'))}',
    'OCS-APIRequest': 'true',
    'Content-Type': 'application/x-www-form-urlencoded',
    'Accept': 'application/json',
  };

  Future<Map<String, String>> fetchUserInfo() async {
    _assertCredentials();

    final url = Uri.parse('$_serverUrl/ocs/v2.php/cloud/user?format=json');
    final response = await _client.get(url, headers: _jsonHeaders);

    if (response.statusCode != 200) {
      throw Exception('Failed to fetch user info: ${response.statusCode} - ${response.body}');
    }

    final payload = jsonDecode(response.body) as Map<String, dynamic>;
    final ocs = payload['ocs'] as Map<String, dynamic>?;
    final data = ocs?['data'] as Map<String, dynamic>? ?? <String, dynamic>{};

    final user = data['user'] as Map<String, dynamic>? ?? <String, dynamic>{};
    final accountProperties = data['accountProperties'] as Map<String, dynamic>? ?? <String, dynamic>{};
    final config = data['configUserValues_selected'] as Map<String, dynamic>? ?? <String, dynamic>{};

    final addressProperty = accountProperties['address'] as Map<String, dynamic>?;

    return {
      'displayName': (user['displayName'] ?? '').toString(),
      'email': (user['email'] ?? '').toString(),
      'address': (addressProperty?['value'] ?? config['settings:address'] ?? '').toString(),
      'timezone': (user['timezone'] ?? config['core:timezone'] ?? '').toString(),
    };
  }

  Future<void> syncUserInfo({
    required String displayName,
    required String email,
    required String address,
    required String timezone,
  }) async {
    _assertCredentials();

    await _updateUserField(key: 'displayname', value: displayName);
    await _updateUserField(key: 'email', value: email);
    await _setPreference(app: 'settings', key: 'address', value: address);
    await _setPreference(app: 'core', key: 'timezone', value: timezone);
  }

  Future<void> _updateUserField({required String key, required String value}) async {
    final url = Uri.parse('$_serverUrl/ocs/v1.php/cloud/users/${Uri.encodeComponent(_userId)}');
    final body = Uri(queryParameters: {key: value}).query;

    final response = await _client.put(
      url,
      headers: _formHeaders,
      body: body,
    );

    if (response.statusCode != 200 || !_ocsStatusOk(response.body)) {
      throw Exception('Failed to update $key: ${response.statusCode} - ${response.body}');
    }
  }

  Future<void> _setPreference({
    required String app,
    required String key,
    required String value,
  }) async {
    final url = Uri.parse(
      '$_serverUrl/ocs/v2.php/apps/provisioning_api/api/v1/config/users/${Uri.encodeComponent(_userId)}/$app/$key',
    );

    final response = await _client.put(
      url,
      headers: _formHeaders,
      body: Uri(queryParameters: {'value': value}).query,
    );

    if (response.statusCode != 200 || !_ocsStatusOk(response.body)) {
      throw Exception('Failed to update $app:$key: ${response.statusCode} - ${response.body}');
    }
  }

  bool _ocsStatusOk(String responseBody) {
    return responseBody.contains('<status>ok</status>') ||
        responseBody.contains('"status":"ok"') ||
        responseBody.contains('"statuscode":100') ||
        responseBody.contains('<statuscode>100</statuscode>');
  }

  void _assertCredentials() {
    if (_userId.isEmpty || _appPassword.isEmpty) {
      throw Exception('Missing Nextcloud credentials. Please login again.');
    }
  }
}

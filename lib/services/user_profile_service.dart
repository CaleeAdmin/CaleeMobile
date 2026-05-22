import 'dart:convert';

import 'package:caleesync/common/app_constant.dart';
import 'package:caleesync/common/utils/mmkv_utils.dart';
import 'package:http/http.dart' as http;

class UserProfileService {
  final http.Client _client;

  UserProfileService({http.Client? client}) : _client = client ?? http.Client();

  Uri _buildUri(String path) {
    final rawServer =
        MMKVUtils.instance.getString(AppConstant.serverKey) ?? AppConstant.caleeServer;
    var server = rawServer.trim();
    if (!server.startsWith('http://') && !server.startsWith('https://')) {
      server = 'https://$server';
    }
    if (server.endsWith('/')) {
      server = server.substring(0, server.length - 1);
    }
    return Uri.parse('$server$path');
  }

  Map<String, String> _headers(String userId, String password) {
    final token = base64Encode(utf8.encode('$userId:$password'));
    return {
      'Authorization': 'Basic $token',
      'OCS-APIRequest': 'true',
      'Accept': 'application/json',
      'Content-Type': 'application/x-www-form-urlencoded',
    };
  }

  bool _isSuccessResponse(String body) {
    final payload = jsonDecode(body) as Map<String, dynamic>;
    final meta = ((payload['ocs'] as Map<String, dynamic>?)?['meta'] as Map<String, dynamic>?) ??
        <String, dynamic>{};
    final statusCode = int.tryParse(meta['statuscode']?.toString() ?? '') ?? -1;
    final status = meta['status']?.toString().toLowerCase() ?? '';
    return statusCode == 100 || status == 'ok';
  }

  String _extractErrorMessage(String body) {
    final payload = jsonDecode(body) as Map<String, dynamic>;
    final meta = ((payload['ocs'] as Map<String, dynamic>?)?['meta'] as Map<String, dynamic>?) ??
        <String, dynamic>{};
    return meta['message']?.toString() ?? 'Unknown error';
  }

  Future<Map<String, String>> fetchCurrentProfile() async {
    final userId = MMKVUtils.instance.getString(AppConstant.loginNameKey) ?? '';
    final password = MMKVUtils.instance.getString(AppConstant.appPasswordKey) ?? '';

    if (userId.isEmpty || password.isEmpty) {
      throw Exception('Missing Calee credentials');
    }

    final uri = _buildUri('/ocs/v2.php/cloud/user?format=json');
    final response = await _client.get(uri, headers: _headers(userId, password));

    if (response.statusCode != 200) {
      throw Exception('Failed to fetch profile: ${response.statusCode}');
    }

    final Map<String, dynamic> body = jsonDecode(response.body) as Map<String, dynamic>;
    final data = ((body['ocs'] as Map<String, dynamic>?)?['data'] as Map<String, dynamic>?) ??
        <String, dynamic>{};
    final accountProperties =
        (data['accountProperties'] as Map<String, dynamic>?) ?? <String, dynamic>{};

    String accountValue(String key) {
      final prop = accountProperties[key];
      if (prop is Map<String, dynamic>) {
        return prop['value']?.toString() ?? '';
      }
      return '';
    }

    return {
      'displayname': accountValue('displayname').isNotEmpty
          ? accountValue('displayname')
          : (data['displayname']?.toString() ?? ''),
      'email': accountValue('email').isNotEmpty
          ? accountValue('email')
          : (data['email']?.toString() ?? ''),
      'address': accountValue('address').isNotEmpty
          ? accountValue('address')
          : (data['address']?.toString() ?? ''),
      'timezone': accountValue('timezone').isNotEmpty
          ? accountValue('timezone')
          : (data['timezone']?.toString() ?? ''),
    };
  }

  Future<void> updateCurrentProfile({
    required String displayName,
    required String email,
    required String address,
    required String timezone,
  }) async {
    final userId = MMKVUtils.instance.getString(AppConstant.loginNameKey) ?? '';
    final password = MMKVUtils.instance.getString(AppConstant.appPasswordKey) ?? '';

    if (userId.isEmpty || password.isEmpty) {
      throw Exception('Missing Calee credentials');
    }

    final uri = _buildUri('/ocs/v2.php/cloud/users/${Uri.encodeComponent(userId)}?format=json');

    final updates = <String, String>{
      'displayname': displayName,
      'email': email,
      'address': address,
      'timezone': timezone,
    };

    final errors = <String>[];

    for (final entry in updates.entries) {
      final response = await _client.put(
        uri,
        headers: _headers(userId, password),
        body: {
          'key': entry.key,
          'value': entry.value,
        },
      );

      if (response.statusCode != 200) {
        errors.add('${entry.key}: HTTP ${response.statusCode}');
        continue;
      }

      final payload = jsonDecode(response.body) as Map<String, dynamic>;
      final meta = ((payload['ocs'] as Map<String, dynamic>?)?['meta'] as Map<String, dynamic>?) ??
          <String, dynamic>{};
      final statusCode = int.tryParse(meta['statuscode']?.toString() ?? '') ?? -1;
      final status = meta['status']?.toString().toLowerCase() ?? '';
      final isSuccess = statusCode == 100 || status == 'ok';

      if (!isSuccess) {
        final message = meta['message']?.toString() ?? 'Unknown error';
        errors.add('${entry.key}: $message');
      }
    }

    if (errors.isNotEmpty) {
      throw Exception('Failed to sync some fields: ${errors.join(', ')}');
    }
  }

  /// Deprecated: CaleeSync login now uses Calee Hub / Keycloak passwords.
  /// Do not call this from UI. Password changes must go through Calee Hub.
  Future<void> changePassword({
    required String currentPassword,
    required String newPassword,
  }) async {
    final userId = MMKVUtils.instance.getString(AppConstant.loginNameKey) ?? '';

    if (userId.isEmpty) {
      throw Exception('Missing Calee credentials');
    }

    final validateUri = _buildUri('/ocs/v2.php/cloud/user?format=json');
    final validateResponse = await _client.get(
      validateUri,
      headers: _headers(userId, currentPassword),
    );

    if (validateResponse.statusCode != 200 || !_isSuccessResponse(validateResponse.body)) {
      throw Exception('Current password is incorrect');
    }

    final updateUri = _buildUri('/ocs/v2.php/cloud/users/${Uri.encodeComponent(userId)}?format=json');
    final updateResponse = await _client.put(
      updateUri,
      headers: _headers(userId, currentPassword),
      body: {
        'key': 'password',
        'value': newPassword,
      },
    );

    if (updateResponse.statusCode != 200) {
      throw Exception('Failed to change password: HTTP ${updateResponse.statusCode}');
    }

    if (!_isSuccessResponse(updateResponse.body)) {
      final message = _extractErrorMessage(updateResponse.body);
      throw Exception('Failed to change password: $message');
    }
  }
}

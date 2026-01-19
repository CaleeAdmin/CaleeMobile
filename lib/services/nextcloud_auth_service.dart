import 'dart:convert';
import 'package:http/http.dart' as http;

/// Nextcloud Login Flow v2 认证服务
/// 
/// 参考文档: https://docs.nextcloud.com/server/latest/developer_manual/client_apis/LoginFlow/index.html#login-flow-v2
class NextcloudAuthService {
  final String serverBaseUrl;

  NextcloudAuthService({required this.serverBaseUrl});

  /// 确保服务器 URL 格式正确（添加 https:// 和 /）
  String get normalizedUrl {
    String url = serverBaseUrl.trim();
    if (!url.startsWith('http://') && !url.startsWith('https://')) {
      url = 'https://$url';
    }
    if (!url.endsWith('/')) {
      url = '$url/';
    }
    return url;
  }

  Future<Map<String, dynamic>> initiateLoginFlow() async {
    final url = Uri.parse('${normalizedUrl}index.php/login/v2');
    
    try {
      final response = await http.post(
        url,
        headers: {
          'Content-Type': 'application/json',
          'OCS-APIRequest': 'true',
        },
      ).timeout(
        const Duration(seconds: 10),
        onTimeout: () {
          throw Exception('Request timeout: Unable to connect to server');
        },
      );

      if (response.statusCode != 200) {
        throw Exception(
          'Failed to initiate login flow: ${response.statusCode} - ${response.body}',
        );
      }

      final data = jsonDecode(response.body) as Map<String, dynamic>;
      return data;
    } catch (e) {
      if (e is FormatException) {
        throw Exception('Invalid server response. Please check the server URL.');
      }
      rethrow;
    }
  }

  /// Step 2: 轮询检查用户是否已完成登录
  /// 
  /// [pollToken] 从 initiateLoginFlow 返回的 poll.token
  /// [pollEndpoint] 从 initiateLoginFlow 返回的 poll.endpoint
  /// 
  /// 返回: {
  ///   'server': 'https://server/',
  ///   'loginName': 'username',
  ///   'appPassword': 'app_password_xxx'
  /// }
  Future<Map<String, dynamic>> pollLoginStatus({
    required String pollToken,
    required String pollEndpoint,
  }) async {
    final url = Uri.parse(pollEndpoint);
    
    try {
      final response = await http.post(
        url,
        headers: {
          'Content-Type': 'application/json',
          'OCS-APIRequest': 'true',
        },
        body: jsonEncode({'token': pollToken}),
      ).timeout(
        const Duration(seconds: 5),
        onTimeout: () {
          throw Exception('Poll timeout');
        },
      );

      if (response.statusCode == 404) {
        // 用户尚未完成登录，需要继续轮询
        return {'status': 'pending'};
      }

      if (response.statusCode != 200) {
        throw Exception(
          'Failed to poll login status: ${response.statusCode} - ${response.body}',
        );
      }

      final data = jsonDecode(response.body) as Map<String, dynamic>;
      return data;
    } catch (e) {
      if (e is FormatException) {
        throw Exception('Invalid server response during polling.');
      }
      rethrow;
    }
  }

  /// 使用用户名密码验证登录
  /// 
  /// [loginName] 用户名
  /// [password] 密码
  /// 
  /// 返回: 验证成功返回 true，失败返回 false
  Future<bool> loginWithCredentials({
    required String loginName,
    required String password,
  }) async {
    // 使用 WebDAV PROPFIND 请求验证凭据
    final url = Uri.parse('${normalizedUrl}remote.php/dav/');
    
    try {
      final client = http.Client();
      final request = http.Request(
        'PROPFIND',
        url,
      );
      request.headers.addAll({
        'Authorization': 'Basic ${base64Encode(utf8.encode('$loginName:$password'))}',
        'Depth': '0',
      });

      final streamedResponse = await client.send(request).timeout(
        const Duration(seconds: 10),
      );
      
      final response = await http.Response.fromStream(streamedResponse);
      client.close();

      return response.statusCode == 207 || response.statusCode == 200;
    } catch (e) {
      return false;
    }
  }
}


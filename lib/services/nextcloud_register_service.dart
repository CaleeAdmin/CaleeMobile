import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:caleesync/common/app_constant.dart';
import 'package:caleesync/common/utils/mmkv_utils.dart';

/// Nextcloud 注册服务
/// 
/// 使用 Nextcloud Provisioning API 进行用户注册
/// 参考: https://docs.nextcloud.com/server/latest/admin_manual/configuration_user/user_provisioning_api.html
/// 
/// API 端点: POST /ocs/v1.php/cloud/users
/// 需要管理员凭据进行 Basic Auth
class NextcloudRegisterService {
  /// 确保服务器 URL 格式正确（添加 https:// 和 /）
  String get normalizedUrl {
    String url = AppConstant.nextcloudServer.trim();
    if (!url.startsWith('http://') && !url.startsWith('https://')) {
      url = 'https://$url';
    }
    if (!url.endsWith('/')) {
      url = '$url/';
    }
    return url;
  }

  /// 获取管理员凭据
  /// 优先从 MMKV 读取，如果没有则使用常量中的默认值
  String get _adminUsername {
    return MMKVUtils.instance.getString(
      AppConstant.mmkvKeyAdminUsername,
      defaultValue: AppConstant.adminUsername,
    ) ?? AppConstant.adminUsername;
  }

  String get _adminPassword {
    return MMKVUtils.instance.getString(
      AppConstant.mmkvKeyAdminPassword,
      defaultValue: AppConstant.adminPassword,
    ) ?? AppConstant.adminPassword;
  }

  /// 注册新用户（使用 Provisioning API）
  /// 
  /// [userid] 用户名（Nextcloud 使用 userid 而不是 username）
  /// [password] 密码
  /// [email] 邮箱地址
  /// 
  /// 返回: 注册成功返回 true，失败抛出异常
  Future<bool> register({
    required String userid,
    required String password,
    required String email,
  }) async {
    // 检查管理员凭据
    if (_adminUsername.isEmpty || _adminPassword.isEmpty) {
      throw Exception('Admin credentials not configured. Please configure admin username and password.');
    }

    final url = Uri.parse('${normalizedUrl}ocs/v1.php/cloud/users');
    
    // 构建 Basic Auth
    final credentials = base64Encode(utf8.encode('$_adminUsername:$_adminPassword'));
    
    // 构建表单数据（application/x-www-form-urlencoded）
    final body = Uri(queryParameters: {
      'userid': userid,
      'password': password,
      'email': email,
    }).query;

    try {
      final response = await http.post(
        url,
        headers: {
          'Authorization': 'Basic $credentials',
          'OCS-APIRequest': 'true',
          'Content-Type': 'application/x-www-form-urlencoded',
        },
        body: body,
      ).timeout(
        const Duration(seconds: 10),
        onTimeout: () {
          throw Exception('Request timeout: Unable to connect to server');
        },
      );

      // Provisioning API 成功返回 200，响应是 XML 格式
      if (response.statusCode == 200) {
        // 解析 XML 响应，检查 status
        final responseBody = response.body;
        if (responseBody.contains('<status>ok</status>') || 
            responseBody.contains('<statuscode>100</statuscode>')) {
          return true;
        }
        
        // 如果包含错误信息，提取错误消息
        if (responseBody.contains('<status>failure</status>')) {
          final messageMatch = RegExp(r'<message>(.*?)</message>').firstMatch(responseBody);
          final message = messageMatch?.group(1) ?? 'Registration failed';
          throw Exception(message);
        }
      }

      // 处理错误响应
      String errorMessage = 'Registration failed';
      try {
        // 尝试解析 XML 错误消息
        final responseBody = response.body;
        final messageMatch = RegExp(r'<message>(.*?)</message>').firstMatch(responseBody);
        if (messageMatch != null) {
          errorMessage = messageMatch.group(1) ?? errorMessage;
        } else {
          errorMessage = 'Registration failed: ${response.statusCode}';
        }
      } catch (_) {
        errorMessage = 'Registration failed: ${response.statusCode}';
      }
      
      throw Exception(errorMessage);
    } catch (e) {
      if (e is Exception) {
        rethrow;
      }
      throw Exception('Registration failed: ${e.toString()}');
    }
  }
}


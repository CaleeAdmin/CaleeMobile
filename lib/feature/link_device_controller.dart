import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:flutter/services.dart';
import 'package:caleesync/feature/nextcloud_auth_automator.dart';
import 'package:caleesync/feature/qr_scanner_page.dart';
import 'package:url_launcher/url_launcher.dart';

class LinkDeviceController {
  final String portalDomain = 'https://portal.calee.com.au';
  final String loginName = 'test';
  final String password = 'test@Calee';


  Future<void> handleQrScan(BuildContext context, String scannedUrl) async {
    final Uri url = Uri.parse(scannedUrl);

    try {
      // 1. 检查系统是否能打开该 URL
      if (await canLaunchUrl(url)) {
        // 2. 关键步骤：使用 externalApplication 模式打开系统浏览器
        // 这样可以复用用户在浏览器中已经登录的 Nextcloud 会话，从而跳过输入密码步骤
        await launchUrl(
          url,
          mode: LaunchMode.externalApplication,
        );

        // 3. 提示用户在浏览器中操作
        _showSuccessSnackBar(context);
      } else {
        throw '无法打开授权页面，请确保已安装浏览器';
      }
    } catch (e) {
      debugPrint('[Auth] 授权跳转失败: $e');
      _showErrorDialog(context, e.toString());
    }
  }

  static void _showSuccessSnackBar(BuildContext context) {
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('已跳转至浏览器，请点击“授权”完成平板关联'),
        backgroundColor: Colors.green,
        duration: Duration(seconds: 5),
      ),
    );
  }

  static void _showErrorDialog(BuildContext context, String message) {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('跳转失败'),
        content: Text(message),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('确定'),
          ),
        ],
      ),
    );
  }

  Future<void> scanAndAuthorize(BuildContext context) async {
    final status = await Permission.camera.request();
    if (!status.isGranted) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Camera permission is required to scan QR codes')),
        );
      }
      return;
    }

    try {
      final result = await Get.to<String>(() => const QRScannerPage());
      if (result == null || result.isEmpty) return;

      debugPrint('🔍 QR scan result: $result');
      await Clipboard.setData(ClipboardData(text: result));

      final flowUrl = result.startsWith('http') ? result : '$portalDomain$result';
      debugPrint('[LinkDeviceController] flowUrl: $flowUrl');
      handleQrScan(context, result);
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Scan failed: $e')));
      }
    }
  }
}



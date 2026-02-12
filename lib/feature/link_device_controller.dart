import 'dart:convert';

import 'package:caleesync/common/app_constant.dart';
import 'package:caleesync/common/utils/mmkv_utils.dart';
import 'package:caleesync/feature/qr_scanner_page.dart';
import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:http/http.dart' as http;
import 'package:permission_handler/permission_handler.dart';

class LinkDeviceController {
  Future<void> handleQrScan(BuildContext context, String scannedValue) async {
    try {
      final payload = _extractCaleePayload(scannedValue);
      final pollToken = (payload['pollToken'] as String?)?.trim() ?? '';
      if (pollToken.isEmpty) {
        throw const FormatException('QR payload missing pollToken');
      }

      final serverFromQr = (payload['server'] as String?)?.trim() ?? '';
      final savedServer = MMKVUtils.instance.getString(AppConstant.Server)?.trim() ?? '';
      final serverBase = _normalizeServerBase(serverFromQr.isNotEmpty ? serverFromQr : savedServer);
      if (serverBase == null) {
        throw const FormatException('Server is missing in QR payload and local settings');
      }

      final loginName = MMKVUtils.instance.getString(AppConstant.loginName)?.trim() ?? '';
      final appPassword = MMKVUtils.instance.getString(AppConstant.password)?.trim() ?? '';
      if (loginName.isEmpty || appPassword.isEmpty) {
        throw const FormatException('Missing saved Nextcloud credentials (loginName/appPassword)');
      }

      final endpoint = Uri.parse('$serverBase/index.php/apps/caleeflow/approve');
      final auth = base64Encode(utf8.encode('$loginName:$appPassword'));

      final response = await http.post(
        endpoint,
        headers: {
          'Authorization': 'Basic $auth',
          'Content-Type': 'application/json',
          'Accept': 'application/json',
        },
        body: jsonEncode({
          'pollToken': pollToken,
          'deviceName': 'CaleeSync',
        }),
      );

      if (response.statusCode != 200) {
        throw Exception(
          'Approval failed (${response.statusCode}): ${response.body}',
        );
      }

      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Device approval sent successfully.'),
            backgroundColor: Colors.green,
          ),
        );
      }
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(e.toString().replaceFirst('Exception: ', '')),
            backgroundColor: Colors.red,
          ),
        );
      }
    }
  }

  Map<String, dynamic> _extractCaleePayload(String qrData) {
    final uri = Uri.parse(qrData);
    final fragment = uri.fragment;
    if (!fragment.startsWith('calee=')) {
      throw const FormatException('QR fragment must contain calee payload');
    }

    final encoded = fragment.substring('calee='.length);
    if (encoded.isEmpty) {
      throw const FormatException('Empty calee payload');
    }

    final normalized = base64Url.normalize(encoded);
    final decoded = utf8.decode(base64Url.decode(normalized));
    final dynamic jsonData = jsonDecode(decoded);
    if (jsonData is! Map<String, dynamic>) {
      throw const FormatException('Invalid calee payload JSON');
    }

    return jsonData;
  }

  String? _normalizeServerBase(String serverBase) {
    if (serverBase.isEmpty) return null;

    final withScheme = serverBase.startsWith('http://') || serverBase.startsWith('https://')
        ? serverBase
        : 'https://$serverBase';

    final uri = Uri.tryParse(withScheme);
    if (uri == null || uri.host.isEmpty) return null;

    final normalizedPath = uri.path.endsWith('/') ? uri.path.substring(0, uri.path.length - 1) : uri.path;
    return Uri(
      scheme: uri.scheme,
      userInfo: uri.userInfo,
      host: uri.host,
      port: uri.hasPort ? uri.port : null,
      path: normalizedPath,
    ).toString();
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

      await handleQrScan(context, result);
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Scan failed: $e')));
      }
    }
  }
}

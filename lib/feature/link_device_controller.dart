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
      final approvalRequest = _parseApprovalRequest(scannedValue);
      if (!context.mounted) return;

      final bool? shouldApprove = await showDialog<bool>(
        context: context,
        builder: (dialogContext) {
          return AlertDialog(
            title: const Text('Approve device link?', textAlign: TextAlign.left),
            titlePadding: const EdgeInsets.fromLTRB(24, 24, 24, 8),
            contentPadding: const EdgeInsets.fromLTRB(24, 0, 24, 12),
            content: SizedBox(
              width: double.maxFinite,
              child: _detailRow('Device name', approvalRequest.deviceName),
            ),
            actionsPadding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(dialogContext).pop(false),
                child: const Text('Cancel'),
              ),
              ElevatedButton(
                onPressed: () => Navigator.of(dialogContext).pop(true),
                child: const Text('Approve'),
              ),
            ],
          );
        },
      );

      if (shouldApprove != true) return;

      await _sendApproval(approvalRequest);

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

  Widget _detailRow(String label, String value) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label, style: const TextStyle(fontWeight: FontWeight.w600)),
        const SizedBox(height: 2),
        SelectableText(value),
      ],
    );
  }

  Future<void> _sendApproval(_ApprovalRequest request) async {
    final endpoint = Uri.parse('${request.serverBase}/index.php/apps/caleeflow/approve');
    final auth = base64Encode(utf8.encode('${request.loginName}:${request.appPassword}'));

    final response = await http.post(
      endpoint,
      headers: {
        'Authorization': 'Basic $auth',
        'Content-Type': 'application/json',
        'Accept': 'application/json',
      },
      body: jsonEncode({
        'pollToken': request.pollToken,
        'deviceName': request.deviceName,
      }),
    );

    if (response.statusCode != 200) {
      throw Exception(
        'Approval failed (${response.statusCode}): ${response.body}',
      );
    }
  }

  _ApprovalRequest _parseApprovalRequest(String scannedValue) {
    final payload = _extractCaleePayload(scannedValue);
    final pollToken = (payload['pollToken'] as String?)?.trim() ?? '';
    if (pollToken.isEmpty) {
      throw const FormatException('QR payload missing pollToken');
    }

    final deviceName = (payload['deviceName'] as String?)?.trim() ?? '';
    if (deviceName.isEmpty) {
      throw const FormatException('QR payload missing deviceName');
    }

    final serverFromQr = (payload['server'] as String?)?.trim() ?? '';
    final savedServer = MMKVUtils.instance.getString(AppConstant.serverKey)?.trim() ?? '';
    final serverBase = _normalizeServerBase(serverFromQr.isNotEmpty ? serverFromQr : savedServer);
    if (serverBase == null) {
      throw const FormatException('Server is missing in QR payload and local settings');
    }

    final loginName = MMKVUtils.instance.getString(AppConstant.loginNameKey)?.trim() ?? '';
    final appPassword = MMKVUtils.instance.getString(AppConstant.appPasswordKey)?.trim() ?? '';
    if (loginName.isEmpty || appPassword.isEmpty) {
      throw const FormatException('Missing saved Nextcloud credentials (loginName/appPassword)');
    }

    return _ApprovalRequest(
      pollToken: pollToken,
      serverBase: serverBase,
      deviceName: deviceName,
      loginName: loginName,
      appPassword: appPassword,
    );
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

class _ApprovalRequest {
  const _ApprovalRequest({
    required this.pollToken,
    required this.serverBase,
    required this.deviceName,
    required this.loginName,
    required this.appPassword,
  });

  final String pollToken;
  final String serverBase;
  final String deviceName;
  final String loginName;
  final String appPassword;
}

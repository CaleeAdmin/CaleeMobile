import 'dart:convert';

import 'package:flutter/cupertino.dart';
import 'package:http/http.dart' as http;

import '../app_constant.dart';
import 'IcsParser.dart';
import 'mmkv_utils.dart';

/// 定义统一的事件数据包
class ParsedEvent {
  final String uid;
  final String summary;
  final int dtstart;
  final int dtend;
  final String? description;
  final String? href;

  ParsedEvent({
    required this.uid,
    required this.summary,
    required this.dtstart,
    required this.dtend,
    this.description,
    this.href,
  });
}

class Eventparsedutils {
  static int? _toInt(dynamic value) {
    if (value is int) return value;
    if (value == null) return null;
    return int.tryParse(value.toString());
  }

  /// 兼容处理普通与Subscribed calendar的详情获取
  static Future<ParsedEvent?> resolveEventData({
    required Map<String, dynamic> remote,
    required bool isSubscription,
  }) async {
    // 1. 内部配置与资源准备
    final String baseUrl = _activeServerBase();
    final String loginName = MMKVUtils.instance.getString(
        AppConstant.loginNameKey) ?? '';
    final String password = MMKVUtils.instance.getString(
        AppConstant.appPasswordKey) ?? '';

    // 内部生成 Auth Header
    final String authHeader = 'Basic ${base64Encode(
        utf8.encode('$loginName:$password'))}';

    final http.Client client = http.Client();

    try {
      // --- 场景 1：Subscribed calendar (直接从内存读取, 不走网络) ---
      if (isSubscription) {
        final String uid =
            ((remote['uid'] ?? remote['remote_uid']) ?? '').toString().trim();
        final int? dtstart = _toInt(remote['dtstart'] ?? remote['start']);
        final int? dtend = _toInt(remote['dtend'] ?? remote['end']);

        if (uid.isEmpty || dtstart == null || dtend == null) {
          return null;
        }

        return ParsedEvent(
          uid: uid,
          summary: remote['summary'] ?? 'Untitled',
          dtstart: dtstart,
          dtend: dtend,
          description: remote['description'],
          href: remote['href'],
        );
      }

      // --- 场景 2：普通日历 (内部发起请求) ---
      final String href = remote['href'] ?? '';
      if (href.isEmpty) return null;

      // 规范化 URL 拼接：处理可能出现的重复斜杠
      final String url = "${baseUrl.replaceAll(RegExp(r'/$'), '')}${href
          .startsWith('/') ? '' : '/'}$href";

      final response = await client.get(
        Uri.parse(url),
        headers: {
          'Authorization': authHeader,
          'User-Agent': 'CaleeSync/1.0',
          'Accept': 'text/calendar',
        },
      ).timeout(const Duration(seconds: 15));

      if (response.statusCode == 200) {
        // 使用 IcsParser 解析单条 ICS 文本
        final parsedMap = IcsParser.parse(response.body, remote['uid'] ?? href);
        return ParsedEvent(
          uid: parsedMap['uid'] ?? remote['uid'] ?? href,
          summary: parsedMap['summary'] ?? 'Untitled event',
          dtstart: parsedMap['dtstart'],
          dtend: parsedMap['dtend'],
          description: parsedMap['description'],
          href: href,
        );
      } else {
        debugPrint('[WARN] Failed to fetch event details [$href]: ${response.statusCode}');
        return null;
      }
    } catch (e) {
      debugPrint('[ERROR] resolveEventData exception: $e');
      return null;
    } finally {
      client.close(); // 释放连接资源
    }
  }

  static String _activeServerBase() {
    final String saved = MMKVUtils.instance.getString(AppConstant.serverKey) ?? AppConstant.caleeServer;
    String normalized = saved.trim();
    if (!normalized.startsWith('http://') && !normalized.startsWith('https://')) {
      normalized = 'https://$normalized';
    }
    return normalized.endsWith('/') ? normalized.substring(0, normalized.length - 1) : normalized;
  }
}

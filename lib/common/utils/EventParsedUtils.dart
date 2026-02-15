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
  /// 兼容处理普通与订阅日历的详情获取
  static Future<ParsedEvent?> resolveEventData({
    required Map<String, dynamic> remote,
    required bool isSubscription,
  }) async {
    // 1. 内部配置与资源准备
    const String baseUrl = "https://nc-dev.ywpl.com.au";
    final String loginName = MMKVUtils.instance.getString(
        AppConstant.loginName) ?? '';
    final String password = MMKVUtils.instance.getString(
        AppConstant.password) ?? '';

    // 内部生成 Auth Header
    final String authHeader = 'Basic ${base64Encode(
        utf8.encode('$loginName:$password'))}';

    final http.Client client = http.Client();

    try {
      // --- 场景 1：订阅日历 (直接从内存读取，不走网络) ---
      if (isSubscription) {
        if (remote['dtstart'] != null) {
          return ParsedEvent(
            uid: remote['uid'],
            summary: remote['summary'] ?? '无标题',
            // 确保类型安全
            dtstart: remote['dtstart'] is int ? remote['dtstart'] : int.parse(
                remote['dtstart'].toString()),
            dtend: remote['dtend'] is int ? remote['dtend'] : int.parse(
                remote['dtend'].toString()),
            description: remote['description'],
            href: remote['href'],
          );
        }
        return null;
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
          summary: parsedMap['summary'] ?? '未命名事件',
          dtstart: parsedMap['dtstart'],
          dtend: parsedMap['dtend'],
          description: parsedMap['description'],
          href: href,
        );
      } else {
        debugPrint('⚠️ 事件详情获取失败 [$href]: ${response.statusCode}');
        return null;
      }
    } catch (e) {
      debugPrint('❌ resolveEventData 异常: $e');
      return null;
    } finally {
      client.close(); // 释放连接资源
    }
  }
}
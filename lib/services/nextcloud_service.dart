import 'dart:convert';
import 'package:flutter/cupertino.dart';
import 'package:http/http.dart' as http;
import 'package:xml/xml.dart' as xml;

import '../common/app_constant.dart';
import '../common/utils/mmkv_utils.dart';

class NextcloudService {
  final http.Client _client = http.Client();

  /// 1. 获取并解析云端日历 (对应 calendar_map)
  Future<List<Map<String, dynamic>>> fetchRemoteCalendars({
    required String serverUrl,
    required String userId,
    required String password,
  }) async {
    final uri = Uri.parse('$serverUrl/remote.php/dav/calendars/${Uri.encodeComponent(userId)}/');

    // 我们保留你之前的复杂 XML，确保获取颜色和类型
    final xmlBody = '''<?xml version="1.0" encoding="utf-8" ?>
<d:propfind xmlns:d="DAV:" xmlns:cal="urn:ietf:params:xml:ns:caldav" xmlns:nc="http://nextcloud.org/ns" xmlns:oc="http://owncloud.org/ns">
  <d:prop>
    <d:displayname />
    <d:resourcetype />
    <nc:calendar-color /> 
    <cal:supported-calendar-component-set />
    <cs:getctag xmlns:cs="http://calendarserver.org/ns/" />
  </d:prop>
</d:propfind>''';

    final res = await _client.send(http.Request('PROPFIND', uri)
      ..headers.addAll({
        'Authorization': 'Basic ${base64Encode(utf8.encode('$userId:$password'))}',
        'Depth': '1',
        'Content-Type': 'application/xml; charset=utf-8',
      })
      ..body = xmlBody);

    final respBody = await res.stream.bytesToString();
    if (res.statusCode != 207) throw StateError('PROPFIND failed: ${res.statusCode}');

    return _parseCalendarXmlToMap(respBody);
  }

  List<Map<String, dynamic>> _parseCalendarXmlToMap(String xmlString) {
    final List<Map<String, dynamic>> results = [];
    final document = xml.XmlDocument.parse(xmlString);

    for (var response in document.findAllElements('d:response')) {
      final href = response.findElements('d:href').firstOrNull?.innerText;
      final prop = response.findAllElements('d:prop').firstOrNull;

      if (prop == null || href == null) continue;

      // 你的原版过滤逻辑：排除删除和特殊文件夹
      if (_isDeleted(prop) || _isSpecialFolder(href)) continue;

      // 必须是 Collection 且是 Calendar 类型
      final isCalendar = prop.findAllElements('cal:calendar').isNotEmpty;
      final hasDisplayName = prop.findAllElements('d:displayname').isNotEmpty;

      if (!isCalendar || !hasDisplayName) continue;

      final displayName = prop.findElements('d:displayname').firstOrNull?.innerText;
      final ctag = prop.findAllElements('cs:getctag').firstOrNull?.innerText;

      results.add({
        'remote_path': href, // 对应 calendar_map.remote_path
        'display_name': displayName, // 对应 calendar_map.display_name
        'last_ctag': ctag, // 对应 calendar_map.last_ctag
      });
    }
    return results;
  }

  /// 2. 获取并解析云端条目 (对应 sync_map)
  /// 批量获取日历中的所有事件
  /// 批量获取日历中的所有事件 (严格参考你的旧分支实现)
  Future<List<Map<String, dynamic>>> fetchRemoteEvents({
    required String calendarPath,
    required String userId,
  }) async {
    // 1. 严格使用你参考代码中的配置获取方式
    final server = _normalizeServer(AppConstant.nextcloudServer);
    final password = MMKVUtils.instance.getString(AppConstant.mmkvKeyNextcloudAppPassword);
    if (password == null || password.isEmpty) return [];

    // 2. 严格按照你参考代码的路径拼接逻辑
    // 注意：calendarPath 如果已经是 /remote.php... 开头，不要再加前缀
    final uri = Uri.parse('$server$calendarPath');

    debugPrint('[Nextcloud] fetchRemoteEvents: Requesting $uri for user $userId');

    final xmlBody = '''<?xml version="1.0" encoding="utf-8" ?>
<c:calendar-query xmlns:d="DAV:" xmlns:c="urn:ietf:params:xml:ns:caldav">
  <d:prop>
    <d:getetag />
    <c:calendar-data />
  </d:prop>
  <c:filter>
    <c:comp-filter name="VCALENDAR">
      <c:comp-filter name="VEVENT" />
    </c:comp-filter>
  </c:filter>
</c:calendar-query>''';

    // 3. 严格使用 http.Request('REPORT', uri) 模式
    final req = http.Request('REPORT', uri)
      ..headers.addAll({
        'Authorization': _getAuthString(userId, password), // 使用你原来的 auth 生成函数
        'Content-Type': 'application/xml; charset=utf-8',
        'Depth': '1',
      })
      ..body = xmlBody;

    final streamed = await _client.send(req);
    final respBody = await streamed.stream.bytesToString();

    debugPrint('[Nextcloud] fetchRemoteEvents: Response status ${streamed.statusCode}');

    if (streamed.statusCode != 207) {
      debugPrint('[Nextcloud] fetchRemoteEvents: Error Body: $respBody');
      throw Exception('REPORT failed: ${streamed.statusCode}');
    }

    // 4. 解析结果映射到我们新定义的数据结构
    return _parseEventsXmlToMap(respBody);
  }

  List<Map<String, dynamic>> _parseEventsXmlToMap(String xmlString) {
    final List<Map<String, dynamic>> events = [];
    final document = xml.XmlDocument.parse(xmlString);

    for (var response in document.findAllElements('d:response')) {
      final href = response.findElements('d:href').firstOrNull?.innerText;
      final etag = response.findAllElements('d:getetag').firstOrNull?.innerText?.replaceAll('"', '');
      final icsData = response.findAllElements('c:calendar-data').firstOrNull?.innerText;

      if (href != null && href.endsWith('.ics') && icsData != null) {
        // 从 ICS 字符串中提取 UID (同步的核心主键)
        final uid = _extractUidFromIcs(icsData);
        if (uid != null) {
          events.add({
            'uid': uid, // 对应 sync_map.uid
            'remote_href': href, // 对应 sync_map.remote_href
            'last_etag': etag, // 对应 sync_map.last_etag
            'item_type': 'event',
          });
        }
      }
    }
    return events;
  }

  // --- 辅助工具函数 ---

  bool _isDeleted(xml.XmlElement prop) {
    return prop.descendants
        .whereType<xml.XmlElement>()
        .any((e) => e.name.local == 'deleted-calendar');
  }

  bool _isSpecialFolder(String href) {
    return href.contains('/inbox/') || href.contains('/outbox/') || href.contains('/trashbin/');
  }

  String? _extractUidFromIcs(String ics) {
    // 简单的正则匹配 UID:xxx
    final reg = RegExp(r'UID:(.*)\r?\n');
    final match = reg.firstMatch(ics);
    return match?.group(1)?.trim();
  }

  String _normalizeServer(String base) {
    base = base.trim();
    if (base.endsWith('/')) base = base.substring(0, base.length - 1);
    if (base.startsWith('http://') || base.startsWith('https://')) return base;
    return 'https://$base';
  }

  String _getAuthString(String user, String pass) =>
      'Basic ${base64Encode(utf8.encode('$user:$pass'))}';

}
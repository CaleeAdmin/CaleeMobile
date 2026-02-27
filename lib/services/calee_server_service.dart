import 'dart:convert';

import 'package:flutter/cupertino.dart';
import 'package:http/http.dart' as http;
import 'package:xml/xml.dart' as xml;

import '../common/app_constant.dart';
import '../common/utils/IcsParser.dart';
import '../common/utils/IcsSerializer.dart';
import '../common/utils/mmkv_utils.dart';
import '../data/database_helper.dart';

class CaleeServerService {
  final http.Client _client = http.Client();
  final DatabaseHelper _dbHelper = DatabaseHelper.instance;

  String get _activeServerBase => _normalizeServer(
      MMKVUtils.instance.getString(AppConstant.serverKey) ?? AppConstant.caleeServer);

  /// 1. 获取并解析云端日历 (对应 remote_collections)
  Future<List<Map<String, dynamic>>> scanRemoteCalendars({
    required String serverUrl,
    required String userId,
  }) async {
    final normalizedServer = _normalizeServer(serverUrl);
    final uri = Uri.parse(
      '$normalizedServer/remote.php/dav/calendars/${Uri.encodeComponent(userId)}/',
    );
    final String password = MMKVUtils.instance.getString(AppConstant.appPasswordKey) ?? "";

    // 1. 增加 cs 命名空间定义, 并请求该属性
    final xmlBody = '''<?xml version="1.0" encoding="utf-8" ?>
  <d:propfind xmlns:d="DAV:" 
              xmlns:cal="urn:ietf:params:xml:ns:caldav" 
              xmlns:nc="http://nextcloud.org/ns" 
              xmlns:cs="http://calendarserver.org/ns/"
              xmlns:oc="http://owncloud.org/ns">
    <d:prop>
      <d:displayname />
      <cal:calendar-description />
      <oc:calendar-description />
      <d:resourcetype />
      <d:current-user-privilege-set />
      <nc:calendar-color /> 
      <nc:subscribe />
      <cs:source />
      <cal:supported-calendar-component-set />
      <cs:getctag />
    </d:prop>
  </d:propfind>''';

    final request = http.Request('PROPFIND', uri)
      ..headers.addAll({
        'Authorization': 'Basic ${base64Encode(utf8.encode('$userId:$password'))}',
        'Depth': '1',
        'Content-Type': 'application/xml; charset=utf-8',
      })
      ..body = xmlBody;

    final res = await _client.send(request);
    final respBody = await res.stream.bytesToString();

    if (res.statusCode != 207) {
      throw StateError('PROPFIND failed: ${res.statusCode} - $respBody');
    }

    final List<Map<String, dynamic>> results = _parseCalendarXmlToMap(respBody);
    await persistRemoteCalendars(results, userId);
    return results;
  }

  List<Map<String, dynamic>> _parseCalendarXmlToMap(String xmlString) {
    final List<Map<String, dynamic>> results = [];
    final document = xml.XmlDocument.parse(xmlString);

    for (var response in document.findAllElements('d:response')) {
      final href = response.findElements('d:href').firstOrNull?.innerText;
      final prop = response.findAllElements('d:prop').firstOrNull;

      if (prop == null || href == null) continue;
      // 过滤掉根路径和特殊系统文件夹
      if (_isSpecialFolder(href)) continue;

      // --- 核心判定逻辑：识别资源类型 ---
      final resourceType = prop.findElements('d:resourcetype').firstOrNull;

      // a. 检查是否是标准日历
      final isStandardCalendar = resourceType?.findElements('cal:calendar').isNotEmpty ?? false;
      // b. 检查是否是Subscribed calendar (你的 curl 结果显示Subscribed calendar带这个标签)
      final isSubscribedResource = resourceType?.findElements('cs:subscribed').isNotEmpty ?? false;

      // 如果两者都不是, 说明是普通文件夹或 inbox/outbox, 跳过
      if (!isStandardCalendar && !isSubscribedResource) continue;

      // --- 字段提取 ---
      final displayName = prop.findElements('d:displayname').firstOrNull?.innerText;
      final String? calendarDescription = prop.findElements('cal:calendar-description').firstOrNull?.innerText
          ?? prop.findElements('oc:calendar-description').firstOrNull?.innerText;
      final Map<String, dynamic> originMeta = _extractOriginMetadata(calendarDescription);
      // Subscribed calendar可能没有 ctag, 使用空字符串兜底
      final ctag = prop.findAllElements('cs:getctag').firstOrNull?.innerText;
      final color = prop.findElements('nc:calendar-color').firstOrNull?.innerText;
      final sourceElement = prop.findElements('cs:source').firstOrNull;
      final String? hrefInSource = sourceElement
          ?.findElements('d:href')
          .firstOrNull
          ?.innerText
          .trim();
      final String? sourceText = sourceElement?.innerText.trim();
      final String? sourceUrl = (hrefInSource != null && hrefInSource.isNotEmpty)
          ? hrefInSource
          : (sourceText != null && sourceText.isNotEmpty ? sourceText : null);
      final String? subscriptionUrl = canonicalizeSubscriptionUrl(sourceUrl);

      // --- 权限与模式逻辑 ---

      // 1. 订阅判定：
      // 满足以下任一condition即视为Subscribed calendar：
      // - resourcetype 包含 cs:subscribed
      // - nc:subscribe 字段值为 "1"
      final ncSubscribe = prop.findElements('nc:subscribe').firstOrNull?.innerText;
      final bool hasSubscriptionSource = subscriptionUrl != null && subscriptionUrl.isNotEmpty;
      bool isSubscribed = isSubscribedResource || _isTruthySubscriptionValue(ncSubscribe) || hasSubscriptionSource;

      // 3. 设定同步模式：新抓取/新创建的远端日历统一默认只读 (0)
      // 双向同步由 UI 的 "Two-way sync" 开关显式开启。
      const int syncMode = 0;

      final String normalizedPath = normalizeRemotePath(href);
      final String collectionType = _classifyCollectionType(prop);
      results.add({
        'collection_type': collectionType,
        'remote_path': normalizedPath,
        'display_name': displayName ?? (isSubscribed ? "Subscribed calendar" : "Untitled calendar"),
        'ctag': ctag ?? "",
        'sync_mode': syncMode,
        'color': color,
        'is_subscription': isSubscribed, // 建议增加此字段方便 UI 展示
        'subscription_url': subscriptionUrl,
        'origin_kind': originMeta['origin_kind'],
        'origin_key': originMeta['origin_key'],
      });
    }
    return results;
  }

  Map<String, dynamic> _extractOriginMetadata(String? calendarDescription) {
    if (calendarDescription == null || calendarDescription.trim().isEmpty) {
      return {'origin_kind': 1, 'origin_key': null};
    }

    final String normalizedDescription = calendarDescription
        .replaceAll('&#10;', '\n')
        .replaceAll('&#13;', '\r')
        .replaceAll('\\n', '\n')
        .replaceAll('\\r', '\r');

    String? origin;
    String? originKey;
    for (final String line in normalizedDescription.split(RegExp(r'[\r\n]+'))) {
      final String normalized = line.trim();
      if (normalized.isEmpty) continue;
      final int idx = normalized.indexOf('=');
      if (idx <= 0) continue;
      final String key = normalized.substring(0, idx).trim().toLowerCase();
      final String value = normalized.substring(idx + 1).trim();
      if (key == 'origin') {
        final String lowered = value.toLowerCase();
        if (lowered.startsWith('local')) {
          origin = 'local';
        } else if (lowered.startsWith('remote')) {
          origin = 'remote';
        } else {
          origin = lowered;
        }
      } else if (key == 'originkey' || key == 'origin_key') {
        originKey = value;
      }
    }

    int originKind = 1;
    if (origin == 'local') {
      originKind = 0;
    } else if (origin == 'remote') {
      originKind = 1;
    }
    return {'origin_kind': originKind, 'origin_key': originKey};
  }

  String _classifyCollectionType(xml.XmlElement prop) {
    final Set<String> componentNames = prop
        .findAllElements('cal:comp')
        .map((node) => (node.getAttribute('name') ?? '').trim().toUpperCase())
        .where((name) => name.isNotEmpty)
        .toSet();

    if (componentNames.contains('VEVENT')) {
      return 'calendar';
    }

    if (componentNames.contains('VTODO')) {
      return 'tasklist';
    }

    if (componentNames.isNotEmpty && componentNames.every((name) => name == 'VJOURNAL')) {
      return 'tasklist';
    }

    return 'calendar';
  }

// 辅助工具：确保不把根目录 /calendars/focus/ 当做日历处理
  bool _isSpecialFolder(String href) {
    // 如果 href 刚好等于根路径, 或者包含系统保留关键字
    final path = href.toLowerCase();
    return path.endsWith('/inbox/') ||
        path.endsWith('/outbox/') ||
        path.endsWith('/trashbin/') ||
        // 这里的正则或判断逻辑应根据你的具体 userId 路径调整
        // 如果 path 只有 4 层级且以用户名为结尾, 通常是根目录
        RegExp(r'/dav/calendars/[^/]+/$').hasMatch(path);
  }

  Future<void> persistRemoteCalendars(List<Map<String, dynamic>> remoteMaps, String accountName) async {
    debugPrint("==remoteMaps===$remoteMaps");

    final db = await _dbHelper.database;

    await db.transaction((txn) async {
      // 1. 提取本次远端扫描到的所有合法路径, 按集合类型作为“白名单”
      final Map<String, List<String>> currentRemotePathsByType = {
        'calendar': <String>[],
        'tasklist': <String>[],
      };

      for (final map in remoteMaps) {
        final String remotePath = normalizeRemotePath((map['remote_path'] ?? '').toString());
        if (remotePath.isEmpty) continue;
        final String collectionType = (map['collection_type']?.toString() ?? 'calendar').trim();
        final String normalizedType = collectionType == 'tasklist' ? 'tasklist' : 'calendar';
        currentRemotePathsByType[normalizedType]!.add(remotePath);
      }

      final int currentRemotePathCount =
          currentRemotePathsByType.values.fold(0, (sum, paths) => sum + paths.length);

      debugPrint("Start persisting remote calendar list, active path count: $currentRemotePathCount");

      // 2. 遍历远端列表：执行“增”或“改”
      for (var map in remoteMaps) {
        // 新日历默认只读；已存在日历保留本地用户已选择的同步模式。
        final int syncMode = (map['sync_mode'] as int?) ?? 0;
        final String remotePath = normalizeRemotePath((map['remote_path'] ?? '').toString());
        if (remotePath.isEmpty) continue;
        final String collectionType = (map['collection_type']?.toString() ?? 'calendar').trim() == 'tasklist'
            ? 'tasklist'
            : 'calendar';
        await txn.rawInsert('''
        INSERT INTO remote_collections (
          account_name,
          collection_type,
          remote_path, 
          display_name, 
          synced_ctag, 
          sync_mode, 
          color, 
          is_subscription,
          subscription_url,
          origin_kind,
          origin_key
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?) -- 增加订阅字段
        ON CONFLICT(account_name, collection_type, remote_path) DO UPDATE SET
          display_name = excluded.display_name,
          synced_ctag = remote_collections.synced_ctag,
          sync_mode = remote_collections.sync_mode,
          -- 只有当远端提供了新颜色且不为空时才更新本地颜色
          color = CASE WHEN excluded.color IS NOT NULL AND excluded.color != "" 
                       THEN excluded.color 
                       ELSE remote_collections.color END,
          is_subscription = excluded.is_subscription,
          subscription_url = CASE
            WHEN excluded.subscription_url IS NOT NULL AND excluded.subscription_url != ''
              THEN excluded.subscription_url
            ELSE remote_collections.subscription_url
          END,
          origin_kind = CASE
            WHEN remote_collections.origin_kind = 0 THEN 0
            ELSE excluded.origin_kind
          END,
          origin_key = CASE
            WHEN excluded.origin_key IS NOT NULL AND excluded.origin_key != ''
              THEN excluded.origin_key
            ELSE remote_collections.origin_key
          END
          -- 注意：绑定信息由 local_bindings 管理, 不在此处更新。
      ''', [
              accountName,
              collectionType,
              remotePath,
              map['display_name'],
              map['ctag'],
              syncMode,
              map['color'],
              (map['is_subscription'] == true || map['is_subscription'] == 1) ? 1 : 0,
              canonicalizeSubscriptionUrl(map['subscription_url']?.toString()),
              (map['origin_kind'] as int?) ?? 1,
              map['origin_key']?.toString(),
            ]);
      }

      final int now = DateTime.now().millisecondsSinceEpoch;
      await txn.rawInsert('''
        INSERT INTO collection_states (remote_collection_id, is_enabled, updated_at)
        SELECT rc.id, 0, ?
        FROM remote_collections rc
        WHERE rc.account_name = ?
          AND NOT EXISTS (
            SELECT 1 FROM collection_states cs WHERE cs.remote_collection_id = rc.id
          )
      ''', [now, accountName]);

      await txn.rawUpdate('''
        UPDATE collection_states
        SET sync_gate_reason = CASE
          WHEN sync_gate_reason IN ('relink_verifying', 'relink_mismatch')
            THEN sync_gate_reason
          WHEN (
            SELECT rc.origin_kind FROM remote_collections rc
            WHERE rc.id = collection_states.remote_collection_id
          ) = 0
          AND NOT EXISTS (
            SELECT 1 FROM local_bindings lb
            WHERE lb.remote_collection_id = collection_states.remote_collection_id
          ) THEN 'relink_required'
          WHEN sync_gate_reason IS NOT NULL AND sync_gate_reason != ''
            THEN sync_gate_reason
          ELSE NULL
        END,
        updated_at = ?
        WHERE remote_collection_id IN (
          SELECT id FROM remote_collections WHERE account_name = ?
        )
      ''', [now, accountName]);

      // 3. 删除云端已不存在的远端起源记录（按集合类型分别清理）
      for (final String collectionType in const ['calendar', 'tasklist']) {
        final List<String> currentRemotePaths = currentRemotePathsByType[collectionType] ?? const [];
        if (currentRemotePaths.isNotEmpty) {
          final placeholders = List.filled(currentRemotePaths.length, '?').join(',');
          await txn.delete(
            'remote_collections',
            where: 'account_name = ? AND collection_type = ? AND remote_path NOT IN ($placeholders)',
            whereArgs: [accountName, collectionType, ...currentRemotePaths],
          );
        } else {
          await txn.delete(
            'remote_collections',
            where: 'account_name = ? AND collection_type = ?',
            whereArgs: [accountName, collectionType],
          );
        }
      }
    });
  }

  /// 2. 获取并解析云端条目 (对应 sync_items)

  /// 核心方法：统一获取事件（适配普通与Subscribed calendar）
  Future<UnifiedEventsSnapshot> fetchUnifiedEventsSnapshot({
    required String calendarPath,
    required bool isSubscription,
  }) async {
    final String fullUrl = "$_activeServerBase$calendarPath${isSubscription ? '?export' : ''}";
    final Map<String, String> headers = _getAuthHeaders();

    try {
      final response = isSubscription
          ? await http.get(Uri.parse(fullUrl), headers: headers)
          : await _sendReportRequest(fullUrl, headers);

      final int statusCode = response.statusCode;
      if (statusCode != 200 && statusCode != 207) {
        return UnifiedEventsSnapshot(
          events: const [],
          statusCode: statusCode,
          fetchSucceeded: false,
          parseProducedZeroEvents: false,
        );
      }

      List<Map<String, String>> eventRawData = [];
      if (isSubscription) {
        final blocks = _splitVevents(response.body);
        eventRawData = blocks.map((b) => {'ics': b, 'href': ''}).toList();
      } else {
        eventRawData = _extractIcsAndHrefFromXml(response.body);
      }

      final List<Map<String, dynamic>> parsedEvents = eventRawData.map((item) {
        final icsString = item['ics']!;
        final parsed = IcsParser.parse(item['ics']!, item['href']!);
        if (parsed.isEmpty) return null;

        final String parsedUid = (parsed['uid'] ?? '').toString();
        if (parsedUid.isEmpty) return null;

        final String resolvedEtag = (item['etag']?.isNotEmpty == true)
            ? item['etag']!
            : _buildUnknownPendingEtag(
                href: item['href'],
                uid: parsedUid,
              );

        return {
          // Canonical event keys shared by subscription and normal remote events.
          'uid': parsedUid,
          'dtstart': parsed['dtstart'],
          'dtend': parsed['dtend'],

          // Backward-compatible aliases for existing sync pipeline consumers.
          'remote_uid': parsedUid,
          'start': parsed['dtstart'],
          'end': parsed['dtend'],

          'summary': parsed['summary'],
          'href': isSubscription ? '$calendarPath$parsedUid.ics' : item['href'],
          // Some CalDAV servers omit ETag. Mark as unknown/pending with a
          // volatile token so sync planner treats it as remoteChanged.
          'etag': resolvedEtag,
          'calendar_data': icsString,
        };
      }).whereType<Map<String, dynamic>>().toList();

      return UnifiedEventsSnapshot(
        events: parsedEvents,
        statusCode: statusCode,
        fetchSucceeded: true,
        parseProducedZeroEvents: parsedEvents.isEmpty,
      );
    } catch (e) {
      debugPrint("[ERROR] Sync exception: $e");
      return UnifiedEventsSnapshot(
        events: const [],
        statusCode: null,
        fetchSucceeded: false,
        parseProducedZeroEvents: false,
      );
    }
  }

  Future<List<Map<String, dynamic>>> fetchUnifiedEvents({
    required String calendarPath,
    required bool isSubscription,
  }) async {
    final snapshot = await fetchUnifiedEventsSnapshot(
      calendarPath: calendarPath,
      isSubscription: isSubscription,
    );
    if (snapshot.fetchSucceeded && (snapshot.statusCode == 200 || snapshot.statusCode == 207)) {
      return snapshot.events;
    }
    throw Exception(
        'Failed to fetch unified events. status=${snapshot.statusCode ?? 'null'}, path=$calendarPath, isSubscription=$isSubscription');
  }

  List<Map<String, String>> _extractIcsAndHrefFromXml(String xmlBody) {
    final document = xml.XmlDocument.parse(xmlBody);
    final List<Map<String, String>> results = [];

    // 查找所有 response 节点
    final responses = document.findAllElements('response', namespace: '*');

    for (var response in responses) {
      final href = response.findAllElements('href', namespace: '*').firstOrNull?.innerText;
      final data = response.findAllElements('calendar-data', namespace: '*').firstOrNull?.innerText;
      final etag = response.findAllElements('getetag', namespace: '*').firstOrNull?.innerText;

      if (href != null && data != null && data.isNotEmpty) {
        results.add({'href': href, 'ics': data, 'etag': etag ?? ''});
      }
    }
    return results;
  }

  String _buildUnknownPendingEtag({
    required String? href,
    required String uid,
  }) {
    final int now = DateTime.now().microsecondsSinceEpoch;
    final String stableHint = (href?.trim().isNotEmpty == true) ? href!.trim() : uid;
    return 'pending_etag:$stableHint:$now';
  }

  /// 针对普通日历发送 REPORT 请求
  Future<http.Response> _sendReportRequest(String url, Map<String, String> headers) async {
    // 1. 确保 URL 以斜杠结尾, 否则某些 WebDAV 服务器会返回 501 或 405
    final requestUrl = url.endsWith('/') ? url : '$url/';

    // 2. 构造 REPORT 请求体
    // 注意：确保命名空间和标签没有拼写Error
    final body = '''<?xml version="1.0" encoding="utf-8" ?>
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

    // 3. 必须包含正确的 Content-Type 和 Depth
    // 某些服务器如果没看到 text/xml 会直接 501
    headers['Content-Type'] = 'application/xml; charset=utf-8';
    headers['Depth'] = '1';

    print('DEBUG: Sending REPORT request -> $requestUrl');

    // 4. 使用 http.Request 显式指定 REPORT 方法
    final request = http.Request('REPORT', Uri.parse(requestUrl))
      ..headers.addAll(headers)
      ..body = body;

    final streamedResponse = await http.Client().send(request);
    return await http.Response.fromStream(streamedResponse);
  }

  /// 将包含多个 VEVENT 的大字符串拆分成独立的列表
  List<String> _splitVevents(String fullIcs) {
    final eventRegex = RegExp(r'BEGIN:VEVENT[\s\S]*?END:VEVENT');
    return eventRegex.allMatches(fullIcs).map((m) => m.group(0)!).toList();
  }

  Map<String, String> _getAuthHeaders() {
    final String userId = MMKVUtils.instance.getString(AppConstant.loginNameKey) ?? "";
    final String password = MMKVUtils.instance.getString(AppConstant.appPasswordKey) ?? "";

    // 核心：生成 Base64 字符串
    String basicAuth = 'Basic ' + base64Encode(utf8.encode('$userId:$password'));

    return {
      'Authorization': basicAuth,
      'Content-Type': 'application/xml; charset=utf-8', // 必须加, 否则服务器可能无法解析 REPORT
    };
  }

  /// [MKCALENDAR] 在云端创建一个新的日历
  /// [MKCALENDAR] 修复后的版本
  Future<String?> createRemoteCalendar({
    required String userId,
    required String calendarName,
    required String calendarId,
    required String color, // 格式应为 #RRGGBB 或 #RRGGBBAA
    String origin = 'remote',
    String? originKey,
  }) async {
    final server = _activeServerBase;
    final password = MMKVUtils.instance.getString(AppConstant.appPasswordKey);

    final encodedId = Uri.encodeComponent(calendarId);
    final calendarPath = '/remote.php/dav/calendars/$userId/$encodedId/';
    final uri = Uri.parse('$server$calendarPath');

    final String encodedDescription = _buildOriginDescription(
      origin: origin,
      originKey: originKey,
    );
    final String safeCalendarName = const HtmlEscape(HtmlEscapeMode.element).convert(calendarName);
    final String safeColor = const HtmlEscape(HtmlEscapeMode.element).convert(color);

    // 重点：增加 apple ical 命名空间来存储颜色
    final xmlBody = '''<?xml version="1.0" encoding="utf-8" ?>
<c:mkcalendar xmlns:d="DAV:" 
              xmlns:c="urn:ietf:params:xml:ns:caldav" 
              xmlns:ic="http://apple.com/ns/ical/"
              xmlns:oc="http://owncloud.org/ns">
  <d:set>
    <d:prop>
      <d:displayname>$safeCalendarName</d:displayname>
      <c:calendar-description>$encodedDescription</c:calendar-description>
      <oc:calendar-description>$encodedDescription</oc:calendar-description>
      <ic:calendar-color>$safeColor</ic:calendar-color>
      <c:supported-calendar-component-set>
        <c:comp name="VEVENT" />
      </c:supported-calendar-component-set>
    </d:prop>
  </d:set>
</c:mkcalendar>''';

    final req = http.Request('MKCALENDAR', uri)
      ..headers.addAll({
        'Authorization': _getAuthString(userId, password!),
        'Content-Type': 'application/xml; charset=utf-8',
      })
      ..body = xmlBody;

    try {
      final res = await _client.send(req);

      // 201 Created 是标准成功response
      if (res.statusCode == 201 || res.statusCode == 204) {
        return calendarPath;
      } else {
        final body = await res.stream.bytesToString();
        debugPrint('[Calee] MKCALENDAR Failed: ${res.statusCode} - $body');
        return null;
      }
    } catch (e) {
      debugPrint('[Calee] MKCALENDAR Exception: $e');
      return null;
    }
  }

  String _buildOriginDescription({required String origin, String? originKey}) {
    final String safeOrigin = const HtmlEscape(HtmlEscapeMode.element)
        .convert(origin.trim().isEmpty ? 'remote' : origin.trim().toLowerCase());
    final List<String> rows = ['origin=$safeOrigin'];
    final String? key = originKey?.trim();
    if (key != null && key.isNotEmpty) {
      rows.add('originKey=${const HtmlEscape(HtmlEscapeMode.element).convert(key)}');
    }
    return rows.join('&#10;');
  }


  // 在 CaleeServerService 类中
  Future<String?> uploadEventData({
    required String userId,
    required String calendarPath,
    required String uid,
    required String title,
    DateTime? start,
    DateTime? end,
    String? targetEventPath,
  }) async {
    // 1. 调用工具类生成标准的 ICS 文本
    final icsString = IcsSerializer.toIcs(
      uid: uid,
      summary: title,
      start: start,
      end: end,
    );

    // 2. 调用原有的 putEvent 或 uploadEvent 方法执行底层网络请求
    return await putEvent(
      calendarPath: calendarPath,
      uid: uid,
      icsData: icsString,
      userId: userId,
      targetEventPath: targetEventPath,
    );
  }

  /// [PUT] 上传单events到云端
// 在 CaleeServerService.dart 中
  Future<String?> putEvent({
    required String calendarPath,
    required String uid,
    required String icsData,
    required String userId,
    String? targetEventPath,
  }) async {
    final baseUrl = _activeServerBase;
    final password = MMKVUtils.instance.getString(AppConstant.appPasswordKey);

    // 严谨拼接 URL
    final String cleanPath = calendarPath.endsWith('/')
        ? calendarPath.substring(0, calendarPath.length - 1)
        : calendarPath;
    final String normalizedTargetPath = (targetEventPath ?? '').trim();
    final String eventPath = normalizedTargetPath.isNotEmpty
        ? (normalizedTargetPath.startsWith('/') ? normalizedTargetPath : '/$normalizedTargetPath')
        : '$cleanPath/$uid.ics';
    final fullUrl = "$baseUrl$eventPath";

    try {
      final response = await http.put(
        Uri.parse(fullUrl),
        headers: {
          'Content-Type': 'text/calendar; charset=utf-8',
          'Authorization': 'Basic ${base64Encode(utf8.encode('$userId:$password'))}',
        },
        body: utf8.encode(icsData),
      );

      // 201: Created, 204: No Content (Updated)
      if (response.statusCode == 201 || response.statusCode == 204) {
        String? etag = response.headers['etag']?.replaceAll('"', '');

        // 容错：如果 header 没给 etag, 则认为此时需要后续同步逻辑去补全, 或者返回一个占位符
        return etag ?? "pending_etag";
      } else if (response.statusCode == 412) {
        print("[Calee] PUT precondition failed: ${response.body}");
        return null;
      } else {
        print("[Calee] PUT Failed: ${response.statusCode} - ${response.body}");
        return null;
      }
    } catch (e) {
      print("[Calee] Network Error during PUT: $e");
      return null;
    }
  }

  // 在 CaleeServerService 中检查 getEventDetail 方法
  /// 建议在同步引擎开始时创建一个 client, 结束后 close
  Future<String?> getEventDetail({
    required http.Client client,
    required String eventPath,
    required String authHeader,
  }) async {
    final url = "$_activeServerBase$eventPath";

    try {
      final response = await client.get(
        Uri.parse(url),
        headers: {
          'Authorization': authHeader,
          'User-Agent': 'CaleeSync/1.0',
        },
      ).timeout(const Duration(seconds: 15));

      if (response.statusCode == 200) {
        return response.body;
      } else {
        print('[WARN] Download failed [$eventPath]: ${response.statusCode}');
        return null;
      }
    } catch (e) {
      print('[ERROR] Network exception [$eventPath]: $e');
      return null;
    }
  }

  /// [PUT] 上传事件并返回最新的 ETag
  Future<String?> uploadEvent({
    required String path,      // 这里的 path 应该是完整的文件路径, 如 /remote.php/.../uid.ics
    required String content,   // ics 文本内容
  }) async {
    final String userId = MMKVUtils.instance.getString(AppConstant.loginNameKey) ?? "";
    final String password = MMKVUtils.instance.getString(AppConstant.appPasswordKey) ?? "";
    final baseUrl = _activeServerBase;
    final url = "$baseUrl${path.startsWith('/') ? path : '/$path'}";

    print("[Calee] Preparing to upload event to: $url");

    try {
      final response = await http.put(
        Uri.parse(url),
        headers: {
          'Content-Type': 'text/calendar; charset=utf-8',
          'Authorization': 'Basic ${base64Encode(utf8.encode('$userId:$password'))}',
          // 不使用 'If-None-Match': '*', 因为我们需要支持“更新”现有事件
        },
        body: utf8.encode(content),
      );

      if (response.statusCode == 201 || response.statusCode == 204) {
        // [INFO] 核心：成功后, 云端通常会在 Header 中返回 ETag
        String? etag = response.headers['etag']?.replaceAll('"', '');
        print("[Calee] Upload succeeded, new ETag: $etag");
        return etag;
      } else {
        print("[Calee] Upload failed, status: ${response.statusCode}, response: ${response.body}");
        return null;
      }
    } catch (e) {
      print("[Calee] Upload exception: $e");
      return null;
    }
  }

  // 在 CaleeServerService 类中添加
  Future<bool> deleteEvent({
    required String eventPath,
  }) async {
    final String userId = MMKVUtils.instance.getString(AppConstant.loginNameKey) ?? "";
    final String password = MMKVUtils.instance.getString(AppConstant.appPasswordKey) ?? "";

    // 建议：确保 eventPath 以 / 开头, 避免 URL 拼接Error
    final String cleanPath = eventPath.startsWith('/') ? eventPath : '/$eventPath';
    final url = "$_activeServerBase$cleanPath";

    try {
      final response = await http.delete(
        Uri.parse(url),
        headers: {
          'Authorization': 'Basic ${base64Encode(utf8.encode('$userId:$password'))}',
        },
      );

      print("[INFO] WebDAV Delete Request: $url | Status: ${response.statusCode}");

      // 💡 关键修改：
      // 204: No Content (WebDAV 标准删除成功状态码)
      // 200: OK (某些服务器实现的成功码)
      // 404: Not Found (云端已不存在, 同步视为完成, 允许本地清理)
      return response.statusCode == 204 ||
          response.statusCode == 200 ||
          response.statusCode == 404;

    } catch (e) {
      print("[ERROR] WebDAV Delete Error: $e");
      return false; // Network exception或其他Error导致删除动作未确认, 保持本地状态供下次重试
    }
  }

  /// [DELETE] 删除云端日历
  Future<bool> deleteRemoteCalendar({
    required String userId,
    required String calendarPath,
  }) async {
    final server = _activeServerBase;
    final password = MMKVUtils.instance.getString(AppConstant.appPasswordKey);

    if (password == null) return false;

    // 拼接优化：确保只有一个斜杠连接
    final String fullUrl = "${server.replaceAll(RegExp(r'/+$'), '')}/${calendarPath.replaceAll(RegExp(r'^/+'), '')}/";
    final uri = Uri.parse(fullUrl);

    debugPrint('[Calee] [INFO] DELETE Calendar: $fullUrl');

    try {
      final response = await _client.delete(
        uri,
        headers: {
          'Authorization': _getAuthString(userId, password),
          'Depth': 'infinity', // 有些服务器删除目录时需要明确 Depth
        },
      ).timeout(const Duration(seconds: 15));

      debugPrint('[Calee] DELETE Status: ${response.statusCode}');

      // 204 No Content 是标准成功response
      // 200 OK 有时也会返回
      // 404 说明云端已无此路径, 视为一致
      if (response.statusCode == 204 || response.statusCode == 200 || response.statusCode == 404) {
        return true;
      }

      debugPrint('[Calee] DELETE failed response body: ${response.body}');
      return false;
    } catch (e) {
      debugPrint('[Calee] DELETE exception: $e');
      return false;
    }
  }

  Future<bool> renameRemoteCalendar({
    required String userId,
    required String calendarPath,
    required String newName,
  }) async {
    final server = _activeServerBase;
    final password = MMKVUtils.instance.getString(AppConstant.appPasswordKey);
    final uri = Uri.parse('$server$calendarPath');

    // 使用 PROPPATCH 修改 displayname
    final xmlBody = '''<?xml version="1.0" encoding="utf-8" ?>
<d:propertyupdate xmlns:d="DAV:">
  <d:set>
    <d:prop>
      <d:displayname>$newName</d:displayname>
    </d:prop>
  </d:set>
</d:propertyupdate>''';

    final req = http.Request('PROPPATCH', uri)
      ..headers.addAll({
        'Authorization': _getAuthString(userId, password!),
        'Content-Type': 'application/xml; charset=utf-8',
      })
      ..body = xmlBody;

    final res = await _client.send(req);
    return res.statusCode == 207; // Multi-Status
  }

  /// 从 ICS 文本中提取日历名称
  Future<String?> getIcsNameFromUrl(String url) async {
    try {
      final response = await http.get(Uri.parse(url)).timeout(const Duration(seconds: 10));

      if (response.statusCode == 200) {
        final text = response.body;

        // 使用正则匹配 X-WR-CALNAME: 之后的内容
        // 支持多种换行符 (\r?\n)
        final regExp = RegExp(r'X-WR-CALNAME:(.*)', caseSensitive: false);
        final match = regExp.firstMatch(text);

        if (match != null && match.groupCount >= 1) {
          String name = match.group(1)!.trim();
          // 过滤掉一些可能存在的特殊字符
          return name.replaceAll('\r', '').replaceAll('\n', '');
        }
      }
    } catch (e) {
      print("[WARN] Failed to fetch ICS name: $e");
    }
    return null;
  }

  /// [MKCOL] 在云端创建一个「Subscribed calendar集合」
  Future<String?> subscribeRemotePublicIcs({
    required String userId,
    required String calendarName,
    required String calendarId, // 这里的 ID 建议用 sub_时间戳
    required String icsUrl,     // 外部公共 ICS 链接
  }) async {
    final server = _activeServerBase;
    final password = MMKVUtils.instance.getString(AppConstant.appPasswordKey);

    // 1. 构建云端路径
    final calendarPath = '/remote.php/dav/calendars/$userId/$calendarId/';
    final uri = Uri.parse('$server$calendarPath');

    // 2. 使用 MKCOL 创建订阅集合
    // 关键点：
    // - resourcetype 包含 cs:subscribed
    // - 远程链接写入 cs:source
    // 这样在 Calee Web UI 中会被识别为Subscribed calendar（只读但允许重命名）
    final xmlBody = '''<?xml version="1.0" encoding="utf-8" ?>
<d:mkcol xmlns:d="DAV:" 
         xmlns:c="urn:ietf:params:xml:ns:caldav"
         xmlns:cs="http://calendarserver.org/ns/">
  <d:set>
    <d:prop>
      <d:resourcetype>
        <d:collection />
        <c:calendar />
        <cs:subscribed />
      </d:resourcetype>
      <d:displayname>$calendarName</d:displayname>
      <cs:source>
        <d:href>$icsUrl</d:href>
      </cs:source>
      <c:supported-calendar-component-set>
        <c:comp name="VEVENT" />
      </c:supported-calendar-component-set>
    </d:prop>
  </d:set>
</d:mkcol>''';

    final req = http.Request('MKCOL', uri)
      ..headers.addAll({
        'Authorization': _getAuthString(userId, password!),
        'Content-Type': 'application/xml; charset=utf-8',
      })
      ..body = xmlBody;

    try {
      final res = await _client.send(req);
      debugPrint('[Calee] Subscription Status: ${res.statusCode}');

      if (res.statusCode == 201) {
        return calendarPath;
      } else {
        final body = await res.stream.bytesToString();
        debugPrint('[Calee] Subscription Failed Body: $body');
        return null;
      }
    } catch (e) {
      debugPrint('[Calee] Subscription Exception: $e');
      return null;
    }
  }

  String _normalizeServer(String base) {
    base = base.trim();
    if (base.endsWith('/')) base = base.substring(0, base.length - 1);
    if (base.startsWith('http://') || base.startsWith('https://')) return base;
    return 'https://$base';
  }

  String _getAuthString(String user, String pass) =>
      'Basic ${base64Encode(utf8.encode('$user:$pass'))}';


  static bool _isTruthySubscriptionValue(String? value) {
    final String normalized = (value ?? '').trim().toLowerCase();
    return normalized == '1' || normalized == 'true' || normalized == 'yes';
  }

  static String? canonicalizeSubscriptionUrl(String? rawUrl) {
    final String trimmed = (rawUrl ?? '').trim();
    if (trimmed.isEmpty) return null;

    final Uri? parsed = Uri.tryParse(trimmed);
    if (parsed == null || parsed.host.isEmpty) {
      return trimmed;
    }

    final String normalizedScheme = parsed.scheme.toLowerCase() == 'webcal'
        ? 'https'
        : parsed.scheme.toLowerCase();
    final int? normalizedPort = (parsed.hasPort &&
            !((normalizedScheme == 'http' && parsed.port == 80) ||
                (normalizedScheme == 'https' && parsed.port == 443)))
        ? parsed.port
        : null;

    final String normalizedPath = (parsed.path.length > 1 && parsed.path.endsWith('/'))
        ? parsed.path.substring(0, parsed.path.length - 1)
        : parsed.path;

    final Uri canonical = parsed.replace(
      scheme: normalizedScheme,
      host: parsed.host.toLowerCase(),
      port: normalizedPort,
      path: normalizedPath,
      fragment: null,
    );

    return canonical.toString();
  }

  static String normalizeRemotePath(String input) {
    final String trimmed = input.trim();
    if (trimmed.isEmpty) return '';
    final Uri? uri = Uri.tryParse(trimmed);
    if (uri == null) return _ensureTrailingSlash(trimmed);
    final String path = uri.path.isNotEmpty ? uri.path : trimmed;
    return _ensureTrailingSlash(path);
  }

  static String _ensureTrailingSlash(String path) {
    if (path.isEmpty) return '';
    return path.endsWith('/') ? path : '$path/';
  }


}

class UnifiedEventsSnapshot {
  final List<Map<String, dynamic>> events;
  final int? statusCode;
  final bool fetchSucceeded;
  final bool parseProducedZeroEvents;

  const UnifiedEventsSnapshot({
    required this.events,
    required this.statusCode,
    required this.fetchSucceeded,
    required this.parseProducedZeroEvents,
  });
}

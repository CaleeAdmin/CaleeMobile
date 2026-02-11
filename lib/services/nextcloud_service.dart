import 'dart:convert';
import 'dart:developer';
import 'package:flutter/cupertino.dart';
import 'package:http/http.dart' as http;
import 'package:xml/xml.dart' as xml;

import '../common/app_constant.dart';
import '../common/utils/IcsSerializer.dart';
import '../common/utils/mmkv_utils.dart';
import '../data/database_helper.dart';
import 'nextcloud_auth_service.dart';

class NextcloudService {
  final http.Client _client = http.Client();
  final DatabaseHelper _dbHelper = DatabaseHelper.instance;

  /// 1. 获取并解析云端日历 (对应 calendar_map)
  Future<List<Map<String, dynamic>>> scanRemoteCalendars({
    required String serverUrl, // 假设传入的是 "https://nc-dev.ywpl.com.au"
    required String userId,    // 假设传入的是 "yiwen"
  }) async {
    // 1. 构建 URI：确保路径与 curl 保持一致
    // 注意：如果 serverUrl 已经包含路径，需根据实际情况调整拼接逻辑
    final uri = Uri.parse('$serverUrl/remote.php/dav/calendars/${Uri.encodeComponent(userId)}/');

    final String password = MMKVUtils.instance.getString(AppConstant.password) ?? "";

    // 2. 结合 curl 调整 XML Body
    // 增加了 nc:subscribe 并保留了你需要的 calendar-color 等信息
    final xmlBody = '''<?xml version="1.0" encoding="utf-8" ?>
    <d:propfind xmlns:d="DAV:" xmlns:cal="urn:ietf:params:xml:ns:caldav" xmlns:nc="http://nextcloud.org/ns" xmlns:oc="http://owncloud.org/ns">
      <d:prop>
        <d:displayname />
        <d:resourcetype />
        <d:current-user-privilege-set />
        <nc:calendar-color /> 
        <nc:subscribe />
        <cal:supported-calendar-component-set />
        <cs:getctag xmlns:cs="http://calendarserver.org/ns/" />
      </d:prop>
    </d:propfind>''';

    // 3. 发送请求
    final request = http.Request('PROPFIND', uri)
      ..headers.addAll({
        'Authorization': 'Basic ${base64Encode(utf8.encode('$userId:$password'))}',
        'Depth': '1',
        'Content-Type': 'application/xml; charset=utf-8',
      })
      ..body = xmlBody;

    final res = await _client.send(request);
    final respBody = await res.stream.bytesToString();

    // 4. 状态码校验 (WebDAV PROPFIND 成功通常返回 207 Multi-Status)
    if (res.statusCode != 207) {
      throw StateError('PROPFIND failed: ${res.statusCode} - $respBody');
    }
    final List<Map<String, dynamic>> results = _parseCalendarXmlToMap(respBody);
    persistRemoteCalendars(results,userId);
    return results;
  }

  List<Map<String, dynamic>> _parseCalendarXmlToMap(String xmlString) {
    final List<Map<String, dynamic>> results = [];
    final document = xml.XmlDocument.parse(xmlString);

    for (var response in document.findAllElements('d:response')) {
      final href = response.findElements('d:href').firstOrNull?.innerText;
      final prop = response.findAllElements('d:prop').firstOrNull;

      if (prop == null || href == null) continue;
      if (_isDeleted(prop) || _isSpecialFolder(href)) continue;

      final resourceType = prop.findElements('d:resourcetype').firstOrNull;
      final isCalendar = resourceType?.findElements('cal:calendar').isNotEmpty ?? false;
      if (!isCalendar) continue;

      // --- 核心字段提取 ---
      final displayName = prop.findElements('d:displayname').firstOrNull?.innerText;
      final ctag = prop.findAllElements('cs:getctag').firstOrNull?.innerText;
      final color = prop.findElements('nc:calendar-color').firstOrNull?.innerText;

      // --- 权限与模式逻辑 ---

      // 1. 检查是否为订阅日历 (Nextcloud 字段)
      final isSubscribed = prop.findElements('nc:subscribe').firstOrNull?.innerText == "1";

      // 2. 检查是否有写权限 (WebDAV 标准字段)
      final privileges = prop.findElements('d:current-user-privilege-set').firstOrNull;
      bool hasWritePrivilege = privileges?.findAllElements('d:write').isNotEmpty ?? false;

      // 3. 统一 sync_mode 逻辑:
      // 如果是订阅日历，或者是没有写权限，则设为只读 (1)
      // 否则设为双向同步 (0)
      int syncMode = (isSubscribed || !hasWritePrivilege) ? 1 : 0;

      results.add({
        'remote_path': href,
        'display_name': displayName ?? "未命名日历",
        'last_ctag': ctag ?? "",
        'sync_mode': syncMode,
        'color': color,
      });
    }
    return results;
  }

  Future<void> persistRemoteCalendars(List<Map<String, dynamic>> remoteMaps, String accountName) async {
    final db = await _dbHelper.database;

    await db.transaction((txn) async {
      for (var map in remoteMaps) {
        // 使用 INSERT OR IGNORE 或手动检查是否存在
        // 这里的策略是：如果路径已存在，更新关键元数据；如果不存在，插入新行
        await txn.rawInsert('''
        INSERT INTO calendar_map (
          remote_path,
          display_name,
          last_ctag,
          sync_mode,
          color,
          account_name,
          origin,
          is_enabled,
          is_provisioned
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
        ON CONFLICT(remote_path) DO UPDATE SET
          display_name = excluded.display_name,
          last_ctag = excluded.last_ctag,
          sync_mode = excluded.sync_mode,
          -- 只有当远端传了新颜色时才更新，否则保留旧的
          color = CASE WHEN excluded.color IS NOT NULL THEN excluded.color ELSE calendar_map.color END
      ''', [
          map['remote_path'],
          map['display_name'],
          map['last_ctag'],
          map['sync_mode'],
          map['color'], // 注意：如果是 #AARRGGBB 格式，请确保 Nextcloud 传回来的格式一致
          accountName,
          1,
          0,
          0
        ]);
      }
    });
  }

  /// 2. 获取并解析云端条目 (对应 sync_map)
  /// 批量获取日历中的所有事件
  /// 批量获取日历中的所有事件 (严格参考你的旧分支实现
  Future<List<Map<String, dynamic>>> fetchRemoteEvents({
    required String calendarPath,
  }) async {
    final String userId = MMKVUtils.instance.getString(AppConstant.loginName) ?? "";
    final String password = MMKVUtils.instance.getString(AppConstant.password) ?? "";
    final url = "https://nc-dev.ywpl.com.au$calendarPath";
    print('🌐 发起请求: $url');

    try {
      final request = http.Request('PROPFIND', Uri.parse(url));
      request.headers.addAll({
        'Authorization': 'Basic ${base64Encode(utf8.encode('$userId:$password'))}',
        'Depth': '1',
        'Content-Type': 'application/xml; charset=utf-8',
        'User-Agent': 'curl/7.81.0', // 伪装成 curl，防止服务器对移动端有限制
      });

      request.body = '<?xml version="1.0" encoding="utf-8" ?><d:propfind xmlns:d="DAV:"><d:prop><d:getetag /></d:prop></d:propfind>';

      final client = http.Client();
      final streamedResponse = await client.send(request);
      final response = await http.Response.fromStream(streamedResponse);

      print('📡 响应状态码: ${response.statusCode}');

      if (response.statusCode == 207) {
        // ⚠️ 这一行是关键，请在日志中确认是否看到了 <d:href>
        print('📄 原始响应内容前500字: ${response.body.length > 500 ? response.body.substring(0, 500) : response.body}');

        final document = xml.XmlDocument.parse(response.body);
        final List<Map<String, dynamic>> events = [];

        // 彻底放弃 namespace 匹配，使用这种最原始的方式查找所有 response
        final responses = document.descendants
            .whereType<xml.XmlElement>()
            .where((node) => node.name.local == 'response');

        for (var responseNode in responses) {
          // 查找 href
          final hrefNode = responseNode.descendants
              .whereType<xml.XmlElement>()
              .where((node) => node.name.local == 'href')
              .firstOrNull;

          final href = hrefNode?.innerText ?? '';

          // 查找 status
          final statusNode = responseNode.descendants
              .whereType<xml.XmlElement>()
              .where((node) => node.name.local == 'status')
              .firstOrNull;

          final status = statusNode?.innerText ?? '';

          if (href.endsWith('.ics') && status.contains('200')) {
            final etagNode = responseNode.descendants
                .whereType<xml.XmlElement>()
                .where((node) => node.name.local == 'getetag')
                .firstOrNull;

            final etag = etagNode?.innerText.replaceAll('&quot;', '').replaceAll('"', '') ?? '';

            events.add({
              'href': href,
              'etag': etag,
            });
          }
        }

        print('✨ 最终拉取到: ${events.length} 个事件');
        return events;
      }
    } catch (e) {
      print('❌ 严重错误: $e');
    }
    return [];
  }

  /// [MKCALENDAR] 在云端创建一个新的日历
  /// [MKCALENDAR] 修复后的版本
  Future<String?> createRemoteCalendar({
    required String userId,
    required String calendarName,
    required String calendarId,
    required String color, // 格式应为 #RRGGBB 或 #RRGGBBAA
  }) async {
    final server = _normalizeServer(AppConstant.nextcloudServer);
    final password = MMKVUtils.instance.getString(AppConstant.password);

    final encodedId = Uri.encodeComponent(calendarId);
    final calendarPath = '/remote.php/dav/calendars/$userId/$encodedId/';
    final uri = Uri.parse('$server$calendarPath');

    // 重点：增加 apple ical 命名空间来存储颜色
    final xmlBody = '''<?xml version="1.0" encoding="utf-8" ?>
<c:mkcalendar xmlns:d="DAV:" 
              xmlns:c="urn:ietf:params:xml:ns:caldav" 
              xmlns:ic="http://apple.com/ns/ical/">
  <d:set>
    <d:prop>
      <d:displayname>$calendarName</d:displayname>
      <ic:calendar-color>$color</ic:calendar-color>
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

      // 201 Created 是标准成功响应
      if (res.statusCode == 201 || res.statusCode == 204) {
        return calendarPath;
      } else {
        final body = await res.stream.bytesToString();
        debugPrint('[Nextcloud] MKCALENDAR Failed: ${res.statusCode} - $body');
        return null;
      }
    } catch (e) {
      debugPrint('[Nextcloud] MKCALENDAR Exception: $e');
      return null;
    }
  }


  // 在 NextcloudService 类中
  Future<String?> uploadEventData({
    required String userId,
    required String calendarPath,
    required String uid,
    required String title,
    DateTime? start,
    DateTime? end,
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
    );
  }

  /// [PUT] 上传单个事件到云端
// 在 NextcloudService.dart 中
  Future<String?> putEvent({
    required String calendarPath,
    required String uid,
    required String icsData,
    required String userId,
  }) async {
    final baseUrl = "https://nc-dev.ywpl.com.au";
    final password = MMKVUtils.instance.getString(AppConstant.password);

    // 严谨拼接 URL
    final String cleanPath = calendarPath.endsWith('/')
        ? calendarPath.substring(0, calendarPath.length - 1)
        : calendarPath;
    final fullUrl = "$baseUrl$cleanPath/$uid.ics";

    try {
      final response = await http.put(
        Uri.parse(fullUrl),
        headers: {
          'Content-Type': 'text/calendar; charset=utf-8',
          'Authorization': 'Basic ${base64Encode(utf8.encode('$userId:$password'))}',
          'If-None-Match': '*',
        },
        body: utf8.encode(icsData),
      );

      // 201: Created, 204: No Content (Updated)
      if (response.statusCode == 201 || response.statusCode == 204) {
        String? etag = response.headers['etag']?.replaceAll('"', '');

        // 容错：如果 header 没给 etag，则认为此时需要后续同步逻辑去补全，或者返回一个占位符
        return etag ?? "pending_etag";
      } else if (response.statusCode == 412) {
        // 冲突：云端已存在。对于场景 1，这通常意味着该日程之前已经上传成功了
        print("[Nextcloud] Event already exists, skipping upload.");
        return "exists";
      } else {
        print("[Nextcloud] PUT Failed: ${response.statusCode} - ${response.body}");
        return null;
      }
    } catch (e) {
      print("[Nextcloud] Network Error during PUT: $e");
      return null;
    }
  }

  // 在 NextcloudService 中检查 getEventDetail 方法
  Future<String?> getEventDetail({required String eventPath}) async {
    // 注意：href 已经是 /remote.php/dav... 开头的完整路径了
    // 不要重复拼接！
    final String userId = MMKVUtils.instance.getString(AppConstant.loginName) ?? "";
    final url = "https://nc-dev.ywpl.com.au$eventPath";

    final response = await http.get(
      Uri.parse(url),
      headers: {
        'Authorization': _getAuthString(userId, MMKVUtils.instance.getString(AppConstant.password)!),
      },
    );
    return response.statusCode == 200 ? response.body : null;
  }

  /// [PUT] 上传事件并返回最新的 ETag
  Future<String?> uploadEvent({
    required String path,      // 这里的 path 应该是完整的文件路径，如 /remote.php/.../uid.ics
    required String content,   // ics 文本内容
  }) async {
    final String userId = MMKVUtils.instance.getString(AppConstant.loginName) ?? "";
    final String password = MMKVUtils.instance.getString(AppConstant.password) ?? "";
    final baseUrl = "https://nc-dev.ywpl.com.au";
    final url = "$baseUrl${path.startsWith('/') ? path : '/$path'}";

    print("[Nextcloud] 准备上传事件至: $url");

    try {
      final response = await http.put(
        Uri.parse(url),
        headers: {
          'Content-Type': 'text/calendar; charset=utf-8',
          'Authorization': 'Basic ${base64Encode(utf8.encode('$userId:$password'))}',
          // 不使用 'If-None-Match': '*'，因为我们需要支持“更新”现有事件
        },
        body: utf8.encode(content),
      );

      if (response.statusCode == 201 || response.statusCode == 204) {
        // 🚀 核心：成功后，云端通常会在 Header 中返回 ETag
        String? etag = response.headers['etag']?.replaceAll('"', '');
        print("[Nextcloud] 上传成功，新 ETag: $etag");
        return etag;
      } else {
        print("[Nextcloud] 上传失败，状态码: ${response.statusCode}, 响应: ${response.body}");
        return null;
      }
    } catch (e) {
      print("[Nextcloud] 上传异常: $e");
      return null;
    }
  }

  // 在 NextcloudService 类中添加
  Future<bool> deleteEvent({
    required String eventPath,
  }) async {
    final String userId = MMKVUtils.instance.getString(AppConstant.loginName) ?? "";
    final String password = MMKVUtils.instance.getString(AppConstant.password) ?? "";

    // 建议：确保 eventPath 以 / 开头，避免 URL 拼接错误
    final String cleanPath = eventPath.startsWith('/') ? eventPath : '/$eventPath';
    final url = "https://nc-dev.ywpl.com.au$cleanPath";

    try {
      final response = await http.delete(
        Uri.parse(url),
        headers: {
          'Authorization': 'Basic ${base64Encode(utf8.encode('$userId:$password'))}',
        },
      );

      print("🗑️ WebDAV Delete Request: $url | Status: ${response.statusCode}");

      // 💡 关键修改：
      // 204: No Content (WebDAV 标准删除成功状态码)
      // 200: OK (某些服务器实现的成功码)
      // 404: Not Found (云端已不存在，同步视为完成，允许本地清理)
      return response.statusCode == 204 ||
          response.statusCode == 200 ||
          response.statusCode == 404;

    } catch (e) {
      print("❌ WebDAV Delete Error: $e");
      return false; // 网络异常或其他错误导致删除动作未确认，保持本地状态供下次重试
    }
  }

  /// [DELETE] 删除云端日历
  Future<bool> deleteRemoteCalendar({
    required String userId,
    required String calendarPath, // 数据库存的: /remote.php/dav/calendars/444/personal-back-1769363944/
  }) async {
    // 使用你提供的规范化方法，确保 server 不带末尾斜杠
    final server = _normalizeServer(AppConstant.nextcloudServer);
    final password = MMKVUtils.instance.getString(AppConstant.password);

    // 拼接 URL：server(无斜杠) + calendarPath(以斜杠开头)
    // 结果应该是: https://nc-dev.ywpl.com.au/remote.php/dav/calendars/444/personal-back-1769363944/
    final fullUrl = '$server$calendarPath';
    final uri = Uri.parse(fullUrl);

    debugPrint('[Nextcloud] 🚀 执行 DELETE 请求: $fullUrl');

    final req = http.Request('DELETE', uri)
      ..headers.addAll({
        'Authorization': _getAuthString(userId, password!),
      });

    try {
      final res = await _client.send(req);
      debugPrint('[Nextcloud] DELETE 状态码: ${res.statusCode}');

      // 204: 成功删除, 404: 云端原本就不存在
      return res.statusCode == 204 || res.statusCode == 404;
    } catch (e) {
      debugPrint('[Nextcloud] DELETE 网络异常: $e');
      return false;
    }
  }

  Future<bool> renameRemoteCalendar({
    required String userId,
    required String calendarPath,
    required String newName,
  }) async {
    final server = _normalizeServer(AppConstant.nextcloudServer);
    final password = MMKVUtils.instance.getString(AppConstant.password);
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
      print("⚠️ 抓取 ICS 名称失败: $e");
    }
    return null;
  }

  /// [MKCALENDAR] 在云端订阅一个外部公共 ICS 日历
  Future<String?> subscribeRemotePublicIcs({
    required String userId,
    required String calendarName,
    required String calendarId, // 这里的 ID 建议用 sub_时间戳
    required String icsUrl,     // 外部公共 ICS 链接
  }) async {
    final server = _normalizeServer(AppConstant.nextcloudServer);
    final password = MMKVUtils.instance.getString(AppConstant.password);

    // 1. 构建云端路径
    final calendarPath = '/remote.php/dav/calendars/$userId/$calendarId/';
    final uri = Uri.parse('$server$calendarPath');

    // 2. 构建带 source 的 XML 负载
    // 注意：Nextcloud 识别 <c:source> 来实现远程挂载
    final xmlBody = '''<?xml version="1.0" encoding="utf-8" ?>
<c:mkcalendar xmlns:d="DAV:" xmlns:c="urn:ietf:params:xml:ns:caldav">
  <d:set>
    <d:prop>
      <d:displayname>$calendarName</d:displayname>
      <c:source><d:href>$icsUrl</d:href></c:source>
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
      debugPrint('[Nextcloud] Subscription Status: ${res.statusCode}');

      if (res.statusCode == 201) {
        return calendarPath;
      } else {
        final body = await res.stream.bytesToString();
        debugPrint('[Nextcloud] Subscription Failed Body: $body');
        return null;
      }
    } catch (e) {
      debugPrint('[Nextcloud] Subscription Exception: $e');
      return null;
    }
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

  String _normalizeServer(String base) {
    base = base.trim();
    if (base.endsWith('/')) base = base.substring(0, base.length - 1);
    if (base.startsWith('http://') || base.startsWith('https://')) return base;
    return 'https://$base';
  }

  String _getAuthString(String user, String pass) =>
      'Basic ${base64Encode(utf8.encode('$user:$pass'))}';

}
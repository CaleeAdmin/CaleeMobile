import 'package:flutter/cupertino.dart';

class IcsParser {
  static Map<String, dynamic> parse(String icsString, String fallbackUid) {
    // 1. 处理折叠行（注意：ICS 标准换行可能是 \r\n 或 \n）
    final content = icsString.replaceAll(RegExp(r'\r?\n\s+'), '');

    String extract(String key) {
      // 修正点：增加 ^ 匹配行首, 以及 $ 匹配行尾, multiLine 设为 true
      // 修正点：匹配 key 后面跟着 [冒号] 或 [分号...冒号]
      final reg = RegExp('^$key(?:;[^:]*)?:(.*)\$', multiLine: true, caseSensitive: false);
      final match = reg.firstMatch(content);
      if (match == null) return "";

      return match.group(1)!.trim();
    }

    // 优先取 ICS 内部的 UID, 没有再用传进来的
    final String internalUid = extract('UID');
    final String finalUid = internalUid.isNotEmpty ? internalUid : fallbackUid;

    final startValue = extract('DTSTART');
    final endValue = extract('DTEND');

    final startMillis = _parseIcsDate(startValue);
    final endMillis = _parseIcsDate(endValue);

    if (startMillis == null) {
      debugPrint("[WARN] Parse failed: DTSTART is empty or malformed ($startValue)");
      return {};
    }

    return {
      'uid': finalUid,
      'summary': _decodeIcsText(extract('SUMMARY').isEmpty ? "Untitled event" : extract('SUMMARY')),
      'description': _decodeIcsText(extract('DESCRIPTION')),
      'dtstart': startMillis,
      'dtend': endMillis ?? (startMillis + 3600000),
      'dtstamp': extract('DTSTAMP'), // 建议存一下这个, 同步对比有用
    };
  }

// 辅助方法：处理 ICS 转义字符
  static String _decodeIcsText(String input) {
    return input
        .replaceAll(r'\,', ',')
        .replaceAll(r'\;', ';')
        .replaceAll(r'\n', '\n')
        .replaceAll(r'\\', r'\');
  }

  static int? _parseIcsDate(String dateStr) {
    try {
      if (dateStr.isEmpty) return null;

      // 过滤掉非数字字符, 只保留数字和 T
      final compact = dateStr.replaceAll(RegExp(r'[^0-9T]'), '');
      if (compact.length < 8) return null;

      final year = int.parse(compact.substring(0, 4));
      final month = int.parse(compact.substring(4, 6));
      final day = int.parse(compact.substring(6, 8));

      int hour = 0, minute = 0, second = 0;

      // 处理带具体时间的格式 20260114T103000
      if (compact.contains('T') && compact.length >= 15) {
        hour = int.parse(compact.substring(9, 11));
        minute = int.parse(compact.substring(11, 13));
        second = int.parse(compact.substring(13, 15));
      }

      // 🌟 判断时区
      if (dateStr.endsWith('Z')) {
        // UTC 时间
        return DateTime.utc(year, month, day, hour, minute, second).millisecondsSinceEpoch;
      } else {
        // 本地时间
        return DateTime(year, month, day, hour, minute, second).millisecondsSinceEpoch;
      }
    } catch (e) {
      return null;
    }
  }
}
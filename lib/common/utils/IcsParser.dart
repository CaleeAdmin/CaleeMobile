class IcsParser {
  static Map<String, dynamic> parse(String icsString, String uid) {
    // 1. 处理折叠行
    final content = icsString.replaceAll(RegExp(r'\r\n\s+'), '');

    String extract(String key) {
      final reg = RegExp('$key[:;](.*)', caseSensitive: false);
      final match = reg.firstMatch(content);
      if (match == null) return "";
      String val = match.group(1)!;
      // 如果包含冒号（比如 TZID 后的冒号），只取冒号后的部分
      return val.contains(':') ? val.split(':').last.trim() : val.trim();
    }

    final startMillis = _parseIcsDate(extract('DTSTART'));
    final endMillis = _parseIcsDate(extract('DTEND'));

    // 🌟 如果解析不出开始时间，直接抛弃这条数据，不返回 DateTime.now()!
    if (startMillis == null) return {};

    return {
      'uid': uid,
      'summary': extract('SUMMARY').isEmpty ? "无标题事件" : extract('SUMMARY'),
      'description': extract('DESCRIPTION').replaceAll('\\n', '\n'),
      'dtstart': startMillis,
      'dtend': endMillis ?? (startMillis + 3600000), // 结束时间默认加1小时
    };
  }

  static int? _parseIcsDate(String dateStr) {
    try {
      if (dateStr.isEmpty) return null;

      // 过滤掉非数字字符，只保留数字和 T
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
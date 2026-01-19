class IcsParser {
  static Map<String, dynamic> parse(String icsString, String uid) {
    // 1. 处理折叠行（很重要：防止长标题被截断）
    final content = icsString.replaceAll(RegExp(r'\r\n\s+'), '');

    String extract(String key) {
      // 增加 ? 允许匹配为空，增加非空保护
      final reg = RegExp('$key:(.*)', caseSensitive: false);
      final match = reg.firstMatch(content);
      return match != null ? match.group(1)!.trim() : "";
    }

    return {
      'uid': uid,
      'summary': extract('SUMMARY').isEmpty ? "无标题事件" : extract('SUMMARY'),
      'description': extract('DESCRIPTION').replaceAll('\\n', '\n'),
      'dtstart': _parseIcsDate(extract('DTSTART')) ?? DateTime.now().millisecondsSinceEpoch,
      'dtend': _parseIcsDate(extract('DTEND')) ?? (DateTime.now().millisecondsSinceEpoch + 3600000),
    };
  }

  // 确保日期解析不会崩溃
  static int? _parseIcsDate(String dateStr) {
    try {
      if (dateStr.isEmpty) return null;
      final clean = dateStr.replaceAll(RegExp(r'[^0-9T]'), '');
      // 简易解析：20260119T100000Z
      final year = int.parse(clean.substring(0, 4));
      final month = int.parse(clean.substring(4, 6));
      final day = int.parse(clean.substring(6, 8));
      return DateTime(year, month, day).millisecondsSinceEpoch;
    } catch (e) {
      return null;
    }
  }
}
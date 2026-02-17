import 'package:intl/intl.dart';

class IcsGenerator {
  /// 将数据库中的 map 转换为标准的 iCalendar (.ics) 字符串
  static String generate(Map<String, dynamic> local) {
    final String uid = local['uid'] ?? '';
    final String summary = _escapeText(local['summary'] ?? '无标题');
    final String description = _escapeText(local['description'] ?? '');

    // 处理时间戳 (毫秒转为 UTC 格式: YYYYMMDDTHHMMSSZ)
    final String dtStart = _formatTimestamp(local['dtstart']);
    final String dtEnd = _formatTimestamp(local['dtend']);
    final String stamp = _formatTimestamp(DateTime.now().millisecondsSinceEpoch);

    // 构建 VEVENT 协议体
    final buffer = StringBuffer();
    buffer.writeln('BEGIN:VCALENDAR');
    buffer.writeln('VERSION:2.0');
    buffer.writeln('PRODID:-//My Calee Pty Ltd//CaleeSync//EN');
    buffer.writeln('BEGIN:VEVENT');
    buffer.writeln('UID:$uid');
    buffer.writeln('DTSTAMP:$stamp');
    buffer.writeln('DTSTART:$dtStart');
    buffer.writeln('DTEND:$dtEnd');
    buffer.writeln('SUMMARY:$summary');
    if (description.isNotEmpty) {
      buffer.writeln('DESCRIPTION:$description');
    }
    buffer.writeln('END:VEVENT');
    buffer.writeln('END:VCALENDAR');

    return buffer.toString();
  }

  /// 格式化时间戳为 iCal 要求的 UTC 格式
  static String _formatTimestamp(dynamic ms) {
    if (ms == null) return DateFormat("yyyyMMdd'T'HHmmss'Z'").format(DateTime.now().toUtc());
    final DateTime dt = DateTime.fromMillisecondsSinceEpoch(ms as int, isUtc: false).toUtc();
    return DateFormat("yyyyMMdd'T'HHmmss'Z'").format(dt);
  }

  /// 字符转义，防止特殊字符破坏 ICS 结构
  static String _escapeText(String text) {
    return text
        .replaceAll('\\', '\\\\')
        .replaceAll(';', '\\;')
        .replaceAll(',', '\\,')
        .replaceAll('\n', '\\n');
  }
}

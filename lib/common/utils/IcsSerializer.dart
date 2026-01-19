import 'package:intl/intl.dart';

class IcsSerializer {
  static String toIcs({
    required String uid,
    required String summary,
    String? description, // 👈 确保定义了这一行
    DateTime? start,
    DateTime? end,
  }) {
    final now = DateTime.now().toUtc();
    final dtStart = start ?? now;
    final dtEnd = end ?? dtStart.add(const Duration(hours: 1));

    String format(DateTime dt) {
      return DateFormat("yyyyMMdd'T'HHmmss'Z'").format(dt.toUtc());
    }

    final StringBuffer sb = StringBuffer();
    sb.write("BEGIN:VCALENDAR\r\n");
    sb.write("VERSION:2.0\r\n");
    sb.write("PRODID:-//CaleeSync//NONSGML v1.0//EN\r\n");
    sb.write("BEGIN:VEVENT\r\n");
    sb.write("UID:$uid\r\n");
    sb.write("DTSTAMP:${format(now)}\r\n");
    sb.write("DTSTART:${format(dtStart)}\r\n");
    sb.write("DTEND:${format(dtEnd)}\r\n");
    sb.write("SUMMARY:$summary\r\n");

    // 👈 如果有描述，则写入 ICS
    if (description != null && description.isNotEmpty) {
      // 处理换行符，ICS 要求描述中的换行要转义为 \n
      String safeDesc = description.replaceAll('\n', '\\n');
      sb.write("DESCRIPTION:$safeDesc\r\n");
    }

    sb.write("SEQUENCE:0\r\n");
    sb.write("TRANSP:OPAQUE\r\n");
    sb.write("END:VEVENT\r\n");
    sb.write("END:VCALENDAR\r\n");

    return sb.toString();
  }
}
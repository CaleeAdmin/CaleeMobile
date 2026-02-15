import 'package:flutter/cupertino.dart';

class Timeutils {

  static int parseToMillis(dynamic date) {
    if (date == null) {
      return DateTime.now().millisecondsSinceEpoch;
    }

    try {
      if (date is String) {
        // DateTime.parse 支持 ISO 8601 格式
        // 注意：如果字符串不含时区信息，Dart 会视其为本地时间
        return DateTime.parse(date).millisecondsSinceEpoch;
      }

      if (date is DateTime) {
        return date.millisecondsSinceEpoch;
      }

      if (date is int) {
        return date; // 已经是毫秒了
      }
    } catch (e) {
      debugPrint("⚠️ 时间解析失败: $date, error: $e");
    }

    return DateTime.now().millisecondsSinceEpoch;
  }
}
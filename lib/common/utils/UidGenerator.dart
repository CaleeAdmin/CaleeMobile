import 'package:uuid/uuid.dart';

class CaleeUid {
  static const _uuid = Uuid();

  /// 生成符合 CalDAV 标准的 UUID
  /// 例如: AE6C35CC-3203-44D8-A56C-973D48D7E289
  static String generate() {
    return _uuid.v4().toUpperCase();
  }
}
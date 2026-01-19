import 'package:pigeon/pigeon.dart'; // 必须是这个路径
/// 配置 Pigeon 生成代码的路径
@ConfigurePigeon(PigeonOptions(
  dartOut: 'lib/core/platform/pigeon/calendar_api.g.dart',
  dartOptions: DartOptions(),
  kotlinOut: 'android/app/src/main/kotlin/com/nextcloud/caleesync/CalendarApi.g.kt',
  kotlinOptions: KotlinOptions(
    package: 'com.nextcloud.caleesync',
  ),
  swiftOut: 'ios/Runner/CalendarApi.g.swift',
  swiftOptions: SwiftOptions(),
))

class PlatformCalendar {
  String? id;              // 系统原生 ID
  String? name;            // 名称
  String? accountName;     // 账号名 (如 "test@gmail.com" 或 "iCloud")
  String? accountType;     // 账号类型 (如 "com.google" 或 "com.apple.account.icloud")
  String? color;           // ARGB 格式颜色: 0xAARRGGBB
  bool? isReadOnly;        // 是否只读（如节假日日历）
  bool? supportsEvents;    // 是否支持活动 (VEVENT)
  bool? supportsTasks;     // 是否支持任务 (VTODO)
}

class PlatformItem {
  String? localId;
  String? uid;
  String? title;
  String? notes;
  String? location;
  int? startTime;
  int? endTime;
  int? lastModified;
  bool? isTask;
  bool? isAllDay;
  int? status;
  int? priority;
}

/// 定义原生侧必须实现的方法
@HostApi()
abstract class NativeCalendarApi {
  /// 获取日历列表前请求权限
  @async
  bool requestPermission(bool forTask);

  /// 获取所有可同步的日历
  List<PlatformCalendar> getCalendars();

  /// 获取指定日历在时间范围内的所有条目
  /// 注意：Android 上由于系统限制，可能只返回 Event
  List<PlatformItem> getEvents(String calendarId, int startMs, int endMs);

  // 🚀 新增：将云端数据写入本地系统日历
  @async
  String? createEvent(
      String calendarId,
      String title,
      int start,
      int end,
      String? notes,
      String? uid // 传入生成的 UUID
      );

  /// 获取指定日历下所有事件的 ID 列表（用于检测本地删除了哪些）
  List<String> getSystemEventIds(String calendarId);

  /// 根据 ID 删除本地事件（用于同步云端的删除操作）
  bool deleteEvent(String eventId);
}
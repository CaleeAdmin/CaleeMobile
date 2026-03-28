import 'package:pigeon/pigeon.dart'; // 必须是这个路径
/// 配置 Pigeon 生成代码的路径
@ConfigurePigeon(PigeonOptions(
  dartOut: 'lib/core/platform/pigeon/calendar_api.g.dart',
  dartOptions: DartOptions(),
  kotlinOut: 'android/app/src/main/kotlin/com/calee/caleesync/CalendarApi.g.kt',
  kotlinOptions: KotlinOptions(
    package: 'com.calee.caleesync',
  ),
  swiftOut: 'ios/Runner/CalendarApi.g.swift',
  swiftOptions: SwiftOptions(),
))

class PlatformCalendar {
  String? id;              // 系统原生 ID
  String? name;            // 名称
  String? accountName;     // Account name (e.g. "test@gmail.com" or "iCloud")
  String? accountType;     // Account type (e.g. "com.google" or "com.apple.account.icloud")
  String? ownerAccount;    // Native owner account identity
  String? calSync1;        // Native sync key candidate
  String? color;           // ARGB 格式颜色: 0xAARRGGBB
  bool? isReadOnly;        // 是否只读（如节假日日历）
  bool? supportsEvents;    // 是否支持活动 (VEVENT)
  bool? supportsTasks;     // 是否支持任务 (VTODO)
  bool? isSubscription;    // 是否为Subscribed calendar
  String? subscriptionUrl; // 订阅源地址（若系统可提供）
}

class PlatformItem {
  String? localId;
  String? uid;
  String? title;
  String? notes;
  String? location;
  String? eventTimezone;
  int? startTime;
  int? endTime;
  int? lastModified;
  bool? isTask;
  bool? isAllDay;
  int? status;
  int? priority;
}

class CalendarEventRequest {
  // 确保这里的定义符合你的业务需求
  String calendarId;
  String title;
  int start;
  int end;
  String? notes;
  String uid;
  String? eventId; // 更新时有值，新建时为 null
  String? eventTimezone;
  String? location;
  bool? isAllDay;

  // Pigeon 会根据这个类生成 Dart 端对应的构造函数
  CalendarEventRequest({
    required this.calendarId,
    required this.title,
    required this.start,
    required this.end,
    this.notes,
    required this.uid,
    this.eventId,
    this.eventTimezone,
    this.location,
    this.isAllDay,
  });
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

  /// 🚀 关键新增：在手机系统里创建一个新的日历账簿
  /// 返回系统分配的数字 ID (String 形式的 Long)
  @async
  String? createCalendar(String displayName, String accountName,int color);

  /// 🚀 关键新增：根据 ID 删除整个日历账簿
  /// Android 上删除日历会自动联级删除该日历下的所有事件 (Events)
  @async
  bool deleteCalendar(String calendarId, String accountName);

  // 🚀 新增：将云端数据写入本地系统日历
  @async
  String? createEvent(
      String calendarId,
      String title,
      int start,
      int end,
      String? notes,
      String? uid, // 传入生成的 UUID
      String? location,
      String? eventTimezone,
      bool? isAllDay,
      );

  @async
  String? createOrUpdateEvent(CalendarEventRequest request);

  /// 获取指定日历下所有事件的 ID 列表（用于检测本地删除了哪些）
  List<String> getSystemEventIds(String calendarId, int startMs, int endMs);

  /// 根据 ID 删除本地事件（用于同步云端的删除操作）
  bool deleteEvent(String eventId);

  @async
  bool modifyCalendarTitle(String calendarId, String newTitle, String accountName, String accountType);

  @async
  bool setCalendarEnabled(String calendarId, String accountName, bool enabled);

  @async
  bool normalizeMirrorCalendarPresentation(String calendarId);

  @async
  bool isCalendarAccountSyncEnabled(String accountName);
}

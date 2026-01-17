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
  List<PlatformItem> getItems(String calendarId, int startMs, int endMs);

  /// 创建或更新条目
  /// 返回写入成功后的系统 localId
  @async
  String upsertItem(String calendarId, PlatformItem item);

  /// 根据 ID 删除条目
  @async
  void deleteItem(String localId);
}
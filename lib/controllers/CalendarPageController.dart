import 'package:caleesync/common/app_constant.dart';
import 'package:caleesync/common/utils/mmkv_utils.dart';
import 'package:caleesync/core/platform/pigeon/calendar_api.g.dart';
import 'package:flutter/cupertino.dart';
import 'package:get/get.dart';
import 'dart:async';

import '../services/calee_auth_service.dart';
import '../sync/SyncEngine.dart';
import '../data/database_helper.dart';
import '../data/sync_repository.dart';
import '../services/calee_server_service.dart';
import 'calendar_probe_controller.dart';

class CalendarDisplayItem {
  // 1. 标识符
  final String? localId;     // Android/iOS 系统日历 ID (对应数据库 local_id)，可能为 null
  final String? remotePath;   // 远程 WebDAV 路径 (作为数据库更新的绝对 Key)，不应为 null

  // 2. 显示内容
  final String name;
  final String color;
  final int eventCount;

  // 3. 状态控制
  final bool isReadOnly;
  final bool isSubscription;
  final bool isLocalReadOnly;
  bool isEnabled;            // 对应数据库 is_enabled
  final int origin;          // 0: 本地创建, 1: 云端同步

  CalendarDisplayItem({
    this.localId,            // 允许为空
    required this.remotePath, // 必须有，否则无法同步
    required this.name,
    required this.color,
    required this.eventCount,
    required this.isReadOnly,
    required this.isSubscription,
    required this.isLocalReadOnly,
    required this.isEnabled,
    required this.origin,
  });

  // 方便从数据库 Map 转换
  factory CalendarDisplayItem.fromMap(Map<String, dynamic> map) {
    return CalendarDisplayItem(
      localId: map['local_id']?.toString(), // 转为 String 处理
      remotePath: map['remote_path'] ?? '',
      name: map['display_name'] ?? '未命名',
      color: map['color'] ?? '#000000',
      eventCount: 0, // 可以在外部查询后再填入
      isReadOnly: false,
      isSubscription: false,
      isLocalReadOnly: false,
      isEnabled: (map['is_enabled'] ?? 0) == 1,
      origin: map['origin'] ?? 0,
    );
  }
}

// 2. Controller 实现
class CalendarPageController extends GetxController {
  // 静态访问器
  static CalendarPageController get to => Get.find();

  // 依赖注入：Repo 必须在 InitialBinding 或 main 中已 put
  final SyncRepository _repo = Get.find<SyncRepository>();
  final CaleeServerService _nc = CaleeServerService();
  final NativeCalendarApi _nativeApi = NativeCalendarApi();
  final engine = SyncEngine();
  final CaleeAuthService _authService = CaleeAuthService(serverBaseUrl: AppConstant.caleeServer);

  // 响应式变量
  var calendars = <CalendarDisplayItem>[].obs;
  var isLoading = false.obs;
  /// 选中的日历 ID 集合（用于 UI 绑定）
  var selectedCalendarIds = <String>{}.obs;
  var subscribingUrls = <String>{}.obs;
  Future<void>? _refreshFuture;

  @override
  void onInit() {
    super.onInit();
    // 页面加载时自动执行一次扫描和数据拉取
    refreshDashboard();
  }

  /// 处理 Checkbox 点击事件
  Future<void> toggleCalendarSelection(CalendarDisplayItem item, bool? newValue) async {
    if (newValue == null) return;

    try {
      // 直接更新当前 item，避免通过 ID 再次查找导致错位
      item.isEnabled = newValue;

      // 如果后面有地方要用到 selectedCalendarIds，这里也同步一下
      final key = (item.remotePath != null && item.remotePath!.isNotEmpty)
          ? item.remotePath!
          : (item.localId ?? '');
      if (key.isNotEmpty) {
        if (newValue) {
          selectedCalendarIds.add(key);
        } else {
          selectedCalendarIds.remove(key);
        }
      }

      // 通知 observers 局部刷新
      calendars.refresh();

      // 持久化到数据库
      await updateEnabledStatus(item, newValue);

    } catch (e) {
      print("❌ 切换日历状态失败: $e");
      Get.snackbar("错误", "无法更新日历同步状态");
      // 回滚本地模型并刷新 UI
      item.isEnabled = !newValue;
      calendars.refresh();
    }
  }

  Future<void> updateEnabledStatus(CalendarDisplayItem item, bool newValue) async {
    final db = await DatabaseHelper.instance.database;

    String whereClause;
    List<dynamic> whereArgs;

    // 1. 优先判断身份：谁有值就用谁查
    if (item.remotePath != null && item.remotePath!.isNotEmpty) {
      // 它是远端日历（即使 localId 为空，路径也是唯一的）
      whereClause = 'remote_path = ?';
      whereArgs = [item.remotePath];
    } else {
      // 它是纯本地日历（一定有系统分配的 ID）
      whereClause = 'local_id = ?';
      whereArgs = [item.localId];
    }

    // 2. 执行更新
    int count = await db.update(
      'calendar_map',
      {'is_enabled': newValue ? 1 : 0},
      where: whereClause,
      whereArgs: whereArgs,
    );

    debugPrint("✅ 更新成功，影响行数: $count (条件: $whereClause = ${whereArgs[0]})");
  }

  /// 核心方法：刷新并重新构建 UI 模型
  Future<void> refreshDashboard({bool includeEventCounts = true}) async {
    if (_refreshFuture != null) {
      return _refreshFuture!;
    }

    _refreshFuture = _refreshDashboardImpl(includeEventCounts: includeEventCounts);
    try {
      await _refreshFuture;
    } finally {
      _refreshFuture = null;
    }
  }

  Future<void> _refreshDashboardImpl({required bool includeEventCounts}) async {
    try {
      isLoading.value = true;
      final String? loginName = MMKVUtils.instance.getString(AppConstant.loginNameKey);
      if (loginName == null) return;

      // 1. 拉取远端 Calee 日历并更新本地映射
      await _nc.scanRemoteCalendars(
          serverUrl: _authService.normalizedUrl,
          userId: loginName);

      // 2. 查询本地 calendar_map 的所有日历记录
      final db = await DatabaseHelper.instance.database;
      final List<Map<String, dynamic>> calendarMaps = await db.query(
        'calendar_map',
      );
      final Map<String, int> cachedCountByCalendarId = {};
      final Map<String, bool> localReadOnlyById = {};
      final List<CalendarDisplayItem> nextCloudCalendars = [];

      try {
        final List<PlatformCalendar?> platformCalendars = await _nativeApi.getCalendars();
        for (final PlatformCalendar calendar in platformCalendars.whereType<PlatformCalendar>()) {
          final String id = calendar.id ?? '';
          if (id.isEmpty) continue;
          localReadOnlyById[id] = calendar.isReadOnly ?? false;
        }
      } catch (e) {
        debugPrint('⚠️ 无法读取本地日历只读信息: $e');
      }

      if (includeEventCounts) {
        final countRows = await db.rawQuery(
          'SELECT calendar_local_id, COUNT(*) AS count FROM sync_map GROUP BY calendar_local_id',
        );
        for (final row in countRows) {
          final String key = (row['calendar_local_id'] ?? '').toString();
          if (key.isEmpty) continue;
          cachedCountByCalendarId[key] = (row['count'] as int?) ?? 0;
        }
      }

      for (var cal in calendarMaps) {
        final String? localId = cal['local_id']?.toString();
        final String? remotePath = cal['remote_path'];
        final int? syncMode = cal['sync_mode'];
        final bool isSubscription = (cal['is_subscription'] == 1 || cal['is_subscription'] == true);
        final int origin = cal['origin'];

        int realCount = 0;
        if (includeEventCounts) {
          final String countKey = (localId != null && localId.isNotEmpty)
              ? localId
              : (remotePath ?? '');
          realCount = cachedCountByCalendarId[countKey] ?? 0;
        }

        // 组装 UI 模型
        var displayItem = CalendarDisplayItem(
          localId: localId,
          name: cal['display_name'] ?? 'Unknown',
          color: cal['color'] ?? '#808080',
          eventCount: realCount,
          isReadOnly: syncMode == 0,
          isSubscription: isSubscription,
          isLocalReadOnly: localReadOnlyById[localId] ?? false,
          isEnabled: cal['is_enabled'] == 1,
          remotePath: remotePath,
          origin: origin,
        );

        nextCloudCalendars.add(displayItem);
      }

      calendars.assignAll(nextCloudCalendars);

    } catch (e) {
      print("❌ Dashboard 刷新异常: $e");
    } finally {
      isLoading.value = false;
    }
  }
  /// 供外部调用的同步接口
  Future<void> syncAll() async {
    // 1. 执行全量同步服务 (处理合并、上传、下载、删除 status 2)
    // await Get.find<SyncService>().executeFullSync();

    // 2. 同步完成后重刷界面
    await refreshDashboard();
  }

  /// 彻底删除一个日历（包含云端、系统日历与本地 DB 清理）
  Future<void> deleteCalendarTotally({String? localId, String? remotePath}) async {
    try {
      final String? resolvedLocalId = (localId != null && localId.isNotEmpty) ? localId : null;
      final String? resolvedRemotePath = (remotePath != null && remotePath.isNotEmpty) ? remotePath : null;
      if (resolvedLocalId == null && resolvedRemotePath == null) return;

      isLoading.value = true;
      await _repo.performAbsoluteDelete(localId: resolvedLocalId, remotePath: resolvedRemotePath);
      await refreshDashboard(includeEventCounts: false);
      unawaited(refreshDashboard());
    } catch (e) {
      print('❌ Dashboard 删除日历失败: $e');
      Get.snackbar('错误', '删除日历失败');
    } finally {
      isLoading.value = false;
    }
  }

  /// 重命名日历（委托给仓库并刷新）
  Future<void> renameCalendar(String? localId, String? remotePath, String newName) async {
    try {
      if ((localId == null || localId.isEmpty) && (remotePath == null || remotePath.isEmpty)) return;
      isLoading.value = true;
      await _repo.renameCalendar(localId: localId, remotePath: remotePath, newName: newName);
      await refreshDashboard(includeEventCounts: false);
      unawaited(refreshDashboard());
    } catch (e) {
      print('❌ Dashboard 重命名失败: $e');
      Get.snackbar('错误', '重命名失败');
      rethrow;
    } finally {
      isLoading.value = false;
    }
  }

  /// 创建新的本地日历（委托给 SyncRepository），并刷新界面
  Future<bool> createNewLocalCalendar(String displayName) async {
    final String? invalidReason = validateNewCalendarName(displayName);
    if (invalidReason != null) {
      Get.snackbar('Invalid calendar name', invalidReason);
      return false;
    }

    try {
      isLoading.value = true;
      final ok = await _repo.createNewLocalCalendar(displayName.trim());
      if (ok) {
        await refreshDashboard(includeEventCounts: false);
        unawaited(refreshDashboard());
        return true;
      } else {
        Get.snackbar('错误', '创建日历失败');
        return false;
      }
    } catch (e) {
      print('❌ 创建本地日历失败: $e');
      Get.snackbar('错误', '创建日历失败');
      return false;
    } finally {
      isLoading.value = false;
    }
  }

  /// 订阅一个公开的 ICS 链接（委托给仓库），并在成功后刷新界面
  Future<bool> subscribePublicIcs(String icsUrl) async {
    final String normalizedUrl = icsUrl.trim();
    final String? invalidReason = validateSubscriptionUrl(normalizedUrl);
    if (invalidReason != null) {
      Get.snackbar('Invalid subscription URL', invalidReason);
      return false;
    }

    if (subscribingUrls.contains(normalizedUrl)) {
      return false;
    }

    subscribingUrls.add(normalizedUrl);

    try {
      isLoading.value = true;
      final ok = await _repo.handlePublicSubscription(normalizedUrl);
      if (ok) {
        await refreshDashboard(includeEventCounts: false);
        unawaited(refreshDashboard());
        // 刷新已订阅列表（如果 probe controller 已注册）
        if (Get.isRegistered<CalendarProbeController>()) {
          await Get.find<CalendarProbeController>().fetchSubscribedCalendars();
        }
        Get.snackbar('Success', 'Subscribed to calendar');
        return true;
      } else {
        Get.snackbar('错误', '订阅失败');
        return false;
      }
    } catch (e) {
      print('❌ 订阅失败: $e');
      Get.snackbar('错误', '订阅失败');
      return false;
    } finally {
      subscribingUrls.remove(normalizedUrl);
      isLoading.value = false;
    }
  }

  String? validateNewCalendarName(String displayName) {
    final String normalized = displayName.trim();
    if (normalized.isEmpty) {
      return 'Calendar name is required.';
    }
    if (normalized.length > 64) {
      return 'Calendar name must be 64 characters or fewer.';
    }
    if (RegExp(r'[\\/:*?"<>|]').hasMatch(normalized)) {
      return 'Calendar name contains unsupported characters.';
    }
    return null;
  }

  String? validateSubscriptionUrl(String icsUrl) {
    final String normalized = icsUrl.trim();
    if (normalized.isEmpty) {
      return 'Subscription URL is required.';
    }

    final Uri? parsed = Uri.tryParse(normalized);
    if (parsed == null || parsed.host.isEmpty) {
      return 'Enter a valid URL.';
    }

    if (parsed.scheme != 'http' && parsed.scheme != 'https' && parsed.scheme != 'webcal') {
      return 'Only http, https, or webcal URLs are supported.';
    }

    return null;
  }

}

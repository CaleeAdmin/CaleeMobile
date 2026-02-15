import 'package:caleesync/common/app_constant.dart';
import 'package:caleesync/common/utils/mmkv_utils.dart';
import 'package:device_calendar/device_calendar.dart';
import 'package:flutter/cupertino.dart';
import 'package:get/get.dart';
import 'package:sqflite/sqflite.dart';
import 'dart:ui';

import '../services/nextcloud_auth_service.dart';
import '../sync/SyncEngine.dart';
import '../data/database_helper.dart';
import '../data/sync_repository.dart';
import '../services/nextcloud_service.dart';
import 'calendar_probe_controller.dart';

// 1. 数据模型定义
class CalendarGroup {
  final String accountName;
  final List<CalendarDisplayItem> calendars;

  CalendarGroup({required this.accountName, required this.calendars});
}

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
  bool isEnabled;            // 对应数据库 is_enabled
  final int origin;          // 0: 本地创建, 1: 云端同步

  CalendarDisplayItem({
    this.localId,            // 允许为空
    required this.remotePath, // 必须有，否则无法同步
    required this.name,
    required this.color,
    required this.eventCount,
    required this.isReadOnly,
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
  final NextcloudService _nc = NextcloudService();
  final engine = SyncEngine();
  final NextcloudAuthService _authService = NextcloudAuthService(serverBaseUrl: AppConstant.nextcloudServer);

  // 响应式变量
  var calendarGroups = <CalendarGroup>[].obs;
  var isLoading = false.obs;
  /// 选中的日历 ID 集合（用于 UI 绑定）
  var selectedCalendarIds = <String>{}.obs;

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
      calendarGroups.refresh();

      // 持久化到数据库
      await updateEnabledStatus(item, newValue);

    } catch (e) {
      print("❌ 切换日历状态失败: $e");
      Get.snackbar("错误", "无法更新日历同步状态");
      // 回滚本地模型并刷新 UI
      item.isEnabled = !newValue;
      calendarGroups.refresh();
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
  Future<void> refreshDashboard() async {
    try {
      isLoading.value = true;
      final String? loginName = MMKVUtils.instance.getString(AppConstant.loginName);
      if (loginName == null) return;

      // 1. 扫描本地系统日历
      await _repo.scanLocalCalendars(loginName);

      // 2. 发现云端新日历
       await _nc.scanRemoteCalendars(
          serverUrl: _authService.normalizedUrl,
          userId: loginName);

      // 2. 获取所有日历记录
      final db = await DatabaseHelper.instance.database;
      final List<Map<String, dynamic>> calendarMaps = await db.query(
        'calendar_map',
        where: 'account_name = ?',
        whereArgs: [loginName],
      );
      final deviceCalendarPlugin = DeviceCalendarPlugin();
      Map<String, List<CalendarDisplayItem>> tempMap = {};

      for (var cal in calendarMaps) {
        final String account = cal['account_type'] ?? 'Unknown';
        final String? localId = cal['local_id']?.toString();
        final String? remotePath = cal['remote_path'];
        final int? syncMode = cal['sync_mode'];
        final int origin = cal['origin'];

        int realCount = 0;

        // --- 🌟 核心修改：针对云端日历的实时计数 ---
        if (remotePath != null && remotePath.isNotEmpty) {
          // A. 先查本地数据库 sync_map
          final localCountResult = await db.rawQuery(
              'SELECT COUNT(*) as count FROM sync_map WHERE calendar_local_id = ?',
              [localId ?? '']);
          realCount = (localCountResult.first['count'] as int?) ?? 0;

          // B. 如果本地计数为 0，说明还没同步过，触发一次“静默拉取”
          if (realCount == 0) {
            print("🌐 [静默拉取] 正在为日历 ${cal['display_name']} 获取云端事件数...");
            try {
              // 仅拉取快照，不涉及复杂的系统日历写入，速度非常快
              final remoteItems = await _nc.fetchUnifiedEvents(calendarPath: remotePath,isSubscription: false);

              // 将云端 UID 存入 sync_map（ local_id 设为 v_ 前缀的影子 ID）
              // 这一步是让 Dashboard 统计生效的关键
              await db.transaction((txn) async {
                for (var item in remoteItems) {
                  String uid = item['uid'] ?? item['href'].split('/').last;
                  // 使用 insert ignore 或 replace 防止重复
                  await txn.insert('sync_map', {
                    'uid': uid,
                    'local_id': 'v_$uid', // 影子 ID，表示未洗白到系统
                    'calendar_local_id': localId ?? remotePath ?? '',
                    'last_etag': item['etag'] ?? '',
                  }, conflictAlgorithm: ConflictAlgorithm.ignore);
                }
              });

              // 重新计算数量
              realCount = remoteItems.length;
            } catch (e) {
              print("❌ 静默拉取失败: $e");
            }
          }
        } else if (localId != null && localId.isNotEmpty) {
          // --- C. 普通本地系统日历统计 ---
          try {
            final now = DateTime.now();
            final eventsResult = await deviceCalendarPlugin.retrieveEvents(
                localId ?? '',
                RetrieveEventsParams(
                    startDate: now.subtract(const Duration(days: 365)),
                    endDate: now.add(const Duration(days: 365))
                )
            );
            if (eventsResult.isSuccess) realCount = eventsResult.data?.length ?? 0;
          } catch (_) {}
        }

        // 组装 UI 模型
        var displayItem = CalendarDisplayItem(
          localId: localId,
          name: cal['display_name'] ?? 'Unknown',
          color: cal['color'] ?? '#808080',
          eventCount: realCount,
          isReadOnly: syncMode == 1,
          isEnabled: cal['is_enabled'] == 1,
          remotePath: remotePath,
          origin: origin,
        );

        tempMap.putIfAbsent(account, () => []).add(displayItem);
      }

      // 排序并更新 UI
      final entries = tempMap.entries.toList();
      entries.sort((a, b) {
        final la = a.key.toLowerCase();
        if (la == 'nextcloud') return -1;
        return 1;
      });

      calendarGroups.assignAll(entries.map((e) => CalendarGroup(accountName: e.key, calendars: e.value)).toList());

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
      await refreshDashboard();
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
      await refreshDashboard();
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
        await refreshDashboard();
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
    final String? invalidReason = validateSubscriptionUrl(icsUrl);
    if (invalidReason != null) {
      Get.snackbar('Invalid subscription URL', invalidReason);
      return false;
    }

    try {
      isLoading.value = true;
      final ok = await _repo.handlePublicSubscription(icsUrl.trim());
      if (ok) {
        await refreshDashboard();
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

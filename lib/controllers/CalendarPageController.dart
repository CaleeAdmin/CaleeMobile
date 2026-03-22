import 'package:caleesync/common/app_constant.dart';
import 'package:caleesync/common/utils/mmkv_utils.dart';
import 'package:caleesync/core/platform/pigeon/calendar_api.g.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart' show Text;
import 'package:get/get.dart';
import 'dart:async';
import 'dart:io';

import '../services/calee_auth_service.dart';
import '../sync/sync_completed_event_bus.dart';
import '../sync/sync_trigger_orchestrator.dart';
import '../data/database_helper.dart';
import '../data/sync_repository.dart';
import '../services/calee_server_service.dart';
import '../sync/SyncEnum.dart';
import 'local_calendar_page_controller.dart';

class CalendarDisplayItem {
  // 1. 标识符
  final String? localId;     // Android/iOS 系统日历 ID (对应数据库 local_id), 可能为 null
  final String? remotePath;   // 远程 WebDAV 路径 (作为数据库更新的绝对 Key), 不应为 null

  // 2. 显示内容
  final String name;
  final String color;
  final int eventCount;

  // 3. 状态控制
  final bool isReadOnly;
  final bool isSubscription;
  final bool isLocalReadOnly;
  final String? subscriptionUrl;
  final String accountName;
  bool isEnabled;            // 对应数据库 collection_states.is_enabled
  final String? syncGateReason;
  final int origin;          // Shared provenance only: where the remote calendar came from, not this-device sync behavior.
  final String? originKey;
  final int bindingId;
  final int bindingRole;     // This-device role: mirror vs ownerLink, and it drives runtime behavior.
  final int remoteCollectionId;
  bool hasRelinkSuggestion;
  bool allowMassDeletionDangerous;

  CalendarDisplayItem({
    this.localId,            // 允许为空
    required this.remotePath, // 必须有, 否则无法同步
    required this.name,
    required this.color,
    required this.eventCount,
    required this.isReadOnly,
    required this.isSubscription,
    required this.isLocalReadOnly,
    this.subscriptionUrl,
    required this.accountName,
    required this.isEnabled,
    this.syncGateReason,
    required this.origin,
    this.originKey,
    required this.bindingId,
    required this.bindingRole,
    required this.remoteCollectionId,
    this.hasRelinkSuggestion = false,
    required this.allowMassDeletionDangerous,
  });

}

// 2. Controller 实现
class CalendarPageController extends GetxController {
  // 静态访问器
  static CalendarPageController get to => Get.find();

  // 依赖注入：Repo 必须在 InitialBinding 或 main 中已 put
  final SyncRepository _repo = Get.find<SyncRepository>();
  final CaleeServerService _nc = CaleeServerService();
  final NativeCalendarApi _nativeApi = NativeCalendarApi();
  final CaleeAuthService _authService = CaleeAuthService(serverBaseUrl: AppConstant.caleeServer);

  // response式变量
  var calendars = <CalendarDisplayItem>[].obs;
  var isLoading = false.obs;
  /// 选中的日历 ID 集合（用于 UI 绑定）
  var selectedCalendarIds = <String>{}.obs;
  var togglingCalendarIds = <String>{}.obs;
  var subscribingUrls = <String>{}.obs;
  StreamSubscription<SyncCompletedEvent>? _syncCompletedSub;

  void _notifyMeaningfulChange() {
    if (Get.isRegistered<SyncTriggerOrchestrator>()) {
      Get.find<SyncTriggerOrchestrator>().notifyMeaningfulForegroundChange();
    }
  }

  @override
  void onInit() {
    super.onInit();
    _syncCompletedSub = SyncCompletedEventBus.stream.listen((_) {
      unawaited(reloadCalendars());
    });
    // 页面加载时自动执行一次扫描和数据拉取
    reloadCalendars();
  }

  @override
  void onClose() {
    _syncCompletedSub?.cancel();
    super.onClose();
  }

  /// 处理 Checkbox 点击事件
  Future<void> handleCalendarEnableToggle(CalendarDisplayItem item, bool? newValue) async {
    if (newValue == null) return;

    final String key = (item.remotePath != null && item.remotePath!.isNotEmpty)
        ? item.remotePath!
        : (item.localId ?? '');

    if (key.isNotEmpty && togglingCalendarIds.contains(key)) {
      return;
    }

    if (key.isNotEmpty) {
      togglingCalendarIds.add(key);
      calendars.refresh();
    }

    try {
      if (newValue == false) {
        try {
          item.isEnabled = false;
          if (key.isNotEmpty) {
            selectedCalendarIds.remove(key);
          }
          calendars.refresh();
          await setCalendarEnabledStatus(item, false);
        } catch (e) {
          print("[ERROR] Failed to toggle calendar state: $e");
          Get.snackbar("Error", "Unable to update calendar sync status");
          item.isEnabled = true;
          calendars.refresh();
        }
        return;
      }

      final String remotePath = CaleeServerService.normalizeRemotePath(item.remotePath ?? '');
      if (remotePath.isEmpty) {
        Get.snackbar('Enable failed', 'Invalid remote calendar path. Please refresh and try again');
        item.isEnabled = false;
        calendars.refresh();
        return;
      }

      // Request permission before enabling calendar
      try {
        final bool hasPermission = await _nativeApi.requestPermission(false);
        if (!hasPermission) {
          Get.snackbar(
            'Permission required',
            'Calendar access permission is required. Please grant calendar permission in settings.',
            duration: const Duration(seconds: 4),
          );
          item.isEnabled = false;
          calendars.refresh();
          return;
        }
      } catch (e) {
        debugPrint('[WARN] Failed to request calendar permission: $e');
        Get.snackbar(
          'Permission error',
          'Failed to request calendar permission. Please check settings.',
          duration: const Duration(seconds: 4),
        );
        item.isEnabled = false;
        calendars.refresh();
        return;
      }

      final EnableCalendarResult enableResult = await _repo.enableRemoteCalendarFromUserAction(remotePath);
      _applyEnableResultToCalendarItem(item, enableResult);

      final String? syncMessage = _repo.takeLastConnectErrorMessage();
      if (!enableResult.success) {
        final String err = syncMessage ?? 'Unable to enable this calendar on this device. Please retry.';
        Get.snackbar(
          'Enable failed',
          err,
        );
      } else if (syncMessage != null && syncMessage.isNotEmpty) {
        Get.snackbar('Sync failed', syncMessage);
      } else {
        // Only check account sync status on Android
        if (Platform.isAndroid) {
          final String accountName = item.accountName;
          if (accountName.isNotEmpty) {
            final bool syncEnabled = await _nativeApi.isCalendarAccountSyncEnabled(accountName);
            if (!syncEnabled) {
              Get.snackbar('Sync disabled in system', 'Please enable CaleeSync account calendar sync in Android Settings.');
            }
          }
        }
      }
      // Keep enable workflow authoritative in repository and update only the
      // affected item here. Full dashboard refresh remains an explicit action
      // (manual refresh, lifecycle load, sync-completed event).
    } catch (e) {
      print("[ERROR] Failed to toggle calendar state: $e");
      Get.snackbar('Enable failed', 'An exception occurred while enabling the calendar. Please try again later');
      item.isEnabled = false;
      calendars.refresh();
    } finally {
      if (key.isNotEmpty) {
        togglingCalendarIds.remove(key);
        calendars.refresh();
      }
    }
  }


  void _applyEnableResultToCalendarItem(CalendarDisplayItem item, EnableCalendarResult result) {
    final String normalizedRemotePath = CaleeServerService.normalizeRemotePath(item.remotePath ?? '');
    final String resultRemotePath = CaleeServerService.normalizeRemotePath(result.remotePath);
    final bool isSameCalendar = normalizedRemotePath.isNotEmpty && normalizedRemotePath == resultRemotePath;

    if (!isSameCalendar) {
      item.isEnabled = result.success;
      calendars.refresh();
      return;
    }

    final String newKey = resultRemotePath.isNotEmpty ? resultRemotePath : (item.localId ?? '');
    if (result.success) {
      if (newKey.isNotEmpty) {
        selectedCalendarIds.add(newKey);
      }
    } else {
      if (newKey.isNotEmpty) {
        selectedCalendarIds.remove(newKey);
      }
    }

    final int index = calendars.indexOf(item);
    if (index < 0) {
      item.isEnabled = result.success;
      calendars.refresh();
      return;
    }

    calendars[index] = CalendarDisplayItem(
      localId: result.localCalendarId ?? item.localId,
      remotePath: item.remotePath,
      name: item.name,
      color: item.color,
      eventCount: item.eventCount,
      isReadOnly: item.isReadOnly,
      isSubscription: item.isSubscription,
      isLocalReadOnly: item.isLocalReadOnly,
      subscriptionUrl: item.subscriptionUrl,
      accountName: item.accountName,
      isEnabled: result.success,
      syncGateReason: item.syncGateReason,
      origin: item.origin,
      bindingId: item.bindingId,
      bindingRole: item.bindingRole,
      remoteCollectionId: item.remoteCollectionId,
      hasRelinkSuggestion: item.hasRelinkSuggestion,
      allowMassDeletionDangerous: item.allowMassDeletionDangerous,
    );
    calendars.refresh();
  }




  Future<void> updateCalendarSyncMode(CalendarDisplayItem item, bool isTwoWay) async {
    final db = await DatabaseHelper.instance.database;
    final int nextSyncMode = isTwoWay ? 1 : 0;

    String whereClause;
    List<dynamic> whereArgs;

    if (item.remotePath != null && item.remotePath!.isNotEmpty) {
      whereClause = 'remote_path = ?';
      whereArgs = [item.remotePath];
    } else {
      whereClause = 'id IN (SELECT remote_collection_id FROM local_bindings WHERE local_collection_id = ?)';
      whereArgs = [item.localId];
    }

    await db.update(
      'remote_collections',
      {'sync_mode': nextSyncMode},
      where: whereClause,
      whereArgs: whereArgs,
    );

    await reloadCalendars();
    _notifyMeaningfulChange();
  }

  Future<void> setAllowMassDeletionDangerous(CalendarDisplayItem item, bool allow) async {
    if (item.bindingId <= 0) return;
    MMKVUtils.instance.setBool(
      '${AppConstant.allowMassDeletionByBindingKeyPrefix}${item.bindingId}',
      allow,
    );
    item.allowMassDeletionDangerous = allow;
    calendars.refresh();
  }

  Future<void> setCalendarEnabledStatus(CalendarDisplayItem item, bool newValue) async {
    final db = await DatabaseHelper.instance.database;

    String whereClause;
    List<dynamic> whereArgs;

    // 1. 优先判断身份：谁有值就用谁查
    if (item.remotePath != null && item.remotePath!.isNotEmpty) {
      // 它是远端日历（即使 localId 为空, 路径也是唯一的）
      whereClause = 'remote_path = ?';
      whereArgs = [item.remotePath];
    } else {
      // 它是纯本地日历（一定有系统分配的 ID）
      whereClause = 'id IN (SELECT remote_collection_id FROM local_bindings WHERE local_collection_id = ?)';
      whereArgs = [item.localId];
    }

    final int now = DateTime.now().millisecondsSinceEpoch;

    await db.rawInsert(
      '''
      INSERT INTO collection_states (remote_collection_id, is_enabled, updated_at)
      SELECT rc.id, ?, ?
      FROM remote_collections rc
      WHERE $whereClause
        AND NOT EXISTS (
          SELECT 1 FROM collection_states cs WHERE cs.remote_collection_id = rc.id
        )
      ''',
      [newValue ? 1 : 0, now, ...whereArgs],
    );

    final int count = await db.rawUpdate(
      '''
      UPDATE collection_states
      SET is_enabled = ?, updated_at = ?
      WHERE remote_collection_id IN (
        SELECT id FROM remote_collections WHERE $whereClause
      )
      ''',
      [newValue ? 1 : 0, now, ...whereArgs],
    );

    debugPrint("[OK] Update succeeded, affected rows: $count (condition: $whereClause = ${whereArgs[0]})");

    final String? localCalendarId = item.localId;
    final String accountName = item.accountName;
    if (localCalendarId != null && localCalendarId.isNotEmpty && accountName.isNotEmpty) {
      try {
        await _nativeApi.setCalendarEnabled(localCalendarId, accountName, newValue);
      } catch (e) {
        debugPrint('[WARN] Failed to update CalendarContract flags for $localCalendarId: $e');
      }
    }
  }

  /// 核心方法：重载日历数据并重新构建 UI 模型。
  ///
  /// This always recalculates per-calendar event totals from `sync_items`
  /// (`COUNT(*) GROUP BY remote_collection_id`).
  Future<void> reloadCalendars() async {
    await _reloadCalendarsImpl();
  }

  Future<void> refreshDashboard() async {
    await reloadCalendars();
  }

  Future<void> _populateRelinkSuggestions(List<CalendarDisplayItem> items) async {
    final String loginName = (MMKVUtils.instance.getString(AppConstant.loginNameKey) ?? '').trim();
    final LocalCalendarPageController localCtrl = Get.isRegistered<LocalCalendarPageController>()
        ? Get.find<LocalCalendarPageController>()
        : Get.put(LocalCalendarPageController());

    for (final item in items) {
      item.hasRelinkSuggestion = false;

      if (loginName.isEmpty ||
          item.origin != SyncBindingOrigin.local ||
          item.remoteCollectionId <= 0 ||
          item.bindingId != 0 ||
          item.remotePath == null ||
          item.remotePath!.isEmpty ||
          item.accountName.trim() != loginName.trim()) {
        continue;
      }

      try {
        final int count = await localCtrl.getHighConfidenceRelinkCandidateCountForRemote(
          remoteCollectionId: item.remoteCollectionId,
          remoteDisplayName: item.name,
          remotePath: item.remotePath!,
        );
        if (count > 0) {
          item.hasRelinkSuggestion = true;
        }
      } catch (e) {
        debugPrint('[WARN] Failed to populate relink suggestions for ${item.remoteCollectionId}: $e');
        item.hasRelinkSuggestion = false;
      }
    }
  }

  Future<void> _reloadCalendarsImpl() async {
    try {
      isLoading.value = true;
      final String authUserId = MMKVUtils.instance.getString(AppConstant.loginNameKey) ?? '';
      final String storedAccountName = MMKVUtils.instance.getString(AppConstant.calendarAccountNameKey) ?? '';
      if (authUserId.isEmpty) return;

      // Some users do not have a bound local calendar account yet, so the
      // persisted account partition can be empty. In that case, fallback to
      // auth user id so the main calendar page can still load remote calendars.
      final String accountName = storedAccountName.isNotEmpty ? storedAccountName : authUserId;

      if (storedAccountName.isEmpty) {
        MMKVUtils.instance.setString(AppConstant.calendarAccountNameKey, accountName);
      }

      // 1. 拉取远端 Calee 日历并更新本地映射
      await _nc.scanRemoteCalendars(
          serverUrl: _authService.normalizedUrl,
          authUserId: authUserId,
          accountName: accountName);

      // 2. 查询本地 remote_collections 的所有日历记录
      final db = await DatabaseHelper.instance.database;
      final List<Map<String, dynamic>> calendarMaps = await db.rawQuery('''
        SELECT rc.*, lb.local_collection_id, lb.id AS binding_id, lb.binding_role AS binding_role, cs.sync_gate_reason, cs.is_enabled AS state_is_enabled
        FROM remote_collections rc
        LEFT JOIN local_bindings lb ON lb.remote_collection_id = rc.id
        LEFT JOIN collection_states cs ON cs.remote_collection_id = rc.id
        WHERE rc.account_name = ?
          AND rc.collection_type = 'calendar'
          AND rc.remote_path IS NOT NULL
          AND rc.remote_path != ''
        ORDER BY rc.id ASC
      ''', [accountName]);
      final Map<String, int> cachedCountByCalendarId = {};
      final Map<String, bool> localReadOnlyById = {};
      final List<CalendarDisplayItem> nextCloudCalendars = [];

      try {
        // Request permission before accessing calendars
        final bool hasPermission = await _nativeApi.requestPermission(false);
        if (!hasPermission) {
          debugPrint('[WARN] Calendar permission not granted, skipping local calendar read-only status');
        } else {
          final List<PlatformCalendar?> platformCalendars = await _nativeApi.getCalendars();
          for (final PlatformCalendar calendar in platformCalendars.whereType<PlatformCalendar>()) {
            final String id = calendar.id ?? '';
            if (id.isEmpty) continue;
            localReadOnlyById[id] = calendar.isReadOnly ?? false;
          }
        }
      } catch (e) {
        debugPrint('[WARN] Failed to read local calendar read-only status: $e');
      }

      final countRows = await db.rawQuery(
        'SELECT remote_collection_id, COUNT(*) AS count FROM sync_items GROUP BY remote_collection_id',
      );
      for (final row in countRows) {
        final String key = (row['remote_collection_id'] ?? '').toString();
        if (key.isEmpty) continue;
        cachedCountByCalendarId[key] = (row['count'] as int?) ?? 0;
      }

      for (var cal in calendarMaps) {
        final String? localId = cal['local_collection_id']?.toString();
        final String? remotePath = cal['remote_path'];
        final int? syncMode = cal['sync_mode'];
        final bool isSubscription = (cal['is_subscription'] == 1 || cal['is_subscription'] == true);
        final int origin = (cal['origin_kind'] as int?) ?? 2;

        final String countKey = (cal['id'] ?? '').toString();
        final int realCount = cachedCountByCalendarId[countKey] ?? 0;

        // 组装 UI 模型
        final int bindingId = (cal['binding_id'] as int?) ?? 0;
        final bool allowMassDeletionDangerous = bindingId > 0
            ? (MMKVUtils.instance.getBool('${AppConstant.allowMassDeletionByBindingKeyPrefix}$bindingId', defaultValue: false) ?? false)
            : false;

        var displayItem = CalendarDisplayItem(
          localId: localId,
          remoteCollectionId: (cal['id'] as int?) ?? 0,
          name: cal['display_name'] ?? 'Unknown',
          color: cal['color'] ?? '#808080',
          eventCount: realCount,
          isReadOnly: syncMode == 0,
          isSubscription: isSubscription,
          isLocalReadOnly: localReadOnlyById[localId] ?? false,
          subscriptionUrl: cal['subscription_url']?.toString(),
          accountName: cal['account_name']?.toString() ?? '',
          isEnabled: (cal['state_is_enabled'] as int?) == 1,
          syncGateReason: cal['sync_gate_reason']?.toString(),
          remotePath: remotePath,
          origin: origin,
          originKey: cal['origin_key']?.toString(),
          bindingId: bindingId,
          bindingRole: (cal['binding_role'] as int?) ?? 0,
          allowMassDeletionDangerous: allowMassDeletionDangerous,
        );

        nextCloudCalendars.add(displayItem);
      }

      await _populateRelinkSuggestions(nextCloudCalendars);
      calendars.assignAll(nextCloudCalendars);

    } catch (e) {
      print("[ERROR] Calendar reload exception: $e");
    } finally {
      isLoading.value = false;
    }
  }
  /// 供外部调用的同步接口
  Future<void> syncAll() async {
    // 1. 执行全量同步服务 (处理合并、上传、下载、删除 status 2)
    // await Get.find<SyncService>().executeFullSync();

    // 2. 同步完成后重刷界面
    await reloadCalendars();
  }

  /// 彻底删除一个日历（包含云端、系统日历与本地 DB 清理）
  Future<void> deleteCalendarTotally({String? localId, String? remotePath}) async {
    try {
      final String? resolvedLocalId = (localId != null && localId.isNotEmpty) ? localId : null;
      final String? resolvedRemotePath = (remotePath != null && remotePath.isNotEmpty) ? remotePath : null;
      if (resolvedLocalId == null && resolvedRemotePath == null) return;

      isLoading.value = true;
      await _repo.performAbsoluteDelete(localId: resolvedLocalId, remotePath: resolvedRemotePath);
      await reloadCalendars();
      _notifyMeaningfulChange();
    } catch (e) {
      print('[ERROR] Dashboard failed to delete calendar: $e');
      Get.snackbar('Error', 'Failed to delete calendar');
    } finally {
      isLoading.value = false;
    }
  }

  /// 重命名日历（委托给仓库并刷新）
  Future<void> renameCalendar(String? localId, String? remotePath, String newName) async {
    final String normalized = newName.trim();
    final String? invalidReason = validateNewCalendarName(normalized);
    if (invalidReason != null) {
      Get.snackbar('Invalid calendar name', invalidReason);
      throw Exception(invalidReason);
    }

    try {
      if ((localId == null || localId.isEmpty) && (remotePath == null || remotePath.isEmpty)) return;
      isLoading.value = true;
      await _repo.renameCalendar(localId: localId, remotePath: remotePath, newName: normalized);
      await reloadCalendars();
      _notifyMeaningfulChange();
    } catch (e) {
      print('[ERROR] Dashboard rename failed: $e');
      Get.snackbar('Error', 'Rename failed');
      rethrow;
    } finally {
      isLoading.value = false;
    }
  }

  /// 创建新的远端日历草稿（委托给 SyncRepository）, 并刷新界面
  Future<bool> createRemoteCalendarDraft(String displayName) async {
    final String? invalidReason = validateNewCalendarName(displayName);
    if (invalidReason != null) {
      Get.snackbar('Invalid calendar name', invalidReason);
      return false;
    }

    try {
      isLoading.value = true;
      final ok = await _repo.createRemoteCalendarDraft(displayName.trim());
      if (ok) {
        await reloadCalendars();
        _notifyMeaningfulChange();
        return true;
      } else {
        Get.snackbar('Error', 'Failed to create calendar');
        return false;
      }
    } catch (e) {
      print('[ERROR] Failed to create remote calendar draft: $e');
      Get.snackbar('Error', 'Failed to create calendar');
      return false;
    } finally {
      isLoading.value = false;
    }
  }

  /// 订阅一个公开的 ICS 链接（委托给仓库）, 并在成功后刷新界面
  Future<bool> subscribePublicIcs(String icsUrl) async {
    final String normalizedUrl = canonicalizeSubscriptionUrl(icsUrl);
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
        await reloadCalendars();
        _notifyMeaningfulChange();
        Get.snackbar('Success', 'Subscribed to calendar');
        return true;
      } else {
        Get.snackbar('Error', 'Subscription failed');
        return false;
      }
    } catch (e) {
      print('[ERROR] Subscription failed: $e');
      Get.snackbar('Error', 'Subscription failed');
      return false;
    } finally {
      subscribingUrls.remove(normalizedUrl);
      isLoading.value = false;
    }
  }

  bool isPublicIcsSubscribed(String? icsUrl) {
    final String normalizedUrl = canonicalizeSubscriptionUrl(icsUrl);
    if (normalizedUrl.isEmpty) return false;

    return calendars.any((calendar) {
      if (!calendar.isSubscription) return false;
      return canonicalizeSubscriptionUrl(calendar.subscriptionUrl) == normalizedUrl;
    });
  }


  String canonicalizeSubscriptionUrl(String? rawUrl) {
    final String trimmed = (rawUrl ?? '').trim();
    if (trimmed.isEmpty) return '';

    final Uri? parsed = Uri.tryParse(trimmed);
    if (parsed == null || parsed.host.isEmpty) {
      return trimmed;
    }

    final String normalizedScheme = parsed.scheme.toLowerCase() == 'webcal'
        ? 'https'
        : parsed.scheme.toLowerCase();
    final int? normalizedPort = (parsed.hasPort &&
            !((normalizedScheme == 'http' && parsed.port == 80) ||
                (normalizedScheme == 'https' && parsed.port == 443)))
        ? parsed.port
        : null;

    final String normalizedPath = (parsed.path.length > 1 && parsed.path.endsWith('/'))
        ? parsed.path.substring(0, parsed.path.length - 1)
        : parsed.path;

    return parsed
        .replace(
          scheme: normalizedScheme,
          host: parsed.host.toLowerCase(),
          port: normalizedPort,
          path: normalizedPath,
          fragment: null,
        )
        .toString();
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

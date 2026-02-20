import 'package:get/get.dart';
import '../sync/SyncEngine.dart';
import '../entity/SyncSummary.dart';
import 'CalendarPageController.dart';
import '../data/sync_repository.dart';
import '../data/sync_run_store.dart';
import '../entity/sync_run_record.dart';

class CalendarProbeController extends GetxController {
  final RxBool isSyncing = false.obs;
  final RxInt success = 0.obs;
  final RxInt failed = 0.obs;
  final RxInt processing = 0.obs;
  /// 当前选中的页面索引（0: Dashboard, 1: Calendars, 2: TaskLists, 3: SyncSettings）
  final RxInt selectedIndex = 1.obs;

  /// 设置选中的页面索引
  void setSelectedIndex(int index) {
    selectedIndex.value = index;
  }
  /// 上次同步时间
  final Rxn<DateTime> lastSyncAt = Rxn<DateTime>();
  /// 当前同步摘要
  final Rxn<SyncSummary> summary = Rxn<SyncSummary>();
  /// 订阅日历列表（含 event_count 等字段），由仓库提供
  final RxList<Map<String, dynamic>> subscribedCalendars = <Map<String, dynamic>>[].obs;

  final SyncRepository _repo = SyncRepository();
  final SyncRunStore _runStore = SyncRunStore();
  final RxList<SyncRunRecord> syncRuns = <SyncRunRecord>[].obs;


  @override
  void onInit() {
    super.onInit();
    loadRecentRuns();
  }

  Future<void> loadRecentRuns() async {
    final runs = await _runStore.loadRuns(limit: 20);
    syncRuns.assignAll(runs);
  }

  /// 获取已订阅日历及对应事件数
  Future<void> fetchSubscribedCalendars() async {
    try {
      isSyncing.value = true; // reuse flag as loading indicator
      final List<Map<String, dynamic>> rows = await _repo.getSubscribedCalendarsWithCount();
      subscribedCalendars.assignAll(rows);
    } catch (e) {
      print('❌ fetchSubscribedCalendars failed: $e');
    } finally {
      isSyncing.value = false;
    }
  }

  /// 执行完整同步并在完成后通知 Dashboard 刷新
  Future<void> syncNow() async {
    if (isSyncing.value) return;
    isSyncing.value = true;
    success.value = 0;
    failed.value = 0;
    processing.value = 0;

    try {
      final engine = SyncEngine();
      final SyncSummary result = await engine.executeFullSync(onProgress: (s) {
        // 更新进度到 Rx 变量（UI 可订阅）
        success.value = s.success;
        failed.value = s.failed;
        processing.value = s.processing;
        summary.value = s;
      });
      // 最终结果
      summary.value = result;
      success.value = result.success;
      failed.value = result.failed;
      processing.value = result.processing;

      // 同步完成后通知 Dashboard 刷新数据
      if (Get.isRegistered<CalendarPageController>()) {
        await Get.find<CalendarPageController>().refreshDashboard();
      }
      // 记录上次同步时间
      lastSyncAt.value = DateTime.now();
      await loadRecentRuns();
    } catch (e) {
      // 可在此处记录错误或展示提示
      rethrow;
    } finally {
      isSyncing.value = false;
    }
  }
}



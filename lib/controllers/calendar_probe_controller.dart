import 'package:caleesync/common/app_constant.dart';
import 'package:caleesync/common/utils/mmkv_utils.dart';
import 'package:get/get.dart';

import '../entity/SyncSummary.dart';
import '../data/sync_repository.dart';
import '../data/sync_run_store.dart';
import '../entity/sync_run_record.dart';
import '../sync/background_sync_scheduler.dart';
import '../sync/sync_trigger_orchestrator.dart';

class CalendarProbeController extends GetxController {
  final RxBool isSyncing = false.obs;
  final RxInt success = 0.obs;
  final RxInt failed = 0.obs;
  final RxInt processing = 0.obs;
  final RxInt configuredSources = 0.obs;
  final RxBool workManagerRunning = false.obs;
  final Rxn<SyncRunRecord> latestRun = Rxn<SyncRunRecord>();

  /// 当前选中的页面索引（0: Dashboard, 1: Calendars, 2: SyncSettings）
  final RxInt selectedIndex = 1.obs;

  /// 设置选中的页面索引
  void setSelectedIndex(int index) {
    selectedIndex.value = index;
  }

  /// 上次同步时间
  final Rxn<DateTime> lastSyncAt = Rxn<DateTime>();
  /// 当前同步摘要
  final Rxn<SyncSummary> summary = Rxn<SyncSummary>();
  /// Subscribed calendar列表（含 event_count 等字段），由仓库提供
  final RxList<Map<String, dynamic>> subscribedCalendars = <Map<String, dynamic>>[].obs;

  final SyncRepository _repo = SyncRepository();
  final SyncRunStore _runStore = SyncRunStore();
  final RxList<SyncRunRecord> syncRuns = <SyncRunRecord>[].obs;

  bool get isRunActive => isSyncing.value || processing.value > 0 || workManagerRunning.value;

  @override
  void onInit() {
    super.onInit();
    refreshOverviewState();
  }

  Future<void> refreshOverviewState() async {
    await Future.wait([
      loadRecentRuns(),
      loadConfiguredSourceCount(),
      loadSchedulerState(),
    ]);
  }

  Future<void> loadConfiguredSourceCount() async {
    final loginName = MMKVUtils.instance.getString(AppConstant.loginNameKey);
    if (loginName == null || loginName.isEmpty) {
      configuredSources.value = 0;
      return;
    }
    configuredSources.value = await _repo.countEnabledCalendarBindings(loginName);
  }

  Future<void> loadSchedulerState() async {
    final status = await BackgroundSyncScheduler.getStatus();
    workManagerRunning.value = status.workerRunning;
  }

  Future<void> loadRecentRuns() async {
    final runs = await _runStore.loadRuns(limit: 20);
    syncRuns.assignAll(runs);
    _syncOverviewFromLatestRun(runs);
  }

  void _syncOverviewFromLatestRun(List<SyncRunRecord> runs) {
    if (runs.isEmpty || isSyncing.value) return;

    final SyncRunRecord latest = runs.first;
    latestRun.value = latest;
    int synced = 0;
    int failures = 0;

    for (final binding in latest.bindings) {
      switch (binding.resultStatus) {
        case SyncBindingResultStatus.success:
          synced++;
          break;
        case SyncBindingResultStatus.partial:
        case SyncBindingResultStatus.failed:
        case SyncBindingResultStatus.abortedBySafety:
          failures++;
          break;
      }
    }

    success.value = synced;
    failed.value = failures;
    processing.value = 0;
    lastSyncAt.value = latest.endTime ?? latest.startTime;
  }

  Future<void> fetchSubscribedCalendars() async {
    try {
      isSyncing.value = true;
      final List<Map<String, dynamic>> rows = await _repo.getSubscribedCalendarsWithCount();
      subscribedCalendars.assignAll(rows);
    } catch (e) {
      print('[ERROR] fetchSubscribedCalendars failed: $e');
    } finally {
      isSyncing.value = false;
    }
  }

  Future<SyncSummary> syncNow() async {
    if (isSyncing.value) {
      return summary.value ?? SyncSummary();
    }

    isSyncing.value = true;
    processing.value = 1;

    try {
      final SyncSummary result;
      if (Get.isRegistered<SyncTriggerOrchestrator>()) {
        result = await Get.find<SyncTriggerOrchestrator>().triggerManual(
          onProgress: (progress) {
            summary.value = progress;
            processing.value = progress.processing;
          },
        );
      } else {
        await BackgroundSyncScheduler.scheduleOneOff(reason: 'sync_now', expedited: true);
        result = SyncSummary();
      }

      await refreshOverviewState();
      return result;
    } finally {
      processing.value = 0;
      isSyncing.value = false;
    }
  }
}

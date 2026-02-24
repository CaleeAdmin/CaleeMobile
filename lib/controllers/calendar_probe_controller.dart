import 'package:get/get.dart';

import '../data/sync_repository.dart';
import '../data/sync_run_store.dart';
import '../entity/SyncSummary.dart';
import '../entity/sync_run_record.dart';
import '../sync/background_sync_scheduler.dart';

class CalendarProbeController extends GetxController {
  final RxBool isSyncing = false.obs;
  final RxInt success = 0.obs;
  final RxInt failed = 0.obs;
  final RxInt processing = 0.obs;
  final RxInt configuredEnabledSources = 0.obs;
  final RxInt configuredDisabledSources = 0.obs;
  final RxString latestRunReasonLabel = ''.obs;

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

  @override
  void onInit() {
    super.onInit();
    loadDashboardData();
  }

  Future<void> loadDashboardData() async {
    await Future.wait([
      loadRecentRuns(),
      loadConfiguredSourceCounts(),
    ]);
  }

  Future<void> loadConfiguredSourceCounts() async {
    final counts = await _repo.getConfiguredSourceCounts();
    configuredEnabledSources.value = counts['enabled'] ?? 0;
    configuredDisabledSources.value = counts['disabled'] ?? 0;
  }

  Future<void> loadRecentRuns() async {
    final runs = await _runStore.loadRuns(limit: 20);
    syncRuns.assignAll(runs);
    _syncOverviewFromLatestRun(runs);
  }

  void _syncOverviewFromLatestRun(List<SyncRunRecord> runs) {
    if (runs.isEmpty || isSyncing.value) {
      success.value = 0;
      failed.value = 0;
      processing.value = 0;
      if (runs.isEmpty) {
        lastSyncAt.value = null;
        latestRunReasonLabel.value = '';
      }
      return;
    }

    final SyncRunRecord latestRun = runs.first;
    int synced = 0;
    int failures = 0;

    for (final binding in latestRun.bindings) {
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
    lastSyncAt.value = latestRun.endTime ?? latestRun.startTime;

    SyncBindingRunRecord? reasonBinding;
    for (final binding in latestRun.bindings) {
      if (binding.safetyGateTriggered || (binding.errorMessage?.trim().isNotEmpty ?? false)) {
        reasonBinding = binding;
        break;
      }
    }
    latestRunReasonLabel.value = reasonBinding?.errorMessage?.trim() ?? '';
  }

  String get latestOutcomeLabel {
    final latest = syncRuns.isEmpty ? null : syncRuns.first;
    if (latest == null) {
      return configuredEnabledSources.value == 0 ? 'No enabled sources' : 'Never run';
    }
    return switch (latest.result) {
      SyncRunResult.success => 'Succeeded',
      SyncRunResult.partial => 'Partially synced',
      SyncRunResult.failed => 'Failed',
      SyncRunResult.abortedBySafety => 'Stopped for safety',
    };
  }

  /// 获取已Subscribed calendar及对应事件数
  Future<void> fetchSubscribedCalendars() async {
    try {
      isSyncing.value = true; // reuse flag as loading indicator
      final List<Map<String, dynamic>> rows = await _repo.getSubscribedCalendarsWithCount();
      subscribedCalendars.assignAll(rows);
    } catch (e) {
      print('[ERROR] fetchSubscribedCalendars failed: $e');
    } finally {
      isSyncing.value = false;
    }
  }

  /// 执行完整同步并在完成后通知 Dashboard 刷新
  Future<void> syncNow() async {
    processing.value = 1;
    await BackgroundSyncScheduler.scheduleOneOff(reason: 'sync_now', expedited: true);
    await loadDashboardData();
    processing.value = 0;
  }
}

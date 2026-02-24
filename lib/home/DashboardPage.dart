import 'package:caleesync/sync/background_sync_scheduler.dart';
import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:intl/intl.dart';

import '../controllers/calendar_probe_controller.dart';
import '../feature/local_calendars_page.dart';
import '../feature/public_subscriptions_page.dart';
import '../entity/sync_run_record.dart';
import 'sync_status_details_page.dart';

class DashboardPage extends StatefulWidget {
  const DashboardPage({super.key});

  @override
  State<DashboardPage> createState() => _DashboardPageState();
}

class _DashboardPageState extends State<DashboardPage> with WidgetsBindingObserver {
  BackgroundSyncStatus? _backgroundStatus;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _loadBackgroundStatus();
    Get.find<CalendarProbeController>().refreshOverviewState();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _loadBackgroundStatus();
      Get.find<CalendarProbeController>().refreshOverviewState();
    }
  }

  Future<void> _loadBackgroundStatus() async {
    final status = await BackgroundSyncScheduler.getStatus();
    if (!mounted) return;
    setState(() => _backgroundStatus = status);
  }

  String _formatTime(DateTime? dt) {
    if (dt == null) return 'Never';
    final local = dt.toLocal();
    final absolute = DateFormat('MMM d, yyyy • HH:mm').format(local);
    final diff = DateTime.now().difference(local);
    final rel = diff.inMinutes < 1
        ? 'just now'
        : diff.inHours < 1
            ? '${diff.inMinutes}m ago'
            : diff.inDays < 1
                ? '${diff.inHours}h ago'
                : '${diff.inDays}d ago';
    return '$absolute ($rel)';
  }

  String _sourceLabel(int count) => '$count ${count == 1 ? 'source' : 'sources'}';

  String _runResultLabel(SyncRunResult? result) {
    switch (result) {
      case SyncRunResult.success:
        return 'Succeeded';
      case SyncRunResult.partial:
        return 'Partially Synced';
      case SyncRunResult.failed:
        return 'Failed';
      case SyncRunResult.abortedBySafety:
        return 'Stopped for Safety';
      case SyncRunResult.skippedNoEnabledSources:
        return 'Skipped (No Enabled Sources)';
      case SyncRunResult.skippedNoChanges:
        return 'Skipped (No Changes)';
      case null:
        return 'No runs yet';
    }
  }

  @override
  Widget build(BuildContext context) {
    final probeCtrl = Get.find<CalendarProbeController>();
    return RefreshIndicator(
      onRefresh: () async {
        await _loadBackgroundStatus();
        await probeCtrl.refreshOverviewState();
      },
      child: SingleChildScrollView(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Obx(() {
              final run = probeCtrl.latestRun.value;
              final configured = probeCtrl.configuredSources.value;
              final isRunning = probeCtrl.isRunActive || (_backgroundStatus?.workerRunning == true);
              final needsAttention = !isRunning && run != null && run.result != SyncRunResult.success;
              return Card(
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    _banner(isRunning, needsAttention),
                    const SizedBox(height: 12),
                    _kvRow(icon: Icons.checklist, label: 'Last completed run', value: _runResultLabel(run?.result)),
                    _kvRow(icon: Icons.history, label: 'Completed at', value: _formatTime(run?.endTime ?? run?.startTime)),
                    const Divider(height: 20),
                    _kvRow(icon: Icons.link, label: 'Configured sources', value: _sourceLabel(configured)),
                    if (configured == 0)
                      Container(
                        margin: const EdgeInsets.only(top: 8),
                        padding: const EdgeInsets.all(12),
                        decoration: BoxDecoration(color: Colors.blueGrey.withOpacity(0.08), borderRadius: BorderRadius.circular(8)),
                        child: const Text('No calendars enabled for sync. Open Calendars to enable at least one source.'),
                      ),
                    const Divider(height: 20),
                    const Text('Background scheduler', style: TextStyle(fontWeight: FontWeight.w600)),
                    const SizedBox(height: 8),
                    _kvRow(icon: Icons.schedule, label: 'State', value: _schedulerStateLabel()),
                    _kvRow(icon: Icons.timer, label: 'Interval', value: _backgroundStatus?.intervalMinutes != null ? 'Every ${_backgroundStatus!.intervalMinutes} minutes' : 'Not set'),
                    _kvRow(icon: Icons.task_alt, label: 'Last run result', value: _friendlyResult(_backgroundStatus?.lastResult)),
                    _kvRow(icon: Icons.update, label: 'Next window', value: _backgroundStatus?.nextScheduledAt == null ? 'Not Scheduled' : _formatTime(_backgroundStatus?.nextScheduledAt)),
                    if ((_backgroundStatus?.periodicConfigured == true) && (_backgroundStatus?.periodicEnabled != true))
                      const Padding(
                        padding: EdgeInsets.only(top: 4),
                        child: Text('Periodic sync is enabled in settings but currently not scheduled. Use Repair Scheduler.', style: TextStyle(color: Colors.deepOrange, fontSize: 12)),
                      ),
                    const SizedBox(height: 8),
                    Wrap(spacing: 8, children: [
                      OutlinedButton.icon(onPressed: probeCtrl.syncNow, icon: const Icon(Icons.sync), label: const Text('Sync Now')),
                      OutlinedButton.icon(
                        onPressed: _repairScheduler,
                        icon: const Icon(Icons.build),
                        label: const Text('Repair Scheduler'),
                      ),
                    ]),
                    Align(
                      alignment: Alignment.centerRight,
                      child: TextButton.icon(onPressed: () async { await _loadBackgroundStatus(); await probeCtrl.refreshOverviewState(); }, icon: const Icon(Icons.refresh), label: const Text('Refresh')),
                    ),
                    Container(
                      width: double.infinity,
                      decoration: BoxDecoration(color: Colors.grey.shade300, borderRadius: BorderRadius.circular(8)),
                      child: TextButton.icon(
                        onPressed: () => Get.to(() => const SyncStatusDetailsPage()),
                        icon: const Icon(Icons.arrow_forward, size: 16),
                        label: const Text('View Detailed Activity'),
                      ),
                    ),
                  ]),
                ),
              );
            }),
            const SizedBox(height: 16),
            Card(
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text('Quick Actions', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
                    const SizedBox(height: 12),
                    SizedBox(
                      width: double.infinity,
                      child: OutlinedButton.icon(onPressed: () => Get.to(() => const PublicSubscriptionsGetxPage()), icon: const Icon(Icons.public), label: const Text('Subscribe to Calee Calendar')),
                    ),
                    const SizedBox(height: 10),
                    SizedBox(
                      width: double.infinity,
                      child: OutlinedButton.icon(onPressed: () => Get.to(() => const LocalCalendarsPage()), icon: const Icon(Icons.link), label: const Text('Link to Device Calendar')),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 32),
          ],
        ),
      ),
    );
  }

  String _schedulerStateLabel() {
    if (_backgroundStatus == null) return 'Disabled';
    if (_backgroundStatus!.periodicConfigured && !_backgroundStatus!.periodicEnabled) {
      return 'Enabled (Not Scheduled)';
    }
    return _backgroundStatus!.periodicEnabled ? 'Enabled' : 'Disabled';
  }


  Future<void> _repairScheduler() async {
    await BackgroundSyncScheduler.selfHealPeriodicIfNeeded();
    await _loadBackgroundStatus();
  }

  Widget _banner(bool isRunning, bool attention) {
    final Color color = isRunning ? Colors.blue : (attention ? Colors.orange : Colors.green);
    final String text = isRunning ? 'Syncing…' : (attention ? 'Attention Required' : 'Idle');
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(color: color.withOpacity(0.1), borderRadius: BorderRadius.circular(8), border: Border.all(color: color.withOpacity(0.3))),
      child: Text(text, style: TextStyle(color: color, fontWeight: FontWeight.w700)),
    );
  }

  String _friendlyResult(String? result) {
    return switch (result) {
      'success' => 'Succeeded',
      'retry' => 'Will retry',
      'failure' => 'Failed',
      _ => 'No background result yet',
    };
  }

  Widget _kvRow({required IconData icon, required String label, required String value}) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 18, color: Colors.black54),
          const SizedBox(width: 8),
          Expanded(child: Text(label, style: const TextStyle(color: Colors.black54))),
          const SizedBox(width: 8),
          Flexible(child: Text(value, textAlign: TextAlign.right, style: const TextStyle(color: Colors.black87))),
        ],
      ),
    );
  }
}

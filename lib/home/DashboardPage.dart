import 'package:caleesync/core/platform/pigeon/background_sync_api.g.dart';
import 'package:caleesync/sync/background_sync_scheduler.dart';
import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:intl/intl.dart';

import '../controllers/calendar_probe_controller.dart';
import '../entity/sync_run_record.dart';
import '../feature/local_calendars_page.dart';
import '../feature/public_subscriptions_page.dart';
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
    _refreshAll();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _refreshAll();
    }
  }

  Future<void> _refreshAll() async {
    final status = await BackgroundSyncScheduler.getStatus();
    if (mounted) {
      setState(() => _backgroundStatus = status);
    }
    await Get.find<CalendarProbeController>().refreshOverviewState();
  }

  String _sourceLabel(int count) => '$count ${count == 1 ? 'source' : 'sources'}';

  String _relative(DateTime? dt) {
    if (dt == null) return 'never';
    final diff = DateTime.now().difference(dt.toLocal());
    if (diff.inMinutes < 1) return 'just now';
    if (diff.inHours < 1) return '${diff.inMinutes}m ago';
    if (diff.inDays < 1) return '${diff.inHours}h ago';
    return '${diff.inDays}d ago';
  }

  String _clock(DateTime? dt) {
    if (dt == null) return 'Not Scheduled';
    return DateFormat('HH:mm').format(dt.toLocal());
  }

  String _runLabel(SyncRunResult? result) {
    return switch (result) {
      SyncRunResult.success => 'Succeeded',
      SyncRunResult.partial => 'Partially Synced',
      SyncRunResult.failed => 'Failed',
      SyncRunResult.abortedBySafety => 'Stopped for Safety',
      SyncRunResult.skippedNoEnabledSources => 'Skipped (No Enabled Sources)',
      SyncRunResult.skippedNoChanges => 'Skipped (No Changes)',
      null => 'No runs yet',
    };
  }

  IconData _runIcon(SyncRunResult? result) {
    return switch (result) {
      SyncRunResult.success => Icons.check_circle,
      SyncRunResult.skippedNoChanges => Icons.info,
      SyncRunResult.skippedNoEnabledSources => Icons.info,
      SyncRunResult.partial => Icons.warning_amber,
      SyncRunResult.abortedBySafety || SyncRunResult.failed => Icons.error,
      null => Icons.history,
    };
  }

  Color _runColor(SyncRunResult? result) {
    return switch (result) {
      SyncRunResult.success => Colors.green,
      SyncRunResult.skippedNoChanges => Colors.blueGrey,
      SyncRunResult.skippedNoEnabledSources => Colors.blueGrey,
      SyncRunResult.partial => Colors.orange,
      SyncRunResult.abortedBySafety || SyncRunResult.failed => Colors.red,
      null => Colors.black54,
    };
  }

  bool _requiresAttention(SyncRunResult? result) {
    return switch (result) {
      SyncRunResult.partial || SyncRunResult.failed || SyncRunResult.abortedBySafety => true,
      SyncRunResult.success || SyncRunResult.skippedNoChanges || SyncRunResult.skippedNoEnabledSources || null => false,
    };
  }

  String _schedulerSummary() {
    final enabled = _backgroundStatus?.periodicEnabled == true;
    final interval = _backgroundStatus?.intervalMinutes != null ? 'Every ${_backgroundStatus!.intervalMinutes}m' : 'Every 15m';
    final next = _clock(_backgroundStatus?.nextScheduledAt);
    return '${enabled ? 'Enabled' : 'Disabled'} · $interval · Next $next';
  }

  bool get _showSchedulerWarning {
    if (_backgroundStatus == null) return false;
    if (_backgroundStatus!.periodicConfigured && !_backgroundStatus!.periodicEnabled) return true;
    return (_backgroundStatus!.lastResult == BackgroundRunOutcome.retry || _backgroundStatus!.lastResult == BackgroundRunOutcome.failure);
  }

  @override
  Widget build(BuildContext context) {
    final probeCtrl = Get.find<CalendarProbeController>();

    return RefreshIndicator(
      onRefresh: _refreshAll,
      child: SingleChildScrollView(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.all(16),
        child: Obx(() {
          final run = probeCtrl.latestRun.value;
          final configured = probeCtrl.configuredSources.value;
          final isRunning = probeCtrl.isRunActive || (_backgroundStatus?.workerRunning == true);
          final needsAttention = !isRunning && _requiresAttention(run?.result);
          final runColor = _runColor(run?.result);

          return Column(
            children: [
              Card(
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      _banner(isRunning, needsAttention),
                      const SizedBox(height: 20),

                      // Last Sync
                      Row(
                        children: [
                          Icon(_runIcon(run?.result), color: runColor, size: 18),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              '${_runLabel(run?.result)} · ${_relative(run?.endTime ?? run?.startTime)}',
                              style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
                            ),
                          ),
                        ],
                      ),

                      const SizedBox(height: 20),

                      // Configured
                      Text(_sourceLabel(configured), style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600)),
                      if (configured == 0) ...[
                        const SizedBox(height: 8),
                        const Text(
                          'No calendars enabled for sync',
                          style: TextStyle(color: Colors.black54),
                        ),
                      ],

                      const SizedBox(height: 20),
                      const Divider(height: 1),
                      const SizedBox(height: 20),

                      // Background
                      const Text('Background', style: TextStyle(fontWeight: FontWeight.w600)),
                      const SizedBox(height: 8),
                      Text(_schedulerSummary(), style: const TextStyle(color: Colors.black87)),
                      if (_showSchedulerWarning) ...[
                        const SizedBox(height: 8),
                        Text(
                          _backgroundStatus?.periodicConfigured == true && _backgroundStatus?.periodicEnabled != true
                              ? 'Scheduler not currently active.'
                              : (_backgroundStatus?.lastResult == BackgroundRunOutcome.retry ? 'Background run will retry.' : 'Background run failed.'),
                          style: const TextStyle(color: Colors.deepOrange),
                        ),
                        const SizedBox(height: 6),
                        ExpansionTile(
                          tilePadding: EdgeInsets.zero,
                          title: const Text('Diagnostics', style: TextStyle(fontSize: 13)),
                          childrenPadding: EdgeInsets.zero,
                          children: [
                            Align(
                              alignment: Alignment.centerLeft,
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text('Result: ${_backgroundStatus?.lastResult?.name ?? 'unknown'}'),
                                  Text('Reason: ${_backgroundStatus?.lastReason?.isNotEmpty == true ? _backgroundStatus!.lastReason! : 'n/a'}'),
                                  Text('Gate: ${_backgroundStatus?.lastGate?.name ?? 'n/a'}'),
                                  Text('Error: ${_backgroundStatus?.lastError?.isNotEmpty == true ? _backgroundStatus!.lastError! : 'n/a'}'),
                                  const SizedBox(height: 8),
                                  TextButton.icon(
                                    onPressed: () async {
                                      await BackgroundSyncScheduler.selfHealPeriodicIfNeeded();
                                      await _refreshAll();
                                    },
                                    icon: const Icon(Icons.build, size: 16),
                                    label: const Text('Repair Scheduler'),
                                  ),
                                ],
                              ),
                            ),
                          ],
                        ),
                      ],

                      const SizedBox(height: 24),

                      // Actions
                      SizedBox(
                        width: double.infinity,
                        child: FilledButton.icon(
                          onPressed: probeCtrl.isSyncing.value ? null : () async {
                            await probeCtrl.syncNow();
                          },
                          icon: const Icon(Icons.sync),
                          label: Text(probeCtrl.isSyncing.value ? 'Syncing…' : 'Sync Now'),
                        ),
                      ),
                      const SizedBox(height: 8),
                      Align(
                        alignment: Alignment.centerLeft,
                        child: TextButton(
                          onPressed: () => Get.to(() => const SyncStatusDetailsPage()),
                          child: const Text('View Activity'),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
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
                        child: OutlinedButton.icon(
                          onPressed: () => Get.to(() => const PublicSubscriptionsGetxPage()),
                          icon: const Icon(Icons.public),
                          label: const Text('Subscribe to Calee Calendar'),
                        ),
                      ),
                      const SizedBox(height: 10),
                      SizedBox(
                        width: double.infinity,
                        child: OutlinedButton.icon(
                          onPressed: () => Get.to(() => const LocalCalendarsPage()),
                          icon: const Icon(Icons.link),
                          label: const Text('Link to Device Calendar'),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          );
        }),
      ),
    );
  }

  Widget _banner(bool isRunning, bool attention) {
    final color = isRunning ? Colors.blue : (attention ? Colors.orange : Colors.green);
    final text = isRunning ? 'Syncing…' : (attention ? 'Attention Required' : 'Idle');
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: color.withOpacity(0.1),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: color.withOpacity(0.3)),
      ),
      child: Text(text, style: TextStyle(color: color, fontWeight: FontWeight.w700)),
    );
  }
}

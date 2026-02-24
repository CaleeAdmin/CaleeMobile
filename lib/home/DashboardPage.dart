import 'package:caleesync/common/app_constant.dart';
import 'package:caleesync/common/utils/mmkv_utils.dart';
import 'package:caleesync/data/sync_repository.dart';
import 'package:caleesync/sync/background_sync_scheduler.dart';
import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:intl/intl.dart';
import 'package:permission_handler/permission_handler.dart';

import '../controllers/CalendarPageController.dart';
import '../controllers/calendar_probe_controller.dart';
import '../feature/local_calendars_page.dart';
import '../feature/public_subscriptions_page.dart';
import '../services/calee_auth_service.dart';
import '../services/calee_server_service.dart';
import 'sync_status_details_page.dart';

class DashboardPage extends StatefulWidget {
  const DashboardPage({super.key});

  @override
  State<DashboardPage> createState() => _DashboardPageState();
}

class _DashboardPageState extends State<DashboardPage> with WidgetsBindingObserver {
  final SyncRepository _repo = SyncRepository();
  final CaleeServerService _nc = CaleeServerService();
  final CaleeAuthService _authService = CaleeAuthService(serverBaseUrl: AppConstant.caleeServer);

  BackgroundSyncStatus? _backgroundStatus;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _refreshOverview();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _refreshOverview();
    }
  }

  Future<void> _refreshOverview() async {
    final probeCtrl = Get.find<CalendarProbeController>();
    await Future.wait([
      _loadBackgroundStatus(),
      probeCtrl.loadDashboardData(),
    ]);
  }

  Future<void> _loadBackgroundStatus() async {
    final status = await BackgroundSyncScheduler.getStatus();
    if (!mounted) return;
    setState(() => _backgroundStatus = status);
  }

  Future<void> _requestCalendarPermission() async {
    Permission calendarPermission = Permission.calendarFullAccess;
    var status = await calendarPermission.status;
    if (status.isPermanentlyDenied) {
      openAppSettings();
      return;
    }
    status = await calendarPermission.request();
    if (status.isGranted) {
      final loginName = MMKVUtils.instance.getString(AppConstant.loginNameKey) ?? 'current_user_id';
      await _repo.scanLocalCalendars(loginName);
      await _nc.scanRemoteCalendars(serverUrl: _authService.normalizedUrl, userId: loginName);
      if (Get.isRegistered<CalendarPageController>()) {
        Get.find<CalendarPageController>().refreshDashboard();
      }
      try {
        if (Get.isRegistered<CalendarProbeController>()) {
          await Get.find<CalendarProbeController>().fetchSubscribedCalendars();
        } else {
          Get.put(CalendarProbeController());
          await Get.find<CalendarProbeController>().fetchSubscribedCalendars();
        }
      } catch (_) {}
    }
  }

  String _friendlyBackgroundResult(String? result) {
    return switch (result) {
      'success' => 'Succeeded',
      'retry' => 'Needs retry',
      'failure' => 'Failed',
      _ => 'Never run',
    };
  }

  String _pluralSources(int count) => '$count ${count == 1 ? 'source' : 'sources'}';

  String _formatFriendlyTime(DateTime? value, {String neverLabel = 'Never'}) {
    if (value == null) return neverLabel;
    final local = value.toLocal();
    final absolute = DateFormat('MMM d, yyyy • HH:mm').format(local);
    return '$absolute (${_relative(local)})';
  }

  String _formatNextWindow(DateTime? nextWindow) {
    if (nextWindow == null) {
      if (_backgroundStatus?.periodicEnabled == true) {
        return 'Not scheduled (repair scheduler)';
      }
      return 'Not scheduled';
    }
    final local = nextWindow.toLocal();
    return 'in ~${_minutesUntil(local)} min (${DateFormat('HH:mm').format(local)})';
  }

  int _minutesUntil(DateTime target) {
    final diff = target.difference(DateTime.now()).inMinutes;
    return diff < 0 ? 0 : diff;
  }

  String _relative(DateTime dt) {
    final now = DateTime.now();
    final diff = now.difference(dt);
    if (diff.inMinutes < 1) return 'just now';
    if (diff.inMinutes < 60) return '${diff.inMinutes}m ago';
    if (diff.inHours < 24) return '${diff.inHours}h ago';
    if (diff.inHours < 48) return 'Yesterday';
    return '${diff.inDays}d ago';
  }

  @override
  Widget build(BuildContext context) {
    final probeCtrl = Get.find<CalendarProbeController>();
    final int interval = MMKVUtils.instance.getInt(AppConstant.syncIntervalCalendarKey) ?? 15;

    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Card(
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text('Quick Actions', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
                  const SizedBox(height: 6),
                  const Text('Jump directly to common calendar setup tasks.', style: TextStyle(color: Colors.black54)),
                  const SizedBox(height: 12),
                  SizedBox(
                    width: double.infinity,
                    child: OutlinedButton.icon(
                      style: OutlinedButton.styleFrom(
                        alignment: Alignment.centerLeft,
                        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 14),
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                      ),
                      onPressed: () => Get.to(() => const PublicSubscriptionsGetxPage()),
                      icon: const Icon(Icons.public),
                      label: const Text('Subscribe to Calee Calendar'),
                    ),
                  ),
                  const SizedBox(height: 10),
                  SizedBox(
                    width: double.infinity,
                    child: OutlinedButton.icon(
                      style: OutlinedButton.styleFrom(
                        alignment: Alignment.centerLeft,
                        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 14),
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                      ),
                      onPressed: () => Get.to(() => const LocalCalendarsPage()),
                      icon: const Icon(Icons.link),
                      label: const Text('Link to Device Calendar'),
                    ),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 16),
          Obx(() {
            final int enabledSources = probeCtrl.configuredEnabledSources.value;
            final int disabledSources = probeCtrl.configuredDisabledSources.value;
            final int totalConfigured = enabledSources + disabledSources;
            final bool schedulerNeedsRepair = _backgroundStatus?.periodicEnabled == true && _backgroundStatus?.nextScheduledAt == null;
            return Card(
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text('Sync Overview', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
                    const SizedBox(height: 6),
                    const Text(
                      'See sync health, recent activity, and background scheduler status in one place.',
                      style: TextStyle(color: Colors.black54),
                    ),
                    const SizedBox(height: 12),
                    _statusTile(
                      color: Colors.blue,
                      icon: Icons.tune,
                      title: 'Configured sources',
                      subtitle: '$totalConfigured (${_pluralSources(enabledSources)} enabled, ${_pluralSources(disabledSources)} disabled)',
                    ),
                    _statusTile(
                      color: Colors.green,
                      icon: Icons.task_alt,
                      title: 'Last run outcome',
                      subtitle: probeCtrl.latestOutcomeLabel,
                    ),
                    _statusTile(
                      color: Colors.lightGreen,
                      icon: Icons.sync,
                      title: 'Current run state',
                      subtitle: probeCtrl.processing.value > 0 || probeCtrl.isSyncing.value ? 'Running' : 'Idle',
                    ),
                    const SizedBox(height: 6),
                    if (enabledSources == 0)
                      Container(
                        width: double.infinity,
                        padding: const EdgeInsets.all(10),
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(8),
                          color: Colors.amber.shade50,
                        ),
                        child: const Text('No calendars enabled for sync. Link a calendar and enable sync to get started.'),
                      )
                    else ...[
                      _statusTile(
                        color: Colors.green,
                        icon: Icons.check_circle,
                        title: 'Synced',
                        subtitle: _pluralSources(probeCtrl.success.value),
                      ),
                      _statusTile(
                        color: Colors.red,
                        icon: Icons.error_outline,
                        title: 'Errors',
                        subtitle: _pluralSources(probeCtrl.failed.value),
                      ),
                    ],
                    const SizedBox(height: 8),
                    _kvRow(
                      icon: Icons.timeline,
                      label: 'Last sync activity',
                      value: _formatFriendlyTime(probeCtrl.lastSyncAt.value),
                    ),
                    if (probeCtrl.latestRunReasonLabel.value.isNotEmpty)
                      _kvRow(icon: Icons.info_outline, label: 'Run note', value: probeCtrl.latestRunReasonLabel.value),
                    const Divider(height: 20),
                    _kvRow(
                      icon: Icons.schedule,
                      label: 'Background sync',
                      value: _backgroundStatus?.periodicEnabled == true ? 'Enabled' : 'Disabled',
                    ),
                    _kvRow(icon: Icons.repeat, label: 'Interval', value: '$interval min'),
                    _kvRow(
                      icon: Icons.task_alt,
                      label: 'Background result',
                      value: _friendlyBackgroundResult(_backgroundStatus?.lastResult),
                    ),
                    _kvRow(
                      icon: Icons.update,
                      label: 'Last background run',
                      value: _formatFriendlyTime(_backgroundStatus?.lastRunAt),
                    ),
                    _kvRow(
                      icon: Icons.av_timer,
                      label: 'Next background window',
                      value: _formatNextWindow(_backgroundStatus?.nextScheduledAt),
                    ),
                    if ((_backgroundStatus?.lastReason ?? '').isNotEmpty)
                      _kvRow(
                        icon: Icons.info_outline,
                        label: 'Background note',
                        value: _backgroundStatus!.lastReason!,
                      ),
                    Wrap(
                      alignment: WrapAlignment.end,
                      spacing: 8,
                      runSpacing: 8,
                      children: [
                        TextButton.icon(
                          onPressed: _refreshOverview,
                          icon: const Icon(Icons.refresh),
                          label: const Text('Refresh background status'),
                        ),
                        TextButton.icon(
                          onPressed: probeCtrl.syncNow,
                          icon: const Icon(Icons.play_arrow),
                          label: const Text('Sync now'),
                        ),
                        TextButton.icon(
                          onPressed: () => Get.to(() => const SyncStatusDetailsPage()),
                          icon: const Icon(Icons.list_alt),
                          label: const Text('View activity'),
                        ),
                        if (schedulerNeedsRepair)
                          TextButton.icon(
                            onPressed: () async {
                              await BackgroundSyncScheduler.selfHealPeriodicIfNeeded();
                              await _loadBackgroundStatus();
                            },
                            icon: const Icon(Icons.build_circle_outlined),
                            label: const Text('Repair scheduler'),
                          ),
                      ],
                    ),
                  ],
                ),
              ),
            );
          }),
          const SizedBox(height: 32),
        ],
      ),
    );
  }

  Widget _statusTile({
    required Color color,
    required IconData icon,
    required String title,
    required String subtitle,
  }) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(12),
      margin: const EdgeInsets.only(bottom: 8),
      decoration: BoxDecoration(
        color: color.withOpacity(0.08),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: color.withOpacity(0.25)),
      ),
      child: Row(
        children: [
          Container(
            width: 36,
            height: 36,
            decoration: BoxDecoration(color: color.withOpacity(0.2), borderRadius: BorderRadius.circular(8)),
            child: Icon(icon, color: color),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title, style: const TextStyle(fontWeight: FontWeight.w600)),
                Text(subtitle, style: const TextStyle(color: Colors.black54)),
              ],
            ),
          ),
        ],
      ),
    );
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
          Flexible(
            child: Text(value, textAlign: TextAlign.right, style: const TextStyle(color: Colors.black87)),
          ),
        ],
      ),
    );
  }
}

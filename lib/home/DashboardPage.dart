import 'package:caleesync/common/app_constant.dart';
import 'package:caleesync/common/utils/mmkv_utils.dart';
import 'package:caleesync/data/sync_repository.dart';
import 'package:caleesync/sync/background_sync_scheduler.dart';
import 'package:flutter/material.dart';
import 'package:get/get.dart';
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

class _DashboardPageState extends State<DashboardPage> {
  final SyncRepository _repo = SyncRepository();
  final CaleeServerService _nc = CaleeServerService();
  final CaleeAuthService _authService = CaleeAuthService(serverBaseUrl: AppConstant.caleeServer);

  BackgroundSyncStatus? _backgroundStatus;

  @override
  void initState() {
    super.initState();
    _loadBackgroundStatus();
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

  String _friendlyResult(String? result) {
    return switch (result) {
      'success' => 'Last run succeeded',
      'retry' => 'Last run will retry',
      'failure' => 'Last run failed',
      _ => 'No background result yet',
    };
  }

  @override
  Widget build(BuildContext context) {
    final probeCtrl = Get.find<CalendarProbeController>();
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
                    Container(
                      width: double.infinity,
                      decoration: BoxDecoration(
                        color: Colors.grey.shade300,
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: TextButton.icon(
                        onPressed: () => Get.to(() => const SyncStatusDetailsPage()),
                        icon: const Icon(Icons.arrow_forward, size: 16),
                        label: const Text('View Detailed Activity'),
                      ),
                    ),
                    const SizedBox(height: 12),
                    _statusTile(
                      color: Colors.green,
                      icon: Icons.check_circle,
                      title: 'Synced',
                      subtitle: '${probeCtrl.success.value} sources',
                    ),
                    _statusTile(
                      color: Colors.lightGreen,
                      icon: Icons.sync,
                      title: 'Syncing',
                      subtitle: '${probeCtrl.processing.value} source',
                    ),
                    _statusTile(
                      color: Colors.red,
                      icon: Icons.error_outline,
                      title: 'Errors',
                      subtitle: '${probeCtrl.failed.value} source',
                    ),
                    const SizedBox(height: 8),
                    _kvRow(
                      icon: Icons.timeline,
                      label: 'Last sync activity',
                      value: probeCtrl.lastSyncAt.value == null ? 'Never' : probeCtrl.lastSyncAt.value!.toLocal().toString(),
                    ),
                    const Divider(height: 20),
                    _kvRow(
                      icon: Icons.schedule,
                      label: 'Background sync',
                      value: _backgroundStatus?.periodicEnabled == true ? 'Enabled' : 'Disabled',
                    ),
                    _kvRow(
                      icon: Icons.task_alt,
                      label: 'Background result',
                      value: _friendlyResult(_backgroundStatus?.lastResult),
                    ),
                    _kvRow(
                      icon: Icons.update,
                      label: 'Last background run',
                      value: _backgroundStatus?.lastRunAt?.toLocal().toString() ?? 'Never',
                    ),
                    _kvRow(
                      icon: Icons.av_timer,
                      label: 'Next background window',
                      value: _backgroundStatus?.nextScheduledAt?.toLocal().toString() ?? 'Not scheduled',
                    ),
                    if ((_backgroundStatus?.lastReason ?? '').isNotEmpty)
                      _kvRow(
                        icon: Icons.info_outline,
                        label: 'Note',
                        value: _backgroundStatus!.lastReason!,
                      ),
                    Align(
                      alignment: Alignment.centerRight,
                      child: TextButton.icon(
                        onPressed: _loadBackgroundStatus,
                        icon: const Icon(Icons.refresh),
                        label: const Text('Refresh background status'),
                      ),
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
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(title, style: const TextStyle(fontWeight: FontWeight.w600)),
              Text(subtitle, style: const TextStyle(color: Colors.black54)),
            ],
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

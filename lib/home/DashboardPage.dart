import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:caleesync/common/app_constant.dart';
import 'package:caleesync/common/utils/mmkv_utils.dart';
import 'package:caleesync/data/sync_repository.dart';
import '../controllers/CalendarPageController.dart';
import '../controllers/calendar_probe_controller.dart';
import '../services/nextcloud_auth_service.dart';
import '../services/nextcloud_service.dart';
import 'sync_status_details_page.dart';

class DashboardPage extends StatefulWidget {
  const DashboardPage({super.key});

  @override
  State<DashboardPage> createState() => _DashboardPageState();
}

class _DashboardPageState extends State<DashboardPage> {
  final SyncRepository _repo = SyncRepository();
  final NextcloudService _nc = NextcloudService();
  final NextcloudAuthService _authService = NextcloudAuthService(serverBaseUrl: AppConstant.nextcloudServer);

  @override
  void initState() {
    super.initState();
    // WidgetsBinding.instance.addPostFrameCallback((_) {
    //   _requestCalendarPermission();
    // });
  }

  Future<void> _requestCalendarPermission() async {
    Permission calendarPermission = Permission.calendarFullAccess;
    var status = await calendarPermission.status;
    if (status.isPermanentlyDenied) {
      // guide to settings
      openAppSettings();
      return;
    }
    status = await calendarPermission.request();
    if (status.isGranted) {
      // refresh local calendars and dashboard
      final loginName = MMKVUtils.instance.getString(AppConstant.loginName) ?? 'current_user_id';
      await _repo.scanLocalCalendars(loginName);
      await _nc.scanRemoteCalendars(
          serverUrl: _authService.normalizedUrl,
          userId: loginName);
      if (Get.isRegistered<CalendarPageController>()) {
        Get.find<CalendarPageController>().refreshDashboard();
      }
      // 尝试刷新已订阅列表
      try {
        if (Get.isRegistered<CalendarProbeController>()) {
          await Get.find<CalendarProbeController>().fetchSubscribedCalendars();
        } else {
          Get.put(CalendarProbeController());
          await Get.find<CalendarProbeController>().fetchSubscribedCalendars();
        }
      } catch (_) {}
    } else if (status.isLimited) {
      // limited access - ignore for now
    } else {
      // denied - do nothing
    }
  }

  @override
  Widget build(BuildContext context) {
    final probeCtrl = Get.find<CalendarProbeController>();
    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Sync Overview card
          Obx(() {
            return Card(
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children:  [
                              Text('Sync Overview', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
                              SizedBox(height: 6),
                              Text(
                                'Current synchronization status across all sources',
                                style: TextStyle(color: Colors.black54),
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                              ),
                              const SizedBox(height: 12),
                              Container(
                                width: double.infinity,
                                  decoration: BoxDecoration(
                                    color: Colors.grey.shade300,
                                    borderRadius: BorderRadius.circular(8),
                                  ),
                              child: TextButton.icon(
                                onPressed: () {
                                  // navigate to Sync Status Details page
                                  Get.to(() => const SyncStatusDetailsPage());
                                },
                                icon: const Icon(Icons.arrow_forward, size: 16),
                                label: const Text('View Details'),
                              )),
                            ],
                          ),
                    const SizedBox(height: 12),
                    // status boxes
                    Column(
                      children: [
                        Container(
                          width: double.infinity,
                          padding: const EdgeInsets.all(12),
                          margin: const EdgeInsets.only(bottom: 8),
                          decoration: BoxDecoration(
                            color: Colors.green.shade50,
                            borderRadius: BorderRadius.circular(8),
                            border: Border.all(color: Colors.green.shade100),
                          ),
                          child: Row(
                            children: [
                              Container(
                                width: 36,
                                height: 36,
                                decoration: BoxDecoration(
                                  color: Colors.green.shade100,
                                  borderRadius: BorderRadius.circular(8),
                                ),
                                child: const Icon(Icons.check_circle, color: Colors.green),
                              ),
                              const SizedBox(width: 12),
                              Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  const Text('Synced', style: TextStyle(fontWeight: FontWeight.w600)),
                                  Text('${probeCtrl.success.value} sources', style: const TextStyle(color: Colors.black54)),
                                ],
                              ),
                            ],
                          ),
                        ),
                        Container(
                          width: double.infinity,
                          padding: const EdgeInsets.all(12),
                          margin: const EdgeInsets.only(bottom: 8),
                          decoration: BoxDecoration(
                            color: Colors.lightGreen.shade50,
                            borderRadius: BorderRadius.circular(8),
                            border: Border.all(color: Colors.lightGreen.shade100),
                          ),
                          child: Row(
                            children: [
                              Container(
                                width: 36,
                                height: 36,
                                decoration: BoxDecoration(
                                  color: Colors.lightGreen.shade100,
                                  borderRadius: BorderRadius.circular(8),
                                ),
                                child: const Icon(Icons.sync, color: Colors.lightGreen),
                              ),
                              const SizedBox(width: 12),
                              Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  const Text('Syncing', style: TextStyle(fontWeight: FontWeight.w600)),
                                  Text('${probeCtrl.processing.value} source', style: const TextStyle(color: Colors.black54)),
                                ],
                              ),
                            ],
                          ),
                        ),
                        Container(
                          width: double.infinity,
                          padding: const EdgeInsets.all(12),
                          margin: const EdgeInsets.only(bottom: 8),
                          decoration: BoxDecoration(
                            color: Colors.red.shade50,
                            borderRadius: BorderRadius.circular(8),
                            border: Border.all(color: Colors.red.shade100),
                          ),
                          child: Row(
                            children: [
                              Container(
                                width: 36,
                                height: 36,
                                decoration: BoxDecoration(
                                  color: Colors.red.shade100,
                                  borderRadius: BorderRadius.circular(8),
                                ),
                                child: const Icon(Icons.error_outline, color: Colors.red),
                              ),
                              const SizedBox(width: 12),
                              Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  const Text('Errors', style: TextStyle(fontWeight: FontWeight.w600)),
                                  Text('${probeCtrl.failed.value} source', style: const TextStyle(color: Colors.black54)),
                                ],
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Row(
                          children: [
                            const Icon(Icons.timeline, size: 18, color: Colors.black54),
                            const SizedBox(width: 8),
                            const Text('Last sync activity', style: TextStyle(color: Colors.black54)),
                          ],
                        ),
                        Flexible(
      child: Text(
                            probeCtrl.lastSyncAt.value == null
                                ? 'Never'
                                : probeCtrl.lastSyncAt.value!.toLocal().toString(),
                            textAlign: TextAlign.right,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(color: Colors.black87),
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            );
          }),
          const SizedBox(height: 16),
          const SizedBox(height: 32),
        ],
      ),
    );
  }
}


import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:caleesync/common/app_constant.dart';
import 'package:caleesync/common/utils/mmkv_utils.dart';
import 'package:caleesync/data/sync_repository.dart';
import '../controllers/CalendarPageController.dart';
import '../controllers/calendar_probe_controller.dart';
import 'sync_status_details_page.dart';
import '../feature/public_subscriptions_page.dart';

class DashboardPage extends StatefulWidget {
  const DashboardPage({super.key});

  @override
  State<DashboardPage> createState() => _DashboardPageState();
}

class _DashboardPageState extends State<DashboardPage> {
  final SyncRepository _repo = SyncRepository();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _requestCalendarPermission();
    });
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
          // Subscribed Calee Calendars card
          Card(
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text('Subscribed Calee Calendars', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
                  const SizedBox(height: 6),
                  const Text('Public calendars you\'re subscribed to', style: TextStyle(color: Colors.black54)),
                  const SizedBox(height: 12),
                  SizedBox(
                    width: double.infinity,
                    child: ElevatedButton.icon(
                      onPressed: () {
                        Get.to(() => const PublicSubscriptionsGetxPage());
                      },
                      icon: const Icon(Icons.add, size: 16),
                      label: const Text('Subscribe to Calee Calendar'),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: const Color(0xFF2563EB),
                        foregroundColor: Colors.white,
                        padding: const EdgeInsets.symmetric(vertical: 12),
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                      ),
                    ),
                  ),
                    const SizedBox(height: 12),
                    // Subscribed list (from probe controller)
                    Obx(() {
                      final list = Get.find<CalendarProbeController>().subscribedCalendars;
                      if (list.isEmpty) return const SizedBox.shrink();
                      return Column(
                        children: list.map((m) {
                          final title = (m['display_name'] ?? m['displayName'] ?? '').toString();
                          final owner = (m['account_name'] ?? '').toString();
                          final events = (m['event_count'] ?? m['eventCount'] ?? 0).toString();
                          // final isActive = (m['sync_status'] == 1);
                          Color iconColor = Colors.blue;
                          try {
                            final col = m['color'];
                            if (col != null) {
                              if (col is int) iconColor = Color(col);
                              else if (col is String) {
                                final t = col.replaceAll('#', '');
                                final p = int.tryParse(t, radix: 16);
                                if (p != null) iconColor = Color(0xFF000000 | p);
                              }
                            }
                          } catch (_) {}

                          return Container(
                            margin: const EdgeInsets.only(bottom: 12),
                            decoration: BoxDecoration(
                              borderRadius: BorderRadius.circular(10),
                              border: Border.all(color: Colors.grey.shade200),
                              color: Colors.white,
                            ),
                            child: ListTile(
                              leading: Container(
                                width: 44,
                                height: 44,
                                decoration: BoxDecoration(color: iconColor, borderRadius: BorderRadius.circular(8)),
                                child: const Icon(Icons.calendar_today, color: Colors.white),
                              ),
                              title: Text(title, style: const TextStyle(fontWeight: FontWeight.w600)),
                              subtitle: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  const SizedBox(height: 4),
                                  Text('By ${owner.isEmpty ? 'Calee Official' : owner} • $events events', style: const TextStyle(color: Colors.black54)),
                                ],
                              ),
                              trailing: Container(
                                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                                decoration: BoxDecoration(
                                  color:  Colors.green.shade50,
                                  borderRadius: BorderRadius.circular(20),
                                ),
                                child: Text('Active', style: TextStyle(color:   Colors.green  )),
                              ),
                            ),
                          );
                        }).toList(),
                      );
                    }),

                ],
              ),
            ),
          ),
          const SizedBox(height: 16),
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
                            color: Colors.blue.shade50,
                            borderRadius: BorderRadius.circular(8),
                            border: Border.all(color: Colors.blue.shade100),
                          ),
                          child: Row(
                            children: [
                              Container(
                                width: 36,
                                height: 36,
                                decoration: BoxDecoration(
                                  color: Colors.blue.shade100,
                                  borderRadius: BorderRadius.circular(8),
                                ),
                                child: const Icon(Icons.sync, color: Colors.blue),
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
                    const SizedBox(height: 8),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Row(
                          children: [
                            const Icon(Icons.wifi, size: 18, color: Colors.black54),
                            const SizedBox(width: 8),
                            const Text('Sync mode', style: TextStyle(color: Colors.black54)),
                          ],
                        ),
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                          decoration: BoxDecoration(
                            color: Colors.grey.shade100,
                            borderRadius: BorderRadius.circular(12),
                          ),
                          child: Text(probeCtrl.syncMode.value, style: const TextStyle(fontSize: 12)),
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


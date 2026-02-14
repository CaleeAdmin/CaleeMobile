import 'package:caleesync/core/platform/pigeon/calendar_api.g.dart';
import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:caleesync/common/widget/calendar_options_dialog.dart';

import '../controllers/CalendarPageController.dart';
import '../data/database_helper.dart';

class CalendarPage extends StatefulWidget {
  const CalendarPage({super.key});

  @override
  State<CalendarPage> createState() => _CalendarPageState();
}

class _CalendarPageState extends State<CalendarPage> {
  late final CalendarPageController controller;

  @override
  void initState() {
    super.initState();
    controller = Get.put(CalendarPageController());
    _requestPermissionAndRefresh();
  }

  Future<void> _requestPermissionAndRefresh() async {
    try {
      Permission calendarPermission = Permission.calendar;
      var status = await calendarPermission.status;
      if (status.isPermanentlyDenied) {
        openAppSettings();
        return;
      }

      if (!status.isGranted) {
        status = await calendarPermission.request();
      }

      if (status.isGranted) {
        // try {
        //   final nativeApi = NativeCalendarApi();
        //   await nativeApi.requestPermission(false);
        // } catch (_) {}

        // 仅在尚未加载数据时才触发一次刷新，避免每次切换 tab 重复刷新
        if (controller.calendarGroups.isEmpty && !controller.isLoading.value) {
          await controller.refreshDashboard();
        }
      } else {
        // 未授权，暂不刷新
      }
    } catch (e) {
      print('⚠️ 请求日历权限时出错: $e');
      await controller.refreshDashboard();
    }
  }

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Obx(() {
        if (controller.isLoading.value) {
          return const Center(child: CircularProgressIndicator());
        }

        final groups = controller.calendarGroups;
        if (groups.isEmpty) {
          return RefreshIndicator(
            onRefresh: controller.refreshDashboard,
            child: ListView(
              children: const [
                SizedBox(height: 120),
                Center(child: Text('No calendars found')),
              ],
            ),
          );
        }

        return RefreshIndicator(
          onRefresh: controller.refreshDashboard,
          child: ListView.builder(
            padding: const EdgeInsets.all(16),
            itemCount: groups.length,
            itemBuilder: (context, gi) {
              final group = groups[gi];
              return _AccountCard(group: group);
            },
          ),
        );
      }),
    );
  }
}

extension on _CalendarRow {
  Future<void> _handleOptionResult(String result, BuildContext context, CalendarDisplayItem item, CalendarPageController controller) async {
    switch (result) {
      case 'rename':
        final bool? confirm = await _showRenameDialog(context, item);
        // 刷新数据（保持原行为）
        if (confirm == true) {
          await controller.refreshDashboard();
        }
        break;
      case 'delete':
        final bool? confirm = await _showDeleteConfirm(context);
        if (confirm == true) {
          try {
            await controller.deleteCalendarTotally(item.localId);
          } catch (_) {}
        }
        break;
      case 'properties':
        Get.snackbar('Action', 'Properties ${item.name}');
        break;
    }
  }

  Future<bool?> _showDeleteConfirm(BuildContext context) {
    return showDialog<bool>(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: const Text('Delete Calendar'),
          content: const Text(
            'Are you sure you want to delete this calendar? '
            'This action cannot be undone and all events in this calendar will be permanently deleted.',
            style: TextStyle(fontSize: 14),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: const Text('Cancel', style: TextStyle(color: Colors.black)),
            ),
            ElevatedButton(
              style: ElevatedButton.styleFrom(
                backgroundColor: Colors.red,
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(6)),
              ),
              onPressed: () => Navigator.of(context).pop(true),
              child: const Text('Delete', style: TextStyle(color: Colors.white)),
            ),
          ],
        );
      },
    );
  }

  Future<bool?> _showRenameDialog(BuildContext context, CalendarDisplayItem item) {
    final TextEditingController _nameCtrl = TextEditingController(text: item.name);
    return showDialog<bool>(
      context: context,
      builder: (context) {
        return Dialog(
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    const Text('Rename Calendar', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600)),
                    IconButton(
                      icon: const Icon(Icons.close),
                      onPressed: () => Navigator.of(context).pop(false),
                    )
                  ],
                ),
                const SizedBox(height: 8),
                const Text('Enter a new name for this calendar', style: TextStyle(color: Colors.black54)),
                const SizedBox(height: 12),
                Align(
                  alignment: Alignment.centerLeft,
                  child: Text('Calendar Name', style: TextStyle(fontSize: 13, color: Colors.black54)),
                ),
                const SizedBox(height: 6),
                TextField(
                  controller: _nameCtrl,
                  decoration: InputDecoration(
                    border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
                    isDense: true,
                  ),
                ),
                const SizedBox(height: 14),
                SizedBox(
                  width: double.infinity,
                  child: ElevatedButton(
                    style: ElevatedButton.styleFrom(
                      backgroundColor: Colors.black,
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                    ),
                    child: const Text('Rename',style: TextStyle(color: Colors.white),),
                    onPressed: () async {
                      final newName = _nameCtrl.text.trim();
                      if (newName.isEmpty) return;
                      try {
                        await Get.find<CalendarPageController>().renameCalendar(item.localId, newName);
                        Navigator.of(context).pop(true);
                      } catch (e) {
                        Navigator.of(context).pop(false);
                      }
                    },
                  ),
                ),
                const SizedBox(height: 8),
                SizedBox(
                  width: double.infinity,
                  child: OutlinedButton(
                    style: OutlinedButton.styleFrom(
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                    ),
                    child: const Text('Cancel',style: TextStyle(color: Colors.black)),
                    onPressed: () => Navigator.of(context).pop(false),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}
class _AccountCard extends StatelessWidget {
  final CalendarGroup group;
  const _AccountCard({required this.group});

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: const EdgeInsets.only(bottom: 16),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Row(
                  children: [
                    Text(
                      group.accountName,
                      style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
                    ),
                    const SizedBox(width: 8),
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                      decoration: BoxDecoration(
                        color: Colors.grey.shade100,
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: Text('${group.calendars.length} calendars',
                          style: const TextStyle(fontSize: 12, color: Colors.black54)),
                    ),
                  ],
                ),
              ],
            ),
            // Nextcloud specific quick actions
            if (group.accountName == 'NextCloud') ...[
              const SizedBox(height: 12),
              SizedBox(
                width: double.infinity,
                child: OutlinedButton.icon(
                  onPressed: () async {
                    final TextEditingController _newCalCtrl = TextEditingController();
                    final res = await showDialog<bool>(
                      context: context,
                      builder: (context) {
                        return Dialog(
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                          child: Padding(
                            padding: const EdgeInsets.all(16),
                            child: Column(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Row(
                                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                                  children: [
                                    const Text('New Calendar', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600)),
                                    IconButton(
                                      icon: const Icon(Icons.close),
                                      onPressed: () => Navigator.of(context).pop(false),
                                    )
                                  ],
                                ),
                                const SizedBox(height: 8),
                                const Text('Create a new calendar in your Calee account', style: TextStyle(color: Colors.black54)),
                                const SizedBox(height: 12),
                                Align(
                                  alignment: Alignment.centerLeft,
                                  child: Text('Calendar Name', style: TextStyle(fontSize: 13, color: Colors.black54)),
                                ),
                                const SizedBox(height: 6),
                                TextField(
                                  controller: _newCalCtrl,
                                  decoration: InputDecoration(
                                    border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
                                    isDense: true,
                                    hintText: 'Enter calendar name',
                                  ),
                                ),
                                const SizedBox(height: 14),
                                SizedBox(
                                  width: double.infinity,
                                  child: ElevatedButton(
                                    style: ElevatedButton.styleFrom(
                                      backgroundColor: Colors.black,
                                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                                    ),
                                    child: const Text('Confirm', style: TextStyle(color: Colors.white)),
                                    onPressed: () async {
                                      final nm = _newCalCtrl.text.trim();
                                      if (nm.isEmpty) return;
                                      // 调用 controller 的方法创建新日历
                                      final ok = await Get.find<CalendarPageController>().createNewLocalCalendar(nm);
                                      if (ok) {
                                        Navigator.of(context).pop(true);
                                      } else {
                                        Navigator.of(context).pop(false);
                                      }
                                    },
                                  ),
                                ),
                                const SizedBox(height: 8),
                                SizedBox(
                                  width: double.infinity,
                                  child: OutlinedButton(
                                    style: OutlinedButton.styleFrom(
                                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                                    ),
                                    child: const Text('Cancel', style: TextStyle(color: Colors.black)),
                                    onPressed: () => Navigator.of(context).pop(false),
                                  ),
                                ),
                              ],
                            ),
                          ),
                        );
                      },
                    );
                    if (res == true) {
                      Get.snackbar('Created', 'New calendar created (placeholder)');
                      // TODO: actually create calendar via repository
                    }
                  },
                  icon: const Icon(Icons.add, size: 16),
                  label: const Text('New Calendar'),
                  style: OutlinedButton.styleFrom(
                    padding: const EdgeInsets.symmetric(vertical: 12),
                    side: BorderSide(color: Colors.grey.shade300),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                    foregroundColor: Colors.black87,
                  ),
                ),
              ),
              const SizedBox(height: 8),
              SizedBox(
                width: double.infinity,
                child: OutlinedButton.icon(
                  onPressed: () {
                    // 弹出订阅链接对话框
                    showDialog<bool>(
                      context: context,
                      builder: (context) {
                        final TextEditingController _urlCtrl = TextEditingController(text: 'https://example.com/calendar.ics');
                        return Dialog(
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                          child: Padding(
                            padding: const EdgeInsets.all(16),
                            child: Column(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Row(
                                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                                  children: [
                                    const Text('New Subscription from Link', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600)),
                                    IconButton(
                                      icon: const Icon(Icons.close),
                                      onPressed: () => Navigator.of(context).pop(false),
                                    )
                                  ],
                                ),
                                const SizedBox(height: 8),
                                const Text('Subscribe to a read-only calendar using a URL', style: TextStyle(color: Colors.black54)),
                                const SizedBox(height: 12),
                                Align(
                                  alignment: Alignment.centerLeft,
                                  child: Text('Calendar URL', style: TextStyle(fontSize: 13, color: Colors.black54)),
                                ),
                                const SizedBox(height: 6),
                                TextField(
                                  controller: _urlCtrl,
                                  decoration: InputDecoration(
                                    border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
                                    isDense: true,
                                  ),
                                ),
                                const SizedBox(height: 14),
                                SizedBox(
                                  width: double.infinity,
                                  child: ElevatedButton(
                                    style: ElevatedButton.styleFrom(
                                      backgroundColor: Colors.black,
                                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                                    ),
                                    child: const Text('Confirm', style: TextStyle(color: Colors.white)),
                                    onPressed: () async {
                                      final url = _urlCtrl.text.trim();
                                      if (url.isEmpty) return;
                                      // 调用 controller 的订阅方法
                                      final ok = await Get.find<CalendarPageController>().subscribePublicIcs(url);
                                      if (ok) {
                                        Navigator.of(context).pop(true);
                                      } else {
                                        Navigator.of(context).pop(false);
                                      }
                                    },
                                  ),
                                ),
                                const SizedBox(height: 8),
                                SizedBox(
                                  width: double.infinity,
                                  child: OutlinedButton(
                                    style: OutlinedButton.styleFrom(
                                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                                    ),
                                    child: const Text('Cancel', style: TextStyle(color: Colors.black)),
                                    onPressed: () => Navigator.of(context).pop(false),
                                  ),
                                ),
                              ],
                            ),
                          ),
                        );
                      },
                    );
                  },
                  icon: const Icon(Icons.add, size: 16),
                  label: const Text('New subscription'),
                  style: OutlinedButton.styleFrom(
                    padding: const EdgeInsets.symmetric(vertical: 12),
                    side: BorderSide(color: Colors.grey.shade300),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                    foregroundColor: Colors.black87,
                  ),
                ),
              ),
            ],
            const SizedBox(height: 12),
            Column(
              children: group.calendars
                  .map(
                    (c) => _CalendarRow(
                      key: ValueKey(c.remotePath ?? c.localId ?? c.name),
                      item: c,
                    ),
                  )
                  .toList(),
            ),
          ],
        ),
      ),
    );
  }
}

class _CalendarRow extends StatelessWidget {
  final CalendarDisplayItem item;
  const _CalendarRow({Key? key, required this.item}) : super(key: key);

  Color _parseColor(String hex) {
    try {
      final cleaned = hex.replaceAll('#', '');
      final intColor = int.parse(cleaned, radix: 16);
      return Color(0xFF000000 | intColor);
    } catch (_) {
      return Colors.grey;
    }
  }

  @override
  Widget build(BuildContext context) {
    final color = _parseColor(item.color);
    final controller = Get.find<CalendarPageController>();
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Row(
        children: [
          // 使用 item.isSelected（非响应式），由外层列表刷新驱动 UI 更新
          Checkbox(
            value: item.isEnabled,
            onChanged: (bool? newValue) {
              controller.toggleCalendarSelection(item, newValue);
            },
          ),
          Container(
            width: 12,
            height: 12,
            decoration: BoxDecoration(color: color, borderRadius: BorderRadius.circular(3)),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SizedBox(height: 44, child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        item.name,
                        style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
                      ),
                    ),
                    IconButton(
                      icon: const Icon(Icons.more_vert, size: 18),
                      onPressed: () async {
                        final result = await showDialog<String>(
                          context: context,
                          builder: (c) => CalendarOptionsDialog(item: item),
                        );

                        if (result == null) return;
                        await _handleOptionResult(result, context, item, controller);
                      },
                    ),
                  ],
                )),
                Container(
                  padding: const EdgeInsets.symmetric(
                      horizontal: 4, vertical: 4),
                      decoration: BoxDecoration(
                        color: Colors.grey.shade300,
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Text(
                        item.isReadOnly ? 'Read-only in Calee' : 'Two-way sync',
                        style: const TextStyle(fontSize: 12, color: Colors.black54),
                      ),
                    ),
                // const SizedBox(width: 12),
                    Text('${item.eventCount} events', style: const TextStyle(fontSize: 12, color: Colors.black54)),

              ],
            ),
          ),
        ],
      ),
    );
  }
}


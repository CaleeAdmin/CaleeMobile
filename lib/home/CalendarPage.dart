import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:caleesync/common/widget/calendar_options_dialog.dart';
import 'package:caleesync/feature/local_calendars_page.dart';
import 'package:caleesync/feature/public_subscriptions_page.dart';
import 'package:caleesync/core/platform/pigeon/calendar_api.g.dart';

import '../controllers/CalendarPageController.dart';
import '../sync/SyncEnum.dart';
import '../sync/sync_gate_reason.dart';

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

      // Also request native calendar permission (required for iOS EventKit)
      try {
        final nativeApi = NativeCalendarApi();
        await nativeApi.requestPermission(false);
      } catch (e) {
        print('[WARN] Failed to request native calendar permission: $e');
      }
      await controller.refreshDashboard();
    } catch (e) {
      print('[WARN] Error while requesting calendar permission: $e');
      await controller.refreshDashboard();
    }
  }

  Future<void> _showQuickActionsSheet() async {
    await showModalBottomSheet<void>(
      context: context,
      builder: (sheetContext) {
        return SafeArea(
          child: Wrap(
            children: [
              ListTile(
                leading: const Icon(Icons.add),
                title: const Text('New Calendar'),
                onTap: () async {
                  Navigator.of(sheetContext).pop();
                  final TextEditingController newCalCtrl = TextEditingController();
                  final ValueNotifier<bool> isSubmitting = ValueNotifier<bool>(false);
                  final res = await showDialog<bool>(
                    context: context,
                    builder: (dialogContext) {
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
                                    onPressed: () => Navigator.of(dialogContext).pop(false),
                                  )
                                ],
                              ),
                              const SizedBox(height: 8),
                              const Text('Create a new calendar in your Calee account', style: TextStyle(color: Colors.black54)),
                              const SizedBox(height: 12),
                              const Align(
                                alignment: Alignment.centerLeft,
                                child: Text('Calendar Name', style: TextStyle(fontSize: 13, color: Colors.black54)),
                              ),
                              const SizedBox(height: 6),
                              TextField(
                                controller: newCalCtrl,
                                decoration: InputDecoration(
                                  border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
                                  isDense: true,
                                  hintText: 'Enter calendar name',
                                ),
                              ),
                              const SizedBox(height: 14),
                              SizedBox(
                                width: double.infinity,
                                child: ValueListenableBuilder<bool>(
                                  valueListenable: isSubmitting,
                                  builder: (context, submitting, _) {
                                    return ElevatedButton(
                                      style: ElevatedButton.styleFrom(
                                        backgroundColor: Colors.black,
                                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                                      ),
                                      onPressed: submitting
                                          ? null
                                          : () async {
                                              isSubmitting.value = true;
                                              final nm = newCalCtrl.text.trim();
                                              final ok = await Get.find<CalendarPageController>().createRemoteCalendarDraft(nm);
                                              isSubmitting.value = false;
                                              if (ok) {
                                                Navigator.of(dialogContext).pop(true);
                                              } else {
                                                Navigator.of(dialogContext).pop(false);
                                              }
                                            },
                                      child: submitting
                                          ? const SizedBox(
                                              width: 18,
                                              height: 18,
                                              child: CircularProgressIndicator(
                                                strokeWidth: 2,
                                                valueColor: AlwaysStoppedAnimation<Color>(Colors.white),
                                              ),
                                            )
                                          : const Text('Confirm', style: TextStyle(color: Colors.white)),
                                    );
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
                                  onPressed: () => Navigator.of(dialogContext).pop(false),
                                ),
                              ),
                            ],
                          ),
                        ),
                      );
                    },
                  );
                  if (res == true) {
                    Get.snackbar('Created', 'New calendar created. Enable sync to connect it locally');
                  }
                },
              ),
              ListTile(
                leading: const Icon(Icons.add_link),
                title: const Text('New subscription'),
                onTap: () {
                  Navigator.of(sheetContext).pop();
                  showDialog<bool>(
                    context: context,
                    builder: (dialogContext) {
                      final TextEditingController urlCtrl = TextEditingController();
                      final ValueNotifier<bool> isSubmitting = ValueNotifier<bool>(false);
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
                                    onPressed: () => Navigator.of(dialogContext).pop(false),
                                  )
                                ],
                              ),
                              const SizedBox(height: 8),
                              const Text('Subscribe to a read-only calendar using a URL', style: TextStyle(color: Colors.black54)),
                              const SizedBox(height: 12),
                              const Align(
                                alignment: Alignment.centerLeft,
                                child: Text('Calendar URL', style: TextStyle(fontSize: 13, color: Colors.black54)),
                              ),
                              const SizedBox(height: 6),
                              TextField(
                                controller: urlCtrl,
                                decoration: InputDecoration(
                                  border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
                                  isDense: true,
                                  hintText: 'https://example.com/calendar.ics',
                                ),
                              ),
                              const SizedBox(height: 14),
                              SizedBox(
                                width: double.infinity,
                                child: ValueListenableBuilder<bool>(
                                  valueListenable: isSubmitting,
                                  builder: (context, submitting, _) {
                                    return ElevatedButton(
                                      style: ElevatedButton.styleFrom(
                                        backgroundColor: Colors.black,
                                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                                      ),
                                      onPressed: submitting
                                          ? null
                                          : () async {
                                              isSubmitting.value = true;
                                              final url = urlCtrl.text.trim();
                                              final ok = await Get.find<CalendarPageController>().subscribePublicIcs(url);
                                              isSubmitting.value = false;
                                              if (ok) {
                                                Navigator.of(dialogContext).pop(true);
                                              } else {
                                                Navigator.of(dialogContext).pop(false);
                                              }
                                            },
                                      child: submitting
                                          ? const SizedBox(
                                              width: 18,
                                              height: 18,
                                              child: CircularProgressIndicator(
                                                strokeWidth: 2,
                                                valueColor: AlwaysStoppedAnimation<Color>(Colors.white),
                                              ),
                                            )
                                          : const Text('Confirm', style: TextStyle(color: Colors.white)),
                                    );
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
                                  onPressed: () => Navigator.of(dialogContext).pop(false),
                                ),
                              ),
                            ],
                          ),
                        ),
                      );
                    },
                  );
                },
              ),
              ListTile(
                leading: const Icon(Icons.public),
                title: const Text('Subscribe to Calee Calendar'),
                onTap: () {
                  Navigator.of(sheetContext).pop();
                  Get.to(() => const PublicSubscriptionsGetxPage());
                },
              ),
              ListTile(
                leading: const Icon(Icons.link),
                title: const Text('Link to Device Calendar'),
                onTap: () {
                  Navigator.of(sheetContext).pop();
                  Get.to(() => const LocalCalendarsPage());
                },
              ),
            ],
          ),
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      floatingActionButton: FloatingActionButton(
        onPressed: _showQuickActionsSheet,
        child: const Icon(Icons.add),
      ),
      body: SafeArea(
        child: Obx(() {
          if (controller.isLoading.value) {
            return const Center(child: CircularProgressIndicator());
          }

          final calendars = controller.calendars;
          if (calendars.isEmpty) {
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
            child: ListView(
              padding: const EdgeInsets.all(16),
              children: [
                _CalendarCard(calendars: calendars),
              ],
            ),
          );
        }),
      ),
    );
  }

}

extension on _CalendarRow {
  String _formatError(Object error) {
    return error.toString().replaceFirst('Exception: ', '');
  }

  String _provenanceLabel(int originKind) {
    switch (originKind) {
      case SyncBindingOrigin.local:
        return 'Local-seeded';
      case SyncBindingOrigin.remote:
        return 'Remote-created';
      default:
        return 'Unknown';
    }
  }

  String _bindingRoleLabel(int bindingRole) {
    switch (bindingRole) {
      case SyncBindingRole.ownerLink:
        return 'Owner link';
      case SyncBindingRole.mirror:
        return 'Mirror';
      default:
        return 'Unknown';
    }
  }

  Future<void> _handleOptionResult(String result, BuildContext context, CalendarDisplayItem item, CalendarPageController controller) async {
    switch (result) {
      case 'rename':
        final bool? confirm = await _showRenameDialog(context, item);
        // 刷新数据（保持原行为）
        if (confirm == true) {
          await controller.reloadCalendars();
        }
        break;
      case 'delete':
        final bool? confirm = await _showDeleteConfirm(context);
        if (confirm == true) {
          try {
            await controller.deleteCalendarTotally(localId: item.localId, remotePath: item.remotePath);
          } catch (e) {
            if (!context.mounted) return;
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(content: Text('Delete failed: ${_formatError(e)}')),
            );
          }
        }
        break;
      case 'properties':
        await _showPropertiesPanel(context, item);
        break;
    }
  }

  Future<void> _showPropertiesPanel(BuildContext context, CalendarDisplayItem item) {
    return showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (panelContext) {
        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  item.name,
                  style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w700),
                ),
                const SizedBox(height: 16),
                _propertyRow('Events', '${item.eventCount}'),
                _propertyRow('Sync Mode', item.isReadOnly ? 'Read-only' : 'Two-way sync'),
                _propertyRow('Enabled', item.isEnabled ? 'Yes' : 'No'),
                _propertyRow('Color', item.color),
                _propertyRow('Provenance', _provenanceLabel(item.origin)),
                _propertyRow('This Device Role', _bindingRoleLabel(item.bindingRole)),
                if ((item.originKey ?? '').isNotEmpty)
                  _propertyRow('Origin Key', item.originKey!),
                if ((item.remotePath ?? '').isNotEmpty)
                  _propertyRow('Remote Path', item.remotePath!),
                if ((item.localId ?? '').isNotEmpty)
                  _propertyRow('Local ID', item.localId!),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _propertyRow(String label, String value) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 110,
            child: Text(
              label,
              style: const TextStyle(
                fontSize: 13,
                color: Colors.black54,
                fontWeight: FontWeight.w500,
              ),
            ),
          ),
          Expanded(
            child: Text(
              value,
              style: const TextStyle(fontSize: 14, color: Colors.black87),
            ),
          ),
        ],
      ),
    );
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
    bool isRenaming = false;
    return showDialog<bool>(
      context: context,
      builder: (context) {
        return StatefulBuilder(
          builder: (context, setState) => Dialog(
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
                        onPressed: isRenaming ? null : () => Navigator.of(context).pop(false),
                      )
                    ],
                  ),
                  const SizedBox(height: 8),
                  const Text('Enter a new name for this calendar', style: TextStyle(color: Colors.black54)),
                  const SizedBox(height: 6),
                  const Text(
                    'Renaming affects the Calee/remote calendar. Depending on how this calendar is linked, your device calendar name may stay unchanged.',
                    style: TextStyle(color: Colors.black54, fontSize: 12),
                  ),
                  const SizedBox(height: 12),
                  Align(
                    alignment: Alignment.centerLeft,
                    child: Text('Calendar Name', style: TextStyle(fontSize: 13, color: Colors.black54)),
                  ),
                  const SizedBox(height: 6),
                  TextField(
                    controller: _nameCtrl,
                    enabled: !isRenaming,
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
                      onPressed: isRenaming
                          ? null
                          : () async {
                              final newName = _nameCtrl.text.trim();
                              final String? invalidReason = Get.find<CalendarPageController>().validateNewCalendarName(newName);
                              if (invalidReason != null) {
                                ScaffoldMessenger.of(context).showSnackBar(
                                  SnackBar(content: Text(invalidReason)),
                                );
                                return;
                              }
                              if (newName == item.name.trim()) {
                                Navigator.of(context).pop(false);
                                return;
                              }
                              setState(() => isRenaming = true);
                              try {
                                await Get.find<CalendarPageController>().renameCalendar(item.localId, item.remotePath, newName);
                                Navigator.of(context).pop(true);
                              } catch (e) {
                                if (context.mounted) {
                                  ScaffoldMessenger.of(context).showSnackBar(
                                    SnackBar(content: Text('Rename failed: ${_formatError(e)}')),
                                  );
                                }
                                Navigator.of(context).pop(false);
                              }
                            },
                      child: isRenaming
                          ? const SizedBox(
                              height: 16,
                              width: 16,
                              child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                            )
                          : const Text('Rename', style: TextStyle(color: Colors.white)),
                    ),
                  ),
                  const SizedBox(height: 8),
                  SizedBox(
                    width: double.infinity,
                    child: OutlinedButton(
                      style: OutlinedButton.styleFrom(
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                      ),
                      onPressed: isRenaming ? null : () => Navigator.of(context).pop(false),
                      child: const Text('Cancel', style: TextStyle(color: Colors.black)),
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}
class _CalendarCard extends StatelessWidget {
  final List<CalendarDisplayItem> calendars;
  const _CalendarCard({required this.calendars});

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
                      'Calee',
                      style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
                    ),
                    const SizedBox(width: 8),
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                      decoration: BoxDecoration(
                        color: Colors.grey.shade100,
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: Text('${calendars.length} calendars',
                          style: const TextStyle(fontSize: 12, color: Colors.black54)),
                    ),
                  ],
                ),
              ],
            ),
            const SizedBox(height: 12),
            Column(
              children: calendars
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


String? _syncGateReasonMessage(String? reason) {
  return SyncGateReason.toUiMessage(reason);
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
    final String key = (item.remotePath != null && item.remotePath!.isNotEmpty)
        ? item.remotePath!
        : (item.localId ?? '');
    final bool isToggling = key.isNotEmpty && controller.togglingCalendarIds.contains(key);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Row(
        children: [
          // 使用 item.isSelected（非response式）, 由外层列表刷新驱动 UI 更新
          Checkbox(
            value: item.isEnabled,
            onChanged: isToggling
                ? null
                : (bool? newValue) {
                    controller.handleCalendarEnableToggle(item, newValue);
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
                          builder: (c) => CalendarOptionsDialog(
                            item: item,
                            onTwoWayChanged: (isTwoWay) async {
                              await controller.updateCalendarSyncMode(item, isTwoWay);
                            },
                            onAllowMassDeletionChanged: (enabled) async {
                              if (!enabled) {
                                await controller.setAllowMassDeletionDangerous(item, false);
                                return true;
                              }

                              final bool? confirmed = await showDialog<bool>(
                                context: c,
                                builder: (dialogContext) => AlertDialog(
                                  title: const Text('Enable mass deletion?'),
                                  content: const Text(
                                    'This can permanently delete large amounts of data on your phone and/or server if the snapshot is incomplete.',
                                  ),
                                  actions: [
                                    TextButton(
                                      onPressed: () => Navigator.of(dialogContext).pop(false),
                                      child: const Text('Cancel'),
                                    ),
                                    FilledButton(
                                      onPressed: () => Navigator.of(dialogContext).pop(true),
                                      child: const Text('I understand, enable'),
                                    ),
                                  ],
                                ),
                              );

                              if (confirmed == true) {
                                await controller.setAllowMassDeletionDangerous(item, true);
                                return true;
                              }
                              return false;
                            },
                          ),
                        );

                        if (result == null) return;
                        await _handleOptionResult(result, context, item, controller);
                      },
                    ),
                  ],
                )),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
                  decoration: BoxDecoration(
                    color: Colors.grey.shade300,
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Text(
                    item.isReadOnly ? 'Read-only' : 'Two-way sync',
                    style: const TextStyle(fontSize: 12, color: Colors.black54),
                  ),
                ),
                if (item.hasRelinkSuggestion)
                  Padding(
                    padding: const EdgeInsets.only(top: 6),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Possible reconnection on this device',
                          style: TextStyle(fontSize: 12, color: Colors.grey.shade700),
                        ),
                        TextButton(
                          style: TextButton.styleFrom(
                            padding: EdgeInsets.zero,
                            minimumSize: const Size(0, 0),
                            tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                            alignment: Alignment.centerLeft,
                          ),
                          onPressed: () {
                            Get.to(
                              () => LocalCalendarsPage(
                                mode: LocalCalendarsPageMode.relinkReview,
                                remoteCollectionId: item.remoteCollectionId,
                                remoteDisplayName: item.name,
                                remotePath: item.remotePath,
                              ),
                            );
                          },
                          child: const Text('Review Re-link'),
                        ),
                      ],
                    ),
                  ),
                if (item.isEnabled && (_syncGateReasonMessage(item.syncGateReason) ?? '').isNotEmpty)
                  Container(
                    margin: const EdgeInsets.only(top: 4),
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                    decoration: BoxDecoration(
                      color: const Color(0xFFFFF7ED),
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(color: const Color(0xFFF59E0B)),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Icon(Icons.warning_amber_rounded, size: 14, color: Color(0xFFD97706)),
                        const SizedBox(width: 6),
                        Flexible(
                          child: Text(
                            _syncGateReasonMessage(item.syncGateReason)!,
                            style: const TextStyle(fontSize: 12, color: Color(0xFFB45309)),
                          ),
                        ),
                      ],
                    ),
                  ),
                Text('${item.eventCount} events', style: const TextStyle(fontSize: 12, color: Colors.black54)),

              ],
            ),
          ),
        ],
      ),
    );
  }
}

import 'package:flutter/material.dart';
import 'package:get/get.dart';

import '../controllers/local_calendar_page_controller.dart';

class LocalCalendarsPage extends StatefulWidget {
  const LocalCalendarsPage({
    super.key,
    this.remotePath,
    this.remoteDisplayName,
    this.remoteOriginKind,
  });

  final String? remotePath;
  final String? remoteDisplayName;
  final int? remoteOriginKind;

  bool get isRemoteScoped => remotePath != null && remotePath!.isNotEmpty;

  @override
  State<LocalCalendarsPage> createState() => _LocalCalendarsPageState();
}

class _LocalCalendarsPageState extends State<LocalCalendarsPage> {
  late final String _controllerTag;
  late final LocalCalendarPageController ctrl;

  @override
  void initState() {
    super.initState();
    _controllerTag = 'local-calendar-page-${DateTime.now().microsecondsSinceEpoch}';
    ctrl = Get.put(
      LocalCalendarPageController(
        remotePath: widget.remotePath,
        remoteDisplayName: widget.remoteDisplayName,
        remoteOriginKind: widget.remoteOriginKind,
      ),
      tag: _controllerTag,
    );
  }

  @override
  void dispose() {
    if (Get.isRegistered<LocalCalendarPageController>(tag: _controllerTag)) {
      Get.delete<LocalCalendarPageController>(tag: _controllerTag);
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        centerTitle: true,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back_ios),
          onPressed: () => Navigator.maybePop(context),
        ),
        title: Text(
          widget.isRemoteScoped ? 'Link Device Calendar' : 'Link to Device Calendar',
          style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 18),
        ),
        elevation: 0,
      ),
      body: Obx(() {
        if (ctrl.isLoading.value) {
          return const Center(child: CircularProgressIndicator());
        }

        final groups = ctrl.calendarGroups.toList();
        if (groups.isEmpty) {
          return const Center(child: Text('No device calendars found'));
        }

        return ListView(
          padding: const EdgeInsets.symmetric(vertical: 16, horizontal: 16),
          children: [
            if (ctrl.isRemoteScoped) ...[
              _RemoteScopedActionCard(controllerTag: _controllerTag),
              const SizedBox(height: 16),
            ],
            ...groups.map((group) => _AccountSection(group: group, controllerTag: _controllerTag)),
          ],
        );
      }),
    );
  }
}

class _RemoteScopedActionCard extends StatelessWidget {
  const _RemoteScopedActionCard({required this.controllerTag});

  final String controllerTag;

  @override
  Widget build(BuildContext context) {
    final controller = Get.find<LocalCalendarPageController>(tag: controllerTag);

    return Card(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      elevation: 0,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              controller.remoteDisplayName?.trim().isNotEmpty == true
                  ? 'Selected remote: ${controller.remoteDisplayName!.trim()}'
                  : 'Selected remote calendar',
              style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 8),
            const Text(
              'Choose an existing device calendar to bind, or create a new local calendar for this remote.',
              style: TextStyle(fontSize: 13, color: Color(0xFF4B5563)),
            ),
            const SizedBox(height: 12),
            SizedBox(
              width: double.infinity,
              child: ElevatedButton.icon(
                onPressed: controller.isCreatingLocalCalendar.value
                    ? null
                    : controller.createLocalForSelectedRemote,
                icon: controller.isCreatingLocalCalendar.value
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                      )
                    : const Icon(Icons.add),
                label: const Text('Create Local Calendar'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _AccountSection extends StatelessWidget {
  final LocalCalendarGroup group;
  final String controllerTag;

  const _AccountSection({required this.group, required this.controllerTag});

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(bottom: 18),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.grey.shade200),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            group.accountName,
            style: const TextStyle(
              fontSize: 16,
              fontWeight: FontWeight.w600,
              color: Colors.black87,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            '${group.calendars.length} calendar${group.calendars.length > 1 ? "s" : ""} available',
            style: const TextStyle(fontSize: 12, color: Color(0xFF6B7280)),
          ),
          const SizedBox(height: 12),
          Column(
            children: group.calendars
                .map(
                  (calendar) => Padding(
                    padding: const EdgeInsets.only(bottom: 12),
                    child: _LocalCalendarCard(calendar: calendar, controllerTag: controllerTag),
                  ),
                )
                .toList(),
          ),
        ],
      ),
    );
  }
}

class _LocalCalendarCard extends StatelessWidget {
  final LocalCalendarItem calendar;
  final String controllerTag;

  const _LocalCalendarCard({required this.calendar, required this.controllerTag});

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
    final controller = Get.find<LocalCalendarPageController>(tag: controllerTag);

    return Obx(() {
      final isConnecting = controller.connectingCalendarIds.contains(calendar.id);

      return Card(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        elevation: 0,
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                width: 56,
                height: 56,
                decoration: BoxDecoration(
                  color: _parseColor(calendar.color),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: const Center(
                  child: Icon(Icons.calendar_today, color: Colors.white),
                ),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Expanded(
                          child: Text(
                            calendar.name,
                            style: const TextStyle(
                              fontSize: 16,
                              fontWeight: FontWeight.w600,
                              color: Colors.black87,
                            ),
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        const SizedBox(width: 8),
                        calendar.isConnected
                            ? const Text(
                                'Linked',
                                style: TextStyle(
                                  fontSize: 14,
                                  fontWeight: FontWeight.w600,
                                  color: Color(0xFF16A34A),
                                ),
                              )
                            : TextButton(
                                onPressed: isConnecting
                                    ? null
                                    : () async {
                                        if (controller.isRemoteScoped) {
                                          await controller.bindRemoteToSelectedLocal(calendar);
                                          return;
                                        }
                                        await controller.linkCalendar(
                                          calendar,
                                          true,
                                          returnToCalendarListAfterConnect: true,
                                        );
                                      },
                                style: TextButton.styleFrom(
                                  backgroundColor: calendar.canRelink
                                      ? const Color(0xFF1D4ED8)
                                      : const Color(0xFF111827),
                                  foregroundColor: Colors.white,
                                  padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                                  textStyle: const TextStyle(
                                    fontSize: 13,
                                    fontWeight: FontWeight.w600,
                                  ),
                                  minimumSize: Size.zero,
                                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                                ),
                                child: isConnecting
                                    ? const SizedBox(
                                        width: 14,
                                        height: 14,
                                        child: CircularProgressIndicator(
                                          strokeWidth: 2,
                                          valueColor: AlwaysStoppedAnimation<Color>(Colors.white),
                                        ),
                                      )
                                    : Text(controller.isRemoteScoped
                                        ? 'Bind'
                                        : (calendar.canRelink ? 'Re-link' : 'Link')),
                              ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    Text(
                      calendar.isReadOnly ? 'Read-only' : 'Two-way sync',
                      style: const TextStyle(fontSize: 14, color: Color(0xFF4B5563)),
                    ),
                    const SizedBox(height: 12),
                    Text(
                      'Events: ${calendar.eventCount}',
                      style: const TextStyle(fontSize: 12, color: Color(0xFF4B5563)),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      );
    });
  }
}

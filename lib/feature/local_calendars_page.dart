import 'package:flutter/material.dart';
import 'package:get/get.dart';

import '../controllers/local_calendar_page_controller.dart';

class LocalCalendarsPage extends StatefulWidget {
  const LocalCalendarsPage({
    super.key,
    this.reconnectMode = false,
    this.targetRemotePath,
    this.targetOriginKind,
  });

  final bool reconnectMode;
  final String? targetRemotePath;
  final int? targetOriginKind;

  @override
  State<LocalCalendarsPage> createState() => _LocalCalendarsPageState();
}

class _LocalCalendarsPageState extends State<LocalCalendarsPage> {
  late final String _tag;
  late final LocalCalendarPageController _ctrl;

  @override
  void initState() {
    super.initState();
    _tag =
        'local-cal-${widget.reconnectMode}-${widget.targetRemotePath ?? ''}-${widget.targetOriginKind ?? ''}';
    _ctrl = Get.put(
      LocalCalendarPageController(
        reconnectMode: widget.reconnectMode,
        targetRemotePath: widget.targetRemotePath,
        targetOriginKind: widget.targetOriginKind,
      ),
      tag: _tag,
    );
  }

  @override
  void dispose() {
    if (Get.isRegistered<LocalCalendarPageController>(tag: _tag)) {
      Get.delete<LocalCalendarPageController>(tag: _tag, force: true);
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final String title = widget.reconnectMode ? 'Reconnect calendar' : 'Link to Device Calendar';

    return Scaffold(
      appBar: AppBar(
        centerTitle: true,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back_ios),
          onPressed: () => Navigator.maybePop(context),
        ),
        title: Text(
          title,
          style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 18),
        ),
        elevation: 0,
      ),
      body: Obx(() {
        if (_ctrl.isLoading.value) {
          return const Center(child: CircularProgressIndicator());
        }

        final groups = _ctrl.calendarGroups.toList();
        if (groups.isEmpty) {
          return Center(
            child: Text(widget.reconnectMode ? 'No reconnect candidates found' : 'No device calendars found'),
          );
        }

        return ListView.builder(
          padding: const EdgeInsets.symmetric(vertical: 16, horizontal: 16),
          itemCount: groups.length,
          itemBuilder: (context, index) {
            return _AccountSection(
              group: groups[index],
              controllerTag: _tag,
              reconnectMode: widget.reconnectMode,
            );
          },
        );
      }),
    );
  }
}

class _AccountSection extends StatelessWidget {
  final LocalCalendarGroup group;
  final String controllerTag;
  final bool reconnectMode;

  const _AccountSection({
    required this.group,
    required this.controllerTag,
    required this.reconnectMode,
  });

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
                    child: _LocalCalendarCard(
                      calendar: calendar,
                      controllerTag: controllerTag,
                      reconnectMode: reconnectMode,
                    ),
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
  final bool reconnectMode;

  const _LocalCalendarCard({
    required this.calendar,
    required this.controllerTag,
    required this.reconnectMode,
  });

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
      final bool hideBecauseConnected = reconnectMode && calendar.isConnected;
      if (hideBecauseConnected) {
        return const SizedBox.shrink();
      }

      final String actionLabel = reconnectMode ? 'Reconnect' : (calendar.canRelink ? 'Reconnect' : 'Link');

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
                        calendar.isConnected && !reconnectMode
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
                                        await controller.linkCalendar(
                                          calendar,
                                          true,
                                          returnToCalendarListAfterConnect: true,
                                        );
                                      },
                                style: TextButton.styleFrom(
                                  backgroundColor: reconnectMode || calendar.canRelink
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
                                    : Text(actionLabel),
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

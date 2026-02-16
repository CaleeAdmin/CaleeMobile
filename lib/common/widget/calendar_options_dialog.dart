import 'package:flutter/material.dart';
import 'package:caleesync/core/platform/pigeon/calendar_api.g.dart';

import '../../controllers/CalendarPageController.dart';

class CalendarOptionsDialog extends StatefulWidget {
  final CalendarDisplayItem item;
  const CalendarOptionsDialog({required this.item, super.key});

  @override
  State<CalendarOptionsDialog> createState() => _CalendarOptionsDialogState();
}

class _CalendarOptionsDialogState extends State<CalendarOptionsDialog> {
  late bool isTwoWay;
  late bool isRenameDisabled;
  late bool isTwoWayDisabled;

  @override
  void initState() {
    super.initState();
    isTwoWay = widget.item.isReadOnly;
    isTwoWayDisabled = widget.item.isReadOnly || widget.item.isSubscription || widget.item.isLocalReadOnly;
    // origin: 0 = 本地初始化, 1 = 云端同步
    // 本地初始化的映射不允许在主日历页重命名
    isRenameDisabled = widget.item.origin == 0;
  }

  @override
  Widget build(BuildContext context) {
    return Dialog(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
      child: IntrinsicWidth(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // Header with checkbox
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  CheckboxListTile(
                    contentPadding: EdgeInsets.zero,
                    value: isTwoWay,
                    onChanged: isTwoWayDisabled ? null : (v) {
                      setState(() {
                        isTwoWay = v ?? false;
                      });
                    },
                    title: const Text('Two-way sync', style: TextStyle(fontWeight: FontWeight.w600)),
                    subtitle: const Text('Sync bidirectionally between Calee Online and Local device', style: TextStyle(fontSize: 12)),
                    controlAffinity: ListTileControlAffinity.leading,
                  ),
                ],
              ),
            ),
            const Divider(height: 1),
            ListTile(
              contentPadding: const EdgeInsets.fromLTRB(12, 12, 12, 4),
              title: const Text('Properties'),
              onTap: () => Navigator.of(context).pop('properties'),
            ),
            ListTile(
              title: Text(
                'Rename',
                style: TextStyle(
                  color: isRenameDisabled ? Colors.black38 : Colors.black,
                ),
              ),
              enabled: !isRenameDisabled,
              onTap: isRenameDisabled ? null : () => Navigator.of(context).pop('rename'),
            ),
            ListTile(
              title: const Text('Delete', style: TextStyle(color: Colors.red)),
              onTap: () => Navigator.of(context).pop('delete'),
            ),
          ],
        ),
      ),
    );
  }
}

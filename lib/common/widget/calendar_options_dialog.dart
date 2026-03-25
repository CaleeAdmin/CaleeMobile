import 'package:flutter/material.dart';
import '../app_constant.dart';
import '../../models/calendar_display_item.dart';

class CalendarOptionsDialog extends StatefulWidget {
  final CalendarDisplayItem item;
  final Future<void> Function(bool isTwoWay)? onTwoWayChanged;
  final Future<bool> Function(bool enabled)? onAllowMassDeletionChanged;

  const CalendarOptionsDialog({
    required this.item,
    this.onTwoWayChanged,
    this.onAllowMassDeletionChanged,
    super.key,
  });

  @override
  State<CalendarOptionsDialog> createState() => _CalendarOptionsDialogState();
}

class _CalendarOptionsDialogState extends State<CalendarOptionsDialog> {
  late bool isTwoWay;
  late bool isTwoWayDisabled;
  late bool allowMassDeletionDangerous;

  @override
  void initState() {
    super.initState();
    isTwoWay = !widget.item.isReadOnly;
    isTwoWayDisabled = widget.item.isSubscription || widget.item.isLocalReadOnly;
    allowMassDeletionDangerous = widget.item.allowMassDeletionDangerous;
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
            if (AppConstant.enableAppSync) ...[
              // Header with checkbox
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    CheckboxListTile(
                      contentPadding: EdgeInsets.zero,
                      value: isTwoWay,
                      onChanged: isTwoWayDisabled ? null : (v) async {
                        final bool nextValue = v ?? false;
                        setState(() {
                          isTwoWay = nextValue;
                        });

                        if (widget.onTwoWayChanged != null) {
                          await widget.onTwoWayChanged!(nextValue);
                        }
                      },
                      title: const Text('Two-way sync', style: TextStyle(fontWeight: FontWeight.w600)),
                      subtitle: const Text('Sync bidirectionally between Calee Online and Local device', style: TextStyle(fontSize: 12)),
                      controlAffinity: ListTileControlAffinity.leading,
                    ),
                    CheckboxListTile(
                      contentPadding: EdgeInsets.zero,
                      value: allowMassDeletionDangerous,
                      onChanged: (v) async {
                        final bool nextValue = v ?? false;
                        if (widget.onAllowMassDeletionChanged == null) return;
                        final bool applied = await widget.onAllowMassDeletionChanged!(nextValue);
                        if (!mounted) return;
                        if (applied) {
                          setState(() {
                            allowMassDeletionDangerous = nextValue;
                          });
                        }
                      },
                      title: const Text('Allow mass deletion', style: TextStyle(fontWeight: FontWeight.w600)),
                      subtitle: const Text('When off, large delete waves are blocked for both local and remote deletes.', style: TextStyle(fontSize: 12)),
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
            ],
            ListTile(
              title: Text(
                'Rename calendar',
                style: const TextStyle(color: Colors.black),
              ),
              onTap: () => Navigator.of(context).pop('rename'),
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

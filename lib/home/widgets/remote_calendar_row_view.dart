import 'package:flutter/material.dart';

import '../../models/calendar_display_item.dart';

class RemoteCalendarRowView extends StatelessWidget {
  final CalendarDisplayItem item;
  final bool isToggling;
  final Color color;
  final VoidCallback? onEnablePressed;
  final VoidCallback? onDisablePressed;
  final VoidCallback? onReviewRelinkPressed;
  final VoidCallback? onEnableAnywayPressed;
  final VoidCallback? onMorePressed;
  final String? syncGateMessage;

  const RemoteCalendarRowView({
    super.key,
    required this.item,
    required this.isToggling,
    required this.color,
    this.onEnablePressed,
    this.onDisablePressed,
    this.onReviewRelinkPressed,
    this.onEnableAnywayPressed,
    this.onMorePressed,
    this.syncGateMessage,
  });

  @override
  Widget build(BuildContext context) {
    final bool showRelinkAction = !item.isEnabled && item.hasRelinkSuggestion;
    final bool showEnableAction = !item.isEnabled && !item.hasRelinkSuggestion;
    final String normalizedSyncGateMessage = syncGateMessage?.trim() ?? '';
    final ButtonStyle compactOutlinedStyle = OutlinedButton.styleFrom(
      visualDensity: VisualDensity.compact,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      minimumSize: Size.zero,
      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
    );
    final ButtonStyle compactTextStyle = TextButton.styleFrom(
      visualDensity: VisualDensity.compact,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      minimumSize: Size.zero,
      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
    );
    final ButtonStyle compactTonalStyle = FilledButton.styleFrom(
      visualDensity: VisualDensity.compact,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      minimumSize: Size.zero,
      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
    );

    Widget buildLoadingSpinner() {
      return const SizedBox(
        width: 16,
        height: 16,
        child: CircularProgressIndicator(strokeWidth: 2),
      );
    }

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  item.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              IconButton(
                icon: const Icon(Icons.more_vert, size: 18),
                onPressed: isToggling ? null : onMorePressed,
              ),
            ],
          ),
          if (isToggling)
            Padding(
              padding: const EdgeInsets.only(bottom: 6),
              child: Text(
                'Updating...',
                style: TextStyle(fontSize: 12, color: Colors.grey.shade600),
              ),
            ),
          Wrap(
            crossAxisAlignment: WrapCrossAlignment.center,
            spacing: 8,
            runSpacing: 6,
            children: [
              Container(
                width: 12,
                height: 12,
                decoration: BoxDecoration(
                  color: color,
                  borderRadius: BorderRadius.circular(3),
                ),
              ),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                decoration: BoxDecoration(
                  color: Colors.grey.shade300,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Text(
                  item.isReadOnly ? 'Read-only' : 'Two-way sync',
                  style: const TextStyle(fontSize: 12, color: Colors.black54),
                ),
              ),
              Text(
                '${item.eventCount} events',
                style: const TextStyle(fontSize: 12, color: Colors.black54),
              ),
              if (item.isEnabled)
                Text(
                  'Connected',
                  style: TextStyle(fontSize: 12, color: Colors.grey.shade600),
                ),
            ],
          ),
          if (!item.isEnabled && item.hasRelinkSuggestion)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Text(
                'Possible reconnection on this device',
                style: TextStyle(fontSize: 12, color: Colors.grey.shade700),
              ),
            ),
          if (item.isEnabled && normalizedSyncGateMessage.isNotEmpty)
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
                  const Icon(
                    Icons.warning_amber_rounded,
                    size: 14,
                    color: Color(0xFFD97706),
                  ),
                  const SizedBox(width: 6),
                  Flexible(
                    child: Text(
                      normalizedSyncGateMessage,
                      style: const TextStyle(
                        fontSize: 12,
                        color: Color(0xFFB45309),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                if (item.isEnabled)
                  OutlinedButton(
                    onPressed: isToggling ? null : onDisablePressed,
                    style: compactOutlinedStyle,
                    child: isToggling ? buildLoadingSpinner() : const Text('Disable'),
                  ),
                if (showEnableAction)
                  FilledButton.tonal(
                    onPressed: isToggling ? null : onEnablePressed,
                    style: compactTonalStyle,
                    child: isToggling ? buildLoadingSpinner() : const Text('Enable'),
                  ),
                if (showRelinkAction) ...[
                  FilledButton.tonal(
                    onPressed: isToggling ? null : onReviewRelinkPressed,
                    style: compactTonalStyle,
                    child: const Text('Review Re-link'),
                  ),
                  TextButton(
                    onPressed: isToggling ? null : onEnableAnywayPressed,
                    style: compactTextStyle,
                    child: const Text('Enable anyway'),
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}

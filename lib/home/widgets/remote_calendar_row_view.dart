import 'package:flutter/material.dart';

import '../../controllers/CalendarPageController.dart';

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

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Row(
        children: [
          const SizedBox(width: 48),
          Container(
            width: 12,
            height: 12,
            decoration: BoxDecoration(
              color: color,
              borderRadius: BorderRadius.circular(3),
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SizedBox(
                  height: 44,
                  child: Row(
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
                      if (item.isEnabled) ...[
                        Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 8,
                            vertical: 4,
                          ),
                          decoration: BoxDecoration(
                            color: Colors.green.withOpacity(0.12),
                            borderRadius: BorderRadius.circular(999),
                          ),
                          child: const Text(
                            'Connected',
                            style: TextStyle(
                              fontSize: 12,
                              fontWeight: FontWeight.w500,
                            ),
                          ),
                        ),
                        const SizedBox(width: 8),
                        TextButton(
                          onPressed: onDisablePressed,
                          child: isToggling
                              ? const SizedBox(
                                  width: 16,
                                  height: 16,
                                  child: CircularProgressIndicator(strokeWidth: 2),
                                )
                              : const Text('Disable'),
                        ),
                        const SizedBox(width: 4),
                      ] else if (showRelinkAction) ...[
                        FilledButton(
                          onPressed: onReviewRelinkPressed,
                          child: const Text('Review Re-link'),
                        ),
                        const SizedBox(width: 4),
                      ] else if (showEnableAction) ...[
                        FilledButton.tonal(
                          onPressed: onEnablePressed,
                          child: isToggling
                              ? const SizedBox(
                                  width: 16,
                                  height: 16,
                                  child: CircularProgressIndicator(strokeWidth: 2),
                                )
                              : const Text('Enable'),
                        ),
                        const SizedBox(width: 4),
                      ],
                      IconButton(
                        icon: const Icon(Icons.more_vert, size: 18),
                        onPressed: onMorePressed,
                      ),
                    ],
                  ),
                ),
                if (isToggling)
                  Padding(
                    padding: const EdgeInsets.only(top: 4),
                    child: Text(
                      'Updating...',
                      style: TextStyle(fontSize: 12, color: Colors.grey.shade600),
                    ),
                  ),
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
                if (!item.isEnabled && item.hasRelinkSuggestion)
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
                          onPressed: onEnableAnywayPressed,
                          child: const Text('Enable anyway'),
                        ),
                      ],
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
                Text(
                  '${item.eventCount} events',
                  style: const TextStyle(fontSize: 12, color: Colors.black54),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

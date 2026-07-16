import 'package:flutter/material.dart';

import '../../../data/models/client_calendar.dart';
import '../../../ui/calee_design.dart';
import 'calendar_widget_helpers.dart';

class CalendarAgendaEventRow extends StatelessWidget {
  const CalendarAgendaEventRow({
    required this.event,
    required this.color,
    required this.onTap,
    this.calendarName,
    this.hideTime = false,
    this.use24h = true,
    super.key,
  });

  final ClientEvent event;
  final Color color;
  final VoidCallback onTap;
  final String? calendarName;
  final bool hideTime;
  final bool use24h;

  @override
  Widget build(BuildContext context) {
    final subtitle = [
      if (calendarName != null && calendarName!.trim().isNotEmpty)
        calendarName!.trim(),
      if ((event.location ?? '').trim().isNotEmpty) event.location!.trim(),
    ].join(' · ');

    return InkWell(
      key: ValueKey(event.id),
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(
          horizontal: CaleeSpacing.md,
          vertical: 10,
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Colored left bar
            Container(
              width: 3,
              height: subtitle.isNotEmpty ? 40 : 22,
              decoration: BoxDecoration(
                color: color,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            const SizedBox(width: CaleeSpacing.sm + 2),
            // Time (omitted for all-day rows inside the All-day section)
            if (!hideTime) ...[
              SizedBox(
                width: 62,
                child: Text(
                  calendarEventTimeLabel(event, use24h: use24h),
                  maxLines: 1,
                  softWrap: false,
                  overflow: TextOverflow.clip,
                  style: const TextStyle(
                    fontSize: 13,
                    color: CaleeColors.textSecondary,
                    height: 1.4,
                  ),
                ),
              ),
              const SizedBox(width: CaleeSpacing.sm),
            ],
            // Title + subtitle
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    event.title,
                    style: const TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.w500,
                      color: CaleeColors.textPrimary,
                    ),
                  ),
                  if (subtitle.isNotEmpty) ...[
                    const SizedBox(height: 2),
                    Text(
                      subtitle,
                      style: const TextStyle(
                        fontSize: 12,
                        color: CaleeColors.textSecondary,
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

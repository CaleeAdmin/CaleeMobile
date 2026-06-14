import 'package:flutter/material.dart';

import '../../../ui/calee_design.dart';
import 'calendar_display_event.dart';

class ReadOnlyCalendarEventRow extends StatelessWidget {
  const ReadOnlyCalendarEventRow({
    required this.event,
    this.hideTime = false,
    this.use24h = true,
    this.onTap,
    super.key,
  });

  final CalendarDisplayEvent event;
  final bool hideTime;
  final bool use24h;
  final VoidCallback? onTap;

  String _timeLabel() {
    if (event.allDay) return 'All day';
    String fmt(DateTime dt) {
      if (use24h) {
        final h = dt.hour.toString().padLeft(2, '0');
        final m = dt.minute.toString().padLeft(2, '0');
        return '$h:$m';
      }
      final h12 = dt.hour % 12 == 0 ? 12 : dt.hour % 12;
      final period = dt.hour < 12 ? 'AM' : 'PM';
      if (dt.minute == 0) return '$h12 $period';
      return '$h12:${dt.minute.toString().padLeft(2, '0')} $period';
    }

    final end = event.end;
    if (end == null) return fmt(event.start);
    return '${fmt(event.start)} – ${fmt(end)}';
  }

  @override
  Widget build(BuildContext context) {
    final subtitle = [
      if (event.calendarName.trim().isNotEmpty) event.calendarName.trim(),
      if ((event.location ?? '').trim().isNotEmpty) event.location!.trim(),
    ].join(' · ');

    Widget inner = Padding(
      padding: const EdgeInsets.symmetric(
        horizontal: CaleeSpacing.md,
        vertical: 10,
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 3,
            height: subtitle.isNotEmpty ? 40 : 22,
            decoration: BoxDecoration(
              color: event.color,
              borderRadius: BorderRadius.circular(2),
            ),
          ),
          const SizedBox(width: CaleeSpacing.sm + 2),
          if (!hideTime) ...[
            SizedBox(
              width: 62,
              child: Text(
                _timeLabel(),
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
    );

    if (onTap == null) return inner;
    return InkWell(onTap: onTap, child: inner);
  }
}

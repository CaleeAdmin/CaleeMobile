import 'package:flutter/material.dart';

import '../../../ui/calee_theme.dart';

class ChoreSummaryStrip extends StatelessWidget {
  const ChoreSummaryStrip({
    required this.overdueCount,
    required this.todoTodayCount,
    required this.doneTodayCount,
    required this.pointsToday,
    super.key,
  });

  final int overdueCount;
  final int todoTodayCount;
  final int doneTodayCount;
  final int pointsToday;

  @override
  Widget build(BuildContext context) {
    return Wrap(
      spacing: CaleeSpacing.sm,
      runSpacing: CaleeSpacing.xs,
      children: [
        if (overdueCount > 0)
          _StripChip(
            label: '$overdueCount overdue',
            color: CaleeColors.dotOrange,
          ),
        if (todoTodayCount > 0) _StripChip(label: '$todoTodayCount today'),
        if (doneTodayCount > 0) _StripChip(label: '$doneTodayCount done'),
        if (pointsToday > 0) _StripChip(label: '$pointsToday stars'),
      ],
    );
  }
}

class _StripChip extends StatelessWidget {
  const _StripChip({required this.label, this.color});

  final String label;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final effectiveColor = color ?? CaleeColors.primary;

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: effectiveColor.withAlpha(CaleeAlpha.pct10),
        borderRadius: BorderRadius.circular(CaleeRadius.dot),
      ),
      child: Text(
        label,
        style: TextStyle(
          fontSize: 12,
          color: effectiveColor,
          fontWeight: FontWeight.w500,
        ),
      ),
    );
  }
}

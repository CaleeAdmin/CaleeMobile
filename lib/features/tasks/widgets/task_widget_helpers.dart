import 'package:flutter/material.dart';

import '../../../ui/calee_theme.dart';

class DueDateQuickPicks extends StatelessWidget {
  const DueDateQuickPicks({
    required this.selectedDate,
    required this.enabled,
    required this.onPick,
    super.key,
  });

  final DateTime? selectedDate;
  final bool enabled;
  final void Function(DateTime? date) onPick;

  bool _isSameDay(DateTime? a, DateTime? b) {
    if (a == null || b == null) return false;
    return a.year == b.year && a.month == b.month && a.day == b.day;
  }

  @override
  Widget build(BuildContext context) {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final tomorrow = today.add(const Duration(days: 1));
    final nextWeek = today.add(const Duration(days: 7));

    final isNoDate = selectedDate == null;
    final isToday = _isSameDay(selectedDate, today);
    final isTomorrow = _isSameDay(selectedDate, tomorrow);
    final isNextWeek = _isSameDay(selectedDate, nextWeek);

    return Wrap(
      spacing: CaleeSpacing.xs,
      runSpacing: CaleeSpacing.xs,
      children: [
        FilterChip(
          label: const Text('Today'),
          selected: isToday,
          onSelected: enabled ? (_) => onPick(today) : null,
          showCheckmark: false,
        ),
        FilterChip(
          label: const Text('Tomorrow'),
          selected: isTomorrow,
          onSelected: enabled ? (_) => onPick(tomorrow) : null,
          showCheckmark: false,
        ),
        FilterChip(
          label: const Text('Next Week'),
          selected: isNextWeek,
          onSelected: enabled ? (_) => onPick(nextWeek) : null,
          showCheckmark: false,
        ),
        FilterChip(
          label: const Text('No Date'),
          selected: isNoDate,
          onSelected: enabled ? (_) => onPick(null) : null,
          showCheckmark: false,
        ),
      ],
    );
  }
}

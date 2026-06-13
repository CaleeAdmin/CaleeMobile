import 'package:flutter/material.dart';

import '../../../data/models/client_calendar.dart';
import '../../../data/models/client_task.dart';
import '../../../ui/calee_theme.dart';
import '../../../ui/calee_widgets.dart';
import 'task_row.dart';

class CompletedTasksSection extends StatelessWidget {
  const CompletedTasksSection({
    required this.tasks,
    required this.calendars,
    required this.isExpanded,
    required this.onToggleExpanded,
    required this.updatingIds,
    required this.deletingIds,
    required this.editingIds,
    required this.onToggle,
    required this.onEdit,
    required this.onDelete,
    required this.calendarNameForTask,
    required this.formatDueLabel,
    super.key,
  });

  final List<ClientTask> tasks;
  final List<ClientCalendar> calendars;
  final bool isExpanded;
  final VoidCallback onToggleExpanded;
  final Set<String> updatingIds;
  final Set<String> deletingIds;
  final Set<String> editingIds;
  final Future<void> Function(ClientTask) onToggle;
  final Future<void> Function(ClientTask) onEdit;
  final Future<void> Function(ClientTask) onDelete;
  final String Function(ClientTask, List<ClientCalendar>) calendarNameForTask;
  final String Function(String?) formatDueLabel;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        InkWell(
          onTap: onToggleExpanded,
          borderRadius: BorderRadius.circular(CaleeRadius.card),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(
              CaleeSpacing.sm,
              0,
              CaleeSpacing.sm,
              CaleeSpacing.xs,
            ),
            child: Row(
              children: [
                Text(
                  'COMPLETED',
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: CaleeColors.textSecondary,
                    letterSpacing: 0.5,
                  ),
                ),
                const SizedBox(width: CaleeSpacing.xs),
                Text(
                  '${tasks.length}',
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: CaleeColors.textSecondary,
                  ),
                ),
                const Spacer(),
                Icon(
                  isExpanded
                      ? Icons.keyboard_arrow_up
                      : Icons.keyboard_arrow_down,
                  size: 16,
                  color: CaleeColors.textTertiary,
                ),
              ],
            ),
          ),
        ),
        if (isExpanded)
          CaleeSection(
            children: tasks
                .map(
                  (task) => TaskRow(
                    key: ValueKey(task.id),
                    task: task,
                    dueLabel: formatDueLabel(task.dueAt),
                    listName: calendarNameForTask(task, calendars),
                    isUpdating: updatingIds.contains(task.id),
                    isDeleting: deletingIds.contains(task.id),
                    isEditing: editingIds.contains(task.id),
                    onToggle: () => onToggle(task),
                    onEdit: () => onEdit(task),
                    onDelete: () => onDelete(task),
                  ),
                )
                .toList(),
          ),
      ],
    );
  }
}

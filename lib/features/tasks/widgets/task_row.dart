import 'package:flutter/material.dart';

import '../../../data/models/client_task.dart';
import '../../../ui/calee_theme.dart';
import '../../../ui/calee_widgets.dart';

class TaskRow extends StatelessWidget {
  const TaskRow({
    required this.task,
    required this.dueLabel,
    required this.listName,
    required this.isUpdating,
    required this.isDeleting,
    required this.isEditing,
    required this.onToggle,
    required this.onEdit,
    required this.onDelete,
    super.key,
  });

  final ClientTask task;
  final String dueLabel;
  final String listName;
  final bool isUpdating;
  final bool isDeleting;
  final bool isEditing;
  final VoidCallback onToggle;
  final VoidCallback onEdit;
  final VoidCallback onDelete;

  String get _subtitle {
    final parts = <String>[
      if (dueLabel.isNotEmpty) dueLabel,
      if (listName.isNotEmpty) listName,
    ];
    return parts.join(' · ');
  }

  @override
  Widget build(BuildContext context) {
    final isBusy = isDeleting || isEditing;

    Widget trailing;
    if (isBusy) {
      trailing = const SizedBox(
        width: 20,
        height: 20,
        child: CircularProgressIndicator(strokeWidth: 2),
      );
    } else {
      trailing = Builder(
        builder: (context) => SizedBox(
          width: 28,
          height: 28,
          child: IconButton(
            key: Key('task_more_${task.id}'),
            padding: EdgeInsets.zero,
            icon: const Icon(
              Icons.more_horiz,
              color: CaleeColors.textTertiary,
              size: 20,
            ),
            onPressed: () => CaleeActionSheet.show(
              context: context,
              title: task.title,
              actions: [
                CaleeAction(
                  label: 'Edit',
                  icon: Icons.edit_outlined,
                  testId: 'task_action_edit',
                  onTap: onEdit,
                ),
                CaleeAction(
                  label: 'Delete',
                  icon: Icons.delete_outline,
                  isDestructive: true,
                  testId: 'task_action_delete',
                  onTap: onDelete,
                ),
              ],
            ),
          ),
        ),
      );
    }

    return CaleeListRow(
      title: task.title,
      subtitle: _subtitle.isNotEmpty ? _subtitle : null,
      titleStyle: task.isCompleted
          ? TextStyle(
              color: CaleeColors.textTertiary,
              decoration: TextDecoration.lineThrough,
              decorationColor: CaleeColors.textTertiary,
            )
          : null,
      subtitleStyle: task.isCompleted
          ? const TextStyle(color: CaleeColors.textTertiary)
          : null,
      leading: CaleeCheckCircle(
        key: Key('task_toggle_${task.id}'),
        isChecked: task.isCompleted,
        onTap: onToggle,
        isLoading: isUpdating,
        color: CaleeColors.primary,
      ),
      trailing: trailing,
      enabled: !isBusy,
      onTap: isBusy ? null : onEdit,
    );
  }
}

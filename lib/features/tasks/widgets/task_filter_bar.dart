import 'package:flutter/material.dart';

import '../../../data/models/client_calendar.dart';
import '../../../data/models/client_task.dart';
import '../../../ui/calee_theme.dart';
import '../../../ui/calee_widgets.dart';

class TaskListChooser extends StatelessWidget {
  const TaskListChooser({
    required this.taskCalendars,
    required this.selectedCalendar,
    required this.allTasks,
    required this.onSelect,
    required this.onAddTaskList,
    super.key,
  });

  final List<ClientCalendar> taskCalendars;
  final ClientCalendar? selectedCalendar;
  final List<ClientTask> allTasks;
  final void Function(ClientCalendar? calendar) onSelect;
  final VoidCallback onAddTaskList;

  int _countForCalendar(ClientCalendar cal) {
    final prefix = '${cal.serviceId}:';
    final rawId = cal.id.startsWith(prefix)
        ? cal.id.substring(prefix.length)
        : cal.id;
    return allTasks
        .where(
          (t) =>
              t.calendarId == cal.id ||
              t.calendarId == rawId ||
              '${t.serviceId}:${t.calendarId}' == cal.id,
        )
        .length;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final countStyle = theme.textTheme.bodySmall?.copyWith(
      color: CaleeColors.textSecondary,
    );

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        CaleeSection(
          children: [
            CaleeListRow(
              title: 'All Tasks',
              leading: selectedCalendar == null
                  ? const Icon(
                      Icons.check,
                      size: 20,
                      color: CaleeColors.primary,
                    )
                  : const SizedBox(width: 20),
              trailing: Text('${allTasks.length}', style: countStyle),
              onTap: () => onSelect(null),
            ),
            ...taskCalendars.map(
              (cal) => CaleeListRow(
                title: cal.name,
                subtitle: cal.serviceName.trim().isNotEmpty
                    ? cal.serviceName
                    : null,
                leading: selectedCalendar?.id == cal.id
                    ? const Icon(
                        Icons.check,
                        size: 20,
                        color: CaleeColors.primary,
                      )
                    : const SizedBox(width: 20),
                trailing: Text('${_countForCalendar(cal)}', style: countStyle),
                onTap: () => onSelect(cal),
              ),
            ),
          ],
        ),
        const SizedBox(height: CaleeSpacing.sectionSpacing),
        CaleeSection(
          title: 'Add',
          children: [
            CaleeListRow(
              title: 'New Task List',
              leading: const Icon(
                Icons.add_circle_outline,
                size: 20,
                color: CaleeColors.primary,
              ),
              onTap: onAddTaskList,
            ),
          ],
        ),
        const SizedBox(height: CaleeSpacing.md),
      ],
    );
  }
}

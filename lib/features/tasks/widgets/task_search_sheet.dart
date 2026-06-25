import 'package:flutter/material.dart';

import '../../../data/models/client_calendar.dart';
import '../../../data/models/client_task.dart';
import '../../../ui/calee_theme.dart';
import '../../../ui/calee_widgets.dart';

class TaskSearchSheet extends StatefulWidget {
  const TaskSearchSheet({
    required this.searchController,
    required this.searchTasks,
    required this.calendarNameForTask,
    required this.formatDueLabel,
    required this.onResultTap,
    super.key,
  });

  final TextEditingController searchController;
  final List<ClientTask> Function(String query) searchTasks;
  final String Function(ClientTask task, List<ClientCalendar> calendars)
  calendarNameForTask;
  final String Function(String? dueAt) formatDueLabel;
  final void Function(ClientTask task) onResultTap;

  @override
  State<TaskSearchSheet> createState() => _TaskSearchSheetState();
}

class _TaskSearchSheetState extends State<TaskSearchSheet> {
  List<ClientTask> _results = [];

  @override
  void initState() {
    super.initState();
    widget.searchController.addListener(_onQueryChanged);
  }

  @override
  void dispose() {
    widget.searchController.removeListener(_onQueryChanged);
    super.dispose();
  }

  void _onQueryChanged() {
    setState(() {
      _results = widget.searchTasks(widget.searchController.text);
    });
  }

  @override
  Widget build(BuildContext context) {
    final bottomInset = MediaQuery.viewInsetsOf(context).bottom;
    final hasQuery = widget.searchController.text.trim().isNotEmpty;

    return Padding(
      padding: EdgeInsets.only(bottom: bottomInset),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Padding(
            padding: const EdgeInsets.only(top: CaleeSpacing.sm),
            child: Container(
              width: 36,
              height: 4,
              decoration: BoxDecoration(
                color: CaleeColors.textTertiary,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
          ),
          // Sheet header
          Padding(
            padding: const EdgeInsets.fromLTRB(
              CaleeSpacing.md,
              CaleeSpacing.sm,
              CaleeSpacing.sm,
              0,
            ),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    'Search Tasks',
                    style: Theme.of(context).textTheme.titleLarge,
                  ),
                ),
                IconButton(
                  icon: const Icon(Icons.close),
                  onPressed: () => Navigator.of(context).maybePop(),
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.all(CaleeSpacing.md),
            child: TextField(
              controller: widget.searchController,
              autofocus: true,
              textInputAction: TextInputAction.search,
              decoration: InputDecoration(
                hintText: 'Search tasks…',
                prefixIcon: const Icon(Icons.search, size: 20),
                suffixIcon: hasQuery
                    ? IconButton(
                        icon: const Icon(Icons.close, size: 18),
                        onPressed: () => widget.searchController.clear(),
                      )
                    : null,
              ),
            ),
          ),
          ConstrainedBox(
            constraints: BoxConstraints(
              maxHeight: MediaQuery.sizeOf(context).height * 0.45,
            ),
            child: hasQuery && _results.isEmpty
                ? Padding(
                    padding: const EdgeInsets.all(CaleeSpacing.lg),
                    child: Text(
                      'No tasks match your search.',
                      style: TextStyle(color: CaleeColors.textSecondary),
                      textAlign: TextAlign.center,
                    ),
                  )
                : ListView.builder(
                    shrinkWrap: true,
                    itemCount: _results.length,
                    itemBuilder: (_, i) {
                      final task = _results[i];
                      final due = widget.formatDueLabel(task.dueAt);
                      return CaleeListRow(
                        title: task.title,
                        subtitle: due.isNotEmpty ? due : null,
                        leading: Icon(
                          task.isCompleted
                              ? Icons.check_circle_outline
                              : Icons.radio_button_unchecked,
                          color: task.isCompleted
                              ? CaleeColors.textTertiary
                              : CaleeColors.primary,
                          size: 20,
                        ),
                        onTap: () => widget.onResultTap(task),
                      );
                    },
                  ),
          ),
          const SizedBox(height: CaleeSpacing.md),
        ],
      ),
    );
  }
}

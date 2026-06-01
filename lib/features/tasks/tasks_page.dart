import 'package:flutter/material.dart';

import '../../data/api/calee_hub_client.dart';
import '../../data/models/client_bootstrap.dart';
import '../settings/calendar_collections_page.dart';
import '../../data/models/client_calendar.dart';
import '../../data/models/client_task.dart';
import '../../ui/calee_theme.dart';
import '../../ui/calee_widgets.dart';

class TasksPage extends StatefulWidget {
  const TasksPage({
    required this.hubClient,
    required this.accessToken,
    required this.services,
    super.key,
  });

  final CaleeHubClient hubClient;
  final String accessToken;
  final List<ClientService> services;

  @override
  State<TasksPage> createState() => _TasksPageState();
}

class _TasksPageState extends State<TasksPage> {
  late Future<_TasksOverview> _overviewFuture;
  bool _isCreatingTask = false;
  final Set<String> _updatingTaskIds = {};
  final Set<String> _deletingTaskIds = {};
  final Set<String> _editingTaskIds = {};
  bool _completedExpanded = false;

  @override
  void initState() {
    super.initState();
    _overviewFuture = _loadOverview();
  }

  Future<_TasksOverview> _loadOverview() async {
    final today = DateTime.now();
    final from = _formatDate(DateTime(today.year, 1, 1));
    final to = _formatDate(DateTime(today.year, 12, 31));

    final calendarList = await widget.hubClient.calendars(
      accessToken: widget.accessToken,
    );
    final taskList = await widget.hubClient.tasks(
      accessToken: widget.accessToken,
      from: from,
      to: to,
    );

    return _TasksOverview(
      calendarList: calendarList,
      taskList: taskList,
      from: from,
      to: to,
    );
  }

  void _openCollectionCreateShortcut() {
    Navigator.of(context)
        .push(
      MaterialPageRoute<void>(
        builder: (_) => CalendarCollectionsPage(
          hubClient: widget.hubClient,
          accessToken: widget.accessToken,
          services: widget.services,
          initialCreateKind: 'tasks',
          autoOpenCreate: true,
        ),
      ),
    )
        .then((_) {
      if (mounted) {
        _reloadOverview();
      }
    });
  }

  void _reloadOverview() {
    setState(() {
      _overviewFuture = _loadOverview();
    });
  }

  Future<void> _openCreateTaskSheet(List<ClientCalendar> taskCalendars) async {
    if (taskCalendars.isEmpty || _isCreatingTask) {
      return;
    }

    final created = await CaleeBottomSheet.show<bool>(
      context: context,
      title: 'New Task',
      child: _CreateTaskForm(
        taskCalendars: taskCalendars,
        onCreate: _createTask,
      ),
    );

    if (created == true && mounted) {
      _reloadOverview();
    }
  }

  Future<void> _createTask({
    required ClientCalendar taskCalendar,
    required String title,
    String? dueAt,
    String? description,
  }) async {
    setState(() {
      _isCreatingTask = true;
    });

    try {
      await widget.hubClient.createTask(
        accessToken: widget.accessToken,
        serviceId: taskCalendar.serviceId,
        calendarId: _rawCalendarId(taskCalendar),
        title: title,
        dueAt: dueAt,
        description: description,
      );
    } finally {
      if (mounted) {
        setState(() {
          _isCreatingTask = false;
        });
      }
    }
  }

  Future<void> _toggleTaskStatus(ClientTask task) async {
    if (_updatingTaskIds.contains(task.id)) {
      return;
    }

    setState(() {
      _updatingTaskIds.add(task.id);
    });

    try {
      await widget.hubClient.updateTaskStatus(
        accessToken: widget.accessToken,
        taskId: task.id,
        completed: !task.isCompleted,
      );

      if (mounted) {
        _reloadOverview();
      }
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Unable to update task.')),
        );
      }
    } finally {
      if (mounted) {
        setState(() {
          _updatingTaskIds.remove(task.id);
        });
      }
    }
  }

  Future<void> _openEditTaskSheet(ClientTask task) async {
    if (_editingTaskIds.contains(task.id) ||
        _deletingTaskIds.contains(task.id)) {
      return;
    }

    final updated = await CaleeBottomSheet.show<bool>(
      context: context,
      title: 'Edit Task',
      child: _EditTaskForm(
        task: task,
        onUpdate: _updateTask,
      ),
    );

    if (updated == true && mounted) {
      _reloadOverview();
    }
  }

  Future<void> _updateTask({
    required ClientTask task,
    required String title,
    String? dueAt,
    String? description,
  }) async {
    setState(() {
      _editingTaskIds.add(task.id);
    });

    try {
      await widget.hubClient.updateTask(
        accessToken: widget.accessToken,
        taskId: task.id,
        title: title,
        dueAt: dueAt,
        description: description,
      );
    } finally {
      if (mounted) {
        setState(() {
          _editingTaskIds.remove(task.id);
        });
      }
    }
  }

  Future<void> _confirmDeleteTask(ClientTask task) async {
    if (_deletingTaskIds.contains(task.id)) {
      return;
    }

    final shouldDelete = await CaleeDestructiveDialog.show(
      context: context,
      title: 'Delete Task',
      body: 'Delete "${task.title}"? This cannot be undone.',
      confirmLabel: 'Delete',
    );

    if (!shouldDelete || !mounted) {
      return;
    }

    setState(() {
      _deletingTaskIds.add(task.id);
    });

    try {
      await widget.hubClient.deleteTask(
        accessToken: widget.accessToken,
        taskId: task.id,
      );

      if (mounted) {
        _reloadOverview();
      }
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Unable to delete task.')),
        );
      }
    } finally {
      if (mounted) {
        setState(() {
          _deletingTaskIds.remove(task.id);
        });
      }
    }
  }

  String _rawCalendarId(ClientCalendar calendar) {
    final prefix = '${calendar.serviceId}:';
    if (calendar.id.startsWith(prefix)) {
      return calendar.id.substring(prefix.length);
    }

    return calendar.id;
  }

  String _formatDate(DateTime value) {
    final year = value.year.toString().padLeft(4, '0');
    final month = value.month.toString().padLeft(2, '0');
    final day = value.day.toString().padLeft(2, '0');

    return '$year-$month-$day';
  }

  String _formatDueLabel(String? value) {
    if (value == null || value.trim().isEmpty) {
      return '';
    }

    final parsed = DateTime.tryParse(value);
    if (parsed == null) {
      return value;
    }

    final local = parsed.toLocal();
    final now = DateTime.now();

    if (local.year == now.year &&
        local.month == now.month &&
        local.day == now.day) {
      return 'Due today';
    }

    final tomorrow = now.add(const Duration(days: 1));
    if (local.year == tomorrow.year &&
        local.month == tomorrow.month &&
        local.day == tomorrow.day) {
      return 'Due tomorrow';
    }

    final yesterday = now.subtract(const Duration(days: 1));
    if (local.year == yesterday.year &&
        local.month == yesterday.month &&
        local.day == yesterday.day) {
      return 'Due yesterday';
    }

    final todayMidnight = DateTime(now.year, now.month, now.day);
    final dDay = DateTime(local.year, local.month, local.day);
    if (dDay.isBefore(todayMidnight)) {
      return 'Overdue ${local.day}/${local.month}/${local.year}';
    }

    return 'Due ${local.day}/${local.month}/${local.year}';
  }

  String _calendarNameForTask(ClientTask task, List<ClientCalendar> calendars) {
    for (final cal in calendars) {
      if (cal.id == task.calendarId ||
          cal.id == '${task.serviceId}:${task.calendarId}') {
        return cal.name;
      }
    }
    return task.serviceName.trim().isNotEmpty ? task.serviceName : '';
  }

  bool _isDueOnOrBefore(String? dueAt, DateTime cutoff) {
    if (dueAt == null || dueAt.trim().isEmpty) return false;
    final d = DateTime.tryParse(dueAt)?.toLocal();
    if (d == null) return false;
    final dDay = DateTime(d.year, d.month, d.day);
    return !dDay.isAfter(cutoff);
  }

  bool _isDueAfter(String? dueAt, DateTime cutoff) {
    if (dueAt == null || dueAt.trim().isEmpty) return false;
    final d = DateTime.tryParse(dueAt)?.toLocal();
    if (d == null) return false;
    final dDay = DateTime(d.year, d.month, d.day);
    return dDay.isAfter(cutoff);
  }

  int _dueSortKey(ClientTask t) {
    if (t.dueAt == null || t.dueAt!.trim().isEmpty) return 0;
    return DateTime.tryParse(t.dueAt!)?.millisecondsSinceEpoch ?? 0;
  }

  Widget _buildSmartSection(
    String title,
    List<ClientTask> tasks,
    List<ClientCalendar> taskCalendars,
  ) {
    return CaleeSection(
      title: title,
      trailing: '${tasks.length}',
      children: tasks
          .map(
            (task) => _TaskRow(
              key: ValueKey(task.id),
              task: task,
              dueLabel: _formatDueLabel(task.dueAt),
              listName: _calendarNameForTask(task, taskCalendars),
              isUpdating: _updatingTaskIds.contains(task.id),
              isDeleting: _deletingTaskIds.contains(task.id),
              isEditing: _editingTaskIds.contains(task.id),
              onToggle: () => _toggleTaskStatus(task),
              onEdit: () => _openEditTaskSheet(task),
              onDelete: () => _confirmDeleteTask(task),
            ),
          )
          .toList(),
    );
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<_TasksOverview>(
      future: _overviewFuture,
      builder: (context, snapshot) {
        if (snapshot.connectionState == ConnectionState.waiting) {
          return const CaleeScaffold(
            body: Center(child: CircularProgressIndicator()),
          );
        }

        if (snapshot.hasError) {
          return CaleeScaffold(
            body: CaleeEmptyState(
              icon: Icons.cloud_off_outlined,
              title: 'Unable to load tasks',
              body: 'Check your connection, then try again.',
              action: FilledButton(
                onPressed: _reloadOverview,
                child: const Text('Try again'),
              ),
            ),
          );
        }

        final overview = snapshot.data;
        if (overview == null) {
          return CaleeScaffold(
            body: CaleeEmptyState(
              icon: Icons.checklist_outlined,
              title: 'No task lists yet',
              body: 'Create a task list to start tracking tasks.',
              action: FilledButton.icon(
                onPressed: _openCollectionCreateShortcut,
                icon: const Icon(Icons.add),
                label: const Text('Create task list'),
              ),
            ),
          );
        }

        final taskCalendars = overview.calendarList.calendars
            .where((calendar) => calendar.isTaskKind)
            .toList();
        final allTasks = overview.taskList.tasks;

        if (taskCalendars.isEmpty && allTasks.isEmpty) {
          return CaleeScaffold(
            body: CaleeEmptyState(
              icon: Icons.checklist_outlined,
              title: 'No task lists yet',
              body: 'Create a task list to start tracking tasks.',
              action: FilledButton.icon(
                onPressed: _openCollectionCreateShortcut,
                icon: const Icon(Icons.add),
                label: const Text('Create task list'),
              ),
            ),
          );
        }

        final openTasks =
            allTasks.where((t) => !t.isCompleted).toList();
        final completedTasks =
            allTasks.where((t) => t.isCompleted).toList();

        final now = DateTime.now();
        final today = DateTime(now.year, now.month, now.day);

        final todayTasks =
            openTasks.where((t) => _isDueOnOrBefore(t.dueAt, today)).toList()
              ..sort((a, b) {
                final cmp = _dueSortKey(a).compareTo(_dueSortKey(b));
                return cmp != 0 ? cmp : a.title.compareTo(b.title);
              });

        final upcomingTasks =
            openTasks.where((t) => _isDueAfter(t.dueAt, today)).toList()
              ..sort((a, b) {
                final cmp = _dueSortKey(a).compareTo(_dueSortKey(b));
                return cmp != 0 ? cmp : a.title.compareTo(b.title);
              });

        final noDateTasks = openTasks
            .where((t) => t.dueAt == null || t.dueAt!.trim().isEmpty)
            .toList()
          ..sort((a, b) => a.title.compareTo(b.title));

        return CaleeScaffold(
          floatingActionButton: taskCalendars.isEmpty
              ? null
              : FloatingActionButton.extended(
                  onPressed: _isCreatingTask
                      ? null
                      : () => _openCreateTaskSheet(taskCalendars),
                  icon: const Icon(Icons.add),
                  label: const Text('Task'),
                ),
          body: RefreshIndicator(
            onRefresh: () async {
              _reloadOverview();
              await _overviewFuture;
            },
            child: ListView(
              padding: const EdgeInsets.symmetric(
                horizontal: CaleeSpacing.pagePadding,
                vertical: CaleeSpacing.md,
              ),
              children: [
                // ── Empty state when no open tasks ───────────────────
                if (openTasks.isEmpty && taskCalendars.isNotEmpty)
                  CaleeSection(
                    children: [
                      CaleeListRow(
                        title: 'No open tasks',
                        subtitle: 'Add a task when something needs doing.',
                        leading: const Icon(
                          Icons.check_circle_outline,
                          color: CaleeColors.textTertiary,
                          size: 22,
                        ),
                      ),
                    ],
                  ),

                // ── Today (includes overdue) ──────────────────────────
                if (todayTasks.isNotEmpty) ...[
                  _buildSmartSection('Today', todayTasks, taskCalendars),
                  const SizedBox(height: CaleeSpacing.sectionSpacing),
                ],

                // ── Upcoming ──────────────────────────────────────────
                if (upcomingTasks.isNotEmpty) ...[
                  _buildSmartSection('Upcoming', upcomingTasks, taskCalendars),
                  const SizedBox(height: CaleeSpacing.sectionSpacing),
                ],

                // ── No Date ───────────────────────────────────────────
                if (noDateTasks.isNotEmpty) ...[
                  _buildSmartSection('No Date', noDateTasks, taskCalendars),
                  const SizedBox(height: CaleeSpacing.sectionSpacing),
                ],

                // ── No task lists ─────────────────────────────────────
                if (taskCalendars.isEmpty)
                  Padding(
                    padding: const EdgeInsets.only(top: CaleeSpacing.md),
                    child: CaleeSection(
                      footer:
                          'Connect a task list to start adding tasks.',
                      children: [
                        CaleeListRow(
                          title: 'Add task list',
                          leading: const Icon(
                            Icons.add_circle_outline,
                            color: CaleeColors.primary,
                            size: 22,
                          ),
                          onTap: _openCollectionCreateShortcut,
                        ),
                      ],
                    ),
                  ),

                // ── Completed tasks ───────────────────────────────────
                if (completedTasks.isNotEmpty)
                  _CompletedSection(
                    tasks: completedTasks,
                    calendars: taskCalendars,
                    isExpanded: _completedExpanded,
                    onToggleExpanded: () {
                      setState(() {
                        _completedExpanded = !_completedExpanded;
                      });
                    },
                    updatingIds: _updatingTaskIds,
                    deletingIds: _deletingTaskIds,
                    editingIds: _editingTaskIds,
                    onToggle: _toggleTaskStatus,
                    onEdit: _openEditTaskSheet,
                    onDelete: _confirmDeleteTask,
                    calendarNameForTask: _calendarNameForTask,
                    formatDueLabel: _formatDueLabel,
                  ),

                const SizedBox(height: 96),
              ],
            ),
          ),
        );
      },
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Completed section with collapse toggle
// ─────────────────────────────────────────────────────────────────────────────

class _CompletedSection extends StatelessWidget {
  const _CompletedSection({
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
        // Collapsible header row
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
                  (task) => _TaskRow(
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

// ─────────────────────────────────────────────────────────────────────────────
// Single task row
// ─────────────────────────────────────────────────────────────────────────────

class _TaskRow extends StatelessWidget {
  const _TaskRow({
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
                  onTap: onEdit,
                ),
                CaleeAction(
                  label: 'Delete',
                  icon: Icons.delete_outline,
                  isDestructive: true,
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

// ─────────────────────────────────────────────────────────────────────────────
// Internal data holder
// ─────────────────────────────────────────────────────────────────────────────

class _TasksOverview {
  const _TasksOverview({
    required this.calendarList,
    required this.taskList,
    required this.from,
    required this.to,
  });

  final ClientCalendarList calendarList;
  final ClientTaskList taskList;
  final String from;
  final String to;
}

// ─────────────────────────────────────────────────────────────────────────────
// Create task form (inside CaleeBottomSheet)
// ─────────────────────────────────────────────────────────────────────────────

class _CreateTaskForm extends StatefulWidget {
  const _CreateTaskForm({
    required this.taskCalendars,
    required this.onCreate,
  });

  final List<ClientCalendar> taskCalendars;
  final Future<void> Function({
    required ClientCalendar taskCalendar,
    required String title,
    String? dueAt,
    String? description,
  }) onCreate;

  @override
  State<_CreateTaskForm> createState() => _CreateTaskFormState();
}

class _CreateTaskFormState extends State<_CreateTaskForm> {
  final _formKey = GlobalKey<FormState>();
  final _titleController = TextEditingController();
  final _descriptionController = TextEditingController();

  ClientCalendar? _selectedTaskCalendar;
  DateTime? _selectedDueDate;
  bool _isSubmitting = false;

  @override
  void initState() {
    super.initState();
    _selectedTaskCalendar = widget.taskCalendars.first;
  }

  @override
  void dispose() {
    _titleController.dispose();
    _descriptionController.dispose();
    super.dispose();
  }

  String _formatDate(DateTime value) {
    final year = value.year.toString().padLeft(4, '0');
    final month = value.month.toString().padLeft(2, '0');
    final day = value.day.toString().padLeft(2, '0');

    return '$year-$month-$day';
  }

  Future<void> _pickDueDate() async {
    final now = DateTime.now();
    final picked = await showDatePicker(
      context: context,
      initialDate: _selectedDueDate ?? now,
      firstDate: DateTime(now.year - 1),
      lastDate: DateTime(now.year + 5),
    );

    if (picked != null && mounted) {
      setState(() {
        _selectedDueDate = picked;
      });
    }
  }

  Future<void> _submit() async {
    if (_isSubmitting || !_formKey.currentState!.validate()) {
      return;
    }

    final selectedTaskCalendar = _selectedTaskCalendar;
    if (selectedTaskCalendar == null) {
      return;
    }

    setState(() {
      _isSubmitting = true;
    });

    try {
      await widget.onCreate(
        taskCalendar: selectedTaskCalendar,
        title: _titleController.text.trim(),
        dueAt:
            _selectedDueDate == null ? null : _formatDate(_selectedDueDate!),
        description: _descriptionController.text.trim(),
      );

      if (mounted) {
        Navigator.of(context).pop(true);
      }
    } catch (_) {
      if (mounted) {
        setState(() {
          _isSubmitting = false;
        });

        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Unable to create task.')),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Form(
      key: _formKey,
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            DropdownButtonFormField<ClientCalendar>(
              initialValue: _selectedTaskCalendar,
              items: widget.taskCalendars
                  .map(
                    (calendar) => DropdownMenuItem(
                      value: calendar,
                      child:
                          Text('${calendar.name} · ${calendar.serviceName}'),
                    ),
                  )
                  .toList(),
              onChanged: _isSubmitting
                  ? null
                  : (calendar) {
                      setState(() {
                        _selectedTaskCalendar = calendar;
                      });
                    },
              decoration: const InputDecoration(labelText: 'Task list'),
            ),
            const SizedBox(height: CaleeSpacing.sm),
            TextFormField(
              controller: _titleController,
              enabled: !_isSubmitting,
              autofocus: true,
              decoration: const InputDecoration(labelText: 'Title'),
              textInputAction: TextInputAction.next,
              validator: (value) {
                if ((value ?? '').trim().isEmpty) {
                  return 'Enter a task title';
                }

                return null;
              },
            ),
            const SizedBox(height: CaleeSpacing.sm),
            _DueDateQuickPicks(
              selectedDate: _selectedDueDate,
              enabled: !_isSubmitting,
              onPick: (date) {
                setState(() {
                  _selectedDueDate = date;
                });
              },
            ),
            const SizedBox(height: CaleeSpacing.xs),
            OutlinedButton.icon(
              onPressed: _isSubmitting ? null : _pickDueDate,
              icon: const Icon(Icons.event_outlined),
              label: Text(
                _selectedDueDate == null
                    ? 'Custom date…'
                    : 'Due ${_formatDate(_selectedDueDate!)}',
              ),
            ),
            const SizedBox(height: CaleeSpacing.sm),
            TextFormField(
              controller: _descriptionController,
              enabled: !_isSubmitting,
              decoration: const InputDecoration(labelText: 'Notes'),
              minLines: 2,
              maxLines: 4,
            ),
            const SizedBox(height: CaleeSpacing.md),
            FilledButton(
              onPressed: _isSubmitting ? null : _submit,
              child: _isSubmitting
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Text('Create Task'),
            ),
          ],
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Edit task form (inside CaleeBottomSheet)
// ─────────────────────────────────────────────────────────────────────────────

class _EditTaskForm extends StatefulWidget {
  const _EditTaskForm({
    required this.task,
    required this.onUpdate,
  });

  final ClientTask task;
  final Future<void> Function({
    required ClientTask task,
    required String title,
    String? dueAt,
    String? description,
  }) onUpdate;

  @override
  State<_EditTaskForm> createState() => _EditTaskFormState();
}

class _EditTaskFormState extends State<_EditTaskForm> {
  final _formKey = GlobalKey<FormState>();
  late final TextEditingController _titleController;
  late final TextEditingController _descriptionController;

  DateTime? _selectedDueDate;
  bool _isSubmitting = false;

  @override
  void initState() {
    super.initState();
    _titleController = TextEditingController(text: widget.task.title);
    _descriptionController =
        TextEditingController(text: widget.task.description ?? '');

    final dueAt = widget.task.dueAt;
    if (dueAt != null && dueAt.trim().isNotEmpty) {
      _selectedDueDate = DateTime.tryParse(dueAt)?.toLocal();
    }
  }

  @override
  void dispose() {
    _titleController.dispose();
    _descriptionController.dispose();
    super.dispose();
  }

  String _formatDate(DateTime value) {
    final year = value.year.toString().padLeft(4, '0');
    final month = value.month.toString().padLeft(2, '0');
    final day = value.day.toString().padLeft(2, '0');

    return '$year-$month-$day';
  }

  Future<void> _pickDueDate() async {
    final now = DateTime.now();
    final picked = await showDatePicker(
      context: context,
      initialDate: _selectedDueDate ?? now,
      firstDate: DateTime(now.year - 1),
      lastDate: DateTime(now.year + 5),
    );

    if (picked != null && mounted) {
      setState(() {
        _selectedDueDate = picked;
      });
    }
  }

  Future<void> _submit() async {
    if (_isSubmitting || !_formKey.currentState!.validate()) {
      return;
    }

    setState(() {
      _isSubmitting = true;
    });

    try {
      await widget.onUpdate(
        task: widget.task,
        title: _titleController.text.trim(),
        dueAt:
            _selectedDueDate == null ? null : _formatDate(_selectedDueDate!),
        description: _descriptionController.text.trim(),
      );

      if (mounted) {
        Navigator.of(context).pop(true);
      }
    } catch (_) {
      if (mounted) {
        setState(() {
          _isSubmitting = false;
        });

        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Unable to update task.')),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Form(
      key: _formKey,
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            TextFormField(
              controller: _titleController,
              enabled: !_isSubmitting,
              autofocus: true,
              decoration: const InputDecoration(labelText: 'Title'),
              textInputAction: TextInputAction.next,
              validator: (value) {
                if ((value ?? '').trim().isEmpty) {
                  return 'Enter a task title';
                }

                return null;
              },
            ),
            const SizedBox(height: CaleeSpacing.sm),
            _DueDateQuickPicks(
              selectedDate: _selectedDueDate,
              enabled: !_isSubmitting,
              onPick: (date) {
                setState(() {
                  _selectedDueDate = date;
                });
              },
            ),
            const SizedBox(height: CaleeSpacing.xs),
            OutlinedButton.icon(
              onPressed: _isSubmitting ? null : _pickDueDate,
              icon: const Icon(Icons.event_outlined),
              label: Text(
                _selectedDueDate == null
                    ? 'Custom date…'
                    : 'Due ${_formatDate(_selectedDueDate!)}',
              ),
            ),
            const SizedBox(height: CaleeSpacing.sm),
            TextFormField(
              controller: _descriptionController,
              enabled: !_isSubmitting,
              decoration: const InputDecoration(labelText: 'Notes'),
              minLines: 2,
              maxLines: 4,
            ),
            const SizedBox(height: CaleeSpacing.md),
            FilledButton(
              onPressed: _isSubmitting ? null : _submit,
              child: _isSubmitting
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Text('Save Task'),
            ),
          ],
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Due-date quick-pick chips (Today / Tomorrow / Next Week / No Date)
// ─────────────────────────────────────────────────────────────────────────────

class _DueDateQuickPicks extends StatelessWidget {
  const _DueDateQuickPicks({
    required this.selectedDate,
    required this.enabled,
    required this.onPick,
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

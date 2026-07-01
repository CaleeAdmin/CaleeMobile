import 'package:flutter/material.dart';

import '../../data/api/calee_hub_client.dart';
import '../../data/models/client_bootstrap.dart';
import '../calendar/widgets/calendar_error_state.dart';
import '../settings/calendar_collections_page.dart';
import '../../data/models/client_calendar.dart';
import '../../data/models/client_task.dart';
import '../../ui/calee_theme.dart';
import '../../ui/calee_widgets.dart';
import 'tasks_controller.dart';
import 'tasks_repository.dart';
import 'widgets/completed_tasks_section.dart';
import 'widgets/create_task_sheet.dart';
import 'widgets/edit_task_sheet.dart';
import 'widgets/task_filter_bar.dart';
import 'widgets/task_row.dart';
import 'widgets/task_search_sheet.dart';

class TasksPage extends StatefulWidget {
  const TasksPage({
    required this.hubClient,
    required this.accessToken,
    required this.services,
    required this.accountId,
    super.key,
  });

  final CaleeHubClient hubClient;
  final String accessToken;
  final List<ClientService> services;
  final String accountId;

  @override
  State<TasksPage> createState() => _TasksPageState();
}

class _TasksPageState extends State<TasksPage> {
  late final TasksController _controller;
  final TextEditingController _searchController = TextEditingController();

  @override
  void initState() {
    super.initState();
    final repository = TasksRepository(
      hubClient: widget.hubClient,
      accessToken: widget.accessToken,
      services: widget.services,
    );
    _controller = TasksController(repository: repository);
    _controller.load();
  }

  @override
  void dispose() {
    _controller.dispose();
    _searchController.dispose();
    super.dispose();
  }

  void _openCollectionCreateShortcut() {
    Navigator.of(context)
        .push(
          MaterialPageRoute<void>(
            builder: (_) => CalendarCollectionsPage(
              hubClient: widget.hubClient,
              accessToken: widget.accessToken,
              services: widget.services,
              accountId: widget.accountId,
              initialCreateKind: 'tasks',
              autoOpenCreate: true,
            ),
          ),
        )
        .then((_) {
          if (mounted) {
            _controller.refresh();
          }
        });
  }

  Future<void> _openTaskListChooser(
    List<ClientCalendar> taskCalendars,
    List<ClientTask> allTasks,
  ) async {
    await CaleeBottomSheet.show<void>(
      context: context,
      title: 'Task Lists',
      child: TaskListChooser(
        taskCalendars: taskCalendars,
        selectedCalendar: _controller.selectedCalendar,
        allTasks: allTasks,
        onSelect: (calendar) {
          _controller.setSelectedCalendar(calendar);
          Navigator.of(context).pop();
        },
        onAddTaskList: () {
          Navigator.of(context).pop();
          _openCollectionCreateShortcut();
        },
      ),
    );
  }

  Future<void> _openCreateTaskSheet(List<ClientCalendar> taskCalendars) async {
    if (taskCalendars.isEmpty || _controller.isCreatingTask) {
      return;
    }

    await CaleeBottomSheet.show<bool>(
      context: context,
      title: 'New Task',
      child: CreateTaskForm(
        taskCalendars: taskCalendars,
        initialCalendar: _controller.selectedCalendar,
        defaultTaskListId: _controller.overview?.preferences.defaultTaskListId,
        onCreate:
            ({
              required taskCalendar,
              required title,
              dueAt,
              description,
            }) async {
              await _controller.createTask(
                taskCalendar: taskCalendar,
                title: title,
                dueAt: dueAt,
                description: description,
              );
            },
      ),
    );
  }

  Future<void> _openEditTaskSheet(ClientTask task) async {
    if (_controller.editingTaskIds.contains(task.id) ||
        _controller.deletingTaskIds.contains(task.id)) {
      return;
    }

    await CaleeBottomSheet.show<bool>(
      context: context,
      title: 'Edit Task',
      child: EditTaskForm(
        task: task,
        onUpdate: ({required task, required title, dueAt, description}) async {
          await _controller.updateTask(
            task: task,
            title: title,
            dueAt: dueAt,
            description: description,
          );
        },
      ),
    );
  }

  Future<void> _confirmDeleteTask(ClientTask task) async {
    if (_controller.deletingTaskIds.contains(task.id)) {
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

    try {
      await _controller.deleteTask(task);
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('Unable to delete task.')));
      }
    }
  }

  Future<void> _toggleTaskStatus(ClientTask task) async {
    try {
      await _controller.toggleTaskStatus(task);
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('Unable to update task.')));
      }
    }
  }

  void _openSearchSheet(
    List<ClientCalendar> taskCalendars,
    List<ClientTask> allTasks,
  ) {
    _searchController.clear();
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: CaleeColors.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(
          top: Radius.circular(CaleeRadius.sheet),
        ),
      ),
      builder: (_) => TaskSearchSheet(
        searchController: _searchController,
        searchTasks: (query) => _searchTaskList(query, allTasks, taskCalendars),
        calendarNameForTask: _calendarNameForTask,
        formatDueLabel: _formatDueLabel,
        onResultTap: (task) {
          Navigator.of(context).pop();
          _openEditTaskSheet(task);
        },
      ),
    );
  }

  bool _matchesSearch(
    ClientTask task,
    String query,
    List<ClientCalendar> taskCalendars,
  ) {
    final q = query.toLowerCase();
    if ((task.title).toLowerCase().contains(q)) return true;
    if ((task.description ?? '').toLowerCase().contains(q)) return true;
    if (_calendarNameForTask(task, taskCalendars).toLowerCase().contains(q)) {
      return true;
    }
    if (_formatDueLabel(task.dueAt).toLowerCase().contains(q)) return true;
    return false;
  }

  List<ClientTask> _searchTaskList(
    String query,
    List<ClientTask> allTasks,
    List<ClientCalendar> taskCalendars,
  ) {
    if (query.trim().isEmpty) return [];
    return allTasks
        .where((t) => _matchesSearch(t, query, taskCalendars))
        .toList();
  }

  String _rawCalendarId(ClientCalendar calendar) {
    final prefix = '${calendar.serviceId}:';
    if (calendar.id.startsWith(prefix)) {
      return calendar.id.substring(prefix.length);
    }
    return calendar.id;
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
            (task) => TaskRow(
              key: ValueKey(task.id),
              task: task,
              dueLabel: _formatDueLabel(task.dueAt),
              listName: _calendarNameForTask(task, taskCalendars),
              isUpdating: _controller.updatingTaskIds.contains(task.id),
              isDeleting: _controller.deletingTaskIds.contains(task.id),
              isEditing: _controller.editingTaskIds.contains(task.id),
              onToggle: () => _toggleTaskStatus(task),
              onEdit: () => _openEditTaskSheet(task),
              onDelete: () => _confirmDeleteTask(task),
            ),
          )
          .toList(),
    );
  }

  PreferredSizeWidget _buildTopBar({
    required List<ClientCalendar> taskCalendars,
    required List<ClientTask> allTasks,
  }) {
    final selectedCalendar = _controller.selectedCalendar;
    final subtitle = selectedCalendar == null
        ? 'All task lists'
        : selectedCalendar.name;

    return PreferredSize(
      preferredSize: const Size.fromHeight(64),
      child: SafeArea(
        bottom: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(
            CaleeSpacing.md,
            CaleeSpacing.xs,
            CaleeSpacing.xs,
            CaleeSpacing.xs,
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              // Context label
              Expanded(
                child: Text(
                  subtitle,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 17,
                    fontWeight: FontWeight.w600,
                    color: CaleeColors.textPrimary,
                  ),
                ),
              ),
              // Search icon
              if (taskCalendars.isNotEmpty)
                IconButton(
                  onPressed: () => _openSearchSheet(taskCalendars, allTasks),
                  icon: const Icon(Icons.search),
                  iconSize: 22,
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints(
                    minWidth: 44,
                    minHeight: 44,
                  ),
                  color: CaleeColors.primary,
                  tooltip: 'Search tasks',
                ),
              // Filter icon
              if (taskCalendars.isNotEmpty)
                IconButton(
                  onPressed: () =>
                      _openTaskListChooser(taskCalendars, allTasks),
                  icon: const Icon(Icons.tune),
                  iconSize: 22,
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints(
                    minWidth: 44,
                    minHeight: 44,
                  ),
                  color: CaleeColors.primary,
                  tooltip: 'Task lists',
                ),
              // Add icon
              IconButton(
                onPressed: taskCalendars.isEmpty
                    ? _openCollectionCreateShortcut
                    : (_controller.isCreatingTask
                          ? null
                          : () => _openCreateTaskSheet(taskCalendars)),
                icon: const Icon(Icons.add),
                iconSize: 22,
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints(minWidth: 44, minHeight: 44),
                color: CaleeColors.primary,
                tooltip: 'Add task',
              ),
            ],
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _controller,
      builder: (context, _) {
        if (_controller.isLoading && _controller.overview == null) {
          return const CaleeScaffold(
            body: Center(child: CircularProgressIndicator()),
          );
        }

        if (_controller.error != null && _controller.overview == null) {
          return CaleeScaffold(
            body: CaleeEmptyState(
              icon: Icons.cloud_off_outlined,
              title: 'We couldn\'t load your tasks',
              body: 'Check your connection and try again.',
              action: FilledButton(
                onPressed: _controller.refresh,
                child: const Text('Try again'),
              ),
            ),
          );
        }

        final overview = _controller.overview;
        if (overview == null) {
          return CaleeScaffold(
            body: CaleeEmptyState(
              icon: Icons.checklist_outlined,
              title: 'No task lists yet',
              body: 'Create a task list to start keeping track.',
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

        // Reset selected calendar if it no longer exists after reload
        final selectedCalendar = _controller.selectedCalendar;
        if (selectedCalendar != null &&
            !taskCalendars.any((c) => c.id == selectedCalendar.id)) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted) _controller.setSelectedCalendar(null);
          });
        }

        if (taskCalendars.isEmpty && allTasks.isEmpty) {
          final serviceErrors = _controller.calendarServiceErrors;
          if (serviceErrors.isNotEmpty) {
            return CaleeScaffold(
              appBar: _buildTopBar(
                taskCalendars: taskCalendars,
                allTasks: allTasks,
              ),
              body: CalendarServiceConnectionErrorState(
                errors: serviceErrors,
                onRetry: _controller.refresh,
              ),
            );
          }
          return CaleeScaffold(
            appBar: _buildTopBar(
              taskCalendars: taskCalendars,
              allTasks: allTasks,
            ),
            body: CaleeEmptyState(
              icon: Icons.checklist_outlined,
              title: 'No task lists yet',
              body: 'Create a task list to start keeping track.',
              action: FilledButton.icon(
                onPressed: _openCollectionCreateShortcut,
                icon: const Icon(Icons.add),
                label: const Text('Create task list'),
              ),
            ),
          );
        }

        // Apply task list filter
        final filteredTasks = selectedCalendar == null
            ? allTasks
            : allTasks.where((t) {
                final sel = selectedCalendar;
                return t.calendarId == sel.id ||
                    t.calendarId == _rawCalendarId(sel) ||
                    '${t.serviceId}:${t.calendarId}' == sel.id;
              }).toList();

        final openTasks = filteredTasks.where((t) => !t.isCompleted).toList();
        final completedTasks = filteredTasks
            .where((t) => t.isCompleted)
            .toList();

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

        final noDateTasks =
            openTasks
                .where((t) => t.dueAt == null || t.dueAt!.trim().isEmpty)
                .toList()
              ..sort((a, b) => a.title.compareTo(b.title));

        final taskServiceErrors = _controller.calendarServiceErrors;
        return CaleeScaffold(
          appBar: _buildTopBar(
            taskCalendars: taskCalendars,
            allTasks: allTasks,
          ),
          body: Column(
            children: [
              if (taskServiceErrors.isNotEmpty && taskCalendars.isNotEmpty)
                CalendarServiceWarningBanner(errors: taskServiceErrors),
              Expanded(
                child: RefreshIndicator(
                  onRefresh: () => _controller.refresh(),
                  child: ListView(
                    padding: const EdgeInsets.symmetric(
                      horizontal: CaleeSpacing.pagePadding,
                      vertical: CaleeSpacing.md,
                    ),
                    children: [
                      // ── Empty state when no open tasks ───────────────────
                      if (openTasks.isEmpty && taskCalendars.isNotEmpty)
                        allTasks.isEmpty
                            ? CaleeSection(
                                children: [
                                  CaleeListRow(
                                    title: 'Add your first task',
                                    subtitle:
                                        'Your task list is ready — tap here to add a task.',
                                    leading: const Icon(
                                      Icons.add_circle_outline,
                                      color: CaleeColors.primary,
                                      size: 22,
                                    ),
                                    onTap: () =>
                                        _openCreateTaskSheet(taskCalendars),
                                  ),
                                ],
                              )
                            : CaleeSection(
                                children: [
                                  CaleeListRow(
                                    title: 'No open tasks',
                                    subtitle: 'You\'re all caught up.',
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
                        _buildSmartSection(
                          'Upcoming',
                          upcomingTasks,
                          taskCalendars,
                        ),
                        const SizedBox(height: CaleeSpacing.sectionSpacing),
                      ],

                      // ── No Date ───────────────────────────────────────────
                      if (noDateTasks.isNotEmpty) ...[
                        _buildSmartSection(
                          'No Date',
                          noDateTasks,
                          taskCalendars,
                        ),
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
                        CompletedTasksSection(
                          tasks: completedTasks,
                          calendars: taskCalendars,
                          isExpanded: _controller.completedExpanded,
                          onToggleExpanded: () {
                            _controller.setCompletedExpanded(
                              !_controller.completedExpanded,
                            );
                          },
                          updatingIds: _controller.updatingTaskIds,
                          deletingIds: _controller.deletingTaskIds,
                          editingIds: _controller.editingTaskIds,
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
              ),
            ],
          ),
        );
      },
    );
  }
}

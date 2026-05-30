import 'package:flutter/material.dart';

import '../../data/api/calee_hub_client.dart';
import '../../data/models/client_bootstrap.dart';
import '../settings/calendar_collections_page.dart';
import '../../data/models/client_calendar.dart';
import '../../data/models/client_task.dart';

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

    final created = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      builder: (context) => _CreateTaskSheet(
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

    final updated = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      builder: (context) => _EditTaskSheet(
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

    final shouldDelete = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete task?'),
        content: Text('Delete "${task.title}"? This cannot be undone.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );

    if (shouldDelete != true || !mounted) {
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

  String _formatDueAt(String? value) {
    if (value == null || value.trim().isEmpty) {
      return 'No due date';
    }

    final parsed = DateTime.tryParse(value);
    if (parsed == null) {
      return value;
    }

    final local = parsed.toLocal();
    return 'Due ${local.day}/${local.month}/${local.year}';
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<_TasksOverview>(
      future: _overviewFuture,
      builder: (context, snapshot) {
        if (snapshot.connectionState == ConnectionState.waiting) {
          return const Center(child: CircularProgressIndicator());
        }

        if (snapshot.hasError) {
          return _TasksErrorState(onRetry: _reloadOverview);
        }

        final overview = snapshot.data;
        if (overview == null) {
          return _TasksEmptyState(
            action: FilledButton.icon(
              onPressed: _openCollectionCreateShortcut,
              icon: const Icon(Icons.add),
              label: const Text('Create task list'),
            ),
          );
        }

        final taskCalendars = overview.calendarList.calendars
            .where((calendar) => calendar.isTaskKind)
            .toList();
        final tasks = overview.taskList.tasks;

        if (taskCalendars.isEmpty && tasks.isEmpty) {
          return _TasksEmptyState(
            action: FilledButton.icon(
              onPressed: _openCollectionCreateShortcut,
              icon: const Icon(Icons.add),
              label: const Text('Create task list'),
            ),
          );
        }

        return Scaffold(
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
              padding: const EdgeInsets.all(16),
              children: [
                _SectionHeader(
                  title: 'Task lists',
                  subtitle: '${taskCalendars.length} found',
                ),
                const SizedBox(height: 8),
                if (taskCalendars.isEmpty)
                  _EmptySectionMessage(
                    message: 'No task lists found yet.',
                    action: TextButton.icon(
                      onPressed: _openCollectionCreateShortcut,
                      icon: const Icon(Icons.add),
                      label: const Text('Create task list'),
                    ),
                  )
                else
                  ...taskCalendars.map(_TaskListTile.new),
                const SizedBox(height: 24),
                _SectionHeader(
                  title: 'Tasks',
                  subtitle: '${tasks.length} found',
                ),
                const SizedBox(height: 8),
                if (tasks.isEmpty)
                  const _EmptySectionMessage(message: 'No tasks found yet.')
                else
                  ...tasks.map(
                    (task) => _TaskTile(
                      task: task,
                      dueLabel: _formatDueAt(task.dueAt),
                      isUpdating: _updatingTaskIds.contains(task.id),
                      isDeleting: _deletingTaskIds.contains(task.id),
                      isEditing: _editingTaskIds.contains(task.id),
                      onToggle: () => _toggleTaskStatus(task),
                      onEdit: () => _openEditTaskSheet(task),
                      onDelete: () => _confirmDeleteTask(task),
                    ),
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

class _CreateTaskSheet extends StatefulWidget {
  const _CreateTaskSheet({
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
  State<_CreateTaskSheet> createState() => _CreateTaskSheetState();
}

class _CreateTaskSheetState extends State<_CreateTaskSheet> {
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
        dueAt: _selectedDueDate == null ? null : _formatDate(_selectedDueDate!),
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
    final bottomInset = MediaQuery.viewInsetsOf(context).bottom;

    return SafeArea(
      child: Padding(
        padding: EdgeInsets.fromLTRB(16, 16, 16, 16 + bottomInset),
        child: Form(
          key: _formKey,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  'New task',
                  style: Theme.of(context).textTheme.titleLarge,
                ),
                const SizedBox(height: 16),
                DropdownButtonFormField<ClientCalendar>(
                  initialValue: _selectedTaskCalendar,
                  items: widget.taskCalendars
                      .map(
                        (calendar) => DropdownMenuItem(
                          value: calendar,
                          child: Text(
                              '${calendar.name} · ${calendar.serviceName}'),
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
                  decoration: const InputDecoration(
                    labelText: 'Task list',
                    border: OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: 12),
                TextFormField(
                  controller: _titleController,
                  enabled: !_isSubmitting,
                  autofocus: true,
                  decoration: const InputDecoration(
                    labelText: 'Title',
                    border: OutlineInputBorder(),
                  ),
                  textInputAction: TextInputAction.next,
                  validator: (value) {
                    if ((value ?? '').trim().isEmpty) {
                      return 'Enter a task title';
                    }

                    return null;
                  },
                ),
                const SizedBox(height: 12),
                OutlinedButton.icon(
                  onPressed: _isSubmitting ? null : _pickDueDate,
                  icon: const Icon(Icons.event_outlined),
                  label: Text(
                    _selectedDueDate == null
                        ? 'Add due date'
                        : 'Due ${_formatDate(_selectedDueDate!)}',
                  ),
                ),
                if (_selectedDueDate != null)
                  TextButton(
                    onPressed: _isSubmitting
                        ? null
                        : () {
                            setState(() {
                              _selectedDueDate = null;
                            });
                          },
                    child: const Text('Remove due date'),
                  ),
                const SizedBox(height: 12),
                TextFormField(
                  controller: _descriptionController,
                  enabled: !_isSubmitting,
                  decoration: const InputDecoration(
                    labelText: 'Notes',
                    border: OutlineInputBorder(),
                  ),
                  minLines: 2,
                  maxLines: 4,
                ),
                const SizedBox(height: 16),
                FilledButton(
                  onPressed: _isSubmitting ? null : _submit,
                  child: _isSubmitting
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Text('Create task'),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _EditTaskSheet extends StatefulWidget {
  const _EditTaskSheet({
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
  State<_EditTaskSheet> createState() => _EditTaskSheetState();
}

class _EditTaskSheetState extends State<_EditTaskSheet> {
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
        dueAt: _selectedDueDate == null ? null : _formatDate(_selectedDueDate!),
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
    final bottomInset = MediaQuery.viewInsetsOf(context).bottom;

    return SafeArea(
      child: Padding(
        padding: EdgeInsets.fromLTRB(16, 16, 16, 16 + bottomInset),
        child: Form(
          key: _formKey,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  'Edit task',
                  style: Theme.of(context).textTheme.titleLarge,
                ),
                const SizedBox(height: 16),
                TextFormField(
                  controller: _titleController,
                  enabled: !_isSubmitting,
                  autofocus: true,
                  decoration: const InputDecoration(
                    labelText: 'Title',
                    border: OutlineInputBorder(),
                  ),
                  textInputAction: TextInputAction.next,
                  validator: (value) {
                    if ((value ?? '').trim().isEmpty) {
                      return 'Enter a task title';
                    }

                    return null;
                  },
                ),
                const SizedBox(height: 12),
                OutlinedButton.icon(
                  onPressed: _isSubmitting ? null : _pickDueDate,
                  icon: const Icon(Icons.event_outlined),
                  label: Text(
                    _selectedDueDate == null
                        ? 'Add due date'
                        : 'Due ${_formatDate(_selectedDueDate!)}',
                  ),
                ),
                if (_selectedDueDate != null)
                  TextButton(
                    onPressed: _isSubmitting
                        ? null
                        : () {
                            setState(() {
                              _selectedDueDate = null;
                            });
                          },
                    child: const Text('Remove due date'),
                  ),
                const SizedBox(height: 12),
                TextFormField(
                  controller: _descriptionController,
                  enabled: !_isSubmitting,
                  decoration: const InputDecoration(
                    labelText: 'Notes',
                    border: OutlineInputBorder(),
                  ),
                  minLines: 2,
                  maxLines: 4,
                ),
                const SizedBox(height: 16),
                FilledButton(
                  onPressed: _isSubmitting ? null : _submit,
                  child: _isSubmitting
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Text('Save task'),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _TaskListTile extends StatelessWidget {
  const _TaskListTile(this.calendar);

  final ClientCalendar calendar;

  @override
  Widget build(BuildContext context) {
    final firstLetter = calendar.name.trim().isNotEmpty
        ? calendar.name.trim().characters.first.toUpperCase()
        : '?';

    return Card(
      child: ListTile(
        leading: CircleAvatar(child: Text(firstLetter)),
        title: Text(calendar.name),
        subtitle: Text(
          [
            if (calendar.serviceName.trim().isNotEmpty)
              'From ${calendar.serviceName}',
            if (calendar.readOnly) 'Read-only',
          ].where((item) => item.trim().isNotEmpty).join(' · '),
        ),
      ),
    );
  }
}

class _TaskTile extends StatelessWidget {
  const _TaskTile({
    required this.task,
    required this.dueLabel,
    required this.isUpdating,
    required this.isDeleting,
    required this.isEditing,
    required this.onToggle,
    required this.onEdit,
    required this.onDelete,
  });

  final ClientTask task;
  final String dueLabel;
  final bool isUpdating;
  final bool isDeleting;
  final bool isEditing;
  final VoidCallback onToggle;
  final VoidCallback onEdit;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: ListTile(
        leading: isUpdating
            ? const SizedBox(
                width: 24,
                height: 24,
                child: CircularProgressIndicator(strokeWidth: 2),
              )
            : IconButton(
                icon: Icon(
                  task.isCompleted
                      ? Icons.check_circle_outline
                      : Icons.radio_button_unchecked,
                ),
                onPressed: onToggle,
                tooltip: task.isCompleted ? 'Mark as not done' : 'Mark as done',
              ),
        title: Text(task.title),
        trailing: isDeleting || isEditing
            ? const SizedBox(
                width: 24,
                height: 24,
                child: CircularProgressIndicator(strokeWidth: 2),
              )
            : PopupMenuButton<String>(
                onSelected: (value) {
                  if (value == 'edit') {
                    onEdit();
                  }
                  if (value == 'delete') {
                    onDelete();
                  }
                },
                itemBuilder: (context) => const [
                  PopupMenuItem(
                    value: 'edit',
                    child: Text('Edit task'),
                  ),
                  PopupMenuItem(
                    value: 'delete',
                    child: Text('Delete task'),
                  ),
                ],
              ),
        subtitle: Text(
          [
            task.statusLabel,
            dueLabel,
            if (task.serviceName.trim().isNotEmpty) 'From ${task.serviceName}',
            if ((task.description ?? '').trim().isNotEmpty) task.description!,
          ].where((item) => item.trim().isNotEmpty).join(' · '),
        ),
      ),
    );
  }
}

class _SectionHeader extends StatelessWidget {
  const _SectionHeader({
    required this.title,
    required this.subtitle,
  });

  final String title;
  final String subtitle;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Text(title, style: Theme.of(context).textTheme.titleLarge),
        Text(subtitle, style: Theme.of(context).textTheme.bodyMedium),
      ],
    );
  }
}

class _EmptySectionMessage extends StatelessWidget {
  const _EmptySectionMessage({
    required this.message,
    this.action,
  });

  final String message;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(message),
            if (action != null) ...[
              const SizedBox(height: 8),
              action!,
            ],
          ],
        ),
      ),
    );
  }
}

class _TasksEmptyState extends StatelessWidget {
  const _TasksEmptyState({
    this.action,
  });

  final Widget? action;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Card(
        margin: const EdgeInsets.all(24),
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text(
                'No task lists or tasks found yet.',
                textAlign: TextAlign.center,
              ),
              if (action != null) ...[
                const SizedBox(height: 16),
                action!,
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class _TasksErrorState extends StatelessWidget {
  const _TasksErrorState({
    required this.onRetry,
  });

  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Card(
        margin: const EdgeInsets.all(24),
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.cloud_off_outlined, size: 40),
              const SizedBox(height: 12),
              Text(
                'Unable to load tasks from Calee.',
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.titleMedium,
              ),
              const SizedBox(height: 8),
              Text(
                'Check your connection, then try again.',
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.bodyMedium,
              ),
              const SizedBox(height: 16),
              FilledButton(
                onPressed: onRetry,
                child: const Text('Try again'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

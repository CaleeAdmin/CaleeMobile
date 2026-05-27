import 'package:flutter/material.dart';

import '../../data/api/calee_hub_client.dart';
import '../../data/models/client_calendar.dart';
import '../../data/models/client_task.dart';

class TasksPage extends StatefulWidget {
  const TasksPage({
    required this.hubClient,
    required this.accessToken,
    super.key,
  });

  final CaleeHubClient hubClient;
  final String accessToken;

  @override
  State<TasksPage> createState() => _TasksPageState();
}

class _TasksPageState extends State<TasksPage> {
  late Future<_TasksOverview> _overviewFuture;
  bool _isCreatingTask = false;

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
          return const _TasksEmptyState();
        }

        final taskCalendars = overview.calendarList.calendars
            .where((calendar) => calendar.isTaskKind)
            .toList();
        final tasks = overview.taskList.tasks;

        if (taskCalendars.isEmpty && tasks.isEmpty) {
          return _TasksEmptyState(
            action: FilledButton.icon(
              onPressed: null,
              icon: const Icon(Icons.add),
              label: const Text('New task'),
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
                  const _EmptySectionMessage(
                    message: 'No task lists found yet.',
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
  });

  final ClientTask task;
  final String dueLabel;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: ListTile(
        leading: Icon(
          task.isCompleted
              ? Icons.check_circle_outline
              : Icons.radio_button_unchecked,
        ),
        title: Text(task.title),
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
  });

  final String message;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(padding: const EdgeInsets.all(16), child: Text(message)),
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

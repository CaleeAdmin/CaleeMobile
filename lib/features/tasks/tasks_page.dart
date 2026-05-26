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
          return const _TasksEmptyState();
        }

        return RefreshIndicator(
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
                const _EmptySectionMessage(message: 'No task lists found yet.')
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
            ],
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
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Text(message),
      ),
    );
  }
}

class _TasksEmptyState extends StatelessWidget {
  const _TasksEmptyState();

  @override
  Widget build(BuildContext context) {
    return const Center(
      child: Card(
        margin: EdgeInsets.all(24),
        child: Padding(
          padding: EdgeInsets.all(24),
          child: Text(
            'No task lists or tasks found yet.',
            textAlign: TextAlign.center,
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

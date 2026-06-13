import 'package:flutter/material.dart';

import '../../data/api/calee_hub_client.dart';
import '../../data/models/client_bootstrap.dart';
import '../../data/models/client_calendar.dart';
import '../../data/models/client_chore.dart';
import '../../data/models/client_task.dart';
import '../calendar/calendar_utils.dart';
import 'today_models.dart';
import 'today_repository.dart';

class TodayPage extends StatefulWidget {
  const TodayPage({
    required this.hubClient,
    required this.accessToken,
    required this.services,
    required this.households,
    this.onNavigateToCalendar,
    this.onNavigateToTasks,
    this.onNavigateToChores,
    super.key,
  });

  final CaleeHubClient hubClient;
  final String accessToken;
  final List<ClientService> services;
  final List<ClientContext> households;
  final VoidCallback? onNavigateToCalendar;
  final VoidCallback? onNavigateToTasks;
  final VoidCallback? onNavigateToChores;

  @override
  State<TodayPage> createState() => _TodayPageState();
}

class _TodayPageState extends State<TodayPage> {
  late final TodayRepository _repository;

  bool _isLoading = false;
  bool _hasLoadedOnce = false;
  TodayOverview? _overview;
  Object? _fatalError;

  bool get _hasChoreService =>
      widget.services.any((s) => s.supportsChores);

  @override
  void initState() {
    super.initState();
    _repository = TodayRepository(
      hubClient: widget.hubClient,
      accessToken: widget.accessToken,
      services: widget.services,
      households: widget.households,
    );
    _load();
  }

  Future<void> _load() async {
    if (_isLoading) return;
    setState(() {
      _isLoading = true;
      if (!_hasLoadedOnce) _fatalError = null;
    });

    try {
      final overview = await _repository.loadToday();
      if (mounted) {
        setState(() {
          _overview = overview;
          _isLoading = false;
          _hasLoadedOnce = true;
          _fatalError = null;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _fatalError = e;
          _isLoading = false;
          _hasLoadedOnce = true;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Scaffold(
      body: SafeArea(
        child: RefreshIndicator(
          onRefresh: _load,
          child: _buildBody(theme),
        ),
      ),
    );
  }

  Widget _buildBody(ThemeData theme) {
    if (!_hasLoadedOnce && _isLoading) {
      return const Center(child: CircularProgressIndicator());
    }

    if (_fatalError != null && _overview == null) {
      return _buildFatalError(theme);
    }

    return CustomScrollView(
      slivers: [
        SliverAppBar(
          title: const Text('Today'),
          floating: true,
          snap: true,
          centerTitle: false,
        ),
        SliverPadding(
          padding: const EdgeInsets.only(bottom: 24),
          sliver: SliverList(
            delegate: SliverChildListDelegate(_buildSections(theme)),
          ),
        ),
      ],
    );
  }

  List<Widget> _buildSections(ThemeData theme) {
    final overview = _overview;
    if (overview == null) return [];

    return [
      _buildCalendarSection(theme, overview),
      _buildTasksSection(theme, overview),
      if (_hasChoreService) _buildChoresSection(theme, overview),
      _buildDisplayPlaceholder(theme),
    ];
  }

  // ── Calendar section ─────────────────────────────────────────────────────

  Widget _buildCalendarSection(ThemeData theme, TodayOverview overview) {
    return _Section(
      title: 'Calendar',
      onViewAll: widget.onNavigateToCalendar,
      viewAllLabel: 'View Calendar',
      child: overview.hasCalendarError
          ? _ErrorRow(message: 'Could not load calendar events.')
          : overview.eventsToday.isEmpty
          ? const _EmptyRow(message: 'No events today')
          : Column(
              children: overview.eventsToday
                  .take(5)
                  .map((e) => _EventRow(event: e, theme: theme))
                  .toList(),
            ),
    );
  }

  // ── Tasks section ────────────────────────────────────────────────────────

  Widget _buildTasksSection(ThemeData theme, TodayOverview overview) {
    final hasItems =
        overview.overdueTasks.isNotEmpty || overview.tasksDueToday.isNotEmpty;

    return _Section(
      title: 'Tasks',
      onViewAll: widget.onNavigateToTasks,
      viewAllLabel: 'View Tasks',
      child: overview.hasTasksError
          ? _ErrorRow(message: 'Could not load tasks.')
          : !hasItems
          ? const _EmptyRow(message: 'No tasks due today')
          : Column(
              children: [
                ...overview.overdueTasks
                    .take(5)
                    .map((t) => _TaskRow(task: t, theme: theme, overdue: true)),
                ...overview.tasksDueToday
                    .take(5)
                    .map(
                      (t) => _TaskRow(task: t, theme: theme, overdue: false),
                    ),
              ],
            ),
    );
  }

  // ── Chores section ───────────────────────────────────────────────────────

  Widget _buildChoresSection(ThemeData theme, TodayOverview overview) {
    final hasItems =
        overview.overdueChores.isNotEmpty || overview.choresDueToday.isNotEmpty;

    return _Section(
      title: 'Chores',
      onViewAll: widget.onNavigateToChores,
      viewAllLabel: 'View Chores',
      child: overview.hasChoresError
          ? _ErrorRow(message: 'Could not load chores.')
          : !hasItems
          ? const _EmptyRow(message: 'No chores due today')
          : Column(
              children: [
                ...overview.overdueChores
                    .take(5)
                    .map((c) => _ChoreRow(chore: c, theme: theme, overdue: true)),
                ...overview.choresDueToday
                    .take(5)
                    .map(
                      (c) => _ChoreRow(chore: c, theme: theme, overdue: false),
                    ),
              ],
            ),
    );
  }

  // ── Display placeholder ──────────────────────────────────────────────────

  Widget _buildDisplayPlaceholder(ThemeData theme) {
    return _Section(
      title: 'Calee Display',
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Text(
          'Display status is coming soon.',
          style: theme.textTheme.bodyMedium?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
            fontStyle: FontStyle.italic,
          ),
        ),
      ),
    );
  }

  // ── Fatal error ──────────────────────────────────────────────────────────

  Widget _buildFatalError(ThemeData theme) {
    return ListView(
      children: [
        const SizedBox(height: 80),
        Center(
          child: Column(
            children: [
              Icon(
                Icons.error_outline,
                size: 48,
                color: theme.colorScheme.error,
              ),
              const SizedBox(height: 16),
              Text('Could not load Today', style: theme.textTheme.titleMedium),
              const SizedBox(height: 8),
              TextButton(onPressed: _load, child: const Text('Try again')),
            ],
          ),
        ),
      ],
    );
  }
}

// ── Section wrapper ──────────────────────────────────────────────────────────

class _Section extends StatelessWidget {
  const _Section({
    required this.title,
    required this.child,
    this.onViewAll,
    this.viewAllLabel,
  });

  final String title;
  final Widget child;
  final VoidCallback? onViewAll;
  final String? viewAllLabel;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 20, 16, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  title,
                  style: theme.textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              if (onViewAll != null && viewAllLabel != null)
                TextButton(
                  onPressed: onViewAll,
                  style: TextButton.styleFrom(
                    padding: EdgeInsets.zero,
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  ),
                  child: Text(viewAllLabel!),
                ),
            ],
          ),
          const SizedBox(height: 4),
          Card(
            margin: EdgeInsets.zero,
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 4),
              child: child,
            ),
          ),
        ],
      ),
    );
  }
}

// ── Reusable rows ────────────────────────────────────────────────────────────

class _EmptyRow extends StatelessWidget {
  const _EmptyRow({required this.message});
  final String message;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      child: Text(
        message,
        style: theme.textTheme.bodyMedium?.copyWith(
          color: theme.colorScheme.onSurfaceVariant,
        ),
      ),
    );
  }
}

class _ErrorRow extends StatelessWidget {
  const _ErrorRow({required this.message});
  final String message;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      child: Row(
        children: [
          Icon(Icons.warning_amber_rounded,
              size: 16, color: theme.colorScheme.error),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              message,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.error,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _EventRow extends StatelessWidget {
  const _EventRow({required this.event, required this.theme});
  final ClientEvent event;
  final ThemeData theme;

  @override
  Widget build(BuildContext context) {
    final timeLabel = eventTimeLabel(event);
    return ListTile(
      dense: true,
      leading: Icon(
        event.allDay ? Icons.event_available : Icons.schedule,
        size: 18,
        color: theme.colorScheme.primary,
      ),
      title: Text(event.title, maxLines: 1, overflow: TextOverflow.ellipsis),
      trailing: Text(
        timeLabel,
        style: theme.textTheme.bodySmall?.copyWith(
          color: theme.colorScheme.onSurfaceVariant,
        ),
      ),
    );
  }
}

class _TaskRow extends StatelessWidget {
  const _TaskRow({
    required this.task,
    required this.theme,
    required this.overdue,
  });
  final ClientTask task;
  final ThemeData theme;
  final bool overdue;

  @override
  Widget build(BuildContext context) {
    return ListTile(
      dense: true,
      leading: Icon(
        Icons.radio_button_unchecked,
        size: 18,
        color: overdue ? theme.colorScheme.error : theme.colorScheme.primary,
      ),
      title: Text(task.title, maxLines: 1, overflow: TextOverflow.ellipsis),
      trailing: overdue
          ? Text(
              'Overdue',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.error,
              ),
            )
          : null,
    );
  }
}

class _ChoreRow extends StatelessWidget {
  const _ChoreRow({
    required this.chore,
    required this.theme,
    required this.overdue,
  });
  final ClientChore chore;
  final ThemeData theme;
  final bool overdue;

  @override
  Widget build(BuildContext context) {
    return ListTile(
      dense: true,
      leading: Icon(
        Icons.check_circle_outline,
        size: 18,
        color: overdue ? theme.colorScheme.error : theme.colorScheme.primary,
      ),
      title: Text(chore.title, maxLines: 1, overflow: TextOverflow.ellipsis),
      trailing: overdue
          ? Text(
              'Overdue',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.error,
              ),
            )
          : null,
    );
  }
}

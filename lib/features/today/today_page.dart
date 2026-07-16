import 'package:flutter/material.dart';

import '../../data/api/calee_hub_client.dart';
import '../../data/models/client_bootstrap.dart';
import '../../data/models/client_calendar.dart';
import '../../data/models/client_chore.dart';
import '../../data/models/client_task.dart';
import '../../shared/meal_icon.dart';
import '../../ui/calee_design.dart';
import '../calendar/calendar_utils.dart';
import 'today_models.dart';
import 'today_repository.dart';

class TodayPage extends StatefulWidget {
  const TodayPage({
    required this.hubClient,
    required this.accessToken,
    required this.services,
    required this.households,
    required this.isFamilyUxContext,
    this.onNavigateToCalendar,
    this.onNavigateToTasks,
    this.onNavigateToChores,
    this.onNavigateToMeals,
    super.key,
  });

  final CaleeHubClient hubClient;
  final String accessToken;
  final List<ClientService> services;
  final List<ClientContext> households;
  final bool isFamilyUxContext;
  final VoidCallback? onNavigateToCalendar;
  final VoidCallback? onNavigateToTasks;
  final VoidCallback? onNavigateToChores;
  final VoidCallback? onNavigateToMeals;

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
      widget.isFamilyUxContext &&
      widget.services.any((s) => s.isActive && s.supportsChores);

  bool get _hasMealsService {
    if (!widget.isFamilyUxContext) return false;
    final portal = widget.services.where((s) => s.id == 'portal').firstOrNull;
    if (portal != null && portal.isActive && portal.supportsMeals) return true;
    return widget.services.any((s) => s.isActive && s.supportsMeals);
  }

  @override
  void initState() {
    super.initState();
    _repository = TodayRepository(
      hubClient: widget.hubClient,
      accessToken: widget.accessToken,
      services: widget.services,
      households: widget.households,
      isFamilyUxContext: widget.isFamilyUxContext,
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
    return CaleeScaffold(
      body: SafeArea(
        child: RefreshIndicator(onRefresh: _load, child: _buildBody()),
      ),
    );
  }

  Widget _buildBody() {
    if (!_hasLoadedOnce && _isLoading) {
      return const Center(child: CircularProgressIndicator());
    }

    if (_fatalError != null && _overview == null) {
      return _buildFatalError();
    }

    return ListView(
      padding: const EdgeInsets.symmetric(
        horizontal: CaleeSpacing.pagePadding,
        vertical: CaleeSpacing.md,
      ),
      children: [
        _buildPageHeader(),
        const SizedBox(height: CaleeSpacing.md),
        ..._buildSections(),
        const SizedBox(height: CaleeSpacing.lg),
      ],
    );
  }

  Widget _buildPageHeader() {
    final now = DateTime.now();
    final dateLabel = _formatHeaderDate(now);

    return Padding(
      padding: const EdgeInsets.only(bottom: CaleeSpacing.md),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'Today',
            style: TextStyle(
              fontSize: 32,
              fontWeight: FontWeight.bold,
              color: CaleeColors.textPrimary,
              height: 1.1,
            ),
          ),
          const SizedBox(height: 2),
          Text(
            dateLabel,
            style: const TextStyle(
              fontSize: 14,
              color: CaleeColors.textSecondary,
            ),
          ),
        ],
      ),
    );
  }

  String _formatHeaderDate(DateTime date) {
    const weekdays = [
      'Monday',
      'Tuesday',
      'Wednesday',
      'Thursday',
      'Friday',
      'Saturday',
      'Sunday',
    ];
    const months = [
      'January',
      'February',
      'March',
      'April',
      'May',
      'June',
      'July',
      'August',
      'September',
      'October',
      'November',
      'December',
    ];
    final weekday = weekdays[date.weekday - 1];
    final month = months[date.month - 1];
    return '$weekday, ${date.day} $month';
  }

  List<Widget> _buildSections() {
    final overview = _overview;
    if (overview == null) return [];

    return [
      _buildCalendarSection(overview),
      const SizedBox(height: CaleeSpacing.sectionSpacing),
      _buildTasksSection(overview),
      if (_hasChoreService) ...[
        const SizedBox(height: CaleeSpacing.sectionSpacing),
        _buildChoresSection(overview),
      ],
      if (_hasMealsService) ...[
        const SizedBox(height: CaleeSpacing.sectionSpacing),
        _buildMealsSection(overview),
      ],
      const SizedBox(height: CaleeSpacing.sectionSpacing),
      _buildCaleeDisplaySection(),
    ];
  }

  // ── Calendar section ──────────────────────────────────────────────────────────────

  Widget _buildCalendarSection(TodayOverview overview) {
    final rows = <Widget>[];
    String? trailing;

    if (overview.hasCalendarServiceError) {
      rows.add(_errorRow(overview.calendarServiceErrors.first.repairMessage));
    } else if (overview.hasCalendarError) {
      rows.add(_errorRow('Could not load calendar events.'));
    } else if (overview.eventsToday.isEmpty) {
      rows.add(_emptyRow('No events today'));
    } else {
      final count = overview.eventsToday.length;
      trailing = '$count ${count == 1 ? 'event' : 'events'}';
      for (final e in overview.eventsToday.take(5)) {
        rows.add(_buildEventRow(e));
      }
    }

    return CaleeSection(title: 'Calendar', trailing: trailing, children: rows);
  }

  Widget _buildEventRow(ClientEvent event) {
    final timeLabel = eventTimeLabel(event);
    return CaleeListRow(
      title: event.title,
      subtitle: timeLabel.isNotEmpty ? timeLabel : null,
      leading: Icon(
        event.allDay ? Icons.event_available : Icons.schedule,
        size: 18,
        color: CaleeColors.primary,
      ),
      onTap: widget.onNavigateToCalendar,
    );
  }

  // ── Tasks section ────────────────────────────────────────────────────────────────

  Widget _buildTasksSection(TodayOverview overview) {
    final hasItems =
        overview.overdueTasks.isNotEmpty || overview.tasksDueToday.isNotEmpty;
    final rows = <Widget>[];
    String? trailing;

    if (overview.hasTasksError) {
      rows.add(_errorRow('Could not load tasks.'));
    } else if (!hasItems) {
      rows.add(_emptyRow('No tasks due today'));
    } else {
      final parts = <String>[];
      if (overview.tasksDueToday.isNotEmpty) {
        parts.add('${overview.tasksDueToday.length} today');
      }
      if (overview.overdueTasks.isNotEmpty) {
        parts.add('${overview.overdueTasks.length} overdue');
      }
      trailing = parts.join(', ');
      for (final t in overview.overdueTasks.take(5)) {
        rows.add(_buildTaskRow(t, overdue: true));
      }
      for (final t in overview.tasksDueToday.take(5)) {
        rows.add(_buildTaskRow(t, overdue: false));
      }
    }

    return CaleeSection(title: 'Tasks', trailing: trailing, children: rows);
  }

  Widget _buildTaskRow(ClientTask task, {required bool overdue}) {
    return CaleeListRow(
      title: task.title,
      subtitle: overdue ? 'Overdue' : 'Due today',
      subtitleStyle: overdue
          ? const TextStyle(fontSize: 12, color: CaleeColors.destructive)
          : null,
      leading: Icon(
        Icons.radio_button_unchecked,
        size: 18,
        color: overdue ? CaleeColors.destructive : CaleeColors.textTertiary,
      ),
      onTap: widget.onNavigateToTasks,
    );
  }

  // ── Chores section ───────────────────────────────────────────────────────────────

  Widget _buildChoresSection(TodayOverview overview) {
    final hasItems =
        overview.overdueChores.isNotEmpty || overview.choresDueToday.isNotEmpty;
    final rows = <Widget>[];
    String? trailing;

    if (overview.hasChoresError) {
      rows.add(_errorRow('Could not load chores.'));
    } else if (!hasItems) {
      rows.add(_emptyRow('No chores due today'));
    } else {
      final parts = <String>[];
      if (overview.choresDueToday.isNotEmpty) {
        parts.add('${overview.choresDueToday.length} today');
      }
      if (overview.overdueChores.isNotEmpty) {
        parts.add('${overview.overdueChores.length} overdue');
      }
      trailing = parts.join(', ');
      for (final c in overview.overdueChores.take(5)) {
        rows.add(_buildChoreRow(c, overdue: true));
      }
      for (final c in overview.choresDueToday.take(5)) {
        rows.add(_buildChoreRow(c, overdue: false));
      }
    }

    return CaleeSection(title: 'Chores', trailing: trailing, children: rows);
  }

  Widget _buildChoreRow(ClientChore chore, {required bool overdue}) {
    return CaleeListRow(
      title: chore.title,
      subtitle: overdue ? 'Overdue' : 'Due today',
      subtitleStyle: overdue
          ? const TextStyle(fontSize: 12, color: CaleeColors.destructive)
          : null,
      leading: Icon(
        Icons.check_circle_outline,
        size: 18,
        color: overdue ? CaleeColors.destructive : CaleeColors.textTertiary,
      ),
      onTap: widget.onNavigateToChores,
    );
  }

  // ── Meals section ────────────────────────────────────────────────────────────────

  Widget _buildMealsSection(TodayOverview overview) {
    final rows = <Widget>[];

    if (overview.hasMealsError) {
      rows.add(_errorRow('Could not load meals.'));
    } else {
      final plannedMeals = [
        for (final mealType in ['breakfast', 'lunch', 'dinner'])
          overview.mealsToday.where((m) => m.mealType == mealType).firstOrNull,
      ].nonNulls.toList();

      if (plannedMeals.isEmpty) {
        rows.add(_emptyRow('No meals planned today'));
      } else {
        for (final meal in plannedMeals) {
          rows.add(
            CaleeListRow(
              title: meal.title,
              leading: Text(
                mealIconEmoji(title: meal.title, mealType: meal.mealType),
                style: const TextStyle(fontSize: 18),
              ),
              onTap: widget.onNavigateToMeals,
            ),
          );
        }
      }
    }

    return CaleeSection(title: "Today's Meals", children: rows);
  }

  // ── Calee Display section ───────────────────────────────────────────────────────

  // TODO(displays): Replace this placeholder once display linking is implemented.
  Widget _buildCaleeDisplaySection() {
    return CaleeSection(
      title: 'Calee Display',
      children: [_emptyRow('Display status and setup are coming soon.')],
    );
  }

  // ── Fatal error ───────────────────────────────────────────────────────────────

  Widget _buildFatalError() {
    return ListView(
      children: [
        const SizedBox(height: 80),
        Center(
          child: Column(
            children: [
              const Icon(
                Icons.error_outline,
                size: 48,
                color: CaleeColors.destructive,
              ),
              const SizedBox(height: CaleeSpacing.md),
              const Text(
                'Could not load Today',
                style: TextStyle(
                  fontSize: 17,
                  fontWeight: FontWeight.w600,
                  color: CaleeColors.textPrimary,
                ),
              ),
              const SizedBox(height: CaleeSpacing.sm),
              TextButton(onPressed: _load, child: const Text('Try again')),
            ],
          ),
        ),
      ],
    );
  }

  // ── Shared row helpers ───────────────────────────────────────────────────────────

  Widget _emptyRow(String message) {
    return CaleeListRow(
      title: message,
      titleStyle: const TextStyle(
        fontSize: 15,
        color: CaleeColors.textSecondary,
      ),
    );
  }

  Widget _errorRow(String message) {
    return CaleeListRow(
      title: message,
      titleStyle: const TextStyle(fontSize: 15, color: CaleeColors.destructive),
      leading: const Icon(
        Icons.warning_amber_rounded,
        size: 16,
        color: CaleeColors.destructive,
      ),
    );
  }
}

import 'package:flutter/material.dart';

import '../../data/api/calee_hub_client.dart';
import '../../data/models/client_calendar.dart';
import '../../data/models/client_chore.dart';

class ChoresPage extends StatefulWidget {
  const ChoresPage({
    required this.hubClient,
    required this.accessToken,
    super.key,
  });

  final CaleeHubClient hubClient;
  final String accessToken;

  @override
  State<ChoresPage> createState() => _ChoresPageState();
}

class _ChoresPageState extends State<ChoresPage> {
  late Future<_ChoresOverview> _overviewFuture;
  final Set<String> _updatingChoreIds = {};

  @override
  void initState() {
    super.initState();
    _overviewFuture = _loadOverview();
  }

  Future<_ChoresOverview> _loadOverview() async {
    final today = DateTime.now();
    final from = _formatDate(DateTime(today.year, 1, 1));
    final to = _formatDate(DateTime(today.year, 12, 31));

    final calendarList = await widget.hubClient.calendars(
      accessToken: widget.accessToken,
    );
    final choreList = await widget.hubClient.chores(
      accessToken: widget.accessToken,
      from: from,
      to: to,
    );

    return _ChoresOverview(
      calendarList: calendarList,
      choreList: choreList,
      from: from,
      to: to,
    );
  }

  void _reloadOverview() {
    setState(() {
      _overviewFuture = _loadOverview();
    });
  }

  Future<void> _toggleChoreCompletion(ClientChore chore) async {
    final choreId = chore.completionActionId;

    if (choreId.trim().isEmpty || _updatingChoreIds.contains(choreId)) {
      return;
    }

    setState(() {
      _updatingChoreIds.add(choreId);
    });

    try {
      if (chore.completedToday || chore.section == 'doneToday') {
        await widget.hubClient.undoChoreCompletion(
          accessToken: widget.accessToken,
          choreId: choreId,
        );
      } else {
        await widget.hubClient.completeChore(
          accessToken: widget.accessToken,
          choreId: choreId,
        );
      }

      if (mounted) {
        _reloadOverview();
      }
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Unable to update chore.')),
        );
      }
    } finally {
      if (mounted) {
        setState(() {
          _updatingChoreIds.remove(choreId);
        });
      }
    }
  }

  String _formatDate(DateTime value) {
    final year = value.year.toString().padLeft(4, '0');
    final month = value.month.toString().padLeft(2, '0');
    final day = value.day.toString().padLeft(2, '0');

    return '$year-$month-$day';
  }

  String _formatScheduledAt(ClientChore chore) {
    final value = chore.scheduledAt;
    if (value == null || value.trim().isEmpty) {
      return 'No scheduled date';
    }

    final parsed = DateTime.tryParse(value);
    if (parsed == null) {
      return value;
    }

    final local = parsed.toLocal();
    return 'Scheduled ${local.day}/${local.month}/${local.year}';
  }

  String _sectionTitle(String section) {
    switch (section) {
      case 'todoToday':
        return 'To do today';
      case 'overdue':
        return 'Overdue';
      case 'doneToday':
        return 'Done today';
      case 'future':
        return 'Future';
      case 'history':
        return 'History';
      default:
        return 'Other';
    }
  }

  String _sectionEmptyMessage(String section) {
    switch (section) {
      case 'todoToday':
        return 'No chores due today.';
      case 'overdue':
        return 'No overdue chores.';
      case 'doneToday':
        return 'No chores completed today yet.';
      case 'future':
        return 'No future chores found.';
      case 'history':
        return 'No completion history found.';
      default:
        return 'No chores found.';
    }
  }

  Map<String, List<ClientChore>> _groupChoresBySection(
    List<ClientChore> chores,
  ) {
    final grouped = <String, List<ClientChore>>{};

    for (final chore in chores) {
      final section = chore.section.trim().isEmpty ? 'future' : chore.section;
      grouped.putIfAbsent(section, () => []).add(chore);
    }

    for (final group in grouped.values) {
      group.sort((a, b) {
        final aDate = a.scheduledDate ?? a.scheduledAt ?? '';
        final bDate = b.scheduledDate ?? b.scheduledAt ?? '';
        final dateCompare = aDate.compareTo(bDate);
        if (dateCompare != 0) {
          return dateCompare;
        }

        return a.title.toLowerCase().compareTo(b.title.toLowerCase());
      });
    }

    return grouped;
  }

  int _weeklyPoints(List<ClientChore> chores) {
    return chores
        .where((chore) => chore.section == 'doneToday' || chore.completedToday)
        .fold<int>(0, (total, chore) => total + chore.points);
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<_ChoresOverview>(
      future: _overviewFuture,
      builder: (context, snapshot) {
        if (snapshot.connectionState == ConnectionState.waiting) {
          return const Center(child: CircularProgressIndicator());
        }

        if (snapshot.hasError) {
          return _ChoresErrorState(onRetry: _reloadOverview);
        }

        final overview = snapshot.data;
        if (overview == null) {
          return const _ChoresEmptyState();
        }

        final choreCalendars = overview.calendarList.calendars
            .where((calendar) => calendar.isChoreKind)
            .toList();
        final chores = overview.choreList.chores;
        final choresBySection = _groupChoresBySection(chores);
        final sectionOrder = [
          'todoToday',
          'overdue',
          'doneToday',
          'future',
          'history',
        ];

        if (choreCalendars.isEmpty && chores.isEmpty) {
          return const _ChoresEmptyState();
        }

        return RefreshIndicator(
          onRefresh: () async {
            _reloadOverview();
            await _overviewFuture;
          },
          child: ListView(
            padding: const EdgeInsets.all(16),
            children: [
              _ChoreSummaryCard(
                todoTodayCount: choresBySection['todoToday']?.length ?? 0,
                overdueCount: choresBySection['overdue']?.length ?? 0,
                doneTodayCount: choresBySection['doneToday']?.length ?? 0,
                weeklyPoints: _weeklyPoints(chores),
              ),
              const SizedBox(height: 24),
              _SectionHeader(
                title: 'Chore lists',
                subtitle: '${choreCalendars.length} found',
              ),
              const SizedBox(height: 8),
              if (choreCalendars.isEmpty)
                const _EmptySectionMessage(message: 'No chore lists found yet.')
              else
                ...choreCalendars.map(_ChoreListTile.new),
              const SizedBox(height: 24),
              _SectionHeader(
                title: 'Chores',
                subtitle: '${chores.length} found',
              ),
              const SizedBox(height: 8),
              if (chores.isEmpty)
                const _EmptySectionMessage(message: 'No chores found yet.')
              else
                for (final section in sectionOrder) ...[
                  _ChoreSection(
                    title: _sectionTitle(section),
                    chores: choresBySection[section] ?? const [],
                    emptyMessage: _sectionEmptyMessage(section),
                    scheduledLabelBuilder: _formatScheduledAt,
                    updatingChoreIds: _updatingChoreIds,
                    onToggleCompletion: _toggleChoreCompletion,
                  ),
                  const SizedBox(height: 16),
                ],
            ],
          ),
        );
      },
    );
  }
}

class _ChoresOverview {
  const _ChoresOverview({
    required this.calendarList,
    required this.choreList,
    required this.from,
    required this.to,
  });

  final ClientCalendarList calendarList;
  final ClientChoreList choreList;
  final String from;
  final String to;
}

class _ChoreSummaryCard extends StatelessWidget {
  const _ChoreSummaryCard({
    required this.todoTodayCount,
    required this.overdueCount,
    required this.doneTodayCount,
    required this.weeklyPoints,
  });

  final int todoTodayCount;
  final int overdueCount;
  final int doneTodayCount;
  final int weeklyPoints;

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Row(
          children: [
            Expanded(
              child: _SummaryMetric(
                label: 'Today',
                value: todoTodayCount.toString(),
              ),
            ),
            Expanded(
              child: _SummaryMetric(
                label: 'Overdue',
                value: overdueCount.toString(),
              ),
            ),
            Expanded(
              child: _SummaryMetric(
                label: 'Done',
                value: doneTodayCount.toString(),
              ),
            ),
            Expanded(
              child: Column(
                children: [
                  Text(
                    weeklyPoints.toString(),
                    style: textTheme.titleLarge,
                  ),
                  const Text('Points'),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _SummaryMetric extends StatelessWidget {
  const _SummaryMetric({
    required this.label,
    required this.value,
  });

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Text(value, style: Theme.of(context).textTheme.titleLarge),
        Text(label),
      ],
    );
  }
}

class _ChoreListTile extends StatelessWidget {
  const _ChoreListTile(this.calendar);

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

class _ChoreSection extends StatelessWidget {
  const _ChoreSection({
    required this.title,
    required this.chores,
    required this.emptyMessage,
    required this.scheduledLabelBuilder,
    required this.updatingChoreIds,
    required this.onToggleCompletion,
  });

  final String title;
  final List<ClientChore> chores;
  final String emptyMessage;
  final String Function(ClientChore chore) scheduledLabelBuilder;
  final Set<String> updatingChoreIds;
  final ValueChanged<ClientChore> onToggleCompletion;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _SectionHeader(
          title: title,
          subtitle: '${chores.length}',
        ),
        const SizedBox(height: 8),
        if (chores.isEmpty)
          _EmptySectionMessage(message: emptyMessage)
        else
          ...chores.map(
            (chore) => _ChoreTile(
              chore: chore,
              scheduledLabel: scheduledLabelBuilder(chore),
              isUpdating: updatingChoreIds.contains(chore.completionActionId),
              onToggleCompletion: () => onToggleCompletion(chore),
            ),
          ),
      ],
    );
  }
}

class _ChoreTile extends StatelessWidget {
  const _ChoreTile({
    required this.chore,
    required this.scheduledLabel,
    required this.isUpdating,
    required this.onToggleCompletion,
  });

  final ClientChore chore;
  final String scheduledLabel;
  final bool isUpdating;
  final VoidCallback onToggleCompletion;

  @override
  Widget build(BuildContext context) {
    final icon = chore.completedToday || chore.section == 'doneToday'
        ? Icons.check_circle_outline
        : Icons.radio_button_unchecked;
    final canToggle = chore.canToggleCompletion;

    return Card(
      child: ListTile(
        leading: isUpdating
            ? const SizedBox(
                width: 24,
                height: 24,
                child: CircularProgressIndicator(strokeWidth: 2),
              )
            : IconButton(
                icon: Icon(icon),
                onPressed: canToggle ? onToggleCompletion : null,
                tooltip: chore.completedToday || chore.section == 'doneToday'
                    ? 'Undo completion'
                    : 'Complete chore',
              ),
        title: Text(chore.title),
        subtitle: Text(
          [
            scheduledLabel,
            if (chore.points > 0)
              '${chore.points} point${chore.points == 1 ? '' : 's'}',
            if (chore.isRecurring) 'Repeats',
            if (chore.serviceName.trim().isNotEmpty)
              'From ${chore.serviceName}',
            if ((chore.description ?? '').trim().isNotEmpty) chore.description!,
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

class _ChoresEmptyState extends StatelessWidget {
  const _ChoresEmptyState();

  @override
  Widget build(BuildContext context) {
    return const Center(
      child: Text('No chores available yet.'),
    );
  }
}

class _ChoresErrorState extends StatelessWidget {
  const _ChoresErrorState({
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
              const Text('Unable to load chores.'),
              const SizedBox(height: 12),
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

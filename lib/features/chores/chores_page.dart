import 'package:flutter/material.dart';

import '../../data/api/calee_hub_client.dart';
import '../../data/models/client_bootstrap.dart';
import '../settings/calendar_collections_page.dart';
import '../settings/household_people_page.dart';
import '../../data/models/client_calendar.dart';
import '../../data/models/client_chore.dart';
import '../../data/models/client_chore_metadata.dart';
import 'chore_grouping.dart';
import '../../data/models/client_person.dart';
import '../../ui/calee_theme.dart';
import '../../ui/calee_widgets.dart';
import 'chores_controller.dart';
import 'chores_repository.dart';

// ─────────────────────────────────────────────
// Helpers
// ─────────────────────────────────────────────

String _formatChoreDate(DateTime value) {
  final year = value.year.toString().padLeft(4, '0');
  final month = value.month.toString().padLeft(2, '0');
  final day = value.day.toString().padLeft(2, '0');
  return '$year-$month-$day';
}

DateTime? _parseChoreDate(String? value) {
  if (value == null || value.trim().isEmpty) return null;
  final parsed = DateTime.tryParse(value);
  if (parsed == null) return null;
  return parsed.toLocal();
}

String? _choreRecurrenceToRrule(String? value) {
  switch (value) {
    case 'daily':
      return 'FREQ=DAILY';
    case 'weekly':
      return 'FREQ=WEEKLY';
    case 'monthly':
      return 'FREQ=MONTHLY';
    default:
      return null;
  }
}

String? _choreRruleToRecurrence(String? value) {
  final rrule = value?.trim().toUpperCase();
  if (rrule == 'FREQ=DAILY') return 'daily';
  if (rrule == 'FREQ=WEEKLY') return 'weekly';
  if (rrule == 'FREQ=MONTHLY') return 'monthly';
  return null;
}

String _choreErrorMessage(Object error, String fallback) {
  if (error is CaleeHubException && error.message.trim().isNotEmpty) {
    return error.message;
  }
  return fallback;
}

bool _isValidChorePoints(int? points) =>
    points != null && points >= 1 && points <= 100;

// ─────────────────────────────────────────────
// ChoresPage
// ─────────────────────────────────────────────

class ChoresPage extends StatefulWidget {
  const ChoresPage({
    required this.hubClient,
    required this.accessToken,
    required this.services,
    required this.households,
    super.key,
  });

  final CaleeHubClient hubClient;
  final String accessToken;
  final List<ClientService> services;
  final List<ClientContext> households;

  @override
  State<ChoresPage> createState() => _ChoresPageState();
}

class _ChoresPageState extends State<ChoresPage> {
  late final ChoresRepository _repository;
  late final ChoresController _controller;
  bool _historyExpanded = false;

  @override
  void initState() {
    super.initState();
    _repository = ChoresRepository(
      hubClient: widget.hubClient,
      accessToken: widget.accessToken,
      services: widget.services,
      households: widget.households,
    );
    _controller = ChoresController(repository: _repository);
    _controller.load();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Set<String> get _choreServiceIds => widget.services
      .where((service) => service.supportsChores)
      .map((service) => service.id)
      .where((id) => id.trim().isNotEmpty)
      .toSet();

  bool _isChoreServiceCalendar(ClientCalendar calendar) {
    return calendar.isChoreKind &&
        _choreServiceIds.contains(calendar.serviceId);
  }

  void _openCollectionCreateShortcut() {
    final choreServices = _repository.choreServices;

    if (choreServices.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('No chore service is available.')),
      );
      return;
    }

    Navigator.of(context)
        .push(
          MaterialPageRoute<void>(
            builder: (_) => CalendarCollectionsPage(
              hubClient: widget.hubClient,
              accessToken: widget.accessToken,
              services: choreServices,
              initialCreateKind: 'chores',
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

  Future<void> _openCreateChoreSheet(
    List<ClientCalendar> choreCalendars,
  ) async {
    final writableCalendars = choreCalendars
        .where((calendar) => !calendar.readOnly)
        .toList();

    if (writableCalendars.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('No writable chore list is available.')),
      );
      return;
    }

    final people = await _controller.fetchPeople();

    if (!mounted) return;

    final created = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      backgroundColor: CaleeColors.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(
          top: Radius.circular(CaleeRadius.sheet),
        ),
      ),
      builder: (context) => _CreateChoreSheet(
        calendars: writableCalendars,
        people: people,
        onCreate:
            ({
              required ClientCalendar calendar,
              required String title,
              String? scheduledAt,
              String? description,
              String? recurrence,
              required String? assigneePersonId,
              required int points,
            }) => _controller.createChore(
              calendar: calendar,
              title: title,
              scheduledAt: scheduledAt,
              description: description,
              recurrence: recurrence,
              assigneePersonId: assigneePersonId,
              points: points,
            ),
      ),
    );

    if (created == true && mounted) {
      // Controller already reloaded after createChore; nothing more needed.
    }
  }

  Future<void> _openEditChoreSheet(ClientChore chore) async {
    final choreId = chore.completionActionId;

    if (choreId.trim().isEmpty ||
        _controller.updatingChoreIds.contains(choreId)) {
      return;
    }

    final people = await _controller.fetchPeople();
    final metadata = await _controller.fetchMetadata(chore);

    if (!mounted) return;

    await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      backgroundColor: CaleeColors.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(
          top: Radius.circular(CaleeRadius.sheet),
        ),
      ),
      builder: (context) => _EditChoreSheet(
        chore: chore,
        people: people,
        metadata: metadata,
        onUpdate:
            ({
              required ClientChore chore,
              required String title,
              String? scheduledAt,
              String? description,
              String? recurrence,
              required String? assigneePersonId,
              required int points,
              required String approvalState,
            }) => _controller.updateChore(
              chore: chore,
              title: title,
              scheduledAt: scheduledAt,
              description: description,
              recurrence: recurrence,
              assigneePersonId: assigneePersonId,
              points: points,
              approvalState: approvalState,
            ),
      ),
    );
    // Controller reloads after updateChore; nothing more needed.
  }

  Future<void> _toggleChoreCompletion(ClientChore chore) async {
    try {
      await _controller.toggleChoreCompletion(chore);
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(_choreErrorMessage(error, 'Unable to update chore.')),
          ),
        );
      }
    }
  }

  void _showChoreActions(ClientChore chore) {
    final choreId = chore.completionActionId;
    if (choreId.trim().isEmpty) return;

    final isDone =
        chore.completedToday || chore.normalizedSection == 'doneToday';
    final actions = <CaleeAction>[
      if (chore.canToggleCompletion)
        CaleeAction(
          label: isDone ? 'Undo Done' : 'Mark Done',
          icon: isDone
              ? Icons.unpublished_outlined
              : Icons.check_circle_outline,
          onTap: () => _toggleChoreCompletion(chore),
        ),
      CaleeAction(
        label: 'Edit Chore',
        icon: Icons.edit_outlined,
        onTap: () => _openEditChoreSheet(chore),
      ),
    ];

    if (chore.isRecurring) {
      actions.addAll([
        CaleeAction(
          label: 'Skip This Time',
          icon: Icons.event_busy_outlined,
          onTap: () => _skipChore(chore),
        ),
        CaleeAction(
          label: 'Stop Repeating',
          icon: Icons.repeat_one_outlined,
          isDestructive: true,
          onTap: () => _stopRepeatingChore(chore),
        ),
        CaleeAction(
          label: 'Delete Permanently',
          icon: Icons.delete_outline,
          isDestructive: true,
          onTap: () => _confirmAndDeletePermanentChore(chore),
        ),
      ]);
    } else {
      actions.add(
        CaleeAction(
          label: 'Delete Chore',
          icon: Icons.delete_outline,
          isDestructive: true,
          onTap: () => _confirmAndDeletePermanentChore(chore),
        ),
      );
    }

    CaleeActionSheet.show(
      context: context,
      title: chore.title,
      actions: actions,
    );
  }

  Future<void> _skipChore(ClientChore chore) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Skip this chore?'),
        content: const Text(
          'This will skip only the current scheduled occurrence.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text(
              'Skip',
              style: TextStyle(fontWeight: FontWeight.w600),
            ),
          ),
        ],
      ),
    );

    if (confirmed == true && mounted) {
      try {
        await _controller.skipRecurringChore(chore);
        if (mounted) {
          ScaffoldMessenger.of(
            context,
          ).showSnackBar(const SnackBar(content: Text('Skipped this time.')));
        }
      } catch (error) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(_choreErrorMessage(error, 'Unable to skip chore.')),
            ),
          );
        }
      }
    }
  }

  Future<void> _stopRepeatingChore(ClientChore chore) async {
    final confirmed = await CaleeDestructiveDialog.show(
      context: context,
      title: 'Stop repeating?',
      body:
          'This chore will stop repeating after the current schedule. Existing completion history will remain.',
      confirmLabel: 'Stop Repeating',
    );

    if (confirmed && mounted) {
      try {
        await _controller.stopRepeatingChore(chore);
        if (mounted) {
          ScaffoldMessenger.of(
            context,
          ).showSnackBar(const SnackBar(content: Text('Repeating stopped.')));
        }
      } catch (error) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(
                _choreErrorMessage(error, 'Unable to stop repeating chore.'),
              ),
            ),
          );
        }
      }
    }
  }

  Future<void> _confirmAndDeletePermanentChore(ClientChore chore) async {
    final confirmed = await CaleeDestructiveDialog.show(
      context: context,
      title: 'Delete chore permanently?',
      body:
          'This will permanently delete "${chore.title}" and its completion records. This cannot be undone.',
      confirmLabel: 'Delete Permanently',
    );

    if (confirmed && mounted) {
      try {
        await _controller.permanentlyDeleteChore(chore);
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Chore deleted permanently.')),
          );
        }
      } catch (error) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(
                _choreErrorMessage(error, 'Unable to delete chore.'),
              ),
            ),
          );
        }
      }
    }
  }

  List<ClientChore> _filterChoresByAssignee(List<ClientChore> chores) {
    final filter = _controller.selectedAssigneeFilter.trim();

    if (filter == 'all') return chores;

    if (filter == 'unassigned') {
      return chores
          .where((chore) => (chore.assigneePersonId ?? '').trim().isEmpty)
          .toList();
    }

    if (filter.startsWith('person:')) {
      final personId = filter.substring('person:'.length);
      return chores
          .where((chore) => (chore.assigneePersonId ?? '').trim() == personId)
          .toList();
    }

    return chores;
  }

  bool _hasUnassignedChores(List<ClientChore> chores) {
    return chores.any((chore) => (chore.assigneePersonId ?? '').trim().isEmpty);
  }

  String _filterLabel(
    String filter,
    List<ClientPerson> people,
    List<ClientChore> allChores,
  ) {
    if (filter == 'all') {
      return 'All Chores · ${_countAllChores(allChores)}';
    }
    if (filter == 'unassigned') {
      return 'Unassigned · ${_countUnassignedChores(allChores)}';
    }
    if (filter.startsWith('person:')) {
      final personId = filter.substring('person:'.length);
      final matches = people.where((p) => p.id == personId);
      final name =
          matches.isNotEmpty && matches.first.displayName.trim().isNotEmpty
          ? matches.first.displayName.trim()
          : 'Unnamed';
      return '$name · ${_countChoresForPerson(allChores, personId)}';
    }
    return 'All Chores · ${_countAllChores(allChores)}';
  }

  Future<void> _openAssigneeFilterChooser({
    required List<ClientPerson> people,
    required bool hasUnassigned,
    required List<ClientChore> allChores,
  }) async {
    await CaleeBottomSheet.show<void>(
      context: context,
      title: 'Filter Chores',
      child: _AssigneeFilterChooser(
        people: people,
        hasUnassigned: hasUnassigned,
        selectedFilter: _controller.selectedAssigneeFilter,
        allCount: _countAllChores(allChores),
        unassignedCount: _countUnassignedChores(allChores),
        personCounts: {
          for (final p in people) p.id: _countChoresForPerson(allChores, p.id),
        },
        onSelect: (value) {
          _controller.setAssigneeFilter(value);
          Navigator.of(context).pop();
        },
        onAddPerson: () {
          Navigator.of(context).pop();
          _openAddPersonSheet();
        },
        onAddChoreList: () {
          Navigator.of(context).pop();
          _openCollectionCreateShortcut();
        },
      ),
    );
  }

  Future<void> _openAddPersonSheet() async {
    final household = _repository.primaryHousehold;

    if (household == null) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('No household is available.')),
        );
      }
      return;
    }

    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => HouseholdPeoplePage(
          hubClient: widget.hubClient,
          accessToken: widget.accessToken,
          households: widget.households,
          initialHouseholdId: household.id,
          autoOpenCreate: true,
        ),
      ),
    );

    if (mounted) {
      _controller.refresh();
    }
  }

  int _countAllChores(List<ClientChore> chores) => chores.length;

  int _countUnassignedChores(List<ClientChore> chores) =>
      chores.where((c) => (c.assigneePersonId ?? '').trim().isEmpty).length;

  int _countChoresForPerson(List<ClientChore> chores, String personId) =>
      chores.where((c) => (c.assigneePersonId ?? '').trim() == personId).length;

  Map<String, List<ClientChore>> _groupChoresBySection(
    List<ClientChore> chores,
  ) {
    return groupChoresBySection(chores, DateTime.now());
  }

  int _todayCompletionPoints(List<ClientChore> chores) {
    return chores
        .where(
          (chore) =>
              chore.normalizedSection == 'doneToday' || chore.completedToday,
        )
        .fold<int>(0, (total, chore) => total + chore.points);
  }

  String _formatScheduledAt(ClientChore chore) {
    final value = chore.scheduledDate ?? chore.scheduledAt;
    final isHistory =
        chore.isCompletionLog || chore.normalizedSection == 'history';

    if (value == null || value.trim().isEmpty) {
      return isHistory ? 'Completed date unknown' : 'No scheduled date';
    }

    final parsed = DateTime.tryParse(value);
    if (parsed == null) {
      return isHistory ? 'Completed $value' : 'Scheduled $value';
    }

    final local = parsed.toLocal();
    final label = isHistory ? 'Completed' : 'Scheduled';
    return '$label ${local.day}/${local.month}/${local.year}';
  }

  String _calendarNameForChore(
    ClientChore chore,
    List<ClientCalendar> calendars,
  ) {
    for (final cal in calendars) {
      if (cal.id == chore.calendarId ||
          cal.id == '${chore.serviceId}:${chore.calendarId}') {
        return cal.name;
      }
    }
    return chore.serviceName.trim().isNotEmpty ? chore.serviceName : '';
  }

  String _sectionTitle(String section) {
    switch (section) {
      case 'todoToday':
        return 'Today';
      case 'overdue':
        return 'Overdue';
      case 'doneToday':
        return 'Done today';
      case 'future':
        return 'Upcoming';
      case 'tomorrow':
        return 'Tomorrow';
      case 'laterThisWeek':
        return 'Later this week';
      case 'later':
        return 'Later';
      case 'history':
        return 'History';
      default:
        return 'Other';
    }
  }

  Widget _buildSectionWidget(
    String section,
    List<ClientChore> sectionChores,
    List<ClientCalendar> choreCalendars,
  ) {
    if (section == 'history' && !_historyExpanded) {
      return CaleeSection(
        children: [
          CaleeListRow(
            leading: const Icon(
              Icons.history_outlined,
              size: 22,
              color: CaleeColors.textTertiary,
            ),
            title: 'Show history',
            trailing: Text(
              '${sectionChores.length}',
              style: Theme.of(
                context,
              ).textTheme.bodySmall?.copyWith(color: CaleeColors.textSecondary),
            ),
            onTap: () => setState(() => _historyExpanded = true),
          ),
        ],
      );
    }

    return CaleeSection(
      title: _sectionTitle(section),
      trailing: '${sectionChores.length}',
      children: sectionChores
          .map(
            (chore) => _ChoreRow(
              key: ValueKey(
                chore.completionActionId.isNotEmpty
                    ? chore.completionActionId
                    : chore.id,
              ),
              chore: chore,
              calendarName: _calendarNameForChore(chore, choreCalendars),
              scheduledLabel: _formatScheduledAt(chore),
              isUpdating: _controller.updatingChoreIds.contains(
                chore.completionActionId,
              ),
              onToggleCompletion: chore.canToggleCompletion
                  ? () => _toggleChoreCompletion(chore)
                  : null,
              onMoreTap:
                  chore.completionActionId.trim().isNotEmpty &&
                      !chore.isCompletionLog &&
                      chore.normalizedSection != 'history'
                  ? () => _showChoreActions(chore)
                  : null,
            ),
          )
          .toList(),
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
              title: 'Unable to load chores',
              body: 'Check your connection, then try again.',
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
              icon: Icons.family_restroom_outlined,
              title: 'No chore lists yet',
              body: 'Create a chore list to start tracking family chores.',
              action: FilledButton.icon(
                onPressed: _openCollectionCreateShortcut,
                icon: const Icon(Icons.add),
                label: const Text('Create chore list'),
              ),
            ),
          );
        }

        final choreCalendars = overview.calendarList.calendars
            .where(_isChoreServiceCalendar)
            .toList();
        final allChores = overview.choreList.chores;
        final chores = _filterChoresByAssignee(allChores);
        final choresBySection = _groupChoresBySection(chores);
        final hasUnassignedChores = _hasUnassignedChores(allChores);
        final showAssigneeFilters =
            allChores.isNotEmpty &&
            (overview.people.isNotEmpty || hasUnassignedChores);

        if (choreCalendars.isEmpty && allChores.isEmpty) {
          return CaleeScaffold(
            body: CaleeEmptyState(
              icon: Icons.family_restroom_outlined,
              title: 'No chore lists yet',
              body: 'Create a chore list to start tracking family chores.',
              action: FilledButton.icon(
                onPressed: _openCollectionCreateShortcut,
                icon: const Icon(Icons.add),
                label: const Text('Create chore list'),
              ),
            ),
          );
        }

        final writableCalendars = choreCalendars
            .where((c) => !c.readOnly)
            .toList();
        final hasWritable = writableCalendars.isNotEmpty;

        const sectionOrder = [
          'overdue',
          'todoToday',
          'doneToday',
          'tomorrow',
          'laterThisWeek',
          'later',
          'history',
        ];

        final activeSections = sectionOrder
            .where((s) => (choresBySection[s]?.isNotEmpty ?? false))
            .toList();

        final overdueCount = choresBySection['overdue']?.length ?? 0;
        final todoTodayCount = choresBySection['todoToday']?.length ?? 0;
        final doneTodayCount = choresBySection['doneToday']?.length ?? 0;
        final pointsToday = _todayCompletionPoints(chores);

        return CaleeScaffold(
          floatingActionButton: hasWritable
              ? FloatingActionButton.extended(
                  onPressed: () => _openCreateChoreSheet(choreCalendars),
                  icon: const Icon(Icons.add),
                  label: const Text('Chore'),
                )
              : null,
          body: RefreshIndicator(
            onRefresh: _controller.refresh,
            child: ListView(
              padding: const EdgeInsets.symmetric(
                horizontal: CaleeSpacing.pagePadding,
                vertical: CaleeSpacing.md,
              ),
              children: [
                if (overdueCount > 0 ||
                    todoTodayCount > 0 ||
                    doneTodayCount > 0) ...[
                  _ChoreSummaryStrip(
                    overdueCount: overdueCount,
                    todoTodayCount: todoTodayCount,
                    doneTodayCount: doneTodayCount,
                    pointsToday: pointsToday,
                  ),
                  const SizedBox(height: CaleeSpacing.sectionSpacing),
                ],

                if (showAssigneeFilters) ...[
                  _AssigneeFilterRow(
                    label: _filterLabel(
                      _controller.selectedAssigneeFilter,
                      overview.people,
                      allChores,
                    ),
                    onTap: () => _openAssigneeFilterChooser(
                      people: overview.people,
                      hasUnassigned: hasUnassignedChores,
                      allChores: allChores,
                    ),
                  ),
                  const SizedBox(height: CaleeSpacing.sectionSpacing),
                ],

                if (activeSections.isEmpty && choreCalendars.isNotEmpty)
                  CaleeSection(
                    title: 'Chores',
                    children: [
                      CaleeListRow(
                        title: allChores.isEmpty
                            ? 'No chores yet'
                            : 'No chores for this filter',
                        subtitle: allChores.isEmpty
                            ? 'Tap + Chore to add your first chore.'
                            : 'Choose another assignee filter.',
                        leading: const Icon(
                          Icons.check_circle_outline,
                          color: CaleeColors.textTertiary,
                          size: 22,
                        ),
                      ),
                    ],
                  )
                else
                  for (final section in activeSections) ...[
                    _buildSectionWidget(
                      section,
                      choresBySection[section]!,
                      choreCalendars,
                    ),
                    const SizedBox(height: CaleeSpacing.sectionSpacing),
                  ],

                if (choreCalendars.isEmpty) ...[
                  if (activeSections.isNotEmpty)
                    const SizedBox(height: CaleeSpacing.sectionSpacing),
                  CaleeSection(
                    footer: 'Connect a chore list to start adding chores.',
                    children: [
                      CaleeListRow(
                        title: 'Add chore list',
                        leading: const Icon(
                          Icons.add_circle_outline,
                          color: CaleeColors.primary,
                          size: 22,
                        ),
                        onTap: _openCollectionCreateShortcut,
                      ),
                    ],
                  ),
                ],

                const SizedBox(height: 96),
              ],
            ),
          ),
        );
      },
    );
  }
}

// ─────────────────────────────────────────────
// Summary strip
// ─────────────────────────────────────────────

class _ChoreSummaryStrip extends StatelessWidget {
  const _ChoreSummaryStrip({
    required this.overdueCount,
    required this.todoTodayCount,
    required this.doneTodayCount,
    required this.pointsToday,
  });

  final int overdueCount;
  final int todoTodayCount;
  final int doneTodayCount;
  final int pointsToday;

  @override
  Widget build(BuildContext context) {
    return Wrap(
      spacing: CaleeSpacing.sm,
      runSpacing: CaleeSpacing.xs,
      children: [
        if (overdueCount > 0)
          _StripChip(
            label: '$overdueCount overdue',
            color: const Color(0xFFFF9500),
          ),
        if (todoTodayCount > 0) _StripChip(label: '$todoTodayCount today'),
        if (doneTodayCount > 0) _StripChip(label: '$doneTodayCount done'),
        if (pointsToday > 0) _StripChip(label: '$pointsToday pts'),
      ],
    );
  }
}

class _StripChip extends StatelessWidget {
  const _StripChip({required this.label, this.color});

  final String label;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final effectiveColor = color ?? CaleeColors.primary;

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: effectiveColor.withAlpha(26),
        borderRadius: BorderRadius.circular(CaleeRadius.dot),
      ),
      child: Text(
        label,
        style: TextStyle(
          fontSize: 12,
          color: effectiveColor,
          fontWeight: FontWeight.w500,
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────
// Points badge
// ─────────────────────────────────────────────

class _PointsBadge extends StatelessWidget {
  const _PointsBadge(this.points);

  final int points;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: CaleeColors.primary.withAlpha(20),
        borderRadius: BorderRadius.circular(CaleeRadius.dot),
      ),
      child: Text(
        '$points pts',
        style: const TextStyle(
          fontSize: 11,
          color: CaleeColors.primary,
          fontWeight: FontWeight.w500,
        ),
      ),
    );
  }
}

class _AssigneeFilterRow extends StatelessWidget {
  const _AssigneeFilterRow({required this.label, required this.onTap});

  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return GestureDetector(
      onTap: onTap,
      child: Container(
        decoration: BoxDecoration(
          color: CaleeColors.surface,
          borderRadius: BorderRadius.circular(CaleeRadius.card),
        ),
        padding: const EdgeInsets.symmetric(
          horizontal: CaleeSpacing.md,
          vertical: CaleeSpacing.sm,
        ),
        child: Row(
          children: [
            const Icon(
              Icons.people_outline,
              size: 18,
              color: CaleeColors.primary,
            ),
            const SizedBox(width: CaleeSpacing.sm),
            Expanded(
              child: Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: CaleeColors.primary,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ),
            const SizedBox(width: CaleeSpacing.xs),
            const Icon(
              Icons.keyboard_arrow_down,
              size: 16,
              color: CaleeColors.primary,
            ),
          ],
        ),
      ),
    );
  }
}

class _AssigneeFilterChooser extends StatelessWidget {
  const _AssigneeFilterChooser({
    required this.people,
    required this.hasUnassigned,
    required this.selectedFilter,
    required this.allCount,
    required this.unassignedCount,
    required this.personCounts,
    required this.onSelect,
    this.onAddPerson,
    this.onAddChoreList,
  });

  final List<ClientPerson> people;
  final bool hasUnassigned;
  final String selectedFilter;
  final int allCount;
  final int unassignedCount;
  final Map<String, int> personCounts;
  final ValueChanged<String> onSelect;
  final VoidCallback? onAddPerson;
  final VoidCallback? onAddChoreList;

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
              title: 'All Chores',
              leading: selectedFilter == 'all'
                  ? const Icon(
                      Icons.check,
                      size: 20,
                      color: CaleeColors.primary,
                    )
                  : const SizedBox(width: 20),
              trailing: Text('$allCount', style: countStyle),
              onTap: () => onSelect('all'),
            ),
            if (hasUnassigned)
              CaleeListRow(
                title: 'Unassigned',
                leading: selectedFilter == 'unassigned'
                    ? const Icon(
                        Icons.check,
                        size: 20,
                        color: CaleeColors.primary,
                      )
                    : const SizedBox(width: 20),
                trailing: Text('$unassignedCount', style: countStyle),
                onTap: () => onSelect('unassigned'),
              ),
            for (final person in people)
              CaleeListRow(
                title: person.displayName.trim().isEmpty
                    ? 'Unnamed'
                    : person.displayName.trim(),
                leading: selectedFilter == 'person:${person.id}'
                    ? const Icon(
                        Icons.check,
                        size: 20,
                        color: CaleeColors.primary,
                      )
                    : const SizedBox(width: 20),
                trailing: Text(
                  '${personCounts[person.id] ?? 0}',
                  style: countStyle,
                ),
                onTap: () => onSelect('person:${person.id}'),
              ),
          ],
        ),
        const SizedBox(height: CaleeSpacing.md),
        CaleeSection(
          title: 'Add',
          children: [
            CaleeListRow(
              title: 'Add Person',
              leading: const Icon(
                Icons.person_add_outlined,
                color: CaleeColors.primary,
                size: 22,
              ),
              onTap: onAddPerson,
            ),
            CaleeListRow(
              title: 'New Chore List',
              leading: const Icon(
                Icons.playlist_add_outlined,
                color: CaleeColors.primary,
                size: 22,
              ),
              onTap: onAddChoreList,
            ),
          ],
        ),
        const SizedBox(height: CaleeSpacing.md),
      ],
    );
  }
}

// ─────────────────────────────────────────────
// Chore row
// ─────────────────────────────────────────────

class _ChoreRow extends StatelessWidget {
  const _ChoreRow({
    required this.chore,
    required this.calendarName,
    required this.scheduledLabel,
    required this.isUpdating,
    this.onToggleCompletion,
    this.onMoreTap,
    super.key,
  });

  final ClientChore chore;
  final String calendarName;
  final String scheduledLabel;
  final bool isUpdating;
  final VoidCallback? onToggleCompletion;
  final VoidCallback? onMoreTap;

  @override
  Widget build(BuildContext context) {
    final isDone =
        chore.completedToday || chore.normalizedSection == 'doneToday';
    final isHistory =
        chore.isCompletionLog || chore.normalizedSection == 'history';

    final subtitleParts = choreSubtitleParts(
      chore: chore,
      calendarName: calendarName,
      scheduledLabel: scheduledLabel,
    );
    final subtitle = subtitleParts.where((p) => p.isNotEmpty).join(' · ');

    Widget leading;
    if (isHistory) {
      leading = const Icon(
        Icons.history_outlined,
        size: 22,
        color: CaleeColors.textTertiary,
      );
    } else {
      leading = Semantics(
        label: isDone ? 'Mark chore not complete' : 'Mark chore complete',
        button: true,
        excludeSemantics: true,
        child: CaleeCheckCircle(
          isChecked: isDone,
          onTap: onToggleCompletion,
          isLoading: isUpdating,
          size: 22,
        ),
      );
    }

    Widget? trailing;
    final showMore = onMoreTap != null;
    if (chore.points > 0 || showMore) {
      trailing = Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (chore.points > 0) _PointsBadge(chore.points),
          if (showMore) ...[
            const SizedBox(width: CaleeSpacing.xs),
            SizedBox(
              width: 28,
              height: 28,
              child: IconButton(
                padding: EdgeInsets.zero,
                icon: const Icon(Icons.more_horiz, size: 18),
                color: CaleeColors.textTertiary,
                onPressed: onMoreTap,
              ),
            ),
          ],
        ],
      );
    }

    TextStyle? titleStyle;
    if (isDone) {
      titleStyle = const TextStyle(
        color: CaleeColors.textTertiary,
        decoration: TextDecoration.lineThrough,
        decorationColor: CaleeColors.textTertiary,
      );
    } else if (isHistory) {
      titleStyle = const TextStyle(color: CaleeColors.textTertiary);
    }

    final effectiveTrailing =
        trailing ??
        (onToggleCompletion != null ? const SizedBox.shrink() : null);

    return CaleeListRow(
      leading: leading,
      title: chore.title,
      subtitle: subtitle.isNotEmpty ? subtitle : null,
      trailing: effectiveTrailing,
      titleStyle: titleStyle,
      onTap: onToggleCompletion,
    );
  }
}

// ─────────────────────────────────────────────
// Create chore sheet
// ─────────────────────────────────────────────

class _CreateChoreSheet extends StatefulWidget {
  const _CreateChoreSheet({
    required this.calendars,
    required this.people,
    required this.onCreate,
  });

  final List<ClientCalendar> calendars;
  final List<ClientPerson> people;
  final Future<void> Function({
    required ClientCalendar calendar,
    required String title,
    String? scheduledAt,
    String? description,
    String? recurrence,
    required String? assigneePersonId,
    required int points,
  })
  onCreate;

  @override
  State<_CreateChoreSheet> createState() => _CreateChoreSheetState();
}

class _CreateChoreSheetState extends State<_CreateChoreSheet> {
  final _formKey = GlobalKey<FormState>();
  final _titleController = TextEditingController();
  final _descriptionController = TextEditingController();

  late ClientCalendar _selectedCalendar;
  DateTime? _selectedDate;
  String? _selectedRecurrence;
  late final TextEditingController _pointsController;
  String? _assigneePersonId;
  bool _isSubmitting = false;

  @override
  void initState() {
    super.initState();
    _selectedCalendar = widget.calendars.first;
    _pointsController = TextEditingController(text: '1');
  }

  @override
  void dispose() {
    _titleController.dispose();
    _descriptionController.dispose();
    _pointsController.dispose();
    super.dispose();
  }

  Future<void> _pickDate() async {
    final now = DateTime.now();
    final picked = await showDatePicker(
      context: context,
      initialDate: _selectedDate ?? now,
      firstDate: DateTime(now.year - 1),
      lastDate: DateTime(now.year + 5),
    );

    if (picked != null && mounted) {
      setState(() {
        _selectedDate = picked;
      });
    }
  }

  Future<void> _submit() async {
    if (_isSubmitting || !_formKey.currentState!.validate()) return;

    final points = int.tryParse(_pointsController.text.trim()) ?? 1;

    setState(() {
      _isSubmitting = true;
    });

    try {
      await widget.onCreate(
        calendar: _selectedCalendar,
        title: _titleController.text.trim(),
        scheduledAt: _selectedDate == null
            ? null
            : _formatChoreDate(_selectedDate!),
        description: _descriptionController.text.trim(),
        recurrence: _choreRecurrenceToRrule(_selectedRecurrence),
        assigneePersonId: _assigneePersonId,
        points: points,
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
          const SnackBar(content: Text('Unable to create chore.')),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return CaleeBottomSheet(
      title: 'Add chore',
      child: Form(
        key: _formKey,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              CaleeSection(
                children: [
                  CaleeSectionTextFormField(
                    controller: _titleController,
                    enabled: !_isSubmitting,
                    autofocus: true,
                    hintText: 'Title',
                    textInputAction: TextInputAction.next,
                    validator: (value) {
                      if ((value ?? '').trim().isEmpty) {
                        return 'Enter a chore title';
                      }
                      return null;
                    },
                  ),
                  CaleeSectionDropdownRow<ClientCalendar>(
                    label: 'Chore List',
                    value: _selectedCalendar,
                    enabled: !_isSubmitting,
                    items: widget.calendars
                        .map(
                          (calendar) => DropdownMenuItem(
                            value: calendar,
                            child: Text(
                              [
                                calendar.name,
                                if (calendar.serviceName.trim().isNotEmpty)
                                  calendar.serviceName,
                              ].join(' · '),
                            ),
                          ),
                        )
                        .toList(),
                    onChanged: (value) {
                      if (value != null) {
                        setState(() {
                          _selectedCalendar = value;
                        });
                      }
                    },
                  ),
                ],
              ),
              const SizedBox(height: CaleeSpacing.sectionSpacing),

              CaleeSection(
                children: [
                  CaleeSectionPickerRow(
                    label: 'Date',
                    value: _selectedDate == null
                        ? 'No Date'
                        : '${_selectedDate!.day}/${_selectedDate!.month}/${_selectedDate!.year}',
                    onTap: _isSubmitting ? null : _pickDate,
                    enabled: !_isSubmitting,
                  ),
                  if (_selectedDate != null)
                    InkWell(
                      onTap: _isSubmitting
                          ? null
                          : () {
                              setState(() {
                                _selectedDate = null;
                              });
                            },
                      child: Padding(
                        padding: const EdgeInsets.symmetric(
                          horizontal: CaleeSpacing.md,
                          vertical: 11,
                        ),
                        child: Text(
                          'Clear Date',
                          style: TextStyle(
                            fontSize: 16,
                            color: _isSubmitting
                                ? CaleeColors.textTertiary
                                : CaleeColors.primary,
                          ),
                        ),
                      ),
                    ),
                  CaleeSectionDropdownRow<String?>(
                    label: 'Repeat',
                    value: _selectedRecurrence,
                    enabled: !_isSubmitting,
                    items: const [
                      DropdownMenuItem<String?>(
                        value: null,
                        child: Text('Does not repeat'),
                      ),
                      DropdownMenuItem<String?>(
                        value: 'daily',
                        child: Text('Daily'),
                      ),
                      DropdownMenuItem<String?>(
                        value: 'weekly',
                        child: Text('Weekly'),
                      ),
                      DropdownMenuItem<String?>(
                        value: 'monthly',
                        child: Text('Monthly'),
                      ),
                    ],
                    onChanged: (value) {
                      setState(() {
                        _selectedRecurrence = value;
                      });
                    },
                  ),
                ],
              ),
              const SizedBox(height: CaleeSpacing.sectionSpacing),

              CaleeSection(
                children: [
                  CaleeSectionDropdownRow<String?>(
                    label: 'Assign to',
                    value: _assigneePersonId,
                    enabled: !_isSubmitting,
                    items: [
                      const DropdownMenuItem<String?>(
                        value: null,
                        child: Text('Unassigned'),
                      ),
                      for (final person in widget.people)
                        DropdownMenuItem<String?>(
                          value: person.id,
                          child: Text(person.displayName),
                        ),
                    ],
                    onChanged: (value) {
                      setState(() {
                        _assigneePersonId = value;
                      });
                    },
                  ),
                  CaleeSectionLabeledTextFormField(
                    label: 'Points',
                    controller: _pointsController,
                    enabled: !_isSubmitting,
                    keyboardType: TextInputType.number,
                    textAlign: TextAlign.right,
                    validator: (value) {
                      final points = int.tryParse((value ?? '').trim());
                      if (!_isValidChorePoints(points)) {
                        return 'Enter points from 1 to 100';
                      }
                      return null;
                    },
                  ),
                ],
              ),
              const SizedBox(height: CaleeSpacing.sectionSpacing),

              CaleeSection(
                children: [
                  CaleeSectionTextFormField(
                    controller: _descriptionController,
                    enabled: !_isSubmitting,
                    hintText: 'Notes',
                    minLines: 2,
                    maxLines: 4,
                  ),
                ],
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
                    : const Text('Create chore'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────
// Edit chore sheet
// ─────────────────────────────────────────────

class _EditChoreSheet extends StatefulWidget {
  const _EditChoreSheet({
    required this.chore,
    required this.people,
    required this.metadata,
    required this.onUpdate,
  });

  final ClientChore chore;
  final List<ClientPerson> people;
  final ClientChoreMetadata? metadata;
  final Future<void> Function({
    required ClientChore chore,
    required String title,
    String? scheduledAt,
    String? description,
    String? recurrence,
    required String? assigneePersonId,
    required int points,
    required String approvalState,
  })
  onUpdate;

  @override
  State<_EditChoreSheet> createState() => _EditChoreSheetState();
}

class _EditChoreSheetState extends State<_EditChoreSheet> {
  final _formKey = GlobalKey<FormState>();
  late final TextEditingController _titleController;
  late final TextEditingController _descriptionController;
  late final TextEditingController _pointsController;

  DateTime? _selectedDate;
  String? _selectedRecurrence;
  String? _assigneePersonId;
  late String _approvalState;
  bool _isSubmitting = false;

  @override
  void initState() {
    super.initState();
    _titleController = TextEditingController(text: widget.chore.title);
    _descriptionController = TextEditingController(
      text: widget.chore.description ?? '',
    );
    _selectedDate = _parseChoreDate(
      widget.chore.scheduledDate ?? widget.chore.scheduledAt,
    );
    _selectedRecurrence = _choreRruleToRecurrence(widget.chore.recurrence);

    final activePeopleIds = widget.people.map((person) => person.id).toSet();
    final existingAssignee =
        widget.metadata?.assigneePersonId ?? widget.chore.assigneePersonId;

    _assigneePersonId = activePeopleIds.contains(existingAssignee)
        ? existingAssignee
        : null;
    _approvalState =
        widget.metadata?.approvalState ?? widget.chore.approvalState;
    _pointsController = TextEditingController(
      text: (widget.metadata?.points ?? widget.chore.points).toString(),
    );
  }

  @override
  void dispose() {
    _titleController.dispose();
    _descriptionController.dispose();
    _pointsController.dispose();
    super.dispose();
  }

  Future<void> _pickDate() async {
    final now = DateTime.now();
    final picked = await showDatePicker(
      context: context,
      initialDate: _selectedDate ?? now,
      firstDate: DateTime(now.year - 1),
      lastDate: DateTime(now.year + 5),
    );

    if (picked != null && mounted) {
      setState(() {
        _selectedDate = picked;
      });
    }
  }

  Future<void> _submit() async {
    if (_isSubmitting || !_formKey.currentState!.validate()) return;

    final points = int.tryParse(_pointsController.text.trim()) ?? 1;

    setState(() {
      _isSubmitting = true;
    });

    try {
      await widget.onUpdate(
        chore: widget.chore,
        title: _titleController.text.trim(),
        scheduledAt: _selectedDate == null
            ? null
            : _formatChoreDate(_selectedDate!),
        description: _descriptionController.text.trim(),
        recurrence: _choreRecurrenceToRrule(_selectedRecurrence),
        assigneePersonId: _assigneePersonId,
        points: points,
        approvalState: _approvalState,
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
          const SnackBar(content: Text('Unable to update chore.')),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return CaleeBottomSheet(
      title: 'Edit chore',
      child: Form(
        key: _formKey,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (widget.chore.isRecurring) ...[
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: CaleeSpacing.md,
                    vertical: CaleeSpacing.sm,
                  ),
                  decoration: BoxDecoration(
                    color: CaleeColors.primary.withAlpha(15),
                    borderRadius: BorderRadius.circular(CaleeRadius.card),
                  ),
                  child: Row(
                    children: [
                      const Icon(
                        Icons.repeat,
                        size: 16,
                        color: CaleeColors.primary,
                      ),
                      const SizedBox(width: CaleeSpacing.sm),
                      Expanded(
                        child: Text(
                          'Repeating chore — changes apply going forward.',
                          style: Theme.of(context).textTheme.bodySmall
                              ?.copyWith(color: CaleeColors.primary),
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: CaleeSpacing.sectionSpacing),
              ],

              CaleeSection(
                children: [
                  CaleeSectionTextFormField(
                    controller: _titleController,
                    enabled: !_isSubmitting,
                    autofocus: true,
                    hintText: 'Title',
                    textInputAction: TextInputAction.next,
                    validator: (value) {
                      if ((value ?? '').trim().isEmpty) {
                        return 'Enter a chore title';
                      }
                      return null;
                    },
                  ),
                ],
              ),
              const SizedBox(height: CaleeSpacing.sectionSpacing),

              CaleeSection(
                children: [
                  CaleeSectionPickerRow(
                    label: 'Date',
                    value: _selectedDate == null
                        ? 'No Date'
                        : '${_selectedDate!.day}/${_selectedDate!.month}/${_selectedDate!.year}',
                    onTap: _isSubmitting ? null : _pickDate,
                    enabled: !_isSubmitting,
                  ),
                  if (_selectedDate != null)
                    InkWell(
                      onTap: _isSubmitting
                          ? null
                          : () {
                              setState(() {
                                _selectedDate = null;
                              });
                            },
                      child: Padding(
                        padding: const EdgeInsets.symmetric(
                          horizontal: CaleeSpacing.md,
                          vertical: 11,
                        ),
                        child: Text(
                          'Clear Date',
                          style: TextStyle(
                            fontSize: 16,
                            color: _isSubmitting
                                ? CaleeColors.textTertiary
                                : CaleeColors.primary,
                          ),
                        ),
                      ),
                    ),
                  CaleeSectionDropdownRow<String?>(
                    label: 'Repeat',
                    value: _selectedRecurrence,
                    enabled: !_isSubmitting,
                    items: const [
                      DropdownMenuItem<String?>(
                        value: null,
                        child: Text('Does not repeat'),
                      ),
                      DropdownMenuItem<String?>(
                        value: 'daily',
                        child: Text('Daily'),
                      ),
                      DropdownMenuItem<String?>(
                        value: 'weekly',
                        child: Text('Weekly'),
                      ),
                      DropdownMenuItem<String?>(
                        value: 'monthly',
                        child: Text('Monthly'),
                      ),
                    ],
                    onChanged: (value) {
                      setState(() {
                        _selectedRecurrence = value;
                      });
                    },
                  ),
                ],
              ),
              const SizedBox(height: CaleeSpacing.sectionSpacing),

              CaleeSection(
                children: [
                  CaleeSectionDropdownRow<String?>(
                    label: 'Assign to',
                    value: _assigneePersonId,
                    enabled: !_isSubmitting,
                    items: [
                      const DropdownMenuItem<String?>(
                        value: null,
                        child: Text('Unassigned'),
                      ),
                      for (final person in widget.people)
                        DropdownMenuItem<String?>(
                          value: person.id,
                          child: Text(person.displayName),
                        ),
                    ],
                    onChanged: (value) {
                      setState(() {
                        _assigneePersonId = value;
                      });
                    },
                  ),
                  CaleeSectionLabeledTextFormField(
                    label: 'Points',
                    controller: _pointsController,
                    enabled: !_isSubmitting,
                    keyboardType: TextInputType.number,
                    textAlign: TextAlign.right,
                    validator: (value) {
                      final points = int.tryParse((value ?? '').trim());
                      if (!_isValidChorePoints(points)) {
                        return 'Enter points from 1 to 100';
                      }
                      return null;
                    },
                  ),
                ],
              ),
              const SizedBox(height: CaleeSpacing.sectionSpacing),

              CaleeSection(
                children: [
                  CaleeSectionTextFormField(
                    controller: _descriptionController,
                    enabled: !_isSubmitting,
                    hintText: 'Notes',
                    minLines: 2,
                    maxLines: 4,
                  ),
                ],
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
                    : const Text('Save chore'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

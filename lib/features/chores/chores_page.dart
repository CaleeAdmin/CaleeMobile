import 'package:flutter/material.dart';

import '../../data/api/calee_hub_client.dart';
import '../../data/models/client_bootstrap.dart';
import '../settings/calendar_collections_page.dart';
import '../settings/household_people_page.dart';
import '../../data/models/client_calendar.dart';
import '../../data/models/client_chore.dart';
import 'chore_grouping.dart';
import '../../data/models/client_person.dart';
import '../../ui/calee_theme.dart';
import '../../ui/calee_widgets.dart';
import 'chores_controller.dart';
import 'chores_repository.dart';
import 'widgets/chore_assignee_filter.dart';
import 'widgets/chore_row.dart';
import 'widgets/chore_summary_strip.dart';
import 'widgets/chore_widget_helpers.dart';
import 'widgets/create_chore_sheet.dart';
import 'widgets/edit_chore_sheet.dart';

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
      builder: (context) => CreateChoreSheet(
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
      builder: (context) => EditChoreSheet(
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
            content: Text(choreErrorMessage(error, 'Unable to update chore.')),
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
              content: Text(choreErrorMessage(error, 'Unable to skip chore.')),
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
                choreErrorMessage(error, 'Unable to stop repeating chore.'),
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
                choreErrorMessage(error, 'Unable to delete chore.'),
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
      child: ChoreAssigneeFilterChooser(
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
            (chore) => ChoreRow(
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
                  ChoreSummaryStrip(
                    overdueCount: overdueCount,
                    todoTodayCount: todoTodayCount,
                    doneTodayCount: doneTodayCount,
                    pointsToday: pointsToday,
                  ),
                  const SizedBox(height: CaleeSpacing.sectionSpacing),
                ],

                if (showAssigneeFilters) ...[
                  ChoreAssigneeFilterRow(
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

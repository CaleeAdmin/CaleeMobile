import 'package:flutter/material.dart';

import '../../data/api/calee_hub_client.dart';
import '../../data/models/client_bootstrap.dart';
import '../calendar/widgets/calendar_error_state.dart';
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
    required this.accountId,
    super.key,
  });

  final CaleeHubClient hubClient;
  final String accessToken;
  final List<ClientService> services;
  final List<ClientContext> households;
  final String accountId;

  @override
  State<ChoresPage> createState() => _ChoresPageState();
}

class _ChoresPageState extends State<ChoresPage> {
  late final ChoresRepository _repository;
  late final ChoresController _controller;
  bool _doneTodayExpanded = false;
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
              accountId: widget.accountId,
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
              required List<String> assigneePersonIds,
              required int points,
            }) => _controller.createChore(
              calendar: calendar,
              title: title,
              scheduledAt: scheduledAt,
              description: description,
              recurrence: recurrence,
              assigneePersonIds: assigneePersonIds,
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
          label: isDone ? 'Undo done' : 'Mark done',
          icon: isDone
              ? Icons.unpublished_outlined
              : Icons.check_circle_outline,
          onTap: () => _toggleChoreCompletion(chore),
        ),
      CaleeAction(
        label: 'Edit chore',
        icon: Icons.edit_outlined,
        onTap: () => _openEditChoreSheet(chore),
      ),
    ];

    if (chore.isRecurring) {
      actions.addAll([
        CaleeAction(
          label: 'Skip this time',
          icon: Icons.event_busy_outlined,
          onTap: () => _skipChore(chore),
        ),
        CaleeAction(
          label: 'Stop repeating',
          icon: Icons.repeat_one_outlined,
          isDestructive: true,
          onTap: () => _stopRepeatingChore(chore),
        ),
        CaleeAction(
          label: 'Delete permanently',
          icon: Icons.delete_outline,
          isDestructive: true,
          onTap: () => _confirmAndDeletePermanentChore(chore),
        ),
      ]);
    } else {
      actions.add(
        CaleeAction(
          label: 'Delete chore',
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
      confirmLabel: 'Stop repeating',
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
      confirmLabel: 'Delete permanently',
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
      return 'All chores';
    }
    if (filter == 'unassigned') {
      return 'Unassigned';
    }
    if (filter.startsWith('person:')) {
      final personId = filter.substring('person:'.length);
      final matches = people.where((p) => p.id == personId);
      return matches.isNotEmpty && matches.first.displayName.trim().isNotEmpty
          ? matches.first.displayName.trim()
          : 'Unnamed';
    }
    return 'All chores';
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

  void _openSearchSheet({
    required List<ClientChore> allChores,
    required List<ClientCalendar> choreCalendars,
    required Map<String, String> personNameMap,
  }) {
    final grouped = _groupChoresBySection(allChores);
    final choreSection = <String, String>{};
    for (final entry in grouped.entries) {
      for (final chore in entry.value) {
        final key = chore.completionActionId.isNotEmpty
            ? chore.completionActionId
            : chore.id;
        choreSection[key] = entry.key;
      }
    }

    final searchable = allChores.map((chore) {
      final key = chore.completionActionId.isNotEmpty
          ? chore.completionActionId
          : chore.id;
      final section = choreSection[key] ?? chore.normalizedSection;
      return _SearchableChore(
        chore: chore,
        assigneeName: personNameMap[chore.assigneePersonId ?? ''] ?? '',
        calendarName: _calendarNameForChore(chore, choreCalendars),
        scheduledLabel: _formatScheduledAt(chore),
        sectionLabel: _sectionTitle(section),
      );
    }).toList();

    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: CaleeColors.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(
          top: Radius.circular(CaleeRadius.sheet),
        ),
      ),
      builder: (sheetContext) => _ChoreSearchSheet(
        searchable: searchable,
        onTapChore: (chore) {
          Navigator.of(sheetContext).pop();
          _showChoreActions(chore);
        },
      ),
    );
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

  String _formatScheduledAt(ClientChore chore) {
    final value = chore.scheduledDate ?? chore.scheduledAt;
    final isHistory =
        chore.isCompletionLog ||
        chore.normalizedSection == 'history' ||
        chore.normalizedSection == 'doneToday';

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
    if (section == 'doneToday' && !_doneTodayExpanded) {
      return CaleeSection(
        title: 'Done today',
        trailing: '${sectionChores.length}',
        children: [
          CaleeListRow(
            leading: const Icon(
              Icons.check_circle_outline,
              size: 22,
              color: CaleeColors.textTertiary,
            ),
            title: 'Show completed chores',
            onTap: () => setState(() => _doneTodayExpanded = true),
          ),
        ],
      );
    }

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

  PreferredSizeWidget _buildTopBar({
    required String label,
    required VoidCallback onSearchTap,
    required VoidCallback onFilterTap,
    required VoidCallback onAddTap,
  }) {
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
              Expanded(
                child: Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 17,
                    fontWeight: FontWeight.w600,
                    color: CaleeColors.textPrimary,
                  ),
                ),
              ),
              IconButton(
                onPressed: onSearchTap,
                icon: const Icon(Icons.search),
                iconSize: 22,
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints(minWidth: 44, minHeight: 44),
                color: CaleeColors.primary,
                tooltip: 'Search chores',
              ),
              IconButton(
                onPressed: onFilterTap,
                icon: const Icon(Icons.tune),
                iconSize: 22,
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints(minWidth: 44, minHeight: 44),
                color: CaleeColors.primary,
                tooltip: 'Filter chores',
              ),
              IconButton(
                onPressed: onAddTap,
                icon: const Icon(Icons.add),
                iconSize: 22,
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints(minWidth: 44, minHeight: 44),
                color: CaleeColors.primary,
                tooltip: 'Add chore',
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
              icon: Icons.checklist_outlined,
              title: 'No chore lists yet',
              body: 'Create a chore list to start tracking chores.',
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

        if (choreCalendars.isEmpty && allChores.isEmpty) {
          final serviceErrors = _controller.calendarServiceErrors;
          if (serviceErrors.isNotEmpty) {
            return CaleeScaffold(
              body: CalendarServiceConnectionErrorState(
                errors: serviceErrors,
                onRetry: _controller.refresh,
              ),
            );
          }
          return CaleeScaffold(
            body: CaleeEmptyState(
              icon: Icons.checklist_outlined,
              title: 'No chore lists yet',
              body: 'Create a chore list to start tracking chores.',
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

        final filterLabel = _filterLabel(
          _controller.selectedAssigneeFilter,
          overview.people,
          allChores,
        );

        final personNameMap = {
          for (final p in overview.people)
            p.id: p.displayName.trim().isEmpty
                ? 'Unnamed'
                : p.displayName.trim(),
        };

        final choreServiceErrors = _controller.calendarServiceErrors;
        return CaleeScaffold(
          appBar: _buildTopBar(
            label: filterLabel,
            onSearchTap: () => _openSearchSheet(
              allChores: allChores,
              choreCalendars: choreCalendars,
              personNameMap: personNameMap,
            ),
            onFilterTap: () => _openAssigneeFilterChooser(
              people: overview.people,
              hasUnassigned: hasUnassignedChores,
              allChores: allChores,
            ),
            onAddTap: () {
              if (hasWritable) {
                _openCreateChoreSheet(choreCalendars);
              } else {
                _openCollectionCreateShortcut();
              }
            },
          ),
          body: Column(
            children: [
              if (choreServiceErrors.isNotEmpty && choreCalendars.isNotEmpty)
                CalendarServiceWarningBanner(errors: choreServiceErrors),
              Expanded(
                child: RefreshIndicator(
            onRefresh: _controller.refresh,
            child: ListView(
              padding: const EdgeInsets.symmetric(
                horizontal: CaleeSpacing.pagePadding,
                vertical: CaleeSpacing.md,
              ),
              children: [
                if (activeSections.isEmpty && choreCalendars.isNotEmpty)
                  CaleeSection(
                    title: 'Chores',
                    children: [
                      CaleeListRow(
                        title: allChores.isEmpty
                            ? 'No chores yet'
                            : 'No chores for this filter',
                        subtitle: allChores.isEmpty
                            ? 'Tap + to add your first chore.'
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
              ),
            ],
          ),
        );
      },
    );
  }
}

// ─────────────────────────────────────────────
// Search support
// ─────────────────────────────────────────────

class _SearchableChore {
  const _SearchableChore({
    required this.chore,
    required this.assigneeName,
    required this.calendarName,
    required this.scheduledLabel,
    required this.sectionLabel,
  });

  final ClientChore chore;
  final String assigneeName;
  final String calendarName;
  final String scheduledLabel;
  final String sectionLabel;

  bool matches(String query) {
    if (query.isEmpty) return false;
    final q = query.toLowerCase();
    return chore.title.toLowerCase().contains(q) ||
        (chore.description ?? '').toLowerCase().contains(q) ||
        assigneeName.toLowerCase().contains(q) ||
        calendarName.toLowerCase().contains(q) ||
        scheduledLabel.toLowerCase().contains(q) ||
        sectionLabel.toLowerCase().contains(q);
  }
}

class _ChoreSearchSheet extends StatefulWidget {
  const _ChoreSearchSheet({required this.searchable, required this.onTapChore});

  final List<_SearchableChore> searchable;
  final ValueChanged<ClientChore> onTapChore;

  @override
  State<_ChoreSearchSheet> createState() => _ChoreSearchSheetState();
}

class _ChoreSearchSheetState extends State<_ChoreSearchSheet> {
  final _controller = TextEditingController();
  List<_SearchableChore> _results = [];

  @override
  void initState() {
    super.initState();
    _controller.addListener(_onQueryChanged);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _onQueryChanged() {
    final q = _controller.text.trim();
    setState(() {
      _results = q.isEmpty
          ? []
          : widget.searchable.where((s) => s.matches(q)).toList();
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final bottomInset = MediaQuery.of(context).viewInsets.bottom;

    return DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.6,
      minChildSize: 0.4,
      maxChildSize: 0.92,
      builder: (context, scrollController) => Padding(
        padding: EdgeInsets.only(bottom: bottomInset),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(
                CaleeSpacing.pagePadding,
                CaleeSpacing.md,
                CaleeSpacing.pagePadding,
                CaleeSpacing.sm,
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Center(
                    child: Container(
                      width: 36,
                      height: 4,
                      margin: const EdgeInsets.only(bottom: CaleeSpacing.md),
                      decoration: BoxDecoration(
                        color: CaleeColors.textTertiary.withValues(alpha: 0.4),
                        borderRadius: BorderRadius.circular(2),
                      ),
                    ),
                  ),
                  Text(
                    'Search chores',
                    style: theme.textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.w600,
                      color: CaleeColors.textPrimary,
                    ),
                  ),
                  const SizedBox(height: CaleeSpacing.sm),
                  TextField(
                    controller: _controller,
                    autofocus: true,
                    textInputAction: TextInputAction.search,
                    decoration: InputDecoration(
                      hintText: 'Search by title, assignee, list…',
                      prefixIcon: const Icon(Icons.search_outlined),
                      suffixIcon: _controller.text.isNotEmpty
                          ? IconButton(
                              icon: const Icon(Icons.clear),
                              onPressed: _controller.clear,
                            )
                          : null,
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(CaleeRadius.card),
                        borderSide: BorderSide.none,
                      ),
                      filled: true,
                      fillColor: CaleeColors.groupedBackground,
                      contentPadding: const EdgeInsets.symmetric(
                        horizontal: CaleeSpacing.md,
                        vertical: CaleeSpacing.sm,
                      ),
                    ),
                  ),
                ],
              ),
            ),
            const Divider(height: 1),
            Expanded(
              child: _controller.text.trim().isEmpty
                  ? Center(
                      child: Text(
                        'Type to search',
                        style: theme.textTheme.bodyMedium?.copyWith(
                          color: CaleeColors.textTertiary,
                        ),
                      ),
                    )
                  : _results.isEmpty
                  ? Center(
                      child: Text(
                        'No chores found',
                        style: theme.textTheme.bodyMedium?.copyWith(
                          color: CaleeColors.textTertiary,
                        ),
                      ),
                    )
                  : ListView.builder(
                      controller: scrollController,
                      padding: const EdgeInsets.symmetric(
                        horizontal: CaleeSpacing.pagePadding,
                        vertical: CaleeSpacing.sm,
                      ),
                      itemCount: _results.length,
                      itemBuilder: (context, index) {
                        final item = _results[index];
                        final subtitle = [
                          if (item.sectionLabel.isNotEmpty) item.sectionLabel,
                          if (item.assigneeName.isNotEmpty) item.assigneeName,
                          if (item.calendarName.isNotEmpty) item.calendarName,
                        ].join(' · ');
                        return CaleeListRow(
                          title: item.chore.title,
                          subtitle: subtitle.isNotEmpty ? subtitle : null,
                          leading: const Icon(
                            Icons.check_circle_outline,
                            size: 22,
                            color: CaleeColors.textTertiary,
                          ),
                          onTap: () => widget.onTapChore(item.chore),
                        );
                      },
                    ),
            ),
          ],
        ),
      ),
    );
  }
}

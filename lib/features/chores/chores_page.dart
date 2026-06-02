import 'package:flutter/material.dart';

import '../../data/api/calee_hub_client.dart';
import '../../data/models/client_bootstrap.dart';
import '../settings/calendar_collections_page.dart';
import '../settings/household_people_page.dart';
import '../../data/models/client_calendar.dart';
import '../../data/models/client_chore.dart';
import '../../data/models/client_chore_metadata.dart';
import '../../data/models/client_person.dart';
import '../../ui/calee_theme.dart';
import '../../ui/calee_widgets.dart';

// ─────────────────────────────────────────────
// Helpers (unchanged from original)
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

String _rruleLabel(String? recurrence) {
  final rrule = recurrence?.trim().toUpperCase();
  if (rrule == 'FREQ=DAILY') return 'Daily';
  if (rrule == 'FREQ=WEEKLY') return 'Weekly';
  if (rrule == 'FREQ=MONTHLY') return 'Monthly';
  return '';
}

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
  late Future<_ChoresOverview> _overviewFuture;
  final Set<String> _updatingChoreIds = {};
  String _assigneeFilter = 'all';

  List<ClientService> get _portalServices =>
      widget.services.where((service) => service.id == 'portal').toList();

  ClientContext? get _metadataHousehold {
    for (final household in widget.households) {
      if (household.type == 'household' && household.status == 'active') {
        return household;
      }
    }

    if (widget.households.isNotEmpty) {
      return widget.households.first;
    }

    return null;
  }

  bool _isPortalCalendar(ClientCalendar calendar) {
    return calendar.serviceId == 'portal' || calendar.id.startsWith('portal:');
  }

  @override
  void initState() {
    super.initState();
    _overviewFuture = _loadOverview();
  }

  Future<_ChoresOverview> _loadOverview() async {
    final today = DateTime.now();
    final from = _formatChoreDate(DateTime(today.year, 1, 1));
    final to = _formatChoreDate(DateTime(today.year, 12, 31));

    final calendarList = await widget.hubClient.calendars(
      accessToken: widget.accessToken,
    );
    final choreList = await widget.hubClient.chores(
      accessToken: widget.accessToken,
      from: from,
      to: to,
    );

    final household = _metadataHousehold;
    var people = <ClientPerson>[];

    if (household != null) {
      try {
        final peopleList = await widget.hubClient.people(
          accessToken: widget.accessToken,
          householdId: household.id,
        );
        people = peopleList.people.where((person) => person.isActive).toList();
      } catch (_) {
        people = <ClientPerson>[];
      }
    }

    return _ChoresOverview(
      calendarList: calendarList,
      choreList: choreList,
      people: people,
      from: from,
      to: to,
    );
  }

  void _openCollectionCreateShortcut() {
    final portalServices = _portalServices;

    if (portalServices.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Calee Portal is not available.')),
      );
      return;
    }

    Navigator.of(context)
        .push(
      MaterialPageRoute<void>(
        builder: (_) => CalendarCollectionsPage(
          hubClient: widget.hubClient,
          accessToken: widget.accessToken,
          services: portalServices,
          initialCreateKind: 'chores',
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

  Future<void> _openCreateChoreSheet(
      List<ClientCalendar> choreCalendars) async {
    final writableCalendars =
        choreCalendars.where((calendar) => !calendar.readOnly).toList();

    if (writableCalendars.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('No writable chore list is available.')),
      );
      return;
    }

    final household = _metadataHousehold;
    var people = <ClientPerson>[];

    if (household != null) {
      try {
        final peopleList = await widget.hubClient.people(
          accessToken: widget.accessToken,
          householdId: household.id,
        );
        people = peopleList.people.where((person) => person.isActive).toList();
      } catch (_) {
        people = <ClientPerson>[];
      }
    }

    if (!mounted) {
      return;
    }

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
        onCreate: _createChore,
      ),
    );

    if (created == true && mounted) {
      _reloadOverview();
    }
  }

  Future<void> _createChore({
    required ClientCalendar calendar,
    required String title,
    String? scheduledAt,
    String? description,
    String? recurrence,
    required String? assigneePersonId,
    required int points,
  }) async {
    final createdChore = await widget.hubClient.createChore(
      accessToken: widget.accessToken,
      serviceId: calendar.serviceId,
      calendarId: calendar.id,
      title: title,
      scheduledAt: scheduledAt,
      description: description,
      recurrence: recurrence,
      points: 1,
    );

    final household = _metadataHousehold;
    final choreUid = createdChore.choreUid?.trim();

    if (household != null && choreUid != null && choreUid.isNotEmpty) {
      await widget.hubClient.updateChoreMetadata(
        accessToken: widget.accessToken,
        householdId: household.id,
        choreUid: choreUid,
        assigneePersonId: assigneePersonId ?? '',
        points: points,
        approvalState: 'none',
      );
    }
  }

  Future<void> _openEditChoreSheet(ClientChore chore) async {
    final choreId = chore.completionActionId;

    if (choreId.trim().isEmpty || _updatingChoreIds.contains(choreId)) {
      return;
    }

    final household = _metadataHousehold;
    final choreUid = chore.choreUid?.trim();
    var people = <ClientPerson>[];
    ClientChoreMetadata? metadata;

    if (household != null && choreUid != null && choreUid.isNotEmpty) {
      try {
        final peopleList = await widget.hubClient.people(
          accessToken: widget.accessToken,
          householdId: household.id,
        );
        people = peopleList.people.where((person) => person.isActive).toList();

        metadata = await widget.hubClient.choreMetadata(
          accessToken: widget.accessToken,
          householdId: household.id,
          choreUid: choreUid,
        );
      } catch (_) {
        people = <ClientPerson>[];
        metadata = null;
      }
    }

    if (!mounted) {
      return;
    }

    final updated = await showModalBottomSheet<bool>(
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
        onUpdate: _updateChore,
      ),
    );

    if (updated == true && mounted) {
      _reloadOverview();
    }
  }

  Future<void> _updateChore({
    required ClientChore chore,
    required String title,
    String? scheduledAt,
    String? description,
    String? recurrence,
    required String? assigneePersonId,
    required int points,
    required String approvalState,
  }) async {
    final choreId = chore.completionActionId;

    if (choreId.trim().isEmpty) {
      throw StateError('Missing chore id');
    }

    await widget.hubClient.updateChore(
      accessToken: widget.accessToken,
      choreId: choreId,
      title: title,
      scheduledAt: scheduledAt,
      description: description,
      recurrence: recurrence,
    );

    final household = _metadataHousehold;
    final choreUid = chore.choreUid?.trim();

    if (household != null && choreUid != null && choreUid.isNotEmpty) {
      await widget.hubClient.updateChoreMetadata(
        accessToken: widget.accessToken,
        householdId: household.id,
        choreUid: choreUid,
        assigneePersonId: assigneePersonId ?? '',
        points: points,
        approvalState: approvalState,
      );
    }
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
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(_choreErrorMessage(error, 'Unable to update chore.')),
          ),
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

  // Replaces _deleteChore: shows a CaleeActionSheet for recurring options,
  // uses CaleeDestructiveDialog for confirmation.
  void _showChoreActions(ClientChore chore) {
    final choreId = chore.completionActionId;
    if (choreId.trim().isEmpty) return;

    final actions = <CaleeAction>[
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
      actions.add(CaleeAction(
        label: 'Delete Chore',
        icon: Icons.delete_outline,
        isDestructive: true,
        onTap: () => _confirmAndDeletePermanentChore(chore),
      ));
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
      final scheduledDate = chore.scheduledDate;
      final actionDate =
          scheduledDate != null && scheduledDate.trim().isNotEmpty
              ? scheduledDate.trim()
              : DateTime.now().toIso8601String().split('T').first;
      _performChoreAction(
        chore: chore,
        action: 'skip',
        actionDate: actionDate,
        successMessage: 'Skipped this time.',
        failureMessage: 'Unable to skip chore.',
      );
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
      _performChoreAction(
        chore: chore,
        action: 'stopRepeating',
        successMessage: 'Repeating stopped.',
        failureMessage: 'Unable to stop repeating chore.',
      );
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
      _performChoreAction(
        chore: chore,
        action: 'deletePermanent',
        successMessage: 'Chore deleted permanently.',
        failureMessage: 'Unable to delete chore.',
      );
    }
  }

  Future<void> _performChoreAction({
    required ClientChore chore,
    required String action,
    String? actionDate,
    required String successMessage,
    required String failureMessage,
  }) async {
    final choreId = chore.completionActionId;

    if (choreId.trim().isEmpty || _updatingChoreIds.contains(choreId)) {
      return;
    }

    setState(() {
      _updatingChoreIds.add(choreId);
    });

    try {
      await widget.hubClient.deleteChore(
        accessToken: widget.accessToken,
        choreId: choreId,
        action: action,
        date: actionDate,
      );

      if (mounted) {
        _reloadOverview();
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(successMessage)),
        );
      }
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(_choreErrorMessage(error, failureMessage)),
          ),
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

  List<ClientChore> _filterChoresByAssignee(List<ClientChore> chores) {
    final filter = _assigneeFilter.trim();

    if (filter == 'all') {
      return chores;
    }

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
      final name = matches.isNotEmpty && matches.first.displayName.trim().isNotEmpty
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
        selectedFilter: _assigneeFilter,
        allCount: _countAllChores(allChores),
        unassignedCount: _countUnassignedChores(allChores),
        personCounts: {
          for (final p in people) p.id: _countChoresForPerson(allChores, p.id),
        },
        onSelect: (value) {
          setState(() {
            _assigneeFilter = value;
          });
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
    final household = _metadataHousehold;

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
      _reloadOverview();
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
        if (dateCompare != 0) return dateCompare;
        return a.title.toLowerCase().compareTo(b.title.toLowerCase());
      });
    }

    return grouped;
  }

  int _todayCompletionPoints(List<ClientChore> chores) {
    return chores
        .where((chore) => chore.section == 'doneToday' || chore.completedToday)
        .fold<int>(0, (total, chore) => total + chore.points);
  }

  String _formatScheduledAt(ClientChore chore) {
    final value = chore.scheduledDate ?? chore.scheduledAt;
    final isHistory = chore.isCompletionLog || chore.section == 'history';

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
      ClientChore chore, List<ClientCalendar> calendars) {
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
      case 'history':
        return 'History';
      default:
        return 'Other';
    }
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<_ChoresOverview>(
      future: _overviewFuture,
      builder: (context, snapshot) {
        if (snapshot.connectionState == ConnectionState.waiting) {
          return const CaleeScaffold(
            body: Center(child: CircularProgressIndicator()),
          );
        }

        if (snapshot.hasError) {
          return CaleeScaffold(
            body: CaleeEmptyState(
              icon: Icons.cloud_off_outlined,
              title: 'Unable to load chores',
              body: 'Check your connection, then try again.',
              action: FilledButton(
                onPressed: _reloadOverview,
                child: const Text('Try again'),
              ),
            ),
          );
        }

        final overview = snapshot.data;
        if (overview == null) {
          return CaleeScaffold(
            body: CaleeEmptyState(
              icon: Icons.family_restroom_outlined,
              title: 'No portal chore lists yet',
              body:
                  'Create a chore list in Calee Portal to start tracking family chores.',
              action: FilledButton.icon(
                onPressed: _openCollectionCreateShortcut,
                icon: const Icon(Icons.add),
                label: const Text('Create chore list'),
              ),
            ),
          );
        }

        final choreCalendars = overview.calendarList.calendars
            .where(
              (calendar) => calendar.isChoreKind && _isPortalCalendar(calendar),
            )
            .toList();
        final allChores = overview.choreList.chores;
        final chores = _filterChoresByAssignee(allChores);
        final choresBySection = _groupChoresBySection(chores);
        final hasUnassignedChores = _hasUnassignedChores(allChores);
        final showAssigneeFilters = allChores.isNotEmpty &&
            (overview.people.isNotEmpty || hasUnassignedChores);

        if (choreCalendars.isEmpty && allChores.isEmpty) {
          return CaleeScaffold(
            body: CaleeEmptyState(
              icon: Icons.family_restroom_outlined,
              title: 'No portal chore lists yet',
              body:
                  'Create a chore list in Calee Portal to start tracking family chores.',
              action: FilledButton.icon(
                onPressed: _openCollectionCreateShortcut,
                icon: const Icon(Icons.add),
                label: const Text('Create chore list'),
              ),
            ),
          );
        }

        final writableCalendars =
            choreCalendars.where((c) => !c.readOnly).toList();
        final hasWritable = writableCalendars.isNotEmpty;

        // Section order: urgent first, then today, done, upcoming, history
        const sectionOrder = [
          'overdue',
          'todoToday',
          'doneToday',
          'future',
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
            onRefresh: () async {
              _reloadOverview();
              await _overviewFuture;
            },
            child: ListView(
              padding: const EdgeInsets.symmetric(
                horizontal: CaleeSpacing.pagePadding,
                vertical: CaleeSpacing.md,
              ),
              children: [
                // ── Summary strip ────────────────────────────────────
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
                      _assigneeFilter,
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

                // ── Chore sections ───────────────────────────────────
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
                    CaleeSection(
                      title: _sectionTitle(section),
                      trailing: '${choresBySection[section]!.length}',
                      children: choresBySection[section]!
                          .map(
                            (chore) => _ChoreRow(
                              key: ValueKey(chore.completionActionId.isNotEmpty
                                  ? chore.completionActionId
                                  : chore.id),
                              chore: chore,
                              calendarName:
                                  _calendarNameForChore(chore, choreCalendars),
                              scheduledLabel: _formatScheduledAt(chore),
                              isUpdating: _updatingChoreIds
                                  .contains(chore.completionActionId),
                              onToggleCompletion: chore.canToggleCompletion
                                  ? () => _toggleChoreCompletion(chore)
                                  : null,
                              onMoreTap:
                                  chore.completionActionId.trim().isNotEmpty &&
                                          !chore.isCompletionLog &&
                                          chore.section != 'history'
                                      ? () => _showChoreActions(chore)
                                      : null,
                            ),
                          )
                          .toList(),
                    ),
                    const SizedBox(height: CaleeSpacing.sectionSpacing),
                  ],

                // ── No chore lists: prompt to create one ─────────────
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
// Data model
// ─────────────────────────────────────────────

class _ChoresOverview {
  const _ChoresOverview({
    required this.calendarList,
    required this.choreList,
    required this.people,
    required this.from,
    required this.to,
  });

  final ClientCalendarList calendarList;
  final ClientChoreList choreList;
  final List<ClientPerson> people;
  final String from;
  final String to;
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
  const _StripChip({
    required this.label,
    this.color,
  });

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
  const _AssigneeFilterRow({
    required this.label,
    required this.onTap,
  });

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
                  ? const Icon(Icons.check, size: 20, color: CaleeColors.primary)
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
          title: 'Setup',
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
              title: 'Add Chore List',
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
    final isDone = chore.completedToday || chore.section == 'doneToday';
    final isHistory = chore.isCompletionLog || chore.section == 'history';

    // Subtitle: date · assignee · recurrence · list name
    final subtitleParts = <String>[];
    if (scheduledLabel.isNotEmpty) subtitleParts.add(scheduledLabel);

    if (!isHistory) {
      final assigneeName = chore.assigneeName?.trim();
      subtitleParts.add(
        assigneeName != null && assigneeName.isNotEmpty
            ? assigneeName
            : 'Unassigned',
      );
    }

    final recLabel = _rruleLabel(chore.recurrence);
    if (recLabel.isNotEmpty) subtitleParts.add('Repeats $recLabel');
    if (calendarName.isNotEmpty) subtitleParts.add(calendarName);
    final subtitle = subtitleParts.where((p) => p.isNotEmpty).join(' · ');

    // Leading widget
    Widget leading;
    if (isHistory) {
      leading = const Icon(
        Icons.history_outlined,
        size: 22,
        color: CaleeColors.textTertiary,
      );
    } else {
      leading = CaleeCheckCircle(
        isChecked: isDone,
        onTap: onToggleCompletion ?? () {},
        isLoading: isUpdating,
        size: 22,
      );
    }

    // Trailing: points badge + more button
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

    // Title style: muted for done/history
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

    return CaleeListRow(
      leading: leading,
      title: chore.title,
      subtitle: subtitle.isNotEmpty ? subtitle : null,
      trailing: trailing,
      titleStyle: titleStyle,
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
  }) onCreate;

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
    if (_isSubmitting || !_formKey.currentState!.validate()) {
      return;
    }

    final points = int.tryParse(_pointsController.text.trim()) ?? 1;

    setState(() {
      _isSubmitting = true;
    });

    try {
      await widget.onCreate(
        calendar: _selectedCalendar,
        title: _titleController.text.trim(),
        scheduledAt:
            _selectedDate == null ? null : _formatChoreDate(_selectedDate!),
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
              // ── Chore ──────────────────────────────────────────────────
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

              // ── Schedule ───────────────────────────────────────────────
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

              // ── Assignment ─────────────────────────────────────────────
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
                      if (points == null || points < 0 || points > 100000) {
                        return 'Enter valid points';
                      }
                      return null;
                    },
                  ),
                ],
              ),
              const SizedBox(height: CaleeSpacing.sectionSpacing),

              // ── Details ────────────────────────────────────────────────
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
  }) onUpdate;

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
    _descriptionController =
        TextEditingController(text: widget.chore.description ?? '');
    _selectedDate =
        _parseChoreDate(widget.chore.scheduledDate ?? widget.chore.scheduledAt);
    _selectedRecurrence = _choreRruleToRecurrence(widget.chore.recurrence);

    final activePeopleIds = widget.people.map((person) => person.id).toSet();
    final existingAssignee =
        widget.metadata?.assigneePersonId ?? widget.chore.assigneePersonId;

    _assigneePersonId =
        activePeopleIds.contains(existingAssignee) ? existingAssignee : null;
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
    if (_isSubmitting || !_formKey.currentState!.validate()) {
      return;
    }

    final points = int.tryParse(_pointsController.text.trim()) ?? 1;

    setState(() {
      _isSubmitting = true;
    });

    try {
      await widget.onUpdate(
        chore: widget.chore,
        title: _titleController.text.trim(),
        scheduledAt:
            _selectedDate == null ? null : _formatChoreDate(_selectedDate!),
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
                          style:
                              Theme.of(context).textTheme.bodySmall?.copyWith(
                                    color: CaleeColors.primary,
                                  ),
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: CaleeSpacing.sectionSpacing),
              ],

              // ── Chore ────────────────────────────────────────────────
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

              // ── Schedule ─────────────────────────────────────────────
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

              // ── Assignment ───────────────────────────────────────────
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
                      if (points == null || points < 0 || points > 100000) {
                        return 'Enter valid points';
                      }
                      return null;
                    },
                  ),
                ],
              ),
              const SizedBox(height: CaleeSpacing.sectionSpacing),

              // ── Details ──────────────────────────────────────────────
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


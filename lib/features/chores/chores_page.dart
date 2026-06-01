import 'package:flutter/material.dart';

import '../../data/api/calee_hub_client.dart';
import '../../data/models/client_bootstrap.dart';
import '../settings/calendar_collections_page.dart';
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

    return _ChoresOverview(
      calendarList: calendarList,
      choreList: choreList,
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
        assigneePersonId: '',
        points: points,
        approvalState: 'none',
      );
    }
  }

  Future<void> _openChoreMetadataSheet(ClientChore chore) async {
    final household = _metadataHousehold;
    final choreUid = chore.choreUid?.trim();

    if (household == null || choreUid == null || choreUid.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
            content: Text('Household chore metadata is not available.')),
      );
      return;
    }

    final saved = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      backgroundColor: CaleeColors.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(
          top: Radius.circular(CaleeRadius.sheet),
        ),
      ),
      builder: (context) => _ChoreMetadataSheet(
        hubClient: widget.hubClient,
        accessToken: widget.accessToken,
        householdId: household.id,
        choreUid: choreUid,
        chore: chore,
      ),
    );

    if (saved == true && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Chore details saved.')),
      );
      _reloadOverview();
    }
  }

  Future<void> _openEditChoreSheet(ClientChore chore) async {
    final choreId = chore.completionActionId;

    if (choreId.trim().isEmpty || _updatingChoreIds.contains(choreId)) {
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

    final canEditMetadata = _metadataHousehold != null &&
        (chore.choreUid?.trim().isNotEmpty ?? false);

    final actions = <CaleeAction>[
      if (canEditMetadata)
        CaleeAction(
          label: 'Assign & points',
          icon: Icons.assignment_ind_outlined,
          onTap: () => _openChoreMetadataSheet(chore),
        ),
      CaleeAction(
        label: 'Edit',
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
      actions.add(CaleeAction(
        label: 'Delete',
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

  void _skipChore(ClientChore chore) {
    final scheduledDate = chore.scheduledDate;
    final actionDate = scheduledDate != null && scheduledDate.trim().isNotEmpty
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

  void _stopRepeatingChore(ClientChore chore) {
    _performChoreAction(
      chore: chore,
      action: 'stopRepeating',
      successMessage: 'Repeating stopped.',
      failureMessage: 'Unable to stop repeating chore.',
    );
  }

  Future<void> _confirmAndDeletePermanentChore(ClientChore chore) async {
    final confirmed = await CaleeDestructiveDialog.show(
      context: context,
      title: 'Delete permanently?',
      body:
          'This will permanently delete "${chore.title}" and its completion records. This cannot be undone.',
      confirmLabel: 'Delete permanently',
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
        final chores = overview.choreList.chores;
        final choresBySection = _groupChoresBySection(chores);

        if (choreCalendars.isEmpty && chores.isEmpty) {
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

                // ── Chore sections ───────────────────────────────────
                if (activeSections.isEmpty && choreCalendars.isNotEmpty)
                  CaleeSection(
                    title: 'Chores',
                    children: [
                      CaleeListRow(
                        title: 'No chores yet',
                        subtitle: 'Tap + Chore to add your first chore.',
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
    required this.from,
    required this.to,
  });

  final ClientCalendarList calendarList;
  final ClientChoreList choreList;
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

class _ChoreMetadataSheet extends StatefulWidget {
  const _ChoreMetadataSheet({
    required this.hubClient,
    required this.accessToken,
    required this.householdId,
    required this.choreUid,
    required this.chore,
  });

  final CaleeHubClient hubClient;
  final String accessToken;
  final String householdId;
  final String choreUid;
  final ClientChore chore;

  @override
  State<_ChoreMetadataSheet> createState() => _ChoreMetadataSheetState();
}

class _ChoreMetadataSheetState extends State<_ChoreMetadataSheet> {
  late Future<_ChoreMetadataEditorData> _future;

  @override
  void initState() {
    super.initState();
    _future = _load();
  }

  Future<_ChoreMetadataEditorData> _load() async {
    final metadata = await widget.hubClient.choreMetadata(
      accessToken: widget.accessToken,
      householdId: widget.householdId,
      choreUid: widget.choreUid,
    );

    final people = await widget.hubClient.people(
      accessToken: widget.accessToken,
      householdId: widget.householdId,
    );

    return _ChoreMetadataEditorData(
      metadata: metadata,
      people: people.people,
    );
  }

  void _retry() {
    setState(() {
      _future = _load();
    });
  }

  Future<void> _save({
    required String? assigneePersonId,
    required int points,
    required String approvalState,
  }) async {
    await widget.hubClient.updateChoreMetadata(
      accessToken: widget.accessToken,
      householdId: widget.householdId,
      choreUid: widget.choreUid,
      assigneePersonId: assigneePersonId ?? '',
      points: points,
      approvalState: approvalState,
    );
  }

  @override
  Widget build(BuildContext context) {
    return CaleeBottomSheet(
      title: 'Assign chore',
      child: FutureBuilder<_ChoreMetadataEditorData>(
        future: _future,
        builder: (context, snapshot) {
          if (snapshot.connectionState == ConnectionState.waiting) {
            return const Padding(
              padding: EdgeInsets.symmetric(vertical: CaleeSpacing.xl),
              child: Center(child: CircularProgressIndicator()),
            );
          }

          if (snapshot.hasError || !snapshot.hasData) {
            return Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const Text('Unable to load chore details.'),
                const SizedBox(height: CaleeSpacing.md),
                FilledButton(
                  onPressed: _retry,
                  child: const Text('Try again'),
                ),
              ],
            );
          }

          return _ChoreMetadataForm(
            chore: widget.chore,
            data: snapshot.data!,
            onSave: _save,
          );
        },
      ),
    );
  }
}

class _ChoreMetadataEditorData {
  const _ChoreMetadataEditorData({
    required this.metadata,
    required this.people,
  });

  final ClientChoreMetadata metadata;
  final List<ClientPerson> people;
}

class _ChoreMetadataForm extends StatefulWidget {
  const _ChoreMetadataForm({
    required this.chore,
    required this.data,
    required this.onSave,
  });

  final ClientChore chore;
  final _ChoreMetadataEditorData data;
  final Future<void> Function({
    required String? assigneePersonId,
    required int points,
    required String approvalState,
  }) onSave;

  @override
  State<_ChoreMetadataForm> createState() => _ChoreMetadataFormState();
}

class _ChoreMetadataFormState extends State<_ChoreMetadataForm> {
  final _formKey = GlobalKey<FormState>();
  late final TextEditingController _pointsController;
  late String? _assigneePersonId;
  late String _approvalState;
  bool _isSubmitting = false;

  @override
  void initState() {
    super.initState();

    final activePeopleIds =
        widget.data.people.map((person) => person.id).toSet();
    final existingAssignee = widget.data.metadata.assigneePersonId;

    _assigneePersonId =
        activePeopleIds.contains(existingAssignee) ? existingAssignee : null;
    _approvalState = widget.data.metadata.approvalState;
    _pointsController =
        TextEditingController(text: widget.data.metadata.points.toString());
  }

  @override
  void dispose() {
    _pointsController.dispose();
    super.dispose();
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
      await widget.onSave(
        assigneePersonId: _assigneePersonId,
        points: points,
        approvalState: _approvalState,
      );

      if (mounted) {
        Navigator.of(context).pop(true);
      }
    } catch (error) {
      if (mounted) {
        setState(() {
          _isSubmitting = false;
        });

        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              _choreErrorMessage(error, 'Unable to save chore details.'),
            ),
          ),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final people = widget.data.people;

    return Form(
      key: _formKey,
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              widget.chore.title,
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: CaleeSpacing.md),
            DropdownButtonFormField<String?>(
              initialValue: _assigneePersonId,
              decoration: const InputDecoration(labelText: 'Assign to'),
              items: [
                const DropdownMenuItem<String?>(
                  value: null,
                  child: Text('Unassigned'),
                ),
                for (final person in people)
                  DropdownMenuItem<String?>(
                    value: person.id,
                    child: Text(person.displayName),
                  ),
              ],
              onChanged: _isSubmitting
                  ? null
                  : (value) {
                      setState(() {
                        _assigneePersonId = value;
                      });
                    },
            ),
            const SizedBox(height: CaleeSpacing.sm + 4),
            TextFormField(
              controller: _pointsController,
              enabled: !_isSubmitting,
              keyboardType: TextInputType.number,
              decoration: const InputDecoration(labelText: 'Points'),
              validator: (value) {
                final points = int.tryParse((value ?? '').trim());
                if (points == null || points < 0 || points > 100000) {
                  return 'Enter valid points';
                }
                return null;
              },
            ),
            const SizedBox(height: CaleeSpacing.sm + 4),
            DropdownButtonFormField<String>(
              initialValue: _approvalState,
              decoration: const InputDecoration(labelText: 'Approval'),
              items: const [
                DropdownMenuItem(value: 'none', child: Text('No approval')),
                DropdownMenuItem(value: 'pending', child: Text('Pending')),
                DropdownMenuItem(value: 'approved', child: Text('Approved')),
                DropdownMenuItem(value: 'rejected', child: Text('Rejected')),
              ],
              onChanged: _isSubmitting
                  ? null
                  : (value) {
                      if (value == null) return;
                      setState(() {
                        _approvalState = value;
                      });
                    },
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
                  : const Text('Save details'),
            ),
          ],
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────
// Create chore sheet
// ─────────────────────────────────────────────

class _CreateChoreSheet extends StatefulWidget {
  const _CreateChoreSheet({
    required this.calendars,
    required this.onCreate,
  });

  final List<ClientCalendar> calendars;
  final Future<void> Function({
    required ClientCalendar calendar,
    required String title,
    String? scheduledAt,
    String? description,
    String? recurrence,
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
  int _points = 1;
  bool _isSubmitting = false;

  @override
  void initState() {
    super.initState();
    _selectedCalendar = widget.calendars.first;
  }

  @override
  void dispose() {
    _titleController.dispose();
    _descriptionController.dispose();
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
        points: _points,
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
              DropdownButtonFormField<ClientCalendar>(
                initialValue: _selectedCalendar,
                decoration: const InputDecoration(labelText: 'Chore list'),
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
                onChanged: _isSubmitting
                    ? null
                    : (value) {
                        if (value != null) {
                          setState(() {
                            _selectedCalendar = value;
                          });
                        }
                      },
              ),
              const SizedBox(height: CaleeSpacing.sm + 4),
              TextFormField(
                controller: _titleController,
                enabled: !_isSubmitting,
                autofocus: true,
                decoration: const InputDecoration(labelText: 'Title'),
                textInputAction: TextInputAction.next,
                validator: (value) {
                  if ((value ?? '').trim().isEmpty) {
                    return 'Enter a chore title';
                  }
                  return null;
                },
              ),
              const SizedBox(height: CaleeSpacing.sm + 4),
              OutlinedButton.icon(
                onPressed: _isSubmitting ? null : _pickDate,
                icon: const Icon(Icons.event_outlined),
                label: Text(
                  _selectedDate == null
                      ? 'Add scheduled date'
                      : 'Scheduled ${_formatChoreDate(_selectedDate!)}',
                ),
              ),
              if (_selectedDate != null)
                TextButton(
                  onPressed: _isSubmitting
                      ? null
                      : () {
                          setState(() {
                            _selectedDate = null;
                          });
                        },
                  child: const Text('Remove scheduled date'),
                ),
              const SizedBox(height: CaleeSpacing.sm + 4),
              DropdownButtonFormField<String?>(
                initialValue: _selectedRecurrence,
                decoration: const InputDecoration(labelText: 'Repeat'),
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
                onChanged: _isSubmitting
                    ? null
                    : (value) {
                        setState(() {
                          _selectedRecurrence = value;
                        });
                      },
              ),
              const SizedBox(height: CaleeSpacing.sm + 4),
              DropdownButtonFormField<int>(
                initialValue: _points,
                decoration: const InputDecoration(labelText: 'Points'),
                items: const [
                  DropdownMenuItem(value: 1, child: Text('1 point')),
                  DropdownMenuItem(value: 2, child: Text('2 points')),
                ],
                onChanged: _isSubmitting
                    ? null
                    : (value) {
                        if (value != null) {
                          setState(() {
                            _points = value;
                          });
                        }
                      },
              ),
              const SizedBox(height: CaleeSpacing.sm + 4),
              TextFormField(
                controller: _descriptionController,
                enabled: !_isSubmitting,
                decoration: const InputDecoration(labelText: 'Notes'),
                minLines: 2,
                maxLines: 4,
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
    required this.onUpdate,
  });

  final ClientChore chore;
  final Future<void> Function({
    required ClientChore chore,
    required String title,
    String? scheduledAt,
    String? description,
    String? recurrence,
  }) onUpdate;

  @override
  State<_EditChoreSheet> createState() => _EditChoreSheetState();
}

class _EditChoreSheetState extends State<_EditChoreSheet> {
  final _formKey = GlobalKey<FormState>();
  late final TextEditingController _titleController;
  late final TextEditingController _descriptionController;

  DateTime? _selectedDate;
  String? _selectedRecurrence;
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
  }

  @override
  void dispose() {
    _titleController.dispose();
    _descriptionController.dispose();
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
                  padding: const EdgeInsets.all(CaleeSpacing.sm + 4),
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
                const SizedBox(height: CaleeSpacing.sm + 4),
              ],
              TextFormField(
                controller: _titleController,
                enabled: !_isSubmitting,
                autofocus: true,
                decoration: const InputDecoration(labelText: 'Title'),
                textInputAction: TextInputAction.next,
                validator: (value) {
                  if ((value ?? '').trim().isEmpty) {
                    return 'Enter a chore title';
                  }
                  return null;
                },
              ),
              const SizedBox(height: CaleeSpacing.sm + 4),
              OutlinedButton.icon(
                onPressed: _isSubmitting ? null : _pickDate,
                icon: const Icon(Icons.event_outlined),
                label: Text(
                  _selectedDate == null
                      ? 'Add scheduled date'
                      : 'Scheduled ${_formatChoreDate(_selectedDate!)}',
                ),
              ),
              if (_selectedDate != null)
                TextButton(
                  onPressed: _isSubmitting
                      ? null
                      : () {
                          setState(() {
                            _selectedDate = null;
                          });
                        },
                  child: const Text('Remove scheduled date'),
                ),
              const SizedBox(height: CaleeSpacing.sm + 4),
              DropdownButtonFormField<String?>(
                initialValue: _selectedRecurrence,
                decoration: const InputDecoration(labelText: 'Repeat'),
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
                onChanged: _isSubmitting
                    ? null
                    : (value) {
                        setState(() {
                          _selectedRecurrence = value;
                        });
                      },
              ),
              const SizedBox(height: CaleeSpacing.sm + 4),
              TextFormField(
                controller: _descriptionController,
                enabled: !_isSubmitting,
                decoration: const InputDecoration(labelText: 'Notes'),
                minLines: 2,
                maxLines: 4,
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

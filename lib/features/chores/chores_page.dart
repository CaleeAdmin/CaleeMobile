import 'package:flutter/material.dart';

import '../../data/api/calee_hub_client.dart';
import '../../data/models/client_bootstrap.dart';
import '../settings/calendar_collections_page.dart';
import '../../data/models/client_calendar.dart';
import '../../data/models/client_chore.dart';

String _formatChoreDate(DateTime value) {
  final year = value.year.toString().padLeft(4, '0');
  final month = value.month.toString().padLeft(2, '0');
  final day = value.day.toString().padLeft(2, '0');

  return '$year-$month-$day';
}

DateTime? _parseChoreDate(String? value) {
  if (value == null || value.trim().isEmpty) {
    return null;
  }

  final parsed = DateTime.tryParse(value);
  if (parsed == null) {
    return null;
  }

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

  if (rrule == 'FREQ=DAILY') {
    return 'daily';
  }

  if (rrule == 'FREQ=WEEKLY') {
    return 'weekly';
  }

  if (rrule == 'FREQ=MONTHLY') {
    return 'monthly';
  }

  return null;
}

String _choreErrorMessage(Object error, String fallback) {
  if (error is CaleeHubException && error.message.trim().isNotEmpty) {
    return error.message;
  }

  return fallback;
}

class ChoresPage extends StatefulWidget {
  const ChoresPage({
    required this.hubClient,
    required this.accessToken,
    required this.services,
    super.key,
  });

  final CaleeHubClient hubClient;
  final String accessToken;
  final List<ClientService> services;

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
    Navigator.of(context)
        .push(
      MaterialPageRoute<void>(
        builder: (_) => CalendarCollectionsPage(
          hubClient: widget.hubClient,
          accessToken: widget.accessToken,
          services: widget.services,
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
    await widget.hubClient.createChore(
      accessToken: widget.accessToken,
      serviceId: calendar.serviceId,
      calendarId: calendar.id,
      title: title,
      scheduledAt: scheduledAt,
      description: description,
      recurrence: recurrence,
      points: points,
    );
  }

  Future<void> _openEditChoreSheet(ClientChore chore) async {
    final choreId = chore.completionActionId;

    if (choreId.trim().isEmpty || _updatingChoreIds.contains(choreId)) {
      return;
    }

    final updated = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
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
    required int points,
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
      points: points,
    );
  }

  Future<bool> _confirmPermanentChoreDelete(ClientChore chore) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete permanently?'),
        content: Text(
          'This will permanently delete "${chore.title}" and its completion records. This cannot be undone.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Delete permanently'),
          ),
        ],
      ),
    );

    return confirmed == true;
  }

  Future<void> _deleteChore(ClientChore chore) async {
    final choreId = chore.completionActionId;

    if (choreId.trim().isEmpty || _updatingChoreIds.contains(choreId)) {
      return;
    }

    String? action;
    String? actionDate;
    var successMessage = 'Chore deleted permanently.';

    if (chore.isRecurring) {
      action = await showDialog<String>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('Recurring chore'),
          content: Text(
            'What would you like to do with "${chore.title}"?',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('Cancel'),
            ),
            TextButton(
              onPressed: () => Navigator.of(context).pop('skip'),
              child: const Text('Skip this time'),
            ),
            TextButton(
              onPressed: () => Navigator.of(context).pop('stopRepeating'),
              child: const Text('Stop repeating'),
            ),
            TextButton(
              style: TextButton.styleFrom(
                foregroundColor: Theme.of(context).colorScheme.error,
              ),
              onPressed: () => Navigator.of(context).pop('deletePermanent'),
              child: const Text('Delete permanently'),
            ),
          ],
        ),
      );

      if (action == null || !mounted) {
        return;
      }

      if (action == 'skip') {
        final scheduledDate = chore.scheduledDate;
        actionDate = scheduledDate != null && scheduledDate.trim().isNotEmpty
            ? scheduledDate.trim()
            : DateTime.now().toIso8601String().split('T').first;
        successMessage = 'Skipped this time.';
      } else if (action == 'stopRepeating') {
        successMessage = 'Repeating stopped.';
      } else if (action == 'deletePermanent') {
        await Future<void>.delayed(Duration.zero);
        if (!mounted) {
          return;
        }

        final confirmedPermanentDelete =
            await _confirmPermanentChoreDelete(chore);

        if (!confirmedPermanentDelete || !mounted) {
          return;
        }
      }
    } else {
      final confirmedPermanentDelete =
          await _confirmPermanentChoreDelete(chore);

      if (!confirmedPermanentDelete || !mounted) {
        return;
      }

      action = 'deletePermanent';
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
        final fallbackMessage = switch (action) {
          'skip' => 'Unable to skip chore.',
          'stopRepeating' => 'Unable to stop repeating chore.',
          _ => 'Unable to delete chore.',
        };

        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(_choreErrorMessage(error, fallbackMessage)),
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

  int _todayCompletionPoints(List<ClientChore> chores) {
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
          return _ChoresEmptyState(
            onCreateChoreList: _openCollectionCreateShortcut,
          );
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
          return _ChoresEmptyState(
            onCreateChoreList: _openCollectionCreateShortcut,
          );
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
                weeklyPoints: _todayCompletionPoints(chores),
              ),
              const SizedBox(height: 24),
              _SectionHeader(
                title: 'Chore lists',
                subtitle: '${choreCalendars.length} found',
              ),
              const SizedBox(height: 8),
              if (choreCalendars.isEmpty)
                _EmptySectionMessage(
                  message: 'No chore lists found yet.',
                  action: TextButton.icon(
                    onPressed: _openCollectionCreateShortcut,
                    icon: const Icon(Icons.add),
                    label: const Text('Create chore list'),
                  ),
                )
              else
                ...choreCalendars.map(_ChoreListTile.new),
              const SizedBox(height: 24),
              _SectionHeader(
                title: 'Chores',
                subtitle: '${chores.length} found',
              ),
              const SizedBox(height: 8),
              Align(
                alignment: Alignment.centerLeft,
                child: FilledButton.icon(
                  onPressed: choreCalendars.isEmpty
                      ? _openCollectionCreateShortcut
                      : () => _openCreateChoreSheet(choreCalendars),
                  icon: const Icon(Icons.add),
                  label: Text(
                    choreCalendars.isEmpty ? 'Create chore list' : 'Add chore',
                  ),
                ),
              ),
              const SizedBox(height: 12),
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
                    onEditChore: _openEditChoreSheet,
                    onDeleteChore: _deleteChore,
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
                  'Add chore',
                  style: Theme.of(context).textTheme.titleLarge,
                ),
                const SizedBox(height: 16),
                DropdownButtonFormField<ClientCalendar>(
                  initialValue: _selectedCalendar,
                  decoration: const InputDecoration(
                    labelText: 'Chore list',
                    border: OutlineInputBorder(),
                  ),
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
                      return 'Enter a chore title';
                    }

                    return null;
                  },
                ),
                const SizedBox(height: 12),
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
                const SizedBox(height: 12),
                DropdownButtonFormField<String?>(
                  initialValue: _selectedRecurrence,
                  decoration: const InputDecoration(
                    labelText: 'Repeat',
                    border: OutlineInputBorder(),
                  ),
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
                const SizedBox(height: 12),
                DropdownButtonFormField<int>(
                  initialValue: _points,
                  decoration: const InputDecoration(
                    labelText: 'Points',
                    border: OutlineInputBorder(),
                  ),
                  items: const [
                    DropdownMenuItem(
                      value: 1,
                      child: Text('1 point'),
                    ),
                    DropdownMenuItem(
                      value: 2,
                      child: Text('2 points'),
                    ),
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
                      : const Text('Create chore'),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

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
    required int points,
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
  late int _points;
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
    _points = widget.chore.points <= 1 ? 1 : 2;
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
          const SnackBar(content: Text('Unable to update chore.')),
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
                  'Edit chore',
                  style: Theme.of(context).textTheme.titleLarge,
                ),
                const SizedBox(height: 16),
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
                      return 'Enter a chore title';
                    }

                    return null;
                  },
                ),
                const SizedBox(height: 12),
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
                const SizedBox(height: 12),
                DropdownButtonFormField<String?>(
                  initialValue: _selectedRecurrence,
                  decoration: const InputDecoration(
                    labelText: 'Repeat',
                    border: OutlineInputBorder(),
                  ),
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
                const SizedBox(height: 12),
                DropdownButtonFormField<int>(
                  initialValue: _points,
                  decoration: const InputDecoration(
                    labelText: 'Points',
                    border: OutlineInputBorder(),
                  ),
                  items: const [
                    DropdownMenuItem(
                      value: 1,
                      child: Text('1 point'),
                    ),
                    DropdownMenuItem(
                      value: 2,
                      child: Text('2 points'),
                    ),
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
                      : const Text('Save chore'),
                ),
              ],
            ),
          ),
        ),
      ),
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
    required this.onEditChore,
    required this.onDeleteChore,
  });

  final String title;
  final List<ClientChore> chores;
  final String emptyMessage;
  final String Function(ClientChore chore) scheduledLabelBuilder;
  final Set<String> updatingChoreIds;
  final ValueChanged<ClientChore> onToggleCompletion;
  final ValueChanged<ClientChore> onEditChore;
  final ValueChanged<ClientChore> onDeleteChore;

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
              onEditChore: () => onEditChore(chore),
              onDeleteChore: () => onDeleteChore(chore),
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
    required this.onEditChore,
    required this.onDeleteChore,
  });

  final ClientChore chore;
  final String scheduledLabel;
  final bool isUpdating;
  final VoidCallback onToggleCompletion;
  final VoidCallback onEditChore;
  final VoidCallback onDeleteChore;

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
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            IconButton(
              icon: const Icon(Icons.edit_outlined),
              onPressed: chore.completionActionId.trim().isEmpty ||
                      chore.section == 'history'
                  ? null
                  : onEditChore,
              tooltip: 'Edit chore',
            ),
            IconButton(
              icon: const Icon(Icons.delete_outline),
              onPressed: chore.completionActionId.trim().isEmpty ||
                      chore.section == 'history'
                  ? null
                  : onDeleteChore,
              tooltip: 'Delete chore',
            ),
          ],
        ),
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
    this.action,
  });

  final String message;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(message),
            if (action != null) ...[
              const SizedBox(height: 8),
              action!,
            ],
          ],
        ),
      ),
    );
  }
}

class _ChoresEmptyState extends StatelessWidget {
  const _ChoresEmptyState({
    this.onCreateChoreList,
  });

  final VoidCallback? onCreateChoreList;

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

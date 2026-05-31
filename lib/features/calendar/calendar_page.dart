import 'package:flutter/material.dart';

import '../../data/api/calee_hub_client.dart';
import '../../data/models/client_bootstrap.dart';
import '../settings/calendar_collections_page.dart';
import '../../data/models/client_calendar.dart';

class CalendarPage extends StatefulWidget {
  const CalendarPage({
    required this.hubClient,
    required this.accessToken,
    required this.services,
    super.key,
  });

  final CaleeHubClient hubClient;
  final String accessToken;
  final List<ClientService> services;

  @override
  State<CalendarPage> createState() => _CalendarPageState();
}

class _CalendarPageState extends State<CalendarPage> {
  late Future<_CalendarOverview> _overviewFuture;

  @override
  void initState() {
    super.initState();
    _overviewFuture = _loadOverview();
  }

  Future<_CalendarOverview> _loadOverview() async {
    final today = DateTime.now();
    final fromDate = today;
    final toDate = today.add(const Duration(days: 7));
    final from = _formatDate(fromDate);
    final to = _formatDate(toDate);

    final results = await Future.wait([
      widget.hubClient.calendars(accessToken: widget.accessToken),
      widget.hubClient.events(
        accessToken: widget.accessToken,
        from: from,
        to: to,
      ),
    ]);

    return _CalendarOverview(
      calendarList: results[0] as ClientCalendarList,
      eventList: results[1] as ClientEventList,
      fromDate: fromDate,
      toDate: toDate,
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
          initialCreateKind: 'calendar',
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

  Future<void> _openCreateEventSheet(List<ClientCalendar> calendars) async {
    final writableCalendars =
        calendars.where((calendar) => !calendar.readOnly).toList();

    if (writableCalendars.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('No writable calendar is available.')),
      );
      return;
    }

    final created = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      builder: (context) => _CreateEventSheet(
        calendars: writableCalendars,
        onCreate: _createEvent,
      ),
    );

    if (created == true && mounted) {
      _reloadOverview();
    }
  }

  ClientCalendar? _calendarForEvent(
    ClientEvent event,
    List<ClientCalendar> calendars,
  ) {
    for (final calendar in calendars) {
      if (calendar.id == event.calendarId ||
          calendar.id.endsWith(':${event.calendarId}') ||
          event.calendarId.endsWith(':${calendar.id}')) {
        return calendar;
      }
    }

    return null;
  }

  Future<void> _openEventActions(
    ClientEvent event,
    List<ClientCalendar> calendars,
  ) async {
    final calendar = _calendarForEvent(event, calendars);
    final canWrite = calendar != null && !calendar.readOnly;

    final editLabel = event.recurring ? 'Edit series' : 'Edit event';
    final deleteLabel = event.recurring ? 'Delete series' : 'Delete event';
    final readOnlyMessage = event.recurring
        ? 'This recurring event calendar is read-only.'
        : 'This calendar is read-only.';

    final action = await showModalBottomSheet<String>(
      context: context,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.event_outlined),
              title: Text(event.title),
              subtitle: Text(_EventTile.formatEventTime(event)),
            ),
            const Divider(height: 1),
            ListTile(
              enabled: canWrite,
              leading: const Icon(Icons.edit_outlined),
              title: Text(editLabel),
              subtitle: canWrite ? null : Text(readOnlyMessage),
              onTap: canWrite ? () => Navigator.of(context).pop('edit') : null,
            ),
            ListTile(
              enabled: canWrite,
              leading: const Icon(Icons.delete_outline),
              title: Text(deleteLabel),
              subtitle: canWrite ? null : Text(readOnlyMessage),
              onTap:
                  canWrite ? () => Navigator.of(context).pop('delete') : null,
            ),
          ],
        ),
      ),
    );

    if (!mounted) {
      return;
    }

    if (action == 'edit') {
      await _openEditEventSheet(event, calendar!);
    } else if (action == 'delete') {
      await _confirmDeleteEvent(event);
    }
  }

  Future<void> _openEditEventSheet(
    ClientEvent event,
    ClientCalendar calendar,
  ) async {
    final updated = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      builder: (context) => _CreateEventSheet(
        calendars: [calendar],
        initialEvent: event,
        onCreate: _createEvent,
        onUpdate: _updateEvent,
      ),
    );

    if (updated == true && mounted) {
      _reloadOverview();
    }
  }

  Future<void> _updateEvent({
    required ClientEvent event,
    required String title,
    required DateTime startsAt,
    required DateTime endsAt,
    required bool allDay,
    String? location,
    String? description,
  }) async {
    await widget.hubClient.updateEvent(
      accessToken: widget.accessToken,
      eventId: event.writableEventId,
      title: title,
      startsAt: allDay ? _formatDate(startsAt) : startsAt.toIso8601String(),
      endsAt: allDay ? _formatDate(endsAt) : endsAt.toIso8601String(),
      allDay: allDay,
      location: location,
      description: description,
    );
  }

  Future<void> _confirmDeleteEvent(ClientEvent event) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(event.recurring ? 'Delete series?' : 'Delete event?'),
        content: Text(
          event.recurring
              ? 'Delete "${event.title}" and all events in this recurring series?'
              : 'Delete "${event.title}"?',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );

    if (confirmed != true) {
      return;
    }

    try {
      await widget.hubClient.deleteEvent(
        accessToken: widget.accessToken,
        eventId: event.writableEventId,
      );

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              event.recurring ? 'Recurring series deleted.' : 'Event deleted.',
            ),
          ),
        );
        _reloadOverview();
      }
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              error is CaleeHubException
                  ? error.message
                  : event.recurring
                      ? 'Unable to delete recurring series.'
                      : 'Unable to delete event.',
            ),
          ),
        );
      }
    }
  }

  Future<void> _createEvent({
    required ClientCalendar calendar,
    required String title,
    required DateTime startsAt,
    required DateTime endsAt,
    required bool allDay,
    String? location,
    String? description,
    String? recurrence,
  }) async {
    await widget.hubClient.createEvent(
      accessToken: widget.accessToken,
      serviceId: calendar.serviceId,
      calendarId: calendar.id,
      title: title,
      startsAt: allDay ? _formatDate(startsAt) : startsAt.toIso8601String(),
      endsAt: allDay ? _formatDate(endsAt) : endsAt.toIso8601String(),
      allDay: allDay,
      location: location,
      description: description,
      recurrence: recurrence,
    );
  }

  void _reloadOverview() {
    setState(() {
      _overviewFuture = _loadOverview();
    });
  }

  String _formatDate(DateTime value) {
    final local = value.toLocal();
    final year = local.year.toString().padLeft(4, '0');
    final month = local.month.toString().padLeft(2, '0');
    final day = local.day.toString().padLeft(2, '0');

    return '$year-$month-$day';
  }

  String _formatDateRange(DateTime from, DateTime to) {
    final start = from.toLocal();
    final end = to.toLocal();

    return '${start.day}/${start.month} - ${end.day}/${end.month}';
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<_CalendarOverview>(
      future: _overviewFuture,
      builder: (context, snapshot) {
        if (snapshot.connectionState == ConnectionState.waiting) {
          return const Center(
            child: CircularProgressIndicator(),
          );
        }

        if (snapshot.hasError) {
          return _CalendarErrorState(
            onRetry: _reloadOverview,
          );
        }

        final overview = snapshot.data;
        if (overview == null) {
          return _CalendarEmptyState(
            onCreateCalendar: _openCollectionCreateShortcut,
          );
        }

        final calendars = overview.calendarList.calendars
            .where((calendar) => calendar.isCalendarKind)
            .toList();
        final events = overview.eventList.events;

        if (calendars.isEmpty && events.isEmpty) {
          return _CalendarEmptyState(
            onCreateCalendar: _openCollectionCreateShortcut,
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
              _SectionHeader(
                title: 'Calendars',
                subtitle: '${calendars.length} found',
              ),
              const SizedBox(height: 8),
              if (calendars.isEmpty)
                _EmptySectionMessage(
                  message: 'No calendars found yet.',
                  action: TextButton.icon(
                    onPressed: _openCollectionCreateShortcut,
                    icon: const Icon(Icons.add),
                    label: const Text('Create calendar'),
                  ),
                )
              else
                ...calendars.map(_CalendarTile.new),
              const SizedBox(height: 24),
              _SectionHeader(
                title: 'Upcoming events',
                subtitle: _formatDateRange(overview.fromDate, overview.toDate),
              ),
              const SizedBox(height: 8),
              Align(
                alignment: Alignment.centerLeft,
                child: FilledButton.icon(
                  onPressed: calendars.isEmpty
                      ? _openCollectionCreateShortcut
                      : () => _openCreateEventSheet(calendars),
                  icon: const Icon(Icons.add),
                  label: Text(
                    calendars.isEmpty ? 'Create calendar' : 'Add event',
                  ),
                ),
              ),
              const SizedBox(height: 12),
              if (events.isEmpty)
                _EmptySectionMessage(
                  message: 'No events found in this date range.',
                  action: calendars.isEmpty
                      ? TextButton.icon(
                          onPressed: _openCollectionCreateShortcut,
                          icon: const Icon(Icons.add),
                          label: const Text('Create calendar'),
                        )
                      : TextButton.icon(
                          onPressed: () => _openCreateEventSheet(calendars),
                          icon: const Icon(Icons.add),
                          label: const Text('Add event'),
                        ),
                )
              else
                ...events.map(
                  (event) => _EventTile(
                    event: event,
                    onTap: () => _openEventActions(event, calendars),
                  ),
                ),
            ],
          ),
        );
      },
    );
  }
}

class _CalendarOverview {
  const _CalendarOverview({
    required this.calendarList,
    required this.eventList,
    required this.fromDate,
    required this.toDate,
  });

  final ClientCalendarList calendarList;
  final ClientEventList eventList;
  final DateTime fromDate;
  final DateTime toDate;
}

class _CalendarTile extends StatelessWidget {
  const _CalendarTile(this.calendar);

  final ClientCalendar calendar;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: ListTile(
        leading: CircleAvatar(
          child: Text(
            calendar.name.isNotEmpty
                ? calendar.name.characters.first.toUpperCase()
                : '?',
          ),
        ),
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

class _EventTile extends StatelessWidget {
  const _EventTile({
    required this.event,
    required this.onTap,
  });

  final ClientEvent event;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: ListTile(
        onTap: onTap,
        leading: const Icon(Icons.event_outlined),
        title: Text(event.title),
        subtitle: Text(
          [
            formatEventTime(event),
            if (event.serviceName.trim().isNotEmpty)
              'From ${event.serviceName}',
            if ((event.location ?? '').trim().isNotEmpty) event.location!,
          ].where((item) => item.trim().isNotEmpty).join(' · '),
        ),
        trailing: const Icon(Icons.more_horiz),
      ),
    );
  }

  static String formatEventTime(ClientEvent event) {
    final start = DateTime.tryParse(event.startsAt);
    if (start == null) {
      return event.allDay ? 'All day' : event.startsAt;
    }

    final local = start.toLocal();

    if (event.allDay) {
      final end = DateTime.tryParse(event.endsAt)?.toLocal();
      if (end == null) {
        return '${local.day}/${local.month} · All day';
      }

      final visibleEnd = end.subtract(const Duration(days: 1));
      if (visibleEnd.year == local.year &&
          visibleEnd.month == local.month &&
          visibleEnd.day == local.day) {
        return '${local.day}/${local.month} · All day';
      }

      return '${local.day}/${local.month} - ${visibleEnd.day}/${visibleEnd.month} · All day';
    }

    final hour = local.hour.toString().padLeft(2, '0');
    final minute = local.minute.toString().padLeft(2, '0');

    return '${local.day}/${local.month} $hour:$minute';
  }
}

class _CreateEventSheet extends StatefulWidget {
  const _CreateEventSheet({
    required this.calendars,
    required this.onCreate,
    this.initialEvent,
    this.onUpdate,
  });

  final List<ClientCalendar> calendars;
  final ClientEvent? initialEvent;
  final Future<void> Function({
    required ClientCalendar calendar,
    required String title,
    required DateTime startsAt,
    required DateTime endsAt,
    required bool allDay,
    String? location,
    String? description,
    String? recurrence,
  }) onCreate;
  final Future<void> Function({
    required ClientEvent event,
    required String title,
    required DateTime startsAt,
    required DateTime endsAt,
    required bool allDay,
    String? location,
    String? description,
  })? onUpdate;

  @override
  State<_CreateEventSheet> createState() => _CreateEventSheetState();
}

class _CreateEventSheetState extends State<_CreateEventSheet> {
  final _formKey = GlobalKey<FormState>();
  final _titleController = TextEditingController();
  final _locationController = TextEditingController();
  final _descriptionController = TextEditingController();
  final _recurrenceCountController = TextEditingController(text: '10');

  late ClientCalendar _selectedCalendar;
  late DateTime _selectedDate;
  late DateTime _selectedEndDate;
  late TimeOfDay _startTime;
  late TimeOfDay _endTime;
  String _selectedRecurrence = 'none';
  String _recurrenceEnd = 'never';
  late DateTime _recurrenceEndDate;
  bool _allDay = false;
  bool _isSubmitting = false;

  bool get _isEditing => widget.initialEvent != null;

  @override
  void initState() {
    super.initState();

    _selectedCalendar = widget.calendars.first;

    final event = widget.initialEvent;
    if (event != null) {
      _titleController.text = event.title;
      _locationController.text = event.location ?? '';
      _descriptionController.text = event.description ?? '';
      _allDay = event.allDay;

      final start =
          DateTime.tryParse(event.startsAt)?.toLocal() ?? DateTime.now();
      final end = DateTime.tryParse(event.endsAt)?.toLocal() ??
          start.add(const Duration(hours: 1));

      _selectedDate = DateTime(start.year, start.month, start.day);
      _recurrenceEndDate = _selectedDate.add(const Duration(days: 30));
      _selectedEndDate = event.allDay
          ? DateTime(end.year, end.month, end.day)
              .subtract(const Duration(days: 1))
          : _selectedDate;

      if (_selectedEndDate.isBefore(_selectedDate)) {
        _selectedEndDate = _selectedDate;
      }

      _startTime = TimeOfDay(hour: start.hour, minute: start.minute);
      _endTime = TimeOfDay(hour: end.hour, minute: end.minute);
      return;
    }

    final now = DateTime.now();
    _selectedDate = DateTime(now.year, now.month, now.day);
    _selectedEndDate = _selectedDate;
    _recurrenceEndDate = _selectedDate.add(const Duration(days: 30));

    final nextHour = now.add(const Duration(hours: 1));
    _startTime = TimeOfDay(hour: nextHour.hour, minute: 0);
    _endTime = TimeOfDay(hour: (nextHour.hour + 1) % 24, minute: 0);
  }

  @override
  void dispose() {
    _titleController.dispose();
    _locationController.dispose();
    _descriptionController.dispose();
    _recurrenceCountController.dispose();
    super.dispose();
  }

  DateTime _dateTimeFor(TimeOfDay time) {
    return DateTime(
      _selectedDate.year,
      _selectedDate.month,
      _selectedDate.day,
      time.hour,
      time.minute,
    );
  }

  String _dateLabel(DateTime value) {
    return '${value.day}/${value.month}/${value.year}';
  }

  String _timeLabel(TimeOfDay value) {
    final hour = value.hour.toString().padLeft(2, '0');
    final minute = value.minute.toString().padLeft(2, '0');
    return '$hour:$minute';
  }

  String? _recurrenceValue() {
    final frequency = switch (_selectedRecurrence) {
      'daily' => 'DAILY',
      'weekly' => 'WEEKLY',
      'monthly' => 'MONTHLY',
      'yearly' => 'YEARLY',
      _ => null,
    };

    if (frequency == null) {
      return null;
    }

    final parts = <String>['FREQ=$frequency'];

    if (_recurrenceEnd == 'count') {
      final count = int.tryParse(_recurrenceCountController.text.trim());
      if (count == null || count < 1) {
        throw const FormatException('Enter a repeat count of at least 1.');
      }

      parts.add('COUNT=$count');
    } else if (_recurrenceEnd == 'date') {
      parts.add('UNTIL=${_formatRRuleUntil(_recurrenceEndDate)}');
    }

    return parts.join(';');
  }

  String _formatRRuleUntil(DateTime value) {
    if (_allDay) {
      final year = value.year.toString().padLeft(4, '0');
      final month = value.month.toString().padLeft(2, '0');
      final day = value.day.toString().padLeft(2, '0');

      return '$year$month$day';
    }

    final localEndOfDay =
        DateTime(value.year, value.month, value.day, 23, 59, 59);
    final utc = localEndOfDay.toUtc();

    final year = utc.year.toString().padLeft(4, '0');
    final month = utc.month.toString().padLeft(2, '0');
    final day = utc.day.toString().padLeft(2, '0');
    final hour = utc.hour.toString().padLeft(2, '0');
    final minute = utc.minute.toString().padLeft(2, '0');
    final second = utc.second.toString().padLeft(2, '0');

    return '$year$month${day}T$hour$minute${second}Z';
  }

  String _recurrenceLabel(String value) {
    switch (value) {
      case 'daily':
        return 'Daily';
      case 'weekly':
        return 'Weekly';
      case 'monthly':
        return 'Monthly';
      case 'yearly':
        return 'Yearly';
      default:
        return 'Does not repeat';
    }
  }

  Future<void> _pickDate() async {
    final picked = await showDatePicker(
      context: context,
      initialDate: _selectedDate,
      firstDate: DateTime(2020),
      lastDate: DateTime(2100),
    );

    if (picked != null && mounted) {
      setState(() {
        _selectedDate = DateTime(picked.year, picked.month, picked.day);

        if (_selectedEndDate.isBefore(_selectedDate)) {
          _selectedEndDate = _selectedDate;
        }
      });
    }
  }

  Future<void> _pickRecurrenceEndDate() async {
    final picked = await showDatePicker(
      context: context,
      initialDate: _recurrenceEndDate.isBefore(_selectedDate)
          ? _selectedDate
          : _recurrenceEndDate,
      firstDate: _selectedDate,
      lastDate: DateTime(2100),
    );

    if (picked != null && mounted) {
      setState(() {
        _recurrenceEndDate = DateTime(picked.year, picked.month, picked.day);
      });
    }
  }

  Future<void> _pickEndDate() async {
    final picked = await showDatePicker(
      context: context,
      initialDate: _selectedEndDate.isBefore(_selectedDate)
          ? _selectedDate
          : _selectedEndDate,
      firstDate: _selectedDate,
      lastDate: DateTime(2100),
    );

    if (picked != null && mounted) {
      setState(() {
        _selectedEndDate = DateTime(picked.year, picked.month, picked.day);
      });
    }
  }

  Future<void> _pickStartTime() async {
    final picked = await showTimePicker(
      context: context,
      initialTime: _startTime,
    );

    if (picked != null && mounted) {
      setState(() {
        _startTime = picked;
      });
    }
  }

  Future<void> _pickEndTime() async {
    final picked = await showTimePicker(
      context: context,
      initialTime: _endTime,
    );

    if (picked != null && mounted) {
      setState(() {
        _endTime = picked;
      });
    }
  }

  Future<void> _submit() async {
    if (_isSubmitting || !_formKey.currentState!.validate()) {
      return;
    }

    final startsAt = _dateTimeFor(_startTime);
    var endsAt = _dateTimeFor(_endTime);

    if (_allDay) {
      if (_selectedEndDate.isBefore(_selectedDate)) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
              content: Text('End date must be on or after start date.')),
        );
        return;
      }

      endsAt = _selectedEndDate.add(const Duration(days: 1));
    } else if (!endsAt.isAfter(startsAt)) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('End time must be after start time.')),
      );
      return;
    }

    setState(() {
      _isSubmitting = true;
    });

    try {
      final title = _titleController.text.trim();
      final location = _locationController.text.trim().isEmpty
          ? null
          : _locationController.text.trim();
      final description = _descriptionController.text.trim().isEmpty
          ? null
          : _descriptionController.text.trim();

      if (_isEditing) {
        await widget.onUpdate!(
          event: widget.initialEvent!,
          title: title,
          startsAt: startsAt,
          endsAt: endsAt,
          allDay: _allDay,
          location: location,
          description: description,
        );
      } else {
        await widget.onCreate(
          calendar: _selectedCalendar,
          title: title,
          startsAt: startsAt,
          endsAt: endsAt,
          allDay: _allDay,
          location: location,
          description: description,
          recurrence: _recurrenceValue(),
        );
      }

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
              error is CaleeHubException
                  ? error.message
                  : _isEditing
                      ? widget.initialEvent!.recurring
                          ? 'Unable to update recurring series.'
                          : 'Unable to update event.'
                      : 'Unable to create event.',
            ),
          ),
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
                  _isEditing
                      ? widget.initialEvent!.recurring
                          ? 'Edit series'
                          : 'Edit event'
                      : 'Add event',
                  style: Theme.of(context).textTheme.titleLarge,
                ),
                const SizedBox(height: 16),
                DropdownButtonFormField<ClientCalendar>(
                  initialValue: _selectedCalendar,
                  decoration: const InputDecoration(
                    labelText: 'Calendar',
                    border: OutlineInputBorder(),
                  ),
                  items: [
                    for (final calendar in widget.calendars)
                      DropdownMenuItem(
                        value: calendar,
                        child: Text(calendar.name),
                      ),
                  ],
                  onChanged: _isSubmitting || _isEditing
                      ? null
                      : (calendar) {
                          if (calendar != null) {
                            setState(() {
                              _selectedCalendar = calendar;
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
                  validator: (value) {
                    if ((value ?? '').trim().isEmpty) {
                      return 'Enter a title';
                    }

                    return null;
                  },
                ),
                const SizedBox(height: 12),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('All day'),
                  value: _allDay,
                  onChanged: _isSubmitting
                      ? null
                      : (value) {
                          setState(() {
                            _allDay = value;
                          });
                        },
                ),
                if (_allDay) ...[
                  Row(
                    children: [
                      Expanded(
                        child: OutlinedButton.icon(
                          onPressed: _isSubmitting ? null : _pickDate,
                          icon: const Icon(Icons.today_outlined),
                          label: Text('Start ${_dateLabel(_selectedDate)}'),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: OutlinedButton.icon(
                          onPressed: _isSubmitting ? null : _pickEndDate,
                          icon: const Icon(Icons.event_available_outlined),
                          label: Text('End ${_dateLabel(_selectedEndDate)}'),
                        ),
                      ),
                    ],
                  ),
                ] else ...[
                  OutlinedButton.icon(
                    onPressed: _isSubmitting ? null : _pickDate,
                    icon: const Icon(Icons.today_outlined),
                    label: Text(_dateLabel(_selectedDate)),
                  ),
                  const SizedBox(height: 8),
                  Row(
                    children: [
                      Expanded(
                        child: OutlinedButton.icon(
                          onPressed: _isSubmitting ? null : _pickStartTime,
                          icon: const Icon(Icons.schedule_outlined),
                          label: Text('Start ${_timeLabel(_startTime)}'),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: OutlinedButton.icon(
                          onPressed: _isSubmitting ? null : _pickEndTime,
                          icon: const Icon(Icons.schedule),
                          label: Text('End ${_timeLabel(_endTime)}'),
                        ),
                      ),
                    ],
                  ),
                ],
                if (!_isEditing) ...[
                  const SizedBox(height: 12),
                  DropdownButtonFormField<String>(
                    initialValue: _selectedRecurrence,
                    decoration: const InputDecoration(
                      labelText: 'Repeat',
                      border: OutlineInputBorder(),
                    ),
                    items: const [
                      DropdownMenuItem(
                        value: 'none',
                        child: Text('Does not repeat'),
                      ),
                      DropdownMenuItem(
                        value: 'daily',
                        child: Text('Daily'),
                      ),
                      DropdownMenuItem(
                        value: 'weekly',
                        child: Text('Weekly'),
                      ),
                      DropdownMenuItem(
                        value: 'monthly',
                        child: Text('Monthly'),
                      ),
                      DropdownMenuItem(
                        value: 'yearly',
                        child: Text('Yearly'),
                      ),
                    ],
                    onChanged: _isSubmitting
                        ? null
                        : (value) {
                            if (value != null) {
                              setState(() {
                                _selectedRecurrence = value;
                              });
                            }
                          },
                  ),
                  if (_selectedRecurrence != 'none') ...[
                    const SizedBox(height: 12),
                    DropdownButtonFormField<String>(
                      initialValue: _recurrenceEnd,
                      decoration: const InputDecoration(
                        labelText: 'Ends',
                        border: OutlineInputBorder(),
                      ),
                      items: const [
                        DropdownMenuItem(
                          value: 'never',
                          child: Text('Never'),
                        ),
                        DropdownMenuItem(
                          value: 'date',
                          child: Text('On date'),
                        ),
                        DropdownMenuItem(
                          value: 'count',
                          child: Text('After count'),
                        ),
                      ],
                      onChanged: _isSubmitting
                          ? null
                          : (value) {
                              if (value != null) {
                                setState(() {
                                  _recurrenceEnd = value;
                                });
                              }
                            },
                    ),
                    if (_recurrenceEnd == 'date') ...[
                      const SizedBox(height: 8),
                      OutlinedButton.icon(
                        onPressed:
                            _isSubmitting ? null : _pickRecurrenceEndDate,
                        icon: const Icon(Icons.event_repeat_outlined),
                        label: Text(
                          'Ends ${_dateLabel(_recurrenceEndDate)}',
                        ),
                      ),
                    ],
                    if (_recurrenceEnd == 'count') ...[
                      const SizedBox(height: 8),
                      TextFormField(
                        controller: _recurrenceCountController,
                        enabled: !_isSubmitting,
                        keyboardType: TextInputType.number,
                        decoration: const InputDecoration(
                          labelText: 'Number of repeats',
                          border: OutlineInputBorder(),
                        ),
                        validator: (value) {
                          if (_selectedRecurrence == 'none' ||
                              _recurrenceEnd != 'count') {
                            return null;
                          }

                          final count = int.tryParse((value ?? '').trim());
                          if (count == null || count < 1) {
                            return 'Enter a number of at least 1';
                          }

                          return null;
                        },
                      ),
                    ],
                    const SizedBox(height: 8),
                    Text(
                      'Repeats ${_recurrenceLabel(_selectedRecurrence).toLowerCase()}${_recurrenceEnd == 'never' ? '' : _recurrenceEnd == 'date' ? ' until ${_dateLabel(_recurrenceEndDate)}' : ' ${_recurrenceCountController.text.trim().isEmpty ? '' : 'for ${_recurrenceCountController.text.trim()} times'}'}.',
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ],
                ],
                const SizedBox(height: 12),
                TextFormField(
                  controller: _locationController,
                  enabled: !_isSubmitting,
                  decoration: const InputDecoration(
                    labelText: 'Location',
                    border: OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: 12),
                TextFormField(
                  controller: _descriptionController,
                  enabled: !_isSubmitting,
                  maxLines: 3,
                  decoration: const InputDecoration(
                    labelText: 'Description',
                    border: OutlineInputBorder(),
                  ),
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
                      : Text(
                          _isEditing
                              ? widget.initialEvent!.recurring
                                  ? 'Update series'
                                  : 'Update event'
                              : 'Save event',
                        ),
                ),
              ],
            ),
          ),
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
        Text(
          title,
          style: Theme.of(context).textTheme.titleLarge,
        ),
        Text(
          subtitle,
          style: Theme.of(context).textTheme.bodyMedium,
        ),
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

class _CalendarErrorState extends StatelessWidget {
  const _CalendarErrorState({
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
                'Unable to load calendars and events from Calee.',
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

class _CalendarEmptyState extends StatelessWidget {
  const _CalendarEmptyState({
    this.onCreateCalendar,
  });

  final VoidCallback? onCreateCalendar;

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
              Text(
                'No calendars found yet. Calee will connect your calendar services automatically, then calendars and events will appear here.',
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.titleMedium,
              ),
              if (onCreateCalendar != null) ...[
                const SizedBox(height: 16),
                FilledButton.icon(
                  onPressed: onCreateCalendar,
                  icon: const Icon(Icons.add),
                  label: const Text('Create calendar'),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

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

  Future<void> _createEvent({
    required ClientCalendar calendar,
    required String title,
    required DateTime startsAt,
    required DateTime endsAt,
    required bool allDay,
    String? location,
    String? description,
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
                ...events.map(_EventTile.new),
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
  const _EventTile(this.event);

  final ClientEvent event;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: ListTile(
        leading: const Icon(Icons.event_outlined),
        title: Text(event.title),
        subtitle: Text(
          [
            _formatEventTime(event),
            if (event.serviceName.trim().isNotEmpty)
              'From ${event.serviceName}',
            if ((event.location ?? '').trim().isNotEmpty) event.location!,
          ].where((item) => item.trim().isNotEmpty).join(' · '),
        ),
      ),
    );
  }

  String _formatEventTime(ClientEvent event) {
    final start = DateTime.tryParse(event.startsAt);
    if (start == null) {
      return event.allDay ? 'All day' : event.startsAt;
    }

    final local = start.toLocal();

    if (event.allDay) {
      return '${local.day}/${local.month} · All day';
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
  });

  final List<ClientCalendar> calendars;
  final Future<void> Function({
    required ClientCalendar calendar,
    required String title,
    required DateTime startsAt,
    required DateTime endsAt,
    required bool allDay,
    String? location,
    String? description,
  }) onCreate;

  @override
  State<_CreateEventSheet> createState() => _CreateEventSheetState();
}

class _CreateEventSheetState extends State<_CreateEventSheet> {
  final _formKey = GlobalKey<FormState>();
  final _titleController = TextEditingController();
  final _locationController = TextEditingController();
  final _descriptionController = TextEditingController();

  late ClientCalendar _selectedCalendar;
  late DateTime _selectedDate;
  late TimeOfDay _startTime;
  late TimeOfDay _endTime;
  bool _allDay = false;
  bool _isSubmitting = false;

  @override
  void initState() {
    super.initState();

    _selectedCalendar = widget.calendars.first;
    final now = DateTime.now();
    _selectedDate = DateTime(now.year, now.month, now.day);

    final nextHour = now.add(const Duration(hours: 1));
    _startTime = TimeOfDay(hour: nextHour.hour, minute: 0);
    _endTime = TimeOfDay(hour: (nextHour.hour + 1) % 24, minute: 0);
  }

  @override
  void dispose() {
    _titleController.dispose();
    _locationController.dispose();
    _descriptionController.dispose();
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
      endsAt = _selectedDate.add(const Duration(days: 1));
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
      await widget.onCreate(
        calendar: _selectedCalendar,
        title: _titleController.text.trim(),
        startsAt: startsAt,
        endsAt: endsAt,
        allDay: _allDay,
        location: _locationController.text.trim().isEmpty
            ? null
            : _locationController.text.trim(),
        description: _descriptionController.text.trim().isEmpty
            ? null
            : _descriptionController.text.trim(),
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
              error is CaleeHubException
                  ? error.message
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
                  'Add event',
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
                  onChanged: _isSubmitting
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
                OutlinedButton.icon(
                  onPressed: _isSubmitting ? null : _pickDate,
                  icon: const Icon(Icons.today_outlined),
                  label: Text(_dateLabel(_selectedDate)),
                ),
                if (!_allDay) ...[
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
                      : const Text('Save event'),
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

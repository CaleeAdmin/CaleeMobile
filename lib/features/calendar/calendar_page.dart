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
              if (events.isEmpty)
                const _EmptySectionMessage(
                    message: 'No events found in this date range.')
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
          child: Text(
            'No calendars found yet. Calee will connect your calendar services automatically, then calendars and events will appear here.',
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.titleMedium,
          ),
        ),
      ),
    );
  }
}

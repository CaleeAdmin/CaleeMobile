import 'package:flutter/material.dart';

import '../../data/api/calee_hub_client.dart';
import '../../data/models/client_calendar.dart';

class CalendarPage extends StatefulWidget {
  const CalendarPage({
    required this.hubClient,
    required this.accessToken,
    super.key,
  });

  final CaleeHubClient hubClient;
  final String accessToken;

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
    final from = _formatDate(today);
    final to = _formatDate(today.add(const Duration(days: 7)));

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
        final calendars = overview?.calendarList.calendars ?? const [];
        final events = overview?.eventList.events ?? const [];

        if (calendars.isEmpty && events.isEmpty) {
          return const _CalendarEmptyState();
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
                subtitle: '${calendars.length} connected',
              ),
              const SizedBox(height: 8),
              if (calendars.isEmpty)
                const _EmptySectionMessage(message: 'No calendars connected yet. Connect a Calee service to show its calendars here.')
              else
                ...calendars.map(_CalendarTile.new),
              const SizedBox(height: 24),
              _SectionHeader(
                title: 'Upcoming events',
                subtitle: 'Next 7 days',
              ),
              const SizedBox(height: 8),
              if (events.isEmpty)
                const _EmptySectionMessage(message: 'No upcoming events in the next 7 days.')
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
  });

  final ClientCalendarList calendarList;
  final ClientEventList eventList;
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
            calendar.serviceName,
            calendar.source,
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
            event.serviceName,
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
                'Unable to load calendars and events.',
                style: Theme.of(context).textTheme.titleMedium,
              ),
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

class _CalendarEmptyState extends StatelessWidget {
  const _CalendarEmptyState();

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Card(
        margin: const EdgeInsets.all(24),
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(
            'No calendars connected yet. Once a Calee service is connected, its calendars and events will appear here.',
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.titleMedium,
          ),
        ),
      ),
    );
  }
}

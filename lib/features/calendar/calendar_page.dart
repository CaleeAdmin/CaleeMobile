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
  late Future<ClientCalendarList> _calendarListFuture;

  @override
  void initState() {
    super.initState();
    _calendarListFuture = _loadCalendars();
  }

  Future<ClientCalendarList> _loadCalendars() {
    return widget.hubClient.calendars(accessToken: widget.accessToken);
  }

  void _reloadCalendars() {
    setState(() {
      _calendarListFuture = _loadCalendars();
    });
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<ClientCalendarList>(
      future: _calendarListFuture,
      builder: (context, snapshot) {
        if (snapshot.connectionState == ConnectionState.waiting) {
          return const Center(
            child: CircularProgressIndicator(),
          );
        }

        if (snapshot.hasError) {
          return _CalendarErrorState(
            onRetry: _reloadCalendars,
          );
        }

        final calendars = snapshot.data?.calendars ?? const [];

        if (calendars.isEmpty) {
          return const _CalendarEmptyState();
        }

        return RefreshIndicator(
          onRefresh: () async {
            _reloadCalendars();
            await _calendarListFuture;
          },
          child: ListView.separated(
            padding: const EdgeInsets.all(16),
            itemCount: calendars.length,
            separatorBuilder: (_, __) => const SizedBox(height: 12),
            itemBuilder: (context, index) {
              final calendar = calendars[index];

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
                  trailing: const Icon(Icons.chevron_right),
                ),
              );
            },
          ),
        );
      },
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
                'Unable to load calendars.',
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
            'No calendars available yet.',
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.titleMedium,
          ),
        ),
      ),
    );
  }
}

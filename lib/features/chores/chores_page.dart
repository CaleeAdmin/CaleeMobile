import 'package:flutter/material.dart';

import '../../data/api/calee_hub_client.dart';
import '../../data/models/client_calendar.dart';
import '../../data/models/client_chore.dart';

class ChoresPage extends StatefulWidget {
  const ChoresPage({
    required this.hubClient,
    required this.accessToken,
    super.key,
  });

  final CaleeHubClient hubClient;
  final String accessToken;

  @override
  State<ChoresPage> createState() => _ChoresPageState();
}

class _ChoresPageState extends State<ChoresPage> {
  late Future<_ChoresOverview> _overviewFuture;

  @override
  void initState() {
    super.initState();
    _overviewFuture = _loadOverview();
  }

  Future<_ChoresOverview> _loadOverview() async {
    final today = DateTime.now();
    final from = _formatDate(DateTime(today.year, 1, 1));
    final to = _formatDate(DateTime(today.year, 12, 31));

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

  void _reloadOverview() {
    setState(() {
      _overviewFuture = _loadOverview();
    });
  }

  String _formatDate(DateTime value) {
    final year = value.year.toString().padLeft(4, '0');
    final month = value.month.toString().padLeft(2, '0');
    final day = value.day.toString().padLeft(2, '0');

    return '$year-$month-$day';
  }

  String _formatScheduledAt(String? value) {
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
          return const _ChoresEmptyState();
        }

        final choreCalendars = overview.calendarList.calendars
            .where((calendar) => calendar.isChoreKind)
            .toList();
        final chores = overview.choreList.chores;

        if (choreCalendars.isEmpty && chores.isEmpty) {
          return const _ChoresEmptyState();
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
                title: 'Chore lists',
                subtitle: '${choreCalendars.length} found',
              ),
              const SizedBox(height: 8),
              if (choreCalendars.isEmpty)
                const _EmptySectionMessage(message: 'No chore lists found yet.')
              else
                ...choreCalendars.map(_ChoreListTile.new),
              const SizedBox(height: 24),
              _SectionHeader(
                title: 'Chores',
                subtitle: '${chores.length} found',
              ),
              const SizedBox(height: 8),
              if (chores.isEmpty)
                const _EmptySectionMessage(message: 'No chores found yet.')
              else
                ...chores.map(
                  (chore) => _ChoreTile(
                    chore: chore,
                    scheduledLabel: _formatScheduledAt(chore.scheduledAt),
                  ),
                ),
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

class _ChoreTile extends StatelessWidget {
  const _ChoreTile({
    required this.chore,
    required this.scheduledLabel,
  });

  final ClientChore chore;
  final String scheduledLabel;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: ListTile(
        leading: const Icon(Icons.cleaning_services_outlined),
        title: Text(chore.title),
        subtitle: Text(
          [
            scheduledLabel,
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

class _ChoresEmptyState extends StatelessWidget {
  const _ChoresEmptyState();

  @override
  Widget build(BuildContext context) {
    return const Center(
      child: Card(
        margin: EdgeInsets.all(24),
        child: Padding(
          padding: EdgeInsets.all(24),
          child: Text(
            'No chore lists or chores found yet.',
            textAlign: TextAlign.center,
          ),
        ),
      ),
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
              const Icon(Icons.cloud_off_outlined, size: 40),
              const SizedBox(height: 12),
              Text(
                'Unable to load chores from Calee.',
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

import 'package:flutter/material.dart';

import '../../data/api/calee_hub_client.dart';
import '../../data/models/client_bootstrap.dart';
import 'calendar_collections_page.dart';

class SettingsPage extends StatelessWidget {
  const SettingsPage({
    required this.hubClient,
    required this.accessToken,
    required this.bootstrap,
    required this.onSignOut,
    super.key,
  });

  final CaleeHubClient hubClient;
  final String accessToken;
  final ClientBootstrap bootstrap;
  final VoidCallback onSignOut;

  @override
  Widget build(BuildContext context) {
    final account = bootstrap.account;

    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Card(
          child: ListTile(
            title: Text(account.displayName ?? 'Calee user'),
            subtitle: Text(account.primaryEmail ?? account.id),
            leading: const CircleAvatar(
              child: Icon(Icons.person),
            ),
          ),
        ),
        const SizedBox(height: 12),
        Card(
          child: ListTile(
            leading: const Icon(Icons.calendar_month_outlined),
            title: const Text('Lists & calendars'),
            subtitle:
                const Text('Manage calendars, task lists, and chore lists'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () {
              Navigator.of(context).push(
                MaterialPageRoute<void>(
                  builder: (_) => CalendarCollectionsPage(
                    hubClient: hubClient,
                    accessToken: accessToken,
                    services: bootstrap.services,
                  ),
                ),
              );
            },
          ),
        ),
        const SizedBox(height: 12),
        Card(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Services',
                  style: Theme.of(context).textTheme.titleMedium,
                ),
                const SizedBox(height: 8),
                for (final service in bootstrap.services)
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    leading: const Icon(Icons.cloud_outlined),
                    title: Text(service.displayName),
                    subtitle: Text(
                      service.hasMissingCalendarCredential
                          ? '${service.baseUrl}\nSign in to connect calendar access'
                          : service.baseUrl,
                    ),
                    trailing: Text(service.accessStatus),
                  ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 12),
        Card(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Contexts',
                  style: Theme.of(context).textTheme.titleMedium,
                ),
                const SizedBox(height: 8),
                if (bootstrap.availableContexts.isEmpty)
                  const Text('No household or organisation contexts yet.'),
                for (final context in bootstrap.availableContexts)
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    leading: const Icon(Icons.group_outlined),
                    title: Text(context.name),
                    subtitle: Text('${context.type} · ${context.role}'),
                  ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 24),
        OutlinedButton.icon(
          onPressed: onSignOut,
          icon: const Icon(Icons.logout),
          label: const Text('Sign out'),
        ),
      ],
    );
  }
}

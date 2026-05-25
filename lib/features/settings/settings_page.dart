import 'package:flutter/material.dart';

import '../../data/models/client_bootstrap.dart';

class SettingsPage extends StatelessWidget {
  const SettingsPage({
    required this.bootstrap,
    required this.onSignOut,
    super.key,
  });

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
                    subtitle: Text(service.baseUrl),
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

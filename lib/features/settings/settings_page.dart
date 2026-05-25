import 'package:flutter/material.dart';

import '../../data/api/calee_hub_client.dart';
import '../../data/models/client_bootstrap.dart';
import 'connect_service_page.dart';

class SettingsPage extends StatelessWidget {
  const SettingsPage({
    required this.hubClient,
    required this.accessToken,
    required this.bootstrap,
    required this.onSignOut,
    required this.onRefreshBootstrap,
    super.key,
  });

  final CaleeHubClient hubClient;
  final String accessToken;
  final ClientBootstrap bootstrap;
  final VoidCallback onSignOut;
  final Future<void> Function() onRefreshBootstrap;

  Future<void> _connectService(
    BuildContext context,
    ClientService service,
  ) async {
    final connected = await Navigator.of(context).push<bool>(
      MaterialPageRoute(
        builder: (_) => ConnectServicePage(
          hubClient: hubClient,
          accessToken: accessToken,
          service: service,
        ),
      ),
    );

    if (connected != true || !context.mounted) {
      return;
    }

    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('${service.displayName} connected'),
      ),
    );

    await onRefreshBootstrap();
  }

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
                if (bootstrap.services.isEmpty)
                  const Text('No services are available for this account.'),
                for (final service in bootstrap.services)
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    leading: const Icon(Icons.cloud_outlined),
                    title: Text(service.displayName),
                    subtitle: Text(
                      [
                        if (service.baseUrl.isNotEmpty) service.baseUrl,
                        if (service.accessStatus.isNotEmpty)
                          'Status: ${service.accessStatus}',
                      ].join('\n'),
                    ),
                    isThreeLine: service.baseUrl.isNotEmpty &&
                        service.accessStatus.isNotEmpty,
                    trailing: OutlinedButton(
                      onPressed: () => _connectService(context, service),
                      child: Text(
                        service.accessStatus == 'connected'
                            ? 'Update'
                            : 'Connect',
                      ),
                    ),
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

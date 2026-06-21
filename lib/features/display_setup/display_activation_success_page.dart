import 'package:flutter/material.dart';

import '../../data/api/calee_hub_client.dart';
import '../../data/models/client_bootstrap.dart';
import '../calendar_onboarding/calendar_source_picker_page.dart';

class DisplayActivationSuccessPage extends StatelessWidget {
  const DisplayActivationSuccessPage({
    required this.hubClient,
    required this.accessToken,
    required this.services,
    required this.accountId,
    required this.onDone,
    super.key,
  });

  final CaleeHubClient hubClient;
  final String accessToken;
  final List<ClientService> services;
  final String accountId;
  final VoidCallback onDone;

  void _finish(BuildContext context) {
    Navigator.of(context).popUntil((route) => route.isFirst);
    onDone();
  }

  void _addCalendars(BuildContext context) {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => CalendarSourcePickerPage(
          hubClient: hubClient,
          accessToken: accessToken,
          services: services,
          accountId: accountId,
          onDone: () => _finish(context),
          onViewCalendar: () => _finish(context),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      body: SafeArea(
        minimum: const EdgeInsets.all(24),
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 420),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Icon(
                  Icons.check_circle_outline,
                  size: 64,
                  color: theme.colorScheme.primary,
                ),
                const SizedBox(height: 16),
                Text(
                  'Your Calee display is ready',
                  textAlign: TextAlign.center,
                  style: theme.textTheme.headlineSmall?.copyWith(
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  'Add the calendars you already use so their events appear on your display.',
                  textAlign: TextAlign.center,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
                const SizedBox(height: 32),
                FilledButton(
                  onPressed: () => _addCalendars(context),
                  child: const Text('Add calendars'),
                ),
                const SizedBox(height: 12),
                OutlinedButton(
                  onPressed: () => _finish(context),
                  child: const Text('Do this later'),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

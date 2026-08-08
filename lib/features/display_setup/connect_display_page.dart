import 'package:flutter/material.dart';

import '../../data/api/calee_hub_client.dart';
import '../../data/models/client_bootstrap.dart';
import 'display_setup_scan_page.dart';

class ConnectDisplayPage extends StatelessWidget {
  const ConnectDisplayPage({
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

  void _scanDisplayQr(BuildContext context) {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => DisplaySetupScanPage(
          hubClient: hubClient,
          accessToken: accessToken,
          services: services,
          accountId: accountId,
          onDone: onDone,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      // Stable selector for the post-registration "connect your display" step
      // (CaleeMobile-Regression onboarding contract). Identifies the state
      // itself rather than its copy, so wording can change freely.
      key: const Key('connect_display_root'),
      appBar: AppBar(title: const Text('Connect display')),
      body: SafeArea(
        minimum: const EdgeInsets.all(24),
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 420),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const Icon(Icons.qr_code_scanner_outlined, size: 48),
                const SizedBox(height: 24),
                Text(
                  'Connect your Calee display',
                  textAlign: TextAlign.center,
                  style: theme.textTheme.headlineSmall?.copyWith(
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const SizedBox(height: 12),
                Text(
                  'Scan the QR code shown on your Calee display.',
                  textAlign: TextAlign.center,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
                const SizedBox(height: 40),
                FilledButton(
                  key: const Key('connect_display_scan_button'),
                  onPressed: () => _scanDisplayQr(context),
                  child: const Text('Scan display QR'),
                ),
                const SizedBox(height: 12),
                TextButton(
                  key: const Key('connect_display_skip_button'),
                  onPressed: onDone,
                  child: const Text('Skip for now'),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

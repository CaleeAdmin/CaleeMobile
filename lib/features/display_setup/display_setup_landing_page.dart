import 'package:flutter/material.dart';

class DisplaySetupLandingPage extends StatelessWidget {
  const DisplaySetupLandingPage({
    required this.onCreateAccount,
    required this.onSignIn,
    required this.onCancel,
    super.key,
  });

  final VoidCallback onCreateAccount;
  final VoidCallback onSignIn;
  final VoidCallback onCancel;

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
                const Icon(Icons.tv_outlined, size: 48),
                const SizedBox(height: 16),
                Text(
                  'Set up your Calee display',
                  textAlign: TextAlign.center,
                  style: theme.textTheme.headlineSmall?.copyWith(
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  'Create a Calee account or sign in to connect this display.',
                  textAlign: TextAlign.center,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
                const SizedBox(height: 32),
                FilledButton(
                  onPressed: onCreateAccount,
                  child: const Text('Create account'),
                ),
                const SizedBox(height: 12),
                TextButton(
                  onPressed: onSignIn,
                  child: const Text('I already have an account'),
                ),
                const SizedBox(height: 12),
                OutlinedButton(
                  onPressed: onCancel,
                  child: const Text('Cancel'),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

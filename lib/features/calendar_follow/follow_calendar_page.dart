import 'package:flutter/material.dart';

import 'calendar_follow_intent.dart';

class FollowCalendarPage extends StatelessWidget {
  const FollowCalendarPage({
    required this.intent,
    required this.onSignIn,
    required this.onCancel,
    super.key,
  });

  final ResolvedCalendarFollowIntent intent;
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
                const Icon(Icons.calendar_today_outlined, size: 48),
                const SizedBox(height: 16),
                Text(
                  'Follow this calendar',
                  textAlign: TextAlign.center,
                  style: theme.textTheme.headlineSmall?.copyWith(
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  intent.title,
                  textAlign: TextAlign.center,
                  style: theme.textTheme.titleMedium,
                ),
                const SizedBox(height: 24),
                Text(
                  'Sign in to add this calendar to your Calee account. '
                  'Read-only local following is coming soon.',
                  textAlign: TextAlign.center,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
                const SizedBox(height: 32),
                FilledButton(
                  onPressed: onSignIn,
                  child: const Text('Sign in'),
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

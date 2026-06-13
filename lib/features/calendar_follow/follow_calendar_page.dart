import 'package:flutter/material.dart';

import 'calendar_follow_intent.dart';

class FollowCalendarPage extends StatelessWidget {
  const FollowCalendarPage({
    required this.intent,
    required this.onSignIn,
    required this.onFollowLocally,
    required this.onCancel,
    this.alreadyFollowed = false,
    super.key,
  });

  final ResolvedCalendarFollowIntent intent;
  final VoidCallback onSignIn;
  final VoidCallback onFollowLocally;
  final VoidCallback onCancel;

  /// True when the URL is already saved locally.
  final bool alreadyFollowed;

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
                if (alreadyFollowed)
                  _AlreadyFollowedMessage(theme: theme)
                else
                  Text(
                    'This calendar is read-only. Sign in to add it to your '
                    'Calee account and sync with your Calee Tablet, or follow '
                    'it on this phone only.',
                    textAlign: TextAlign.center,
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                const SizedBox(height: 32),
                FilledButton(
                  onPressed: onSignIn,
                  child: const Text('Continue with Calee account'),
                ),
                const SizedBox(height: 12),
                FilledButton.tonal(
                  onPressed: onFollowLocally,
                  child: Text(
                    alreadyFollowed
                        ? 'Open local calendar'
                        : 'Follow on this phone only',
                  ),
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

class _AlreadyFollowedMessage extends StatelessWidget {
  const _AlreadyFollowedMessage({required this.theme});
  final ThemeData theme;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: theme.colorScheme.secondaryContainer,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Text(
        'This calendar is already followed on this phone.',
        textAlign: TextAlign.center,
        style: theme.textTheme.bodyMedium?.copyWith(
          color: theme.colorScheme.onSecondaryContainer,
        ),
      ),
    );
  }
}

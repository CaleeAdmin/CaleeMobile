import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

const _kTermsAndConditionsUrl = 'https://portal.calee.com.au/terms';

class WelcomePage extends StatelessWidget {
  const WelcomePage({
    required this.onSetupDisplay,
    required this.onSignIn,
    super.key,
  });

  final VoidCallback onSetupDisplay;
  final VoidCallback onSignIn;

  Future<void> _openTerms() async {
    final uri = Uri.parse(_kTermsAndConditionsUrl);
    if (await canLaunchUrl(uri)) {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    }
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
                const Icon(Icons.tv_outlined, size: 48),
                const SizedBox(height: 24),
                Text(
                  'Welcome to Calee',
                  textAlign: TextAlign.center,
                  style: theme.textTheme.headlineSmall?.copyWith(
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const SizedBox(height: 12),
                Text(
                  'Connect a Calee display and bring your calendars, tasks and reminders together.',
                  textAlign: TextAlign.center,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
                const SizedBox(height: 40),
                FilledButton(
                  onPressed: onSetupDisplay,
                  child: const Text('Set up a Calee display'),
                ),
                const SizedBox(height: 12),
                TextButton(
                  onPressed: onSignIn,
                  child: const Text('I already have an account'),
                ),
                const SizedBox(height: 24),
                Center(
                  child: TextButton(
                    onPressed: _openTerms,
                    style: TextButton.styleFrom(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 8,
                        vertical: 4,
                      ),
                      minimumSize: const Size(0, 36),
                      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    ),
                    child: Text(
                      'Terms and Conditions',
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.primary,
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

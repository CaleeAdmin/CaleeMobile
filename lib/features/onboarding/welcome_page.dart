import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

const _kTermsAndConditionsUrl = 'https://portal.calee.com.au/terms';

class WelcomePage extends StatelessWidget {
  const WelcomePage({
    required this.onCreateAccount,
    required this.onSignIn,
    super.key,
  });

  final VoidCallback onCreateAccount;
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
        // Scrollable so the added recovery guidance cannot push the account
        // actions off a short screen (or off a screen using large
        // accessibility text). Layout is unchanged whenever the content
        // fits, which is the normal case.
        child: SingleChildScrollView(
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
                    onPressed: onCreateAccount,
                    child: const Text('Create account'),
                  ),
                  const SizedBox(height: 12),
                  TextButton(
                    onPressed: onSignIn,
                    child: const Text('I already have an account'),
                  ),
                  const SizedBox(height: 24),
                  const _SharedCalendarRecoveryNote(),
                  const SizedBox(height: 8),
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
      ),
    );
  }
}

/// Recovery guidance for the installation boundary.
///
/// Welcome is the no-intent fallback screen, and neither the App Store nor
/// Google Play carries the original calendar link across an install. A user
/// who opened a shared calendar link, was sent to the store, and then opened
/// the freshly installed app arrives here with no intent to act on — so this
/// note tells them how to get their intent back.
///
/// It is explanatory text only. It deliberately adds no way to acquire a
/// calendar from Welcome (no follow button, no URL entry, no search, no QR
/// scanner) and does not advertise the local five-calendar allowance, which
/// belongs in the local-calendar experience where it is relevant.
class _SharedCalendarRecoveryNote extends StatelessWidget {
  const _SharedCalendarRecoveryNote();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      key: const Key('welcome_shared_calendar_recovery'),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: theme.colorScheme.outlineVariant),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Following a shared calendar?',
            style: theme.textTheme.bodyMedium?.copyWith(
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            'If you installed Calee after opening a calendar link, return to '
            'that link and open it again.',
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            'No account is required to follow a shared calendar.',
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }
}

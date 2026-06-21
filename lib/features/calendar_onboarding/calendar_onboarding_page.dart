import 'package:flutter/material.dart';

import '../../data/api/calee_hub_client.dart';
import '../../data/auth/calee_preferences.dart';
import '../../data/models/client_bootstrap.dart';
import '../../ui/calee_design.dart';
import 'calendar_onboarding_status.dart';
import 'calendar_source_picker_page.dart';

class CalendarOnboardingPage extends StatelessWidget {
  const CalendarOnboardingPage({
    required this.hubClient,
    required this.accessToken,
    required this.services,
    required this.accountId,
    required this.onDismissed,
    required this.onViewCalendar,
    this.isManual = false,
    super.key,
  });

  final CaleeHubClient hubClient;
  final String accessToken;
  final List<ClientService> services;
  final String accountId;
  final VoidCallback onDismissed;
  final VoidCallback onViewCalendar;

  /// When true the page was opened manually from Settings. Shows "Not now"
  /// instead of "Remind me later" / "Don't show this again", and does not
  /// mutate the saved onboarding status.
  final bool isManual;

  Future<void> _remindLater(BuildContext context) async {
    await CaleePreferences().saveCalendarOnboardingStatus(
      accountId,
      CalendarOnboardingStatus.remindLater,
    );
    if (context.mounted) onDismissed();
  }

  Future<void> _dismissForever(BuildContext context) async {
    await CaleePreferences().saveCalendarOnboardingStatus(
      accountId,
      CalendarOnboardingStatus.dismissedForever,
    );
    if (context.mounted) onDismissed();
  }

  void _addExistingCalendars(BuildContext context) {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        settings: const RouteSettings(name: CalendarSourcePickerPage.routeName),
        builder: (_) => CalendarSourcePickerPage(
          hubClient: hubClient,
          accessToken: accessToken,
          services: services,
          accountId: accountId,
          onDone: onDismissed,
          onViewCalendar: onViewCalendar,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      backgroundColor: CaleeColors.scaffoldBackground,
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(CaleeSpacing.pagePadding),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Spacer(),
              const Icon(
                Icons.calendar_month_rounded,
                size: 64,
                color: CaleeColors.primary,
              ),
              const SizedBox(height: CaleeSpacing.lg),
              Text(
                'Your Calee calendar is ready',
                style: theme.textTheme.headlineSmall?.copyWith(
                  color: CaleeColors.textPrimary,
                  fontWeight: FontWeight.w600,
                ),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: CaleeSpacing.md),
              Text(
                'Calee has created a default calendar for you.\n'
                'You can start using Calee now, or add calendars you already use so their events appear on your Calee display.',
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: CaleeColors.textSecondary,
                ),
                textAlign: TextAlign.center,
              ),
              const Spacer(),
              FilledButton(
                onPressed: () => _addExistingCalendars(context),
                child: const Text('Add existing calendars'),
              ),
              const SizedBox(height: CaleeSpacing.sm),
              if (isManual) ...[
                OutlinedButton(
                  onPressed: onDismissed,
                  child: const Text('Not now'),
                ),
              ] else ...[
                OutlinedButton(
                  onPressed: () => _remindLater(context),
                  child: const Text('Remind me later'),
                ),
                const SizedBox(height: CaleeSpacing.sm),
                TextButton(
                  onPressed: () => _dismissForever(context),
                  child: const Text("Don't show this again"),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

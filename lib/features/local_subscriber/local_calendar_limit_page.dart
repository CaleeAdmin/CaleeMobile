import 'package:flutter/material.dart';

import '../../ui/calee_design.dart';
import 'local_calendar_subscription_repository.dart';

/// Conversion experience shown when a signed-out user tries to follow a
/// calendar beyond the local allowance (see
/// [kMaxLocalCalendarSubscriptions]).
///
/// It is reached only from the typed
/// [LocalCalendarSubscriptionLimitException] — never from a parser, storage
/// or network failure — and it is entirely non-destructive: nothing on this
/// screen adds, removes or modifies a stored calendar, and the attempted
/// calendar is simply not followed.
///
/// The copy leads with the benefit rather than the product label: a user who
/// has only ever followed a shared calendar has no reason to know what
/// "Calee Home" means, so the name is never load-bearing here.
class LocalCalendarLimitPage extends StatelessWidget {
  const LocalCalendarLimitPage({
    required this.limit,
    required this.onSeeCaleeForHome,
    required this.onManageCalendars,
    required this.onDismiss,
    super.key,
  });

  /// The typed domain condition that produced this screen. Carries the
  /// attempted calendar so its name stays visible as context.
  final LocalCalendarSubscriptionLimitException limit;

  /// Opens the canonical Calee-for-home marketing page. Must never consume
  /// the pending calendar intent, sign the user in, or touch the locally
  /// stored subscriptions — returning to the app restores this same screen.
  final VoidCallback onSeeCaleeForHome;

  /// Opens the existing local-calendar management UI, where an existing
  /// calendar can be removed to make room.
  final VoidCallback onManageCalendars;

  /// Dismisses the attempt. The five stored calendars are left untouched.
  final VoidCallback onDismiss;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        // System back behaves like "Not now": the attempt is abandoned and
        // nothing already stored changes.
        if (!didPop) onDismiss();
      },
      child: Scaffold(
        body: SafeArea(
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 420),
              child: ListView(
                key: const Key('local_calendar_limit_page'),
                padding: const EdgeInsets.all(CaleeSpacing.lg),
                children: [
                  const SizedBox(height: CaleeSpacing.sm),
                  const Center(child: CaleeHomeProductThumbnail(size: 96)),
                  const SizedBox(height: CaleeSpacing.lg),

                  // Benefit-led heading. Deliberately not "Get Calee Home".
                  Text(
                    'Bring more calendars together',
                    textAlign: TextAlign.center,
                    style: theme.textTheme.headlineSmall?.copyWith(
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  const SizedBox(height: CaleeSpacing.md),
                  Text(
                    "You're already following ${limit.limit} calendars on "
                    'this phone.',
                    textAlign: TextAlign.center,
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                  const SizedBox(height: CaleeSpacing.sm),
                  Text(
                    "Calee can bring your family's calendars, schedules, "
                    'tasks and reminders together on a shared display at '
                    'home.',
                    textAlign: TextAlign.center,
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                  const SizedBox(height: CaleeSpacing.lg),

                  // Context for the attempt: which calendar was not added,
                  // and the explicit reassurance that nothing was changed.
                  _AttemptedCalendarCard(
                    theme: theme,
                    title: limit.attemptedTitle,
                  ),
                  const SizedBox(height: CaleeSpacing.lg),

                  FilledButton(
                    key: const Key('local_calendar_limit_see_calee_for_home'),
                    onPressed: onSeeCaleeForHome,
                    style: FilledButton.styleFrom(
                      minimumSize: const Size.fromHeight(48),
                    ),
                    child: const Text('See Calee for your home'),
                  ),
                  const SizedBox(height: CaleeSpacing.sm),
                  OutlinedButton(
                    key: const Key('local_calendar_limit_manage_calendars'),
                    onPressed: onManageCalendars,
                    style: OutlinedButton.styleFrom(
                      minimumSize: const Size.fromHeight(48),
                    ),
                    child: const Text('Manage my calendars'),
                  ),
                  const SizedBox(height: CaleeSpacing.xs),
                  TextButton(
                    key: const Key('local_calendar_limit_dismiss'),
                    onPressed: onDismiss,
                    style: TextButton.styleFrom(
                      foregroundColor: theme.colorScheme.onSurfaceVariant,
                      minimumSize: const Size.fromHeight(48),
                    ),
                    child: const Text('Not now'),
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

// ── Attempted calendar context ────────────────────────────────────────────────

class _AttemptedCalendarCard extends StatelessWidget {
  const _AttemptedCalendarCard({required this.theme, required this.title});

  final ThemeData theme;
  final String title;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(CaleeSpacing.md),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(
              Icons.calendar_today_outlined,
              color: theme.colorScheme.onSurfaceVariant,
            ),
            const SizedBox(width: CaleeSpacing.md),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: theme.textTheme.titleSmall?.copyWith(
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    'Not added. Your existing calendars are unchanged — '
                    'remove one to make room for this calendar.',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

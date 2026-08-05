import 'package:flutter/material.dart';

import '../../ui/calee_design.dart';
import 'calendar_follow_intent.dart';

/// Decision page for a public calendar-follow link.
///
/// The primary task is adding the read-only calendar locally to this phone —
/// no account or purchase required. Promotion of the paid Calee home solution
/// is secondary and compact, and existing Calee-at-home customers get a
/// tertiary sign-in row that preserves the pending intent.
class FollowCalendarPage extends StatelessWidget {
  const FollowCalendarPage({
    required this.intent,
    required this.onAddToPhone,
    required this.onOpenLocalCalendar,
    required this.onLearnAboutHome,
    required this.onExistingCustomerSignIn,
    required this.onCancel,
    this.alreadyFollowed = false,
    super.key,
  });

  final ResolvedCalendarFollowIntent intent;

  /// Adds the calendar locally on this phone. Never asks for authentication.
  final VoidCallback onAddToPhone;

  /// Closes the decision state and reveals the already-added local calendar.
  final VoidCallback onOpenLocalCalendar;

  /// Opens the Calee-for-home marketing page. Must not consume the intent.
  final VoidCallback onLearnAboutHome;

  /// Existing Calee-at-home customers: opens the normal login flow with the
  /// pending intent preserved.
  final VoidCallback onExistingCustomerSignIn;

  final VoidCallback onCancel;

  /// True when the URL is already saved locally.
  final bool alreadyFollowed;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        // System back cancels the pending follow flow, same as Cancel.
        if (!didPop) onCancel();
      },
      child: Scaffold(
        body: SafeArea(
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 420),
              child: ListView(
                padding: const EdgeInsets.all(CaleeSpacing.lg),
                children: [
                  const SizedBox(height: CaleeSpacing.sm),
                  const Icon(Icons.calendar_today_outlined, size: 48),
                  const SizedBox(height: CaleeSpacing.md),
                  Text(
                    alreadyFollowed
                        ? 'Already on this phone'
                        : 'Add this calendar',
                    textAlign: TextAlign.center,
                    style: theme.textTheme.headlineSmall?.copyWith(
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  const SizedBox(height: CaleeSpacing.sm),
                  Text(
                    intent.title,
                    textAlign: TextAlign.center,
                    style: theme.textTheme.titleMedium,
                  ),
                  const SizedBox(height: CaleeSpacing.lg),
                  if (alreadyFollowed)
                    _OpenCalendarCard(
                      theme: theme,
                      onOpenLocalCalendar: onOpenLocalCalendar,
                    )
                  else
                    _AddToPhoneCard(theme: theme, onAddToPhone: onAddToPhone),
                  const SizedBox(height: CaleeSpacing.md),
                  _HomePromoRow(theme: theme, onTap: onLearnAboutHome),
                  const SizedBox(height: CaleeSpacing.sm),
                  TextButton(
                    key: const Key('calendar_follow_existing_customer_sign_in'),
                    onPressed: onExistingCustomerSignIn,
                    style: TextButton.styleFrom(
                      minimumSize: const Size.fromHeight(48),
                    ),
                    child: const Text('Already have Calee at home? Sign in'),
                  ),
                  const SizedBox(height: CaleeSpacing.xs),
                  TextButton(
                    key: const Key('calendar_follow_cancel_button'),
                    onPressed: onCancel,
                    style: TextButton.styleFrom(
                      foregroundColor: theme.colorScheme.onSurfaceVariant,
                      minimumSize: const Size.fromHeight(48),
                    ),
                    child: const Text('Cancel'),
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

// ── Primary card: add locally ─────────────────────────────────────────────────

class _AddToPhoneCard extends StatelessWidget {
  const _AddToPhoneCard({required this.theme, required this.onAddToPhone});

  final ThemeData theme;
  final VoidCallback onAddToPhone;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(CaleeSpacing.md),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              'Add to this phone',
              style: theme.textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: CaleeSpacing.sm),
            Text(
              'View this read-only calendar in the Calee app on this phone. '
              'No account or purchase required.',
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: CaleeSpacing.md),
            FilledButton(
              key: const Key('calendar_follow_add_to_phone_button'),
              onPressed: onAddToPhone,
              child: const Text('Add to this phone'),
            ),
          ],
        ),
      ),
    );
  }
}

// ── Primary card: already followed ────────────────────────────────────────────

class _OpenCalendarCard extends StatelessWidget {
  const _OpenCalendarCard({
    required this.theme,
    required this.onOpenLocalCalendar,
  });

  final ThemeData theme;
  final VoidCallback onOpenLocalCalendar;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(CaleeSpacing.md),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              'This read-only calendar is already available in Calee.',
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: CaleeSpacing.md),
            FilledButton(
              key: const Key('calendar_follow_open_calendar_button'),
              onPressed: onOpenLocalCalendar,
              child: const Text('Open calendar'),
            ),
          ],
        ),
      ),
    );
  }
}

// ── Compact home promotion ────────────────────────────────────────────────────

class _HomePromoRow extends StatelessWidget {
  const _HomePromoRow({required this.theme, required this.onTap});

  final ThemeData theme;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return MergeSemantics(
      child: Semantics(
        button: true,
        child: Material(
          color: theme.colorScheme.surface,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(CaleeRadius.card),
            side: BorderSide(color: theme.colorScheme.outlineVariant),
          ),
          child: InkWell(
            key: const Key('calendar_follow_home_promo'),
            borderRadius: BorderRadius.circular(CaleeRadius.card),
            onTap: onTap,
            child: ConstrainedBox(
              constraints: const BoxConstraints(minHeight: 48),
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: CaleeSpacing.md,
                  vertical: CaleeSpacing.md,
                ),
                child: Row(
                  children: [
                    const CaleeHomeProductThumbnail(),
                    const SizedBox(width: CaleeSpacing.md),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            'See this calendar on a shared family screen',
                            style: theme.textTheme.bodyMedium?.copyWith(
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                          const SizedBox(height: 2),
                          Text(
                            'Discover Calee for your home.',
                            style: theme.textTheme.bodySmall?.copyWith(
                              color: theme.colorScheme.onSurfaceVariant,
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(width: CaleeSpacing.sm),
                    Icon(
                      Icons.chevron_right,
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

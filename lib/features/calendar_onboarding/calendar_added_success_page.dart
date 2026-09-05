import 'package:flutter/material.dart';

import '../../data/models/client_calendar.dart';
import '../../ui/calee_design.dart';
import 'calendar_source_picker_page.dart';

class CalendarAddedSuccessPage extends StatelessWidget {
  const CalendarAddedSuccessPage({
    required this.onViewCalendar,
    this.syncState,
    super.key,
  });

  final VoidCallback onViewCalendar;

  /// How far the calendar just added has got through its first sync, as
  /// reported by Hub. Null on an older Hub (or a non-subscription add), which
  /// keeps the pre-existing wording exactly as it was.
  final CalendarSyncState? syncState;

  /// The headline. Kept short and true: with the events already in hand this
  /// is a completed add; while syncing it is still a completed add, so the
  /// heading does not change — only the line beneath it does.
  String get title => 'Calendar added to Calee';

  /// The line beneath the headline.
  ///
  /// The syncing wording is the point of this page's change: "Your events will
  /// appear shortly" is a promise, and the user who reported this defect got
  /// the promise and then an empty calendar. Saying "Syncing events…" says
  /// what is actually happening, and the Calendar screen carries the same
  /// state through to convergence.
  String get detail {
    switch (syncState) {
      case CalendarSyncState.syncing:
        return 'Syncing events… They will appear on your Calee display as soon '
            'as this finishes.';
      case CalendarSyncState.error:
        return 'Calee could not sync this calendar just now and will keep '
            'trying. You can pull to refresh in Calendar.';
      case CalendarSyncState.ready:
      case null:
        return 'Your events will appear on your Calee display shortly.';
    }
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
              Icon(
                syncState == CalendarSyncState.syncing
                    ? Icons.sync_rounded
                    : Icons.check_circle_rounded,
                size: 64,
                color: CaleeColors.primary,
              ),
              const SizedBox(height: CaleeSpacing.lg),
              Text(
                title,
                key: const Key('calendar_added_title'),
                style: theme.textTheme.headlineSmall?.copyWith(
                  color: CaleeColors.textPrimary,
                  fontWeight: FontWeight.w600,
                ),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: CaleeSpacing.md),
              Text(
                detail,
                key: const Key('calendar_added_detail'),
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: CaleeColors.textSecondary,
                ),
                textAlign: TextAlign.center,
              ),
              const Spacer(),
              FilledButton(
                onPressed: () {
                  Navigator.of(context).popUntil(
                    (route) =>
                        route.settings.name ==
                            CalendarSourcePickerPage.routeName ||
                        route.isFirst,
                  );
                },
                child: const Text('Add another calendar'),
              ),
              const SizedBox(height: CaleeSpacing.sm),
              OutlinedButton(
                onPressed: onViewCalendar,
                child: const Text('View calendar'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

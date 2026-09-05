import 'package:flutter/material.dart';

import '../../../data/models/calendar_service_error.dart';
import '../../../ui/calee_design.dart';

class CalendarErrorState extends StatelessWidget {
  const CalendarErrorState({required this.onRetry, super.key});

  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return CaleeEmptyState(
      icon: Icons.cloud_off_outlined,
      title: 'We couldn\'t load your calendar',
      body: 'Check your connection and try again.',
      action: FilledButton(onPressed: onRetry, child: const Text('Try again')),
    );
  }
}

class CalendarServiceConnectionErrorState extends StatelessWidget {
  const CalendarServiceConnectionErrorState({
    required this.errors,
    required this.onRetry,
    super.key,
  });

  final List<CalendarServiceError> errors;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final message = errors.length == 1
        ? errors.first.repairMessage
        : 'Calendar connection needs repair. Please contact Calee support.';

    return CaleeEmptyState(
      icon: Icons.sync_problem_outlined,
      title: 'Calendar Connection Problem',
      body: message,
      action: FilledButton(onPressed: onRetry, child: const Text('Try again')),
    );
  }
}

class CalendarServiceWarningBanner extends StatelessWidget {
  const CalendarServiceWarningBanner({required this.errors, super.key});

  final List<CalendarServiceError> errors;

  @override
  Widget build(BuildContext context) {
    final message = errors.length == 1
        ? errors.first.repairMessage
        : 'One or more calendar connections need repair. Please contact Calee support.';

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(
        horizontal: CaleeSpacing.pagePadding,
        vertical: CaleeSpacing.sm,
      ),
      color: CaleeColors.dotOrange.withValues(alpha: 0.12),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Icon(
            Icons.warning_amber_rounded,
            size: 18,
            color: CaleeColors.dotOrange,
          ),
          const SizedBox(width: CaleeSpacing.xs),
          Expanded(
            child: Text(
              message,
              style: const TextStyle(
                fontSize: 13,
                color: CaleeColors.textPrimary,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Non-blocking notice that a connected calendar has not finished its first
/// synchronisation yet.
///
/// Sits in the same slot as [CalendarServiceWarningBanner]: one slim strip
/// above the calendar. It never replaces the calendar, never covers it, and
/// never hides another family member's events — the rest of the month stays
/// usable while one feed catches up. That is the whole point: the alternative
/// the user actually hit was a calendar that looked simply empty.
///
/// Deliberately claims no completion time. [exhausted] switches the wording
/// from an in-progress "Syncing…" to a passive, honest state once Calee has
/// stopped re-checking on its own, so the user is told what to do rather than
/// left watching an indefinite spinner.
class CalendarSyncingBanner extends StatelessWidget {
  const CalendarSyncingBanner({
    required this.syncingCalendarNames,
    this.failedCalendarNames = const [],
    this.exhausted = false,
    super.key,
  });

  /// Display names of the calendars still completing their first sync.
  final List<String> syncingCalendarNames;

  /// Display names of calendars whose first sync failed.
  final List<String> failedCalendarNames;

  /// True once the automatic re-checks have been used up.
  final bool exhausted;

  /// The message, exposed so tests assert on the contract rather than on a
  /// rendered pixel.
  String get message {
    if (syncingCalendarNames.isEmpty && failedCalendarNames.isNotEmpty) {
      return failedCalendarNames.length == 1
          ? 'Calee could not sync ${failedCalendarNames.first}. Pull to refresh.'
          : 'Calee could not sync some calendars. Pull to refresh.';
    }

    final subject = syncingCalendarNames.length == 1
        ? syncingCalendarNames.first
        : '${syncingCalendarNames.length} calendars';

    return exhausted
        ? 'Still syncing $subject. Pull to refresh.'
        : 'Syncing $subject…';
  }

  bool get _isFailureOnly =>
      syncingCalendarNames.isEmpty && failedCalendarNames.isNotEmpty;

  @override
  Widget build(BuildContext context) {
    if (syncingCalendarNames.isEmpty && failedCalendarNames.isEmpty) {
      return const SizedBox.shrink();
    }

    final accent = _isFailureOnly ? CaleeColors.dotOrange : CaleeColors.primary;

    return Container(
      key: const Key('calendar_syncing_banner'),
      width: double.infinity,
      padding: const EdgeInsets.symmetric(
        horizontal: CaleeSpacing.pagePadding,
        vertical: CaleeSpacing.sm,
      ),
      color: accent.withValues(alpha: 0.10),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(
            _isFailureOnly ? Icons.sync_problem_rounded : Icons.sync_rounded,
            size: 18,
            color: accent,
          ),
          const SizedBox(width: CaleeSpacing.xs),
          Expanded(
            child: Text(
              message,
              // No maxLines: at large text scales this must wrap rather than
              // truncate the calendar's name out of its own status line.
              style: const TextStyle(
                fontSize: 13,
                color: CaleeColors.textPrimary,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

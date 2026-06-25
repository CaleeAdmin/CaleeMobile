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
  const CalendarServiceWarningBanner({
    required this.errors,
    super.key,
  });

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

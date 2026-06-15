import 'package:flutter/material.dart';

import '../../ui/calee_design.dart';

class CalendarAddedSuccessPage extends StatelessWidget {
  const CalendarAddedSuccessPage({
    required this.onViewCalendar,
    super.key,
  });

  final VoidCallback onViewCalendar;

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
                Icons.check_circle_rounded,
                size: 64,
                color: CaleeColors.primary,
              ),
              const SizedBox(height: CaleeSpacing.lg),
              Text(
                'Calendar added to Calee',
                style: theme.textTheme.headlineSmall?.copyWith(
                  color: CaleeColors.textPrimary,
                  fontWeight: FontWeight.w600,
                ),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: CaleeSpacing.md),
              Text(
                'Your events will appear on your Calee display shortly.',
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: CaleeColors.textSecondary,
                ),
                textAlign: TextAlign.center,
              ),
              const Spacer(),
              FilledButton(
                onPressed: () {
                  Navigator.of(context).popUntil(
                    ModalRoute.withName('calendar_source_picker'),
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

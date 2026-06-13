import 'package:flutter/material.dart';

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

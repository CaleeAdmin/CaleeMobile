import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../ui/calee_theme.dart';
import '../../ui/calee_widgets.dart';

class FamilySetupPage extends StatelessWidget {
  const FamilySetupPage({this.portalUrl, super.key});

  final String? portalUrl;

  @override
  Widget build(BuildContext context) {
    return CaleeScaffold(
      appBar: AppBar(title: const Text('People')),
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(CaleeSpacing.pagePadding),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(
                Icons.group_outlined,
                size: 48,
                color: CaleeColors.textTertiary,
              ),
              const SizedBox(height: CaleeSpacing.md),
              Text(
                'People setup needed',
                style: Theme.of(context).textTheme.titleMedium,
              ),
              const SizedBox(height: CaleeSpacing.xs),
              Text(
                'People are used to assign chores. Please complete setup in Calee Portal first.',
                style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                  color: CaleeColors.textSecondary,
                ),
                textAlign: TextAlign.center,
              ),
              if (portalUrl != null) ...[
                const SizedBox(height: CaleeSpacing.lg),
                FilledButton(
                  onPressed: () async {
                    final uri = Uri.tryParse(portalUrl!);
                    if (uri != null) {
                      await launchUrl(
                        uri,
                        mode: LaunchMode.externalApplication,
                      );
                    }
                  },
                  child: const Text('Open Calee Portal'),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

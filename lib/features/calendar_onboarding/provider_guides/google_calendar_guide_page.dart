import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../../data/api/calee_hub_client.dart';
import '../../../data/models/client_bootstrap.dart';
import '../../../ui/calee_design.dart';
import 'generic_calendar_link_page.dart';

enum _GoogleGuideView { main, continueOnComputer, phoneFallback }

class GoogleCalendarGuidePage extends StatefulWidget {
  const GoogleCalendarGuidePage({
    required this.hubClient,
    required this.accessToken,
    required this.services,
    required this.accountId,
    required this.onDone,
    required this.onViewCalendar,
    super.key,
  });

  final CaleeHubClient hubClient;
  final String accessToken;
  final List<ClientService> services;
  final String accountId;
  final VoidCallback onDone;
  final VoidCallback onViewCalendar;

  @override
  State<GoogleCalendarGuidePage> createState() =>
      _GoogleCalendarGuidePageState();
}

class _GoogleCalendarGuidePageState extends State<GoogleCalendarGuidePage> {
  _GoogleGuideView _view = _GoogleGuideView.main;

  String? get _portalUrl => widget.services
      .where((s) => s.launchUrl.trim().isNotEmpty)
      .map((s) => s.launchUrl)
      .firstOrNull;

  void _openLink(BuildContext context) {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => GenericCalendarLinkPage(
          hubClient: widget.hubClient,
          accessToken: widget.accessToken,
          services: widget.services,
          accountId: widget.accountId,
          onDone: widget.onDone,
          onViewCalendar: widget.onViewCalendar,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return CaleeScaffold(
      appBar: AppBar(
        title: const Text('Add Google Calendar'),
        leading: _view == _GoogleGuideView.main
            ? null
            : BackButton(
                onPressed: () => setState(() => _view = _GoogleGuideView.main),
              ),
      ),
      body: AnimatedSwitcher(
        duration: const Duration(milliseconds: 200),
        child: switch (_view) {
          _GoogleGuideView.main => _MainView(
            key: const ValueKey('main'),
            onContinueOnComputer: () =>
                setState(() => _view = _GoogleGuideView.continueOnComputer),
            onAlreadyHaveLink: () => _openLink(context),
            onNoComputer: () =>
                setState(() => _view = _GoogleGuideView.phoneFallback),
          ),
          _GoogleGuideView.continueOnComputer => _ComputerView(
            key: const ValueKey('computer'),
            portalUrl: _portalUrl,
            onAlreadyHaveLink: () => _openLink(context),
          ),
          _GoogleGuideView.phoneFallback => _PhoneFallbackView(
            key: const ValueKey('phone'),
            onAlreadyHaveLink: () => _openLink(context),
          ),
        },
      ),
    );
  }
}

// ── Main view ──────────────────────────────────────────────────────────────

class _MainView extends StatelessWidget {
  const _MainView({
    required this.onContinueOnComputer,
    required this.onAlreadyHaveLink,
    required this.onNoComputer,
    super.key,
  });

  final VoidCallback onContinueOnComputer;
  final VoidCallback onAlreadyHaveLink;
  final VoidCallback onNoComputer;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(
        CaleeSpacing.pagePadding,
        CaleeSpacing.md,
        CaleeSpacing.pagePadding,
        96,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            'Google Calendar links are easiest to copy from a computer.',
            style: theme.textTheme.bodyMedium?.copyWith(
              color: CaleeColors.textSecondary,
            ),
          ),
          const SizedBox(height: CaleeSpacing.md),
          CaleeSection(
            title: 'On your computer',
            children: [
              _StepRow(
                number: 1,
                text: 'Open Google Calendar in a web browser.',
              ),
              _StepRow(number: 2, text: 'Open the calendar\'s settings.'),
              _StepRow(
                number: 3,
                text:
                    'Under "Integrate calendar", copy the "Secret address in iCal format".',
              ),
              _StepRow(number: 4, text: 'Sign in to Calee Portal.'),
              _StepRow(number: 5, text: 'Add the link to Calee Calendar.'),
            ],
          ),
          const SizedBox(height: CaleeSpacing.xs),
          Text(
            'Once added, your Google Calendar will appear in the Calee app and on your Calee display.',
            style: theme.textTheme.bodySmall?.copyWith(
              color: CaleeColors.textSecondary,
            ),
          ),
          const SizedBox(height: CaleeSpacing.sectionSpacing),
          FilledButton(
            onPressed: onContinueOnComputer,
            child: const Text('Continue on computer'),
          ),
          const SizedBox(height: CaleeSpacing.sm),
          OutlinedButton(
            onPressed: onAlreadyHaveLink,
            child: const Text('I already have the link'),
          ),
          const SizedBox(height: CaleeSpacing.sm),
          TextButton(
            onPressed: onNoComputer,
            child: const Text('No computer available?'),
          ),
        ],
      ),
    );
  }
}

// ── Computer view ─────────────────────────────────────────────────────────

class _ComputerView extends StatelessWidget {
  const _ComputerView({
    required this.portalUrl,
    required this.onAlreadyHaveLink,
    super.key,
  });

  final String? portalUrl;
  final VoidCallback onAlreadyHaveLink;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(
        CaleeSpacing.pagePadding,
        CaleeSpacing.md,
        CaleeSpacing.pagePadding,
        96,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            'On your computer, open Calee Portal and add the Google Calendar link.',
            style: theme.textTheme.bodyMedium?.copyWith(
              color: CaleeColors.textSecondary,
            ),
          ),
          const SizedBox(height: CaleeSpacing.md),
          CaleeSection(
            children: [
              _StepRow(
                number: 1,
                text:
                    'Copy the secret iCal address from Google Calendar settings.',
              ),
              _StepRow(number: 2, text: 'Open Calee Portal in your browser.'),
              _StepRow(
                number: 3,
                text: 'Go to Calendar settings and add the link.',
              ),
            ],
          ),
          if (portalUrl != null) ...[
            const SizedBox(height: CaleeSpacing.md),
            CaleeSection(
              title: 'Calee Portal',
              children: [
                InkWell(
                  onTap: () async {
                    final uri = Uri.tryParse(portalUrl!);
                    if (uri != null && await canLaunchUrl(uri)) {
                      await launchUrl(
                        uri,
                        mode: LaunchMode.externalApplication,
                      );
                    }
                  },
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: CaleeSpacing.md,
                      vertical: 12,
                    ),
                    child: Row(
                      children: [
                        Expanded(
                          child: Text(
                            portalUrl!,
                            style: theme.textTheme.bodyMedium?.copyWith(
                              color: CaleeColors.primary,
                            ),
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        const SizedBox(width: CaleeSpacing.sm),
                        const Icon(
                          Icons.open_in_new,
                          size: 18,
                          color: CaleeColors.primary,
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ],
          const SizedBox(height: CaleeSpacing.sectionSpacing),
          OutlinedButton(
            onPressed: onAlreadyHaveLink,
            child: const Text('I already have the link'),
          ),
        ],
      ),
    );
  }
}

// ── Phone fallback view ───────────────────────────────────────────────────

class _PhoneFallbackView extends StatelessWidget {
  const _PhoneFallbackView({required this.onAlreadyHaveLink, super.key});

  final VoidCallback onAlreadyHaveLink;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(
        CaleeSpacing.pagePadding,
        CaleeSpacing.md,
        CaleeSpacing.pagePadding,
        96,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            'Use your phone instead',
            style: theme.textTheme.titleMedium?.copyWith(
              color: CaleeColors.textPrimary,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: CaleeSpacing.sm),
          Text(
            'This is harder on a phone, but you can try using desktop mode in your browser.',
            style: theme.textTheme.bodyMedium?.copyWith(
              color: CaleeColors.textSecondary,
            ),
          ),
          const SizedBox(height: CaleeSpacing.md),
          CaleeSection(
            children: [
              _StepRow(
                number: 1,
                text: 'Open Google Calendar in your phone browser.',
              ),
              _StepRow(number: 2, text: 'Turn on "Desktop site".'),
              _StepRow(number: 3, text: 'Open the calendar\'s settings.'),
              _StepRow(
                number: 4,
                text: 'Under "Integrate calendar", copy the private iCal link.',
              ),
              _StepRow(
                number: 5,
                text: 'Come back to Calee and paste the link.',
              ),
            ],
          ),
          const SizedBox(height: CaleeSpacing.sectionSpacing),
          FilledButton(
            onPressed: onAlreadyHaveLink,
            child: const Text('I have the link'),
          ),
        ],
      ),
    );
  }
}

// ── Step row widget ───────────────────────────────────────────────────────

class _StepRow extends StatelessWidget {
  const _StepRow({required this.number, required this.text});

  final int number;
  final String text;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(
        horizontal: CaleeSpacing.md,
        vertical: 8,
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 20,
            child: Text(
              '$number.',
              style: theme.textTheme.bodyMedium?.copyWith(
                color: CaleeColors.textSecondary,
              ),
            ),
          ),
          const SizedBox(width: CaleeSpacing.sm),
          Expanded(
            child: Text(
              text,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: CaleeColors.textPrimary,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

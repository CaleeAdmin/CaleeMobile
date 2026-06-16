import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../data/api/calee_hub_client.dart';
import '../../../data/models/client_bootstrap.dart';
import '../../../ui/calee_design.dart';
import 'generic_calendar_link_page.dart';

enum _GoogleGuideView { main, continueOnComputer, phoneFallback }

const _kWebsiteGuideUrl = 'calee.com.au/start';

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
  _GoogleGuideView? _previousView;

  void _goTo(_GoogleGuideView view) {
    setState(() {
      _previousView = _view;
      _view = view;
    });
  }

  void _goBack() {
    setState(() {
      _view = _previousView ?? _GoogleGuideView.main;
      _previousView = null;
    });
  }

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
          pageTitle: 'Add Google Calendar link',
          introText:
              'Paste the Google Calendar link you copied from Google Calendar settings.',
          showExamples: false,
          nameHintText: 'My Google Calendar',
          linkHintText: 'https://calendar.google.com/calendar/ical/...',
          readOnlyText:
              'This will show your Google Calendar events on your Calee display. '
              'Your Google Calendar stays in Google, and you still edit events in Google Calendar.',
          validationErrorText:
              'This does not look like a calendar link. Paste a link that starts with http, https, or webcal.',
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
            : BackButton(onPressed: _goBack),
      ),
      body: AnimatedSwitcher(
        duration: const Duration(milliseconds: 200),
        child: switch (_view) {
          _GoogleGuideView.main => _MainView(
            key: const ValueKey('main'),
            onContinueOnComputer: () =>
                _goTo(_GoogleGuideView.continueOnComputer),
            onPasteLink: () => _openLink(context),
            onNoComputer: () => _goTo(_GoogleGuideView.phoneFallback),
          ),
          _GoogleGuideView.continueOnComputer => _ComputerView(
            key: const ValueKey('computer'),
            onCopyWebsiteAddress: () {
              Clipboard.setData(const ClipboardData(text: _kWebsiteGuideUrl));
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text('Website address copied')),
              );
            },
            onOpenGuideOnPhone: () => _goTo(_GoogleGuideView.phoneFallback),
            onPasteLink: () => _openLink(context),
          ),
          _GoogleGuideView.phoneFallback => _PhoneFallbackView(
            key: const ValueKey('phone'),
            onPasteLink: () => _openLink(context),
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
    required this.onPasteLink,
    required this.onNoComputer,
    super.key,
  });

  final VoidCallback onContinueOnComputer;
  final VoidCallback onPasteLink;
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
            'Google Calendar is easiest to connect from a computer.',
            style: theme.textTheme.bodyMedium?.copyWith(
              color: CaleeColors.textSecondary,
            ),
          ),
          const SizedBox(height: CaleeSpacing.sm),
          Text(
            'Calee will show your Google Calendar events on your Calee display. '
            'Your Google Calendar stays in Google, and you still edit events in Google Calendar.',
            style: theme.textTheme.bodyMedium?.copyWith(
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
            onPressed: onPasteLink,
            child: const Text('Paste the link in Calee'),
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
    required this.onCopyWebsiteAddress,
    required this.onOpenGuideOnPhone,
    required this.onPasteLink,
    super.key,
  });

  final VoidCallback onCopyWebsiteAddress;
  final VoidCallback onOpenGuideOnPhone;
  final VoidCallback onPasteLink;

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
            'Use the website guide on your computer so you can follow the Google Calendar steps more easily.',
            style: theme.textTheme.bodyMedium?.copyWith(
              color: CaleeColors.textSecondary,
            ),
          ),
          const SizedBox(height: CaleeSpacing.md),
          Text(
            'On your computer, go to:',
            style: theme.textTheme.bodyMedium?.copyWith(
              color: CaleeColors.textSecondary,
            ),
          ),
          const SizedBox(height: CaleeSpacing.xs),
          Text(
            _kWebsiteGuideUrl,
            style: theme.textTheme.bodyLarge?.copyWith(
              color: CaleeColors.primary,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: CaleeSpacing.xs),
          Text(
            'Then choose "Add Google Calendar to Calee".',
            style: theme.textTheme.bodyMedium?.copyWith(
              color: CaleeColors.textSecondary,
            ),
          ),
          const SizedBox(height: CaleeSpacing.md),
          CaleeSection(
            children: [
              _StepRow(
                number: 1,
                text: 'On your computer, open $_kWebsiteGuideUrl.',
              ),
              _StepRow(
                number: 2,
                text: 'Choose "Add Google Calendar to Calee".',
              ),
              _StepRow(
                number: 3,
                text: 'Follow the guide to open Google Calendar.',
              ),
              _StepRow(
                number: 4,
                text: 'Copy your Secret address in iCal format.',
              ),
              _StepRow(number: 5, text: 'Open Calee Portal from the guide.'),
              _StepRow(number: 6, text: 'Paste the link into Calee.'),
            ],
          ),
          const SizedBox(height: CaleeSpacing.sectionSpacing),
          FilledButton(
            onPressed: onCopyWebsiteAddress,
            child: const Text('Copy website address'),
          ),
          const SizedBox(height: CaleeSpacing.sm),
          OutlinedButton(
            onPressed: onOpenGuideOnPhone,
            child: const Text('Open guide on this phone'),
          ),
          const SizedBox(height: CaleeSpacing.sm),
          TextButton(
            onPressed: onPasteLink,
            child: const Text('Paste the link in Calee'),
          ),
        ],
      ),
    );
  }
}

// ── Phone fallback view ───────────────────────────────────────────────────

class _PhoneFallbackView extends StatelessWidget {
  const _PhoneFallbackView({required this.onPasteLink, super.key});

  final VoidCallback onPasteLink;

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
                text:
                    'Under "Integrate calendar", copy the Secret address in iCal format.',
              ),
              _StepRow(
                number: 5,
                text: 'Come back to Calee and paste the link.',
              ),
            ],
          ),
          const SizedBox(height: CaleeSpacing.sectionSpacing),
          FilledButton(
            onPressed: onPasteLink,
            child: const Text('Paste the link in Calee'),
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

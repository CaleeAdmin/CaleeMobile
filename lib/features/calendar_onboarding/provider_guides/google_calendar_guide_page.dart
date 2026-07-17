import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../../data/api/calee_hub_client.dart';
import '../../../data/auth/calee_preferences.dart';
import '../../../data/models/client_bootstrap.dart';
import '../../../ui/calee_design.dart';
import '../calendar_onboarding_status.dart';
import 'generic_calendar_link_page.dart';
import 'google_calendar_selection_page.dart';

enum _GoogleGuideView { main, waitingForBrowser, connectionNotFound }

class GoogleCalendarGuidePage extends StatefulWidget {
  const GoogleCalendarGuidePage({
    required this.hubClient,
    required this.accessToken,
    required this.services,
    required this.accountId,
    required this.onDone,
    required this.onViewCalendar,
    this.launchUrl,
    super.key,
  });

  final CaleeHubClient hubClient;
  final String accessToken;
  final List<ClientService> services;
  final String accountId;
  final VoidCallback onDone;
  final VoidCallback onViewCalendar;

  /// Optional URL launcher override used by widget tests.
  final Future<void> Function(String url)? launchUrl;

  @override
  State<GoogleCalendarGuidePage> createState() =>
      _GoogleCalendarGuidePageState();
}

class _GoogleCalendarGuidePageState extends State<GoogleCalendarGuidePage> {
  _GoogleGuideView _view = _GoogleGuideView.main;
  bool _isStarting = false;
  bool _isCheckingConnection = false;
  String? _errorMessage;

  @override
  void initState() {
    super.initState();
    GoogleCalendarSelectionGate.reset();
  }

  Future<void> _startOAuth() async {
    setState(() {
      _isStarting = true;
      _errorMessage = null;
    });

    try {
      final url = await widget.hubClient.startExternalCalendarOAuth(
        accessToken: widget.accessToken,
        providerKey: 'google_calendar',
        accessMode: 'read_only',
      );

      final launch = widget.launchUrl;
      if (launch != null) {
        await launch(url);
      } else {
        await launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication);
      }

      if (mounted) {
        setState(() {
          _view = _GoogleGuideView.waitingForBrowser;
          _isStarting = false;
        });
      }
    } catch (error) {
      if (mounted) {
        setState(() {
          _isStarting = false;
          _errorMessage = error is CaleeHubException
              ? error.message
              : 'Could not start Google sign-in. Please try again.';
        });
      }
    }
  }

  Future<void> _checkConnection() async {
    setState(() {
      _isCheckingConnection = true;
      _errorMessage = null;
    });

    try {
      final connections = await widget.hubClient.externalCalendarConnections(
        accessToken: widget.accessToken,
      );

      final googleConnection = connections
          .where((c) => c.isGoogle && c.isActive)
          .toList();

      if (!mounted) return;

      if (googleConnection.isNotEmpty) {
        final connection = googleConnection.first;
        debugPrint(
          '[GoogleCalendarGuide] active Google connection found: id=${connection.id}',
        );
        if (!GoogleCalendarSelectionGate.tryOpen()) {
          debugPrint(
            '[GoogleCalendarGuide] selection page already opened elsewhere; '
            'skipping duplicate navigation',
          );
          setState(() => _isCheckingConnection = false);
          return;
        }
        await CaleePreferences().saveCalendarOnboardingStatus(
          widget.accountId,
          CalendarOnboardingStatus.dismissedForever,
        );
        if (!mounted) return;
        Navigator.of(context).push(
          MaterialPageRoute<void>(
            builder: (_) => GoogleCalendarSelectionPage(
              hubClient: widget.hubClient,
              accessToken: widget.accessToken,
              connection: connection,
              onViewCalendar: widget.onViewCalendar,
              onDone: widget.onDone,
            ),
          ),
        );
        setState(() => _isCheckingConnection = false);
      } else {
        debugPrint('[GoogleCalendarGuide] no active Google connection found');
        setState(() {
          _isCheckingConnection = false;
          _view = _GoogleGuideView.connectionNotFound;
        });
      }
    } catch (error) {
      if (mounted) {
        setState(() {
          _isCheckingConnection = false;
          _errorMessage = error is CaleeHubException
              ? error.message
              : 'Could not check your connection. Please try again.';
        });
      }
    }
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
        leading: _view != _GoogleGuideView.main
            ? BackButton(
                onPressed: () => setState(() => _view = _GoogleGuideView.main),
              )
            : null,
      ),
      body: AnimatedSwitcher(
        duration: const Duration(milliseconds: 200),
        child: switch (_view) {
          _GoogleGuideView.main => _MainView(
            key: const ValueKey('main'),
            isStarting: _isStarting,
            errorMessage: _errorMessage,
            onConnect: _startOAuth,
            onPasteLink: () => _openLink(context),
          ),
          _GoogleGuideView.waitingForBrowser => _WaitingView(
            key: const ValueKey('waiting'),
            isChecking: _isCheckingConnection,
            errorMessage: _errorMessage,
            onFinished: _checkConnection,
            onPasteLink: () => _openLink(context),
          ),
          _GoogleGuideView.connectionNotFound => _NotFoundView(
            key: const ValueKey('notfound'),
            isChecking: _isCheckingConnection,
            errorMessage: _errorMessage,
            onCheckAgain: _checkConnection,
            onPasteLink: () => _openLink(context),
          ),
        },
      ),
    );
  }
}

// ── Main view ──────────────────────────────────────────────────────────

class _MainView extends StatelessWidget {
  const _MainView({
    required this.isStarting,
    required this.onConnect,
    required this.onPasteLink,
    this.errorMessage,
    super.key,
  });

  final bool isStarting;
  final VoidCallback onConnect;
  final VoidCallback onPasteLink;
  final String? errorMessage;

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
            'Connect Google Calendar to show your existing Google events on '
            'your Calee display. Google Calendar stays in Google, and events '
            'are read-only in Calee.',
            style: theme.textTheme.bodyMedium?.copyWith(
              color: CaleeColors.textSecondary,
            ),
          ),
          const SizedBox(height: CaleeSpacing.xs),
          Text(
            'You will sign in with Google in your browser. Calee does not see '
            'your Google password.',
            style: theme.textTheme.bodySmall?.copyWith(
              color: CaleeColors.textSecondary,
            ),
          ),
          if (errorMessage != null) ...[
            const SizedBox(height: CaleeSpacing.sm),
            Text(
              errorMessage!,
              style: theme.textTheme.bodySmall?.copyWith(
                color: CaleeColors.destructive,
              ),
            ),
          ],
          const SizedBox(height: CaleeSpacing.sectionSpacing),
          FilledButton(
            key: const Key('google_calendar_connect_button'),
            onPressed: isStarting ? null : onConnect,
            child: isStarting
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Text('Connect Google Calendar'),
          ),
          const SizedBox(height: CaleeSpacing.sm),
          OutlinedButton(
            onPressed: onPasteLink,
            child: const Text('Paste calendar link instead'),
          ),
        ],
      ),
    );
  }
}

// ── Waiting for browser view ─────────────────────────────────────────────────

class _WaitingView extends StatelessWidget {
  const _WaitingView({
    required this.isChecking,
    required this.onFinished,
    required this.onPasteLink,
    this.errorMessage,
    super.key,
  });

  final bool isChecking;
  final VoidCallback onFinished;
  final VoidCallback onPasteLink;
  final String? errorMessage;

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
            'Sign in to Google in your browser',
            style: theme.textTheme.titleMedium?.copyWith(
              color: CaleeColors.textPrimary,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: CaleeSpacing.sm),
          Text(
            'Follow the steps in your browser to sign in with Google. '
            'Once you have finished, come back here and tap the button below.',
            style: theme.textTheme.bodyMedium?.copyWith(
              color: CaleeColors.textSecondary,
            ),
          ),
          if (errorMessage != null) ...[
            const SizedBox(height: CaleeSpacing.sm),
            Text(
              errorMessage!,
              style: theme.textTheme.bodySmall?.copyWith(
                color: CaleeColors.destructive,
              ),
            ),
          ],
          const SizedBox(height: CaleeSpacing.sectionSpacing),
          FilledButton(
            onPressed: isChecking ? null : onFinished,
            child: isChecking
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Text('I finished in browser'),
          ),
          const SizedBox(height: CaleeSpacing.sm),
          TextButton(
            onPressed: onPasteLink,
            child: const Text('Paste calendar link instead'),
          ),
        ],
      ),
    );
  }
}

// ── Connection not found view ────────────────────────────────────────────────

class _NotFoundView extends StatelessWidget {
  const _NotFoundView({
    required this.isChecking,
    required this.onCheckAgain,
    required this.onPasteLink,
    this.errorMessage,
    super.key,
  });

  final bool isChecking;
  final VoidCallback onCheckAgain;
  final VoidCallback onPasteLink;
  final String? errorMessage;

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
            'Connection not found yet',
            style: theme.textTheme.titleMedium?.copyWith(
              color: CaleeColors.textPrimary,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: CaleeSpacing.sm),
          Text(
            'We could not find an active Google connection. If you completed '
            'the sign-in steps, tap Check again. Otherwise go back and try again.',
            style: theme.textTheme.bodyMedium?.copyWith(
              color: CaleeColors.textSecondary,
            ),
          ),
          if (errorMessage != null) ...[
            const SizedBox(height: CaleeSpacing.sm),
            Text(
              errorMessage!,
              style: theme.textTheme.bodySmall?.copyWith(
                color: CaleeColors.destructive,
              ),
            ),
          ],
          const SizedBox(height: CaleeSpacing.sectionSpacing),
          FilledButton(
            onPressed: isChecking ? null : onCheckAgain,
            child: isChecking
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Text('Check again'),
          ),
          const SizedBox(height: CaleeSpacing.sm),
          TextButton(
            onPressed: onPasteLink,
            child: const Text('Paste calendar link instead'),
          ),
        ],
      ),
    );
  }
}

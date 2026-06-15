import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../data/api/calee_hub_client.dart';
import '../../../data/auth/calee_preferences.dart';
import '../../../data/models/client_bootstrap.dart';
import '../../../data/models/client_service_calendar_address.dart';
import '../../../features/settings/service_calendar_address_api.dart';
import '../../../ui/calee_design.dart';
import '../calendar_added_success_page.dart';
import '../calendar_onboarding_status.dart';

enum _OutlookState {
  loading,
  aliasLoaded,
  sharedWaiting,
  error,
}

class OutlookCalendarGuidePage extends StatefulWidget {
  const OutlookCalendarGuidePage({
    required this.hubClient,
    required this.accessToken,
    required this.services,
    required this.accountId,
    required this.onDone,
    super.key,
  });

  final CaleeHubClient hubClient;
  final String accessToken;
  final List<ClientService> services;
  final String accountId;
  final VoidCallback onDone;

  @override
  State<OutlookCalendarGuidePage> createState() =>
      _OutlookCalendarGuidePageState();
}

class _OutlookCalendarGuidePageState extends State<OutlookCalendarGuidePage> {
  late final ServiceCalendarAddressApi _api;
  _OutlookState _state = _OutlookState.loading;
  ClientServiceCalendarAddress? _address;
  String? _error;
  bool _checkingForCalendar = false;
  List<String>? _baselineCalendarIds;

  ClientService? get _sharingService => widget.services.firstWhereOrNull(
    (s) => s.supportsCalendarSharingAddress,
  );

  @override
  void initState() {
    super.initState();
    _api = ServiceCalendarAddressApi(hubClient: widget.hubClient);
    _loadAlias();
    _loadBaselineCalendars();
  }

  Future<void> _loadAlias() async {
    final service = _sharingService;
    if (service == null) {
      if (!mounted) return;
      setState(() {
        _state = _OutlookState.error;
        _error =
            'Calendar sharing is not available for your account. '
            'Some work or school organisations may only allow sharing inside the organisation.';
      });
      return;
    }

    try {
      final address = await _api.load(
        accessToken: widget.accessToken,
        serviceId: service.id,
      );
      if (!mounted) return;
      setState(() {
        _address = address;
        _state = _OutlookState.aliasLoaded;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _state = _OutlookState.error;
        _error = 'Could not load Calendar Share Alias. Please try again.';
      });
    }
  }

  Future<void> _loadBaselineCalendars() async {
    try {
      final list = await widget.hubClient.calendars(
        accessToken: widget.accessToken,
      );
      if (!mounted) return;
      _baselineCalendarIds = list.calendars.map((c) => c.id).toList();
    } catch (_) {
      // Non-critical: if we can't get baseline, we show success anyway
    }
  }

  void _copyAlias(BuildContext context) {
    final value = _address?.copyValue ?? _address?.address ?? '';
    Clipboard.setData(ClipboardData(text: value));
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(const SnackBar(content: Text('Calendar Share Alias copied')));
  }

  Future<void> _iveSharedIt(BuildContext context) async {
    setState(() {
      _checkingForCalendar = true;
      _state = _OutlookState.sharedWaiting;
    });

    try {
      final list = await widget.hubClient.calendars(
        accessToken: widget.accessToken,
      );
      if (!mounted) return;

      final newCalendars = list.calendars
          .where(
            (c) =>
                _baselineCalendarIds == null ||
                !_baselineCalendarIds!.contains(c.id),
          )
          .toList();

      if (newCalendars.isNotEmpty) {
        await CaleePreferences().saveCalendarOnboardingStatus(
          widget.accountId,
          CalendarOnboardingStatus.dismissedForever,
        );
        if (!mounted) return;
        Navigator.of(context).push(
          MaterialPageRoute<void>(
            builder: (_) => CalendarAddedSuccessPage(
              onViewCalendar: widget.onDone,
            ),
          ),
        );
      } else {
        setState(() => _checkingForCalendar = false);
      }
    } catch (_) {
      if (!mounted) return;
      setState(() => _checkingForCalendar = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return CaleeScaffold(
      appBar: AppBar(title: const Text('Add Outlook Calendar')),
      body: switch (_state) {
        _OutlookState.loading => const Center(
          child: CircularProgressIndicator(),
        ),
        _OutlookState.error => CaleeEmptyState(
          icon: Icons.error_outline,
          title: 'Not available',
          body: _error ??
              'Calendar sharing could not be loaded. Please try again.',
          action: _sharingService != null
              ? TextButton(
                  onPressed: () {
                    setState(() {
                      _state = _OutlookState.loading;
                      _error = null;
                    });
                    _loadAlias();
                  },
                  child: const Text('Try again'),
                )
              : null,
        ),
        _OutlookState.aliasLoaded => _AliasView(
          address: _address!,
          onCopy: () => _copyAlias(context),
          onShared: () => _iveSharedIt(context),
          onBack: () => Navigator.of(context).pop(),
        ),
        _OutlookState.sharedWaiting => _WaitingView(
          isChecking: _checkingForCalendar,
          onTryAgain: () => _iveSharedIt(context),
          onBack: () => setState(() => _state = _OutlookState.aliasLoaded),
        ),
      },
    );
  }
}

// ── Alias view ─────────────────────────────────────────────────────────────

class _AliasView extends StatelessWidget {
  const _AliasView({
    required this.address,
    required this.onCopy,
    required this.onShared,
    required this.onBack,
  });

  final ClientServiceCalendarAddress address;
  final VoidCallback onCopy;
  final VoidCallback onShared;
  final VoidCallback onBack;

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
            'To show an Outlook calendar on Calee, share it with your Calendar Share Alias.',
            style: theme.textTheme.bodyMedium?.copyWith(
              color: CaleeColors.textSecondary,
            ),
          ),
          const SizedBox(height: CaleeSpacing.md),
          CaleeSection(
            title: 'Your Calendar Share Alias',
            children: [
              Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: CaleeSpacing.md,
                  vertical: 11,
                ),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        address.address,
                        style: theme.textTheme.bodyMedium?.copyWith(
                          color: CaleeColors.textPrimary,
                        ),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    const SizedBox(width: CaleeSpacing.xs),
                    TextButton(
                      onPressed: onCopy,
                      style: TextButton.styleFrom(
                        padding: const EdgeInsets.symmetric(
                          horizontal: CaleeSpacing.sm,
                        ),
                        minimumSize: Size.zero,
                        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                      ),
                      child: const Text('Copy'),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: CaleeSpacing.xs),
          Text(
            'This alias is only for receiving shared calendar invitations. It is not your login email.',
            style: theme.textTheme.bodySmall?.copyWith(
              color: CaleeColors.textSecondary,
            ),
          ),
          const SizedBox(height: CaleeSpacing.sectionSpacing),
          CaleeSection(
            title: 'In Outlook',
            children: [
              _StepRow(
                number: 1,
                text: 'In the Calee app, copy your Calendar Share Alias above.',
              ),
              _StepRow(number: 2, text: 'Open the Outlook app on your phone.'),
              _StepRow(number: 3, text: 'Go to Calendar.'),
              _StepRow(number: 4, text: 'Open the calendar menu.'),
              _StepRow(
                number: 5,
                text: 'Tap the calendar settings or gear icon.',
              ),
              _StepRow(
                number: 6,
                text: 'Choose the Outlook calendar you want to share.',
              ),
              _StepRow(number: 7, text: 'Tap Add people.'),
              _StepRow(number: 8, text: 'Paste your Calendar Share Alias.'),
              _StepRow(number: 9, text: 'Choose the sharing permission.'),
              _StepRow(number: 10, text: 'Confirm the share.'),
            ],
          ),
          const SizedBox(height: CaleeSpacing.xs),
          Text(
            'The shared calendar usually appears in Calee shortly after Outlook sends the sharing email.',
            style: theme.textTheme.bodySmall?.copyWith(
              color: CaleeColors.textSecondary,
            ),
          ),
          const SizedBox(height: CaleeSpacing.xs),
          Text(
            'Connected Outlook calendars are read-only in Calee. To edit events, use Outlook.',
            style: theme.textTheme.bodySmall?.copyWith(
              color: CaleeColors.textSecondary,
            ),
          ),
          const SizedBox(height: CaleeSpacing.xs),
          Text(
            'Calendar sharing may not be available for every Outlook account. Some work or school organisations may only allow sharing inside the organisation.',
            style: theme.textTheme.bodySmall?.copyWith(
              color: CaleeColors.textSecondary,
            ),
          ),
          const SizedBox(height: CaleeSpacing.sectionSpacing),
          FilledButton(
            onPressed: onCopy,
            child: const Text('Copy Calendar Share Alias'),
          ),
          const SizedBox(height: CaleeSpacing.sm),
          OutlinedButton(
            onPressed: onShared,
            child: const Text("I've shared it"),
          ),
          const SizedBox(height: CaleeSpacing.sm),
          TextButton(
            onPressed: onBack,
            child: const Text('Back'),
          ),
        ],
      ),
    );
  }
}

// ── Waiting view ───────────────────────────────────────────────────────────

class _WaitingView extends StatelessWidget {
  const _WaitingView({
    required this.isChecking,
    required this.onTryAgain,
    required this.onBack,
  });

  final bool isChecking;
  final VoidCallback onTryAgain;
  final VoidCallback onBack;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.all(CaleeSpacing.pagePadding),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Spacer(),
          Icon(
            isChecking ? Icons.hourglass_empty_rounded : Icons.schedule_rounded,
            size: 64,
            color: CaleeColors.textTertiary,
          ),
          const SizedBox(height: CaleeSpacing.lg),
          Text(
            'Waiting for Outlook share',
            style: theme.textTheme.headlineSmall?.copyWith(
              color: CaleeColors.textPrimary,
              fontWeight: FontWeight.w600,
            ),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: CaleeSpacing.md),
          Text(
            'Outlook may take a minute to send the sharing invitation. Please try again shortly.',
            style: theme.textTheme.bodyMedium?.copyWith(
              color: CaleeColors.textSecondary,
            ),
            textAlign: TextAlign.center,
          ),
          const Spacer(),
          if (isChecking) ...[
            const Center(child: CircularProgressIndicator()),
            const SizedBox(height: CaleeSpacing.md),
          ],
          FilledButton(
            onPressed: isChecking ? null : onTryAgain,
            child: const Text('Try again'),
          ),
          const SizedBox(height: CaleeSpacing.sm),
          TextButton(
            onPressed: isChecking ? null : onBack,
            child: const Text('Back'),
          ),
        ],
      ),
    );
  }
}

// ── Step row widget ────────────────────────────────────────────────────────

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
            width: 24,
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

// ── Extension helper ───────────────────────────────────────────────────────

extension _FirstWhereOrNull<T> on List<T> {
  T? firstWhereOrNull(bool Function(T) test) {
    for (final e in this) {
      if (test(e)) return e;
    }
    return null;
  }
}

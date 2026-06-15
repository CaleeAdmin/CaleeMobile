import 'package:flutter/material.dart';

import '../../../data/api/calee_hub_client.dart';
import '../../../data/auth/calee_preferences.dart';
import '../../../data/models/client_bootstrap.dart';
import '../../../ui/calee_design.dart';
import '../calendar_added_success_page.dart';
import '../calendar_onboarding_status.dart';

class AppleIcloudCalendarGuidePage extends StatefulWidget {
  const AppleIcloudCalendarGuidePage({
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
  State<AppleIcloudCalendarGuidePage> createState() =>
      _AppleIcloudCalendarGuidePageState();
}

class _AppleIcloudCalendarGuidePageState
    extends State<AppleIcloudCalendarGuidePage> {
  final _formKey = GlobalKey<FormState>();
  final _nameController = TextEditingController();
  final _urlController = TextEditingController();
  bool _isSubmitting = false;
  ClientService? _selectedService;

  List<ClientService> get _calendarServices => widget.services
      .where(
        (s) =>
            s.serviceType == 'nextcloud_calendar' &&
            s.hasConnectedCalendarCredential,
      )
      .toList();

  @override
  void initState() {
    super.initState();
    final services = _calendarServices;
    _selectedService = services.isEmpty ? null : services.first;
  }

  @override
  void dispose() {
    _nameController.dispose();
    _urlController.dispose();
    super.dispose();
  }

  bool _isAllowedSubscriptionUrl(String value) {
    final url = value.trim();
    if (url.isEmpty) return false;
    final parsed = Uri.tryParse(url);
    final scheme = parsed?.scheme.toLowerCase() ?? '';
    return parsed != null &&
        parsed.host.trim().isNotEmpty &&
        (scheme == 'https' || scheme == 'http' || scheme == 'webcal');
  }

  Future<void> _submit() async {
    if (_isSubmitting || !_formKey.currentState!.validate()) return;

    final service = _selectedService;
    if (service == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('No connected calendar service available.')),
      );
      return;
    }

    setState(() => _isSubmitting = true);

    try {
      await widget.hubClient.subscribeCalendarFromLink(
        accessToken: widget.accessToken,
        serviceId: service.id,
        name: _nameController.text.trim(),
        url: _urlController.text.trim(),
      );

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
    } catch (error) {
      if (!mounted) return;
      setState(() => _isSubmitting = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            error is CaleeHubException
                ? error.message
                : 'Unable to add this calendar.',
          ),
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final services = _calendarServices;

    return CaleeScaffold(
      appBar: AppBar(title: const Text('Add Apple / iCloud Calendar')),
      body: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(
          CaleeSpacing.pagePadding,
          CaleeSpacing.md,
          CaleeSpacing.pagePadding,
          96,
        ),
        child: Form(
          key: _formKey,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                'To show an iCloud calendar on Calee, copy its shared calendar link first.',
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: CaleeColors.textSecondary,
                ),
              ),
              const SizedBox(height: CaleeSpacing.md),
              CaleeSection(
                title: 'On your iPhone',
                children: [
                  _StepRow(number: 1, text: 'Open the Calendar app.'),
                  _StepRow(number: 2, text: 'Tap Calendars.'),
                  _StepRow(
                    number: 3,
                    text: 'Tap the info button beside the iCloud calendar.',
                  ),
                  _StepRow(number: 4, text: 'Turn on Public Calendar.'),
                  _StepRow(
                    number: 5,
                    text: 'Tap Share Link and copy the link.',
                  ),
                  _StepRow(
                    number: 6,
                    text: 'Come back to Calee and paste the link below.',
                  ),
                ],
              ),
              const SizedBox(height: CaleeSpacing.xs),
              Text(
                'Connected iCloud calendars are read-only in Calee. To edit events, use Apple Calendar.',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: CaleeColors.textSecondary,
                ),
              ),
              const SizedBox(height: CaleeSpacing.sectionSpacing),
              if (services.length >= 2) ...[
                DropdownButtonFormField<ClientService>(
                  value: _selectedService,
                  decoration: const InputDecoration(labelText: 'Service'),
                  items: [
                    for (final s in services)
                      DropdownMenuItem(value: s, child: Text(s.displayName)),
                  ],
                  onChanged: _isSubmitting
                      ? null
                      : (s) => setState(() => _selectedService = s),
                  validator: (s) => s == null ? 'Choose a service' : null,
                ),
                const SizedBox(height: CaleeSpacing.sm + 4),
              ],
              TextFormField(
                controller: _nameController,
                enabled: !_isSubmitting,
                autofocus: true,
                textCapitalization: TextCapitalization.words,
                decoration: const InputDecoration(
                  labelText: 'Calendar name',
                  hintText: 'My iCloud calendar',
                ),
                validator: (v) {
                  final name = (v ?? '').trim();
                  if (name.isEmpty) return 'Enter a calendar name';
                  if (name.length > 120) return 'Name is too long';
                  return null;
                },
              ),
              const SizedBox(height: CaleeSpacing.sm + 4),
              TextFormField(
                controller: _urlController,
                enabled: !_isSubmitting,
                keyboardType: TextInputType.url,
                autocorrect: false,
                decoration: const InputDecoration(
                  labelText: 'Calendar link',
                  hintText: 'webcal://p12-caldav.icloud.com/...',
                ),
                validator: (v) {
                  final url = (v ?? '').trim();
                  if (url.isEmpty) return 'Enter a calendar link';
                  if (!_isAllowedSubscriptionUrl(url)) {
                    return 'Use a valid http, https, or webcal link';
                  }
                  return null;
                },
              ),
              const SizedBox(height: CaleeSpacing.md),
              FilledButton(
                onPressed: _isSubmitting ? null : _submit,
                child: _isSubmitting
                    ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Text('Add to Calee'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

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

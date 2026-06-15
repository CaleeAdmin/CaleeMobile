import 'package:flutter/material.dart';

import '../../../data/api/calee_hub_client.dart';
import '../../../data/auth/calee_preferences.dart';
import '../../../data/models/client_bootstrap.dart';
import '../../../ui/calee_design.dart';
import '../calendar_added_success_page.dart';
import '../calendar_onboarding_status.dart';

class GenericCalendarLinkPage extends StatefulWidget {
  const GenericCalendarLinkPage({
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
  State<GenericCalendarLinkPage> createState() =>
      _GenericCalendarLinkPageState();
}

class _GenericCalendarLinkPageState extends State<GenericCalendarLinkPage> {
  static const List<(String, Color)> _colorPalette = [
    ('#FF3B30', CaleeColors.dotRed),
    ('#FF9500', CaleeColors.dotOrange),
    ('#FFCC00', CaleeColors.dotYellow),
    ('#34C759', CaleeColors.dotGreen),
    ('#5AC8FA', CaleeColors.dotTeal),
    ('#007AFF', CaleeColors.dotBlue),
    ('#AF52DE', CaleeColors.dotPurple),
    ('#FF2D55', CaleeColors.dotPink),
    ('#8E8E93', CaleeColors.dotGray),
  ];

  final _formKey = GlobalKey<FormState>();
  final _nameController = TextEditingController();
  final _urlController = TextEditingController();
  final _colorController = TextEditingController(text: '#007AFF');
  bool _showMoreOptions = false;
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
    _colorController.addListener(() => setState(() {}));
  }

  @override
  void dispose() {
    _nameController.dispose();
    _urlController.dispose();
    _colorController.dispose();
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

  bool _isPaletteColorSelected(String hex) =>
      _colorController.text.trim().toUpperCase() == hex.toUpperCase();

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
        color: _colorController.text.trim().isEmpty
            ? null
            : _colorController.text.trim(),
      );

      await CaleePreferences().saveCalendarOnboardingStatus(
        widget.accountId,
        CalendarOnboardingStatus.dismissedForever,
      );

      if (!mounted) return;
      Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) => CalendarAddedSuccessPage(
            onViewCalendar: widget.onViewCalendar,
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
                : 'Unable to add this calendar link.',
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
      appBar: AppBar(title: const Text('Add calendar link')),
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
                'Paste any supported calendar link, such as an ICS, iCal, or webcal link.',
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: CaleeColors.textSecondary,
                ),
              ),
              const SizedBox(height: CaleeSpacing.xs),
              Text(
                'Examples include school calendars, sports calendars, roster calendars, booking calendars, public holiday calendars, or shared calendar links.',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: CaleeColors.textSecondary,
                ),
              ),
              const SizedBox(height: CaleeSpacing.xs),
              Text(
                'Connected calendars are read-only in Calee. To edit events, use the original calendar app or provider.',
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
                  hintText: 'School calendar',
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
                  hintText: 'https://example.com/calendar.ics',
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
              TextButton(
                onPressed: () =>
                    setState(() => _showMoreOptions = !_showMoreOptions),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(_showMoreOptions ? 'Hide options' : 'More options'),
                    const SizedBox(width: CaleeSpacing.xs),
                    Icon(
                      _showMoreOptions
                          ? Icons.expand_less
                          : Icons.expand_more,
                      size: 18,
                    ),
                  ],
                ),
              ),
              if (_showMoreOptions) ...[
                Text(
                  'Color',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: CaleeColors.textSecondary,
                  ),
                ),
                const SizedBox(height: CaleeSpacing.sm),
                Wrap(
                  spacing: CaleeSpacing.sm,
                  runSpacing: CaleeSpacing.sm,
                  children: [
                    for (final (hex, color) in _colorPalette)
                      _ColorDot(
                        hex: hex,
                        color: color,
                        isSelected: _isPaletteColorSelected(hex),
                        onTap: () =>
                            setState(() => _colorController.text = hex),
                      ),
                  ],
                ),
                const SizedBox(height: CaleeSpacing.sm + 4),
                TextFormField(
                  controller: _colorController,
                  enabled: !_isSubmitting,
                  decoration: const InputDecoration(
                    labelText: 'Custom color',
                    hintText: '#007AFF',
                  ),
                  validator: (v) {
                    final color = (v ?? '').trim();
                    if (color.isEmpty) return null;
                    final n = color.startsWith('#') ? color : '#$color';
                    if (!RegExp(r'^#[0-9A-Fa-f]{6}$').hasMatch(n)) {
                      return 'Use a color like #007AFF';
                    }
                    return null;
                  },
                ),
                const SizedBox(height: CaleeSpacing.md),
              ],
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

class _ColorDot extends StatelessWidget {
  const _ColorDot({
    required this.hex,
    required this.color,
    required this.isSelected,
    required this.onTap,
  });

  final String hex;
  final Color color;
  final bool isSelected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 150),
        width: 30,
        height: 30,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: color,
          border: isSelected
              ? Border.all(
                  color: CaleeColors.textPrimary,
                  width: 2,
                  strokeAlign: BorderSide.strokeAlignOutside,
                )
              : null,
        ),
        child: isSelected
            ? const Icon(Icons.check, size: 16, color: Colors.white)
            : null,
      ),
    );
  }
}

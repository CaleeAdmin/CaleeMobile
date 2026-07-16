import 'package:flutter/material.dart';

import '../../../data/api/calee_hub_client.dart';
import '../../../data/auth/calee_preferences.dart';
import '../../../data/models/calendar_subscription_validation.dart';
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
    this.pageTitle = 'Add calendar link',
    this.introText =
        'Paste any supported calendar link, such as an ICS, iCal, or webcal link.',
    this.exampleText =
        'Examples: school calendar, sports calendar, work roster, staff calendar, '
        'booking calendar, public holidays, or another shared calendar link.',
    this.showExamples = true,
    this.linkHintText = 'https://example.com/calendar.ics',
    this.nameHintText = 'Shared calendar',
    this.readOnlyText =
        'Connected calendars are read-only in Calee. To change events, use the original calendar app or provider.',
    this.submitButtonText = 'Add to Calee',
    this.successDelayText =
        'After you add it, events may take a few minutes to appear on your Calee display.',
    this.validationErrorText =
        'This does not look like a calendar link. Paste a calendar link that starts with https:// or webcal://.',
    super.key,
  });

  final CaleeHubClient hubClient;
  final String accessToken;
  final List<ClientService> services;
  final String accountId;
  final VoidCallback onDone;
  final VoidCallback onViewCalendar;
  final String pageTitle;
  final String introText;
  final String exampleText;
  final bool showExamples;
  final String linkHintText;
  final String nameHintText;
  final String readOnlyText;
  final String submitButtonText;
  final String successDelayText;
  final String validationErrorText;

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
  bool _isLoadingBootstrap = true;
  ClientService? _selectedService;
  List<ClientService> _freshServices = const [];
  String? _bootstrapProblem;

  bool _isChecking = false;
  String? _checkError;
  CalendarSubscriptionValidationResult? _validationResult;

  // Snapshot of what the last check (successful or not) was run against, so
  // an edit to name/url/service can invalidate a now-stale check result.
  String? _checkedName;
  String? _checkedUrl;
  String? _checkedServiceId;

  List<ClientService> get _calendarServices => _freshServices
      .where(
        (s) =>
            (s.serviceType == 'nextcloud_calendar' ||
                s.serviceType == 'nextcloud_portal') &&
            s.hasConnectedCalendarCredential,
      )
      .toList();

  @override
  void initState() {
    super.initState();
    _colorController.addListener(() => setState(() {}));
    _nameController.addListener(_clearStaleCheck);
    _urlController.addListener(_clearStaleCheck);
    _refreshBootstrap();
  }

  Future<void> _refreshBootstrap() async {
    try {
      final bs = await widget.hubClient.bootstrap(
        accessToken: widget.accessToken,
      );
      if (!mounted) return;
      setState(() {
        _freshServices = bs.services;
        _bootstrapProblem = bs.calendarServiceReady
            ? null
            : bs.readinessProblem;
        final services = _calendarServices;
        _selectedService = services.isEmpty ? null : services.first;
        _isLoadingBootstrap = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _freshServices = widget.services;
        _bootstrapProblem = null;
        final services = _calendarServices;
        _selectedService = services.isEmpty ? null : services.first;
        _isLoadingBootstrap = false;
      });
    }
  }

  @override
  void dispose() {
    _nameController.removeListener(_clearStaleCheck);
    _urlController.removeListener(_clearStaleCheck);
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
        (scheme == 'https' || scheme == 'webcal');
  }

  bool _isPaletteColorSelected(String hex) =>
      _colorController.text.trim().toUpperCase() == hex.toUpperCase();

  String _noServiceMessage() {
    if (_bootstrapProblem == 'no_connected_calendar_service') {
      return 'Your account setup is not complete. Please sign out and sign in again.';
    }
    final hasMissingCredential = _freshServices.any(
      (s) =>
          (s.serviceType == 'nextcloud_calendar' ||
              s.serviceType == 'nextcloud_portal') &&
          s.hasMissingCalendarCredential,
    );
    if (hasMissingCredential) {
      return 'Your calendar service credential is missing. Please sign out and sign in again.';
    }
    final hasBusinessService = _freshServices.any(
      (s) => s.id == 'business' && s.accessStatus == 'active',
    );
    if (hasBusinessService) {
      return 'Your business calendar credential is not ready. Please contact your administrator.';
    }
    return 'No calendar service access found. Please sign out and sign in again.';
  }

  /// True once a check has run (result or error) but the form no longer
  /// matches the name/url/service it was checked against.
  bool get _hasStaleCheck {
    if (_validationResult == null && _checkError == null) return false;
    return _nameController.text != _checkedName ||
        _urlController.text != _checkedUrl ||
        _selectedService?.id != _checkedServiceId;
  }

  void _clearStaleCheck() {
    if (!_hasStaleCheck) return;
    setState(() {
      _validationResult = null;
      _checkError = null;
    });
  }

  Future<void> _checkCalendar() async {
    if (_isChecking || _isSubmitting) return;
    if (!_formKey.currentState!.validate()) return;

    final service = _selectedService;
    if (service == null) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(_noServiceMessage())));
      return;
    }

    final name = _nameController.text.trim();
    final url = _urlController.text.trim();

    setState(() {
      _isChecking = true;
      _checkError = null;
      _validationResult = null;
    });

    try {
      final result = await widget.hubClient.validateCalendarSubscription(
        accessToken: widget.accessToken,
        serviceId: service.id,
        name: name,
        url: url,
      );
      if (!mounted) return;
      setState(() {
        _isChecking = false;
        _checkedName = name;
        _checkedUrl = url;
        _checkedServiceId = service.id;
        if (result.valid) {
          _validationResult = result;
          _checkError = null;
        } else {
          _validationResult = null;
          final message = result.message?.trim();
          _checkError = (message != null && message.isNotEmpty)
              ? message
              : 'This does not look like a calendar subscription link.';
        }
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _isChecking = false;
        _validationResult = null;
        _checkError =
            'Calee could not check this calendar link. Please try again.';
      });
    }
  }

  Future<void> _submit() async {
    final validation = _validationResult;
    if (_isSubmitting ||
        _isChecking ||
        validation == null ||
        !validation.valid) {
      return;
    }
    if (!_formKey.currentState!.validate()) return;

    final service = _selectedService;
    if (service == null) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(_noServiceMessage())));
      return;
    }

    setState(() => _isSubmitting = true);

    try {
      await widget.hubClient.subscribeCalendarFromLink(
        accessToken: widget.accessToken,
        serviceId: service.id,
        name: _nameController.text.trim(),
        url: validation.normalizedUrl ?? _urlController.text.trim(),
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
          builder: (_) =>
              CalendarAddedSuccessPage(onViewCalendar: widget.onViewCalendar),
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
    final busy = _isChecking || _isSubmitting;
    final isValidated = _validationResult?.valid == true;

    if (_isLoadingBootstrap) {
      return CaleeScaffold(
        appBar: AppBar(title: Text(widget.pageTitle)),
        body: const Center(child: CircularProgressIndicator()),
      );
    }

    return CaleeScaffold(
      appBar: AppBar(title: Text(widget.pageTitle)),
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
                widget.introText,
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: CaleeColors.textSecondary,
                ),
              ),
              if (widget.showExamples) ...[
                const SizedBox(height: CaleeSpacing.xs),
                Text(
                  widget.exampleText,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: CaleeColors.textSecondary,
                  ),
                ),
              ],
              const SizedBox(height: CaleeSpacing.xs),
              Text(
                'Calendar links often end in .ics or start with webcal://',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: CaleeColors.textSecondary,
                ),
              ),
              const SizedBox(height: CaleeSpacing.xs),
              Text(
                widget.readOnlyText,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: CaleeColors.textSecondary,
                ),
              ),
              const SizedBox(height: CaleeSpacing.sectionSpacing),
              if (services.length >= 2) ...[
                DropdownButtonFormField<ClientService>(
                  initialValue: _selectedService,
                  decoration: const InputDecoration(labelText: 'Service'),
                  items: [
                    for (final s in services)
                      DropdownMenuItem(value: s, child: Text(s.displayName)),
                  ],
                  onChanged: busy
                      ? null
                      : (s) => setState(() {
                          _selectedService = s;
                          if (_hasStaleCheck) {
                            _validationResult = null;
                            _checkError = null;
                          }
                        }),
                  validator: (s) => s == null ? 'Choose a service' : null,
                ),
                const SizedBox(height: CaleeSpacing.sm + 4),
              ],
              TextFormField(
                controller: _nameController,
                enabled: !busy,
                autofocus: true,
                textCapitalization: TextCapitalization.words,
                decoration: InputDecoration(
                  labelText: 'Calendar name',
                  hintText: widget.nameHintText,
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
                enabled: !busy,
                keyboardType: TextInputType.url,
                autocorrect: false,
                decoration: InputDecoration(
                  labelText: 'Calendar link',
                  hintText: widget.linkHintText,
                ),
                validator: (v) {
                  final url = (v ?? '').trim();
                  if (url.isEmpty) return 'Enter a calendar link';
                  if (!_isAllowedSubscriptionUrl(url)) {
                    return widget.validationErrorText;
                  }
                  return null;
                },
              ),
              const SizedBox(height: CaleeSpacing.xs),
              Text(
                widget.successDelayText,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: CaleeColors.textSecondary,
                ),
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
                      _showMoreOptions ? Icons.expand_less : Icons.expand_more,
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
                  enabled: !busy,
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
              if (_checkError != null) ...[
                _CalendarCheckErrorBanner(message: _checkError!),
                const SizedBox(height: CaleeSpacing.sm + 4),
              ],
              if (isValidated) ...[
                _CalendarCheckPreviewCard(preview: _validationResult!.preview),
                const SizedBox(height: CaleeSpacing.sm + 4),
              ],
              FilledButton(
                onPressed: busy
                    ? null
                    : (isValidated ? _submit : _checkCalendar),
                child: _isSubmitting
                    ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : Text(
                        _isChecking
                            ? 'Checking calendar…'
                            : (isValidated
                                  ? widget.submitButtonText
                                  : 'Check calendar'),
                      ),
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

// ─── _CalendarCheckErrorBanner ────────────────────────────────────────────────

class _CalendarCheckErrorBanner extends StatelessWidget {
  const _CalendarCheckErrorBanner({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Container(
      padding: const EdgeInsets.all(CaleeSpacing.sm + 4),
      decoration: BoxDecoration(
        color: theme.colorScheme.errorContainer,
        borderRadius: BorderRadius.circular(CaleeRadius.card),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(
            Icons.warning_amber_rounded,
            size: 20,
            color: theme.colorScheme.error,
          ),
          const SizedBox(width: CaleeSpacing.sm),
          Expanded(
            child: Text(
              message,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.onErrorContainer,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// ─── _CalendarCheckPreviewCard ────────────────────────────────────────────────

class _CalendarCheckPreviewCard extends StatelessWidget {
  const _CalendarCheckPreviewCard({required this.preview});

  final CalendarSubscriptionPreview? preview;

  String _providerLabel(String? provider) {
    switch (provider) {
      case 'icloud':
        return 'iCloud';
      case 'google':
        return 'Google';
      case 'ics':
        return 'ICS';
      default:
        return '';
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final providerLabel = _providerLabel(preview?.provider);
    final eventCount = preview?.eventCount;

    return Container(
      padding: const EdgeInsets.all(CaleeSpacing.sm + 4),
      decoration: BoxDecoration(
        color: CaleeColors.primary.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(CaleeRadius.card),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Icon(Icons.check_circle, size: 20, color: CaleeColors.primary),
          const SizedBox(width: CaleeSpacing.sm),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Calendar found',
                  style: theme.textTheme.bodyMedium?.copyWith(
                    fontWeight: FontWeight.w600,
                    color: CaleeColors.textPrimary,
                  ),
                ),
                if (providerLabel.isNotEmpty)
                  Text(
                    'Provider: $providerLabel',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: CaleeColors.textSecondary,
                    ),
                  ),
                if (eventCount != null)
                  Text(
                    'Events found: $eventCount',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: CaleeColors.textSecondary,
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

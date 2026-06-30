import 'package:flutter/material.dart';

import '../../data/api/calee_hub_client.dart';
import '../../ui/calee_theme.dart';
import '../../ui/calee_widgets.dart';
import 'profile_controller.dart';
import 'profile_repository.dart';

const _kCommonTimezones = [
  'Pacific/Honolulu',
  'America/Anchorage',
  'America/Los_Angeles',
  'America/Denver',
  'America/Chicago',
  'America/New_York',
  'America/Sao_Paulo',
  'UTC',
  'Europe/London',
  'Europe/Paris',
  'Africa/Cairo',
  'Europe/Helsinki',
  'Europe/Moscow',
  'Asia/Dubai',
  'Asia/Kolkata',
  'Asia/Dhaka',
  'Asia/Bangkok',
  'Asia/Singapore',
  'Asia/Shanghai',
  'Australia/Perth',
  'Asia/Tokyo',
  'Asia/Seoul',
  'Australia/Darwin',
  'Australia/Adelaide',
  'Australia/Brisbane',
  'Australia/Sydney',
  'Australia/Melbourne',
  'Australia/Hobart',
  'Pacific/Auckland',
  'Pacific/Fiji',
];

final _kPostalCodeRe = RegExp(r'^[A-Za-z0-9 \-]{0,32}$');

class ProfilePage extends StatefulWidget {
  const ProfilePage({
    required this.hubClient,
    required this.accessToken,
    this.onProfileSaved,
    super.key,
  });

  final CaleeHubClient hubClient;
  final String accessToken;
  final VoidCallback? onProfileSaved;

  @override
  State<ProfilePage> createState() => _ProfilePageState();
}

class _ProfilePageState extends State<ProfilePage> {
  late final ProfileController _controller;
  final _formKey = GlobalKey<FormState>();

  final _firstNameCtrl = TextEditingController();
  final _lastNameCtrl = TextEditingController();
  final _displayNameCtrl = TextEditingController();
  final _postalCodeCtrl = TextEditingController();

  String? _selectedTimezone;
  bool _fieldsLoaded = false;

  @override
  void initState() {
    super.initState();
    _controller = ProfileController(
      repository: ProfileRepository(
        hubClient: widget.hubClient,
        accessToken: widget.accessToken,
      ),
    );
    _controller.addListener(_onControllerUpdate);
    _controller.load();
  }

  void _onControllerUpdate() {
    if (!_fieldsLoaded && _controller.profile != null) {
      final p = _controller.profile!;
      _firstNameCtrl.text = p.firstName;
      _lastNameCtrl.text = p.lastName;
      _displayNameCtrl.text = p.displayName ?? '';
      _postalCodeCtrl.text = p.postalCode ?? '';
      _selectedTimezone = p.timeZone;
      _fieldsLoaded = true;
    }

    if (!mounted) return;
    setState(() {});

    final status = _controller.saveStatus;
    if (status == ProfileSaveStatus.saved) {
      final hasWarnings = _controller.profile?.hasWarnings ?? false;
      final msg = hasWarnings
          ? 'Profile saved, but some connected services may update later.'
          : 'Profile updated';
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
      _controller.clearSaveStatus();
      widget.onProfileSaved?.call();
    } else if (status == ProfileSaveStatus.error) {
      final raw = _controller.saveError ?? 'An error occurred';
      final msg = raw.contains('EMAIL_NOT_EDITABLE')
          ? 'Email cannot be changed in the app. Contact Calee support.'
          : raw.replaceFirst('Exception: ', '');
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
      _controller.clearSaveStatus();
    }
  }

  @override
  void dispose() {
    _controller.removeListener(_onControllerUpdate);
    _controller.dispose();
    _firstNameCtrl.dispose();
    _lastNameCtrl.dispose();
    _displayNameCtrl.dispose();
    _postalCodeCtrl.dispose();
    super.dispose();
  }

  void _save() {
    if (!(_formKey.currentState?.validate() ?? false)) return;
    _controller.save(
      firstName: _firstNameCtrl.text.trim(),
      lastName: _lastNameCtrl.text.trim(),
      displayName: _displayNameCtrl.text.trim().isEmpty
          ? null
          : _displayNameCtrl.text.trim(),
      timeZone: _selectedTimezone,
      postalCode: _postalCodeCtrl.text.trim(),
    );
  }

  @override
  Widget build(BuildContext context) {
    return CaleeScaffold(
      appBar: AppBar(
        title: const Text('Personal profile'),
        backgroundColor: CaleeColors.scaffoldBackground,
        elevation: 0,
      ),
      body: _buildBody(context),
    );
  }

  Widget _buildBody(BuildContext context) {
    if (_controller.isLoading) {
      return const Center(child: CircularProgressIndicator());
    }

    if (_controller.loadError != null && _controller.profile == null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(CaleeSpacing.xl),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(
                Icons.error_outline,
                size: 48,
                color: CaleeColors.textTertiary,
              ),
              const SizedBox(height: CaleeSpacing.md),
              Text(
                _controller.loadError.toString(),
                textAlign: TextAlign.center,
                style: const TextStyle(color: CaleeColors.textSecondary),
              ),
              const SizedBox(height: CaleeSpacing.md),
              ElevatedButton(
                onPressed: _controller.load,
                child: const Text('Retry'),
              ),
            ],
          ),
        ),
      );
    }

    final profile = _controller.profile;
    final isSaving = _controller.saveStatus == ProfileSaveStatus.saving;

    return Form(
      key: _formKey,
      child: ListView(
        padding: const EdgeInsets.symmetric(
          horizontal: CaleeSpacing.pagePadding,
          vertical: CaleeSpacing.md,
        ),
        children: [
          // ── Account section (email read-only) ───────────
          CaleeSection(
            title: 'Account',
            children: [
              Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: CaleeSpacing.md,
                  vertical: 11,
                ),
                child: Row(
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Text(
                            'Email',
                            style: TextStyle(
                              fontSize: 16,
                              color: CaleeColors.textPrimary,
                            ),
                          ),
                        ],
                      ),
                    ),
                    Text(
                      profile?.email ?? '',
                      key: const Key('email_display'),
                      style: const TextStyle(
                        fontSize: 16,
                        color: CaleeColors.textTertiary,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),

          const SizedBox(height: CaleeSpacing.sectionSpacing),

          // ── Name section ────────────────────────────────
          CaleeSection(
            title: 'Name',
            children: [
              CaleeSectionLabeledTextFormField(
                label: 'First name',
                controller: _firstNameCtrl,
                hintText: 'Required',
                enabled: !isSaving,
                validator: (v) =>
                    (v == null || v.trim().isEmpty) ? 'Required' : null,
              ),
              CaleeSectionLabeledTextFormField(
                label: 'Last name',
                controller: _lastNameCtrl,
                hintText: 'Required',
                enabled: !isSaving,
                validator: (v) =>
                    (v == null || v.trim().isEmpty) ? 'Required' : null,
              ),
              CaleeSectionLabeledTextFormField(
                label: 'Display name',
                controller: _displayNameCtrl,
                hintText: 'Optional',
                enabled: !isSaving,
              ),
            ],
          ),

          const SizedBox(height: CaleeSpacing.sectionSpacing),

          // ── Location & timezone ─────────────────────────
          CaleeSection(
            title: 'Location & timezone',
            children: [
              _TimezoneRow(
                value: _selectedTimezone,
                enabled: !isSaving,
                onChanged: (tz) => setState(() => _selectedTimezone = tz),
                validator: () =>
                    (_selectedTimezone == null || _selectedTimezone!.isEmpty)
                    ? 'Required'
                    : null,
              ),
              CaleeSectionLabeledTextFormField(
                label: 'Postcode',
                controller: _postalCodeCtrl,
                hintText: 'Optional',
                enabled: !isSaving,
                validator: (v) {
                  if (v == null || v.trim().isEmpty) return null;
                  if (!_kPostalCodeRe.hasMatch(v.trim())) {
                    return 'Letters, numbers, spaces, or hyphen only (max 32)';
                  }
                  return null;
                },
              ),
            ],
          ),

          const SizedBox(height: CaleeSpacing.sectionSpacing),

          // ── Save button ─────────────────────────────────
          SizedBox(
            width: double.infinity,
            child: ElevatedButton(
              onPressed: isSaving ? null : _save,
              style: ElevatedButton.styleFrom(
                backgroundColor: CaleeColors.primary,
                foregroundColor: Colors.white,
                padding: const EdgeInsets.symmetric(vertical: 14),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(CaleeRadius.card),
                ),
              ),
              child: isSaving
                  ? const SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: Colors.white,
                      ),
                    )
                  : const Text('Save changes'),
            ),
          ),

          const SizedBox(height: 96),
        ],
      ),
    );
  }
}

// ─────────────────────────────────────────────
// _TimezoneRow
// ─────────────────────────────────────────────

class _TimezoneRow extends StatefulWidget {
  const _TimezoneRow({
    required this.value,
    required this.onChanged,
    required this.enabled,
    required this.validator,
  });

  final String? value;
  final ValueChanged<String?> onChanged;
  final bool enabled;
  final String? Function() validator;

  @override
  State<_TimezoneRow> createState() => _TimezoneRowState();
}

class _TimezoneRowState extends State<_TimezoneRow> {
  @override
  Widget build(BuildContext context) {
    return FormField<String>(
      validator: (_) => widget.validator(),
      builder: (field) {
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            CaleeSectionDropdownRow<String>(
              label: 'Timezone',
              value: _kCommonTimezones.contains(widget.value)
                  ? widget.value
                  : null,
              enabled: widget.enabled,
              items: _kCommonTimezones
                  .map((tz) => DropdownMenuItem(value: tz, child: Text(tz)))
                  .toList(),
              onChanged: (v) {
                widget.onChanged(v);
                field.didChange(v);
              },
            ),
            if (field.errorText != null)
              Padding(
                padding: const EdgeInsets.fromLTRB(
                  CaleeSpacing.md,
                  2,
                  CaleeSpacing.md,
                  4,
                ),
                child: Text(
                  field.errorText!,
                  style: const TextStyle(
                    fontSize: 12,
                    color: CaleeColors.destructive,
                  ),
                ),
              ),
          ],
        );
      },
    );
  }
}

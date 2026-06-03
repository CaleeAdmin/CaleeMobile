import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../../data/api/calee_hub_client.dart';
import '../../data/auth/calee_preferences.dart';
import '../../data/models/client_bootstrap.dart';
import '../../data/models/client_calendar.dart';
import '../../ui/calee_theme.dart';
import '../../ui/calee_widgets.dart';
import 'calendar_collections_page.dart';
import 'family_setup_page.dart';
import 'household_people_page.dart';
import 'service_details_page.dart';
import 'settings_controller.dart';
import 'settings_repository.dart';

class SettingsPage extends StatefulWidget {
  const SettingsPage({
    required this.hubClient,
    required this.accessToken,
    required this.bootstrap,
    required this.onSignOut,
    this.onBootstrapRefreshed,
    super.key,
  });

  final CaleeHubClient hubClient;
  final String accessToken;
  final ClientBootstrap bootstrap;
  final VoidCallback onSignOut;
  final void Function(ClientBootstrap)? onBootstrapRefreshed;

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  late final SettingsController _controller;

  @override
  void initState() {
    super.initState();
    final repository = SettingsRepository(
      hubClient: widget.hubClient,
      accessToken: widget.accessToken,
    );
    _controller = SettingsController(
      repository: repository,
      initialBootstrap: widget.bootstrap,
    );
    _controller.load();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _openFamilyMembers() async {
    final households = _controller.bootstrap.contexts.households;

    if (households.isNotEmpty) {
      Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) => HouseholdPeoplePage(
            hubClient: widget.hubClient,
            accessToken: widget.accessToken,
            households: households,
          ),
        ),
      );
      return;
    }

    try {
      final fresh =
          await _controller.ensureDefaultFamilyAndRefreshBootstrap();

      if (!mounted) return;
      widget.onBootstrapRefreshed?.call(fresh);

      final freshHouseholds = fresh.contexts.households;
      if (freshHouseholds.isEmpty) {
        _showFamilySetupPage();
        return;
      }

      Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) => HouseholdPeoplePage(
            hubClient: widget.hubClient,
            accessToken: widget.accessToken,
            households: freshHouseholds,
            autoOpenCreate: true,
          ),
        ),
      );
    } catch (e, st) {
      if (!mounted) return;
      debugPrint('[SettingsPage] Family setup failed: $e\n$st');
      if (kDebugMode) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Family setup error: $e')),
        );
      }
      _showFamilySetupPage();
    }
  }

  void _showFamilySetupPage() {
    final portalUrl = _controller.bootstrap.services
        .where((s) => s.launchUrl.trim().isNotEmpty)
        .map((s) => s.launchUrl)
        .firstOrNull;

    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => FamilySetupPage(portalUrl: portalUrl),
      ),
    );
  }

  void _openServiceDetails(ClientService service) {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => ServiceDetailsPage(
          hubClient: widget.hubClient,
          accessToken: widget.accessToken,
          service: service,
        ),
      ),
    );
  }

  ClientCalendar? _findById(List<ClientCalendar> list, String id) {
    for (final c in list) {
      if (c.id == id) return c;
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _controller,
      builder: (context, _) => _buildContent(context),
    );
  }

  Widget _buildContent(BuildContext context) {
    final account = _controller.bootstrap.account;
    final calendars = _controller.calendars;
    final preferences = _controller.preferences;
    final isLoadingPrefs = _controller.isLoadingPreferences;
    final isOpeningFamily = _controller.isOpeningFamily;

    final writableCalendars =
        calendars.where((c) => c.isCalendarKind && !c.readOnly).toList();
    final taskCalendars = calendars.where((c) => c.isTaskKind).toList();

    final storedCalId = preferences.defaultCalendarId;
    final defaultCal =
        storedCalId != null ? _findById(writableCalendars, storedCalId) : null;

    final storedTaskId = preferences.defaultTaskListId;
    final defaultTask =
        storedTaskId != null ? _findById(taskCalendars, storedTaskId) : null;

    return ListView(
      padding: const EdgeInsets.symmetric(
        horizontal: CaleeSpacing.pagePadding,
        vertical: CaleeSpacing.md,
      ),
      children: [
        // ── Account ──────────────────────────────────
        CaleeSection(
          title: 'Account',
          children: [
            CaleeListRow(
              title: account.displayName ?? 'Calee user',
              subtitle: account.primaryEmail ?? account.id,
              leading: Container(
                width: 32,
                height: 32,
                decoration: BoxDecoration(
                  color: CaleeColors.primary.withAlpha(26),
                  shape: BoxShape.circle,
                ),
                child: const Icon(
                  Icons.person_outline,
                  size: 18,
                  color: CaleeColors.primary,
                ),
              ),
            ),
          ],
        ),

        const SizedBox(height: CaleeSpacing.sectionSpacing),

        // ── Preferences ──────────────────────────────
        CaleeSection(
          title: 'Preferences',
          children: [
            if (isLoadingPrefs)
              const Padding(
                padding: EdgeInsets.symmetric(
                  horizontal: CaleeSpacing.md,
                  vertical: CaleeSpacing.md,
                ),
                child: Center(child: CircularProgressIndicator()),
              )
            else ...[
              CaleeSectionDropdownRow<FirstDayOfWeek>(
                label: 'First day of week',
                value: preferences.firstDayOfWeek,
                items: FirstDayOfWeek.values
                    .map((v) => DropdownMenuItem(
                          value: v,
                          child: Text(v.displayLabel),
                        ))
                    .toList(),
                onChanged: (v) {
                  if (v != null) _controller.setFirstDayOfWeek(v);
                },
              ),
              CaleeSectionDropdownRow<TimeFormatPref>(
                label: 'Time format',
                value: preferences.timeFormat,
                items: TimeFormatPref.values
                    .map((v) => DropdownMenuItem(
                          value: v,
                          child: Text(v.displayLabel),
                        ))
                    .toList(),
                onChanged: (v) {
                  if (v != null) _controller.setTimeFormat(v);
                },
              ),
              if (writableCalendars.isNotEmpty)
                CaleeSectionDropdownRow<ClientCalendar?>(
                  label: 'Default calendar',
                  value: defaultCal,
                  items: [
                    const DropdownMenuItem(
                      value: null,
                      child: Text('None'),
                    ),
                    ...writableCalendars.map(
                      (c) => DropdownMenuItem(
                        value: c,
                        child: Text(c.name),
                      ),
                    ),
                  ],
                  onChanged: _controller.setDefaultCalendar,
                ),
              if (taskCalendars.isNotEmpty)
                CaleeSectionDropdownRow<ClientCalendar?>(
                  label: 'Default task list',
                  value: defaultTask,
                  items: [
                    const DropdownMenuItem(
                      value: null,
                      child: Text('None'),
                    ),
                    ...taskCalendars.map(
                      (c) => DropdownMenuItem(
                        value: c,
                        child: Text(c.name),
                      ),
                    ),
                  ],
                  onChanged: _controller.setDefaultTaskList,
                ),
            ],
          ],
        ),

        const SizedBox(height: CaleeSpacing.sectionSpacing),

        // ── Manage ───────────────────────────────────
        CaleeSection(
          title: 'Manage',
          children: [
            CaleeListRow(
              title: 'Calendars & Lists',
              subtitle: 'Manage calendars, task lists, and chore lists',
              leading: const Icon(
                Icons.calendar_month_outlined,
                size: 20,
                color: CaleeColors.primary,
              ),
              onTap: () {
                Navigator.of(context)
                    .push(
                  MaterialPageRoute<void>(
                    builder: (_) => CalendarCollectionsPage(
                      hubClient: widget.hubClient,
                      accessToken: widget.accessToken,
                      services: _controller.bootstrap.services,
                    ),
                  ),
                )
                    .then((_) {
                  if (mounted) _controller.refresh();
                });
              },
            ),
            CaleeListRow(
              title: 'Family Members',
              subtitle: isOpeningFamily
                  ? 'Setting up family…'
                  : 'Manage people used for chores',
              leading: isOpeningFamily
                  ? const SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(
                      Icons.group_outlined,
                      size: 20,
                      color: CaleeColors.primary,
                    ),
              onTap: isOpeningFamily ? null : _openFamilyMembers,
            ),
          ],
        ),

        const SizedBox(height: CaleeSpacing.sectionSpacing),

        // ── Services ─────────────────────────────────
        CaleeSection(
          title: 'Services',
          children: [
            if (_controller.bootstrap.services.isEmpty)
              _EmptyRowText('No services connected.')
            else
              for (final service in _controller.bootstrap.services)
                _ServiceRow(
                  service: service,
                  onTap: () => _openServiceDetails(service),
                ),
          ],
        ),

        const SizedBox(height: CaleeSpacing.sectionSpacing),

        // ── Sign out ─────────────────────────────────
        CaleeSection(
          children: [
            CaleeListRow(
              title: 'Sign out',
              titleStyle: Theme.of(context).textTheme.bodyLarge?.copyWith(
                    color: CaleeColors.destructive,
                  ),
              onTap: widget.onSignOut,
              trailing: const SizedBox.shrink(),
            ),
          ],
        ),

        const SizedBox(height: 96),
      ],
    );
  }
}

// ─────────────────────────────────────────────
// _ServiceRow
// ─────────────────────────────────────────────

class _ServiceRow extends StatelessWidget {
  const _ServiceRow({
    required this.service,
    required this.onTap,
  });

  final ClientService service;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final hasMissing = service.hasMissingCalendarCredential;
    final subtitle = '${service.baseUrl} · ${service.accessStatus}';

    return CaleeListRow(
      title: service.displayName,
      subtitle: subtitle,
      leading: Icon(
        Icons.cloud_outlined,
        size: 20,
        color: hasMissing ? CaleeColors.dotOrange : CaleeColors.textTertiary,
      ),
      trailing: hasMissing
          ? const Icon(
              Icons.warning_amber_rounded,
              size: 16,
              color: CaleeColors.dotOrange,
            )
          : null,
      onTap: onTap,
    );
  }
}

// ─────────────────────────────────────────────
// _EmptyRowText
// ─────────────────────────────────────────────

class _EmptyRowText extends StatelessWidget {
  const _EmptyRowText(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(
        horizontal: CaleeSpacing.md,
        vertical: CaleeSpacing.sm + 4,
      ),
      child: Text(
        text,
        style: Theme.of(context).textTheme.bodyMedium?.copyWith(
              color: CaleeColors.textSecondary,
            ),
      ),
    );
  }
}

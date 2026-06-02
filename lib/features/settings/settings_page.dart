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

class SettingsPage extends StatefulWidget {
  const SettingsPage({
    required this.hubClient,
    required this.accessToken,
    required this.bootstrap,
    required this.onSignOut,
    super.key,
  });

  final CaleeHubClient hubClient;
  final String accessToken;
  final ClientBootstrap bootstrap;
  final VoidCallback onSignOut;

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  final _prefs = CaleePreferences();

  StoredPreferences _preferences = const StoredPreferences();
  List<ClientCalendar> _calendars = [];
  bool _loadingPrefs = true;
  bool _openingFamily = false;

  Future<void> _openFamilyMembers() async {
    final households = widget.bootstrap.contexts.households;

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

    setState(() => _openingFamily = true);

    try {
      await widget.hubClient
          .ensureDefaultFamily(accessToken: widget.accessToken);
      final fresh =
          await widget.hubClient.bootstrap(accessToken: widget.accessToken);

      if (!mounted) return;
      setState(() => _openingFamily = false);

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
    } catch (_) {
      if (!mounted) return;
      setState(() => _openingFamily = false);
      _showFamilySetupPage();
    }
  }

  void _showFamilySetupPage() {
    final portalUrl = widget.bootstrap.services
        .where((s) => s.launchUrl.trim().isNotEmpty)
        .map((s) => s.launchUrl)
        .firstOrNull;

    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => FamilySetupPage(portalUrl: portalUrl),
      ),
    );
  }

  @override
  void initState() {
    super.initState();
    _loadAll();
  }

  Future<void> _loadAll() async {
    try {
      final results = await Future.wait([
        _prefs.load(),
        widget.hubClient.calendars(accessToken: widget.accessToken),
      ]);
      if (!mounted) return;

      var prefs = results[0] as StoredPreferences;
      final allCalendars = (results[1] as ClientCalendarList).calendars;

      // Clear stale default calendar if the stored calendar no longer exists.
      final calId = prefs.defaultCalendarId;
      final writableCalendars =
          allCalendars.where((c) => c.isCalendarKind && !c.readOnly).toList();
      if (calId != null && !writableCalendars.any((c) => c.id == calId)) {
        await _prefs.saveDefaultCalendarId(null);
        prefs = StoredPreferences(
          firstDayOfWeek: prefs.firstDayOfWeek,
          timeFormat: prefs.timeFormat,
          defaultCalendarId: null,
          defaultTaskListId: prefs.defaultTaskListId,
        );
      }

      // Clear stale default task list if the stored list no longer exists.
      final taskListId = prefs.defaultTaskListId;
      final taskCalendars = allCalendars.where((c) => c.isTaskKind).toList();
      if (taskListId != null && !taskCalendars.any((c) => c.id == taskListId)) {
        await _prefs.saveDefaultTaskListId(null);
        prefs = StoredPreferences(
          firstDayOfWeek: prefs.firstDayOfWeek,
          timeFormat: prefs.timeFormat,
          defaultCalendarId: prefs.defaultCalendarId,
          defaultTaskListId: null,
        );
      }

      if (!mounted) return;
      setState(() {
        _preferences = prefs;
        _calendars = allCalendars;
        _loadingPrefs = false;
      });
    } catch (_) {
      // Preferences are non-critical; show the page without them.
      if (mounted) setState(() => _loadingPrefs = false);
    }
  }

  Future<void> _setFirstDayOfWeek(FirstDayOfWeek value) async {
    await _prefs.saveFirstDayOfWeek(value);
    if (mounted) {
      setState(() => _preferences = StoredPreferences(
            firstDayOfWeek: value,
            timeFormat: _preferences.timeFormat,
            defaultCalendarId: _preferences.defaultCalendarId,
            defaultTaskListId: _preferences.defaultTaskListId,
          ));
    }
  }

  Future<void> _setTimeFormat(TimeFormatPref value) async {
    await _prefs.saveTimeFormat(value);
    if (mounted) {
      setState(() => _preferences = StoredPreferences(
            firstDayOfWeek: _preferences.firstDayOfWeek,
            timeFormat: value,
            defaultCalendarId: _preferences.defaultCalendarId,
            defaultTaskListId: _preferences.defaultTaskListId,
          ));
    }
  }

  Future<void> _setDefaultCalendar(ClientCalendar? cal) async {
    await _prefs.saveDefaultCalendarId(cal?.id);
    if (mounted) {
      setState(() => _preferences = StoredPreferences(
            firstDayOfWeek: _preferences.firstDayOfWeek,
            timeFormat: _preferences.timeFormat,
            defaultCalendarId: cal?.id,
            defaultTaskListId: _preferences.defaultTaskListId,
          ));
    }
  }

  ClientCalendar? _findById(List<ClientCalendar> list, String id) {
    for (final c in list) {
      if (c.id == id) return c;
    }
    return null;
  }

  Future<void> _setDefaultTaskList(ClientCalendar? cal) async {
    await _prefs.saveDefaultTaskListId(cal?.id);
    if (mounted) {
      setState(() => _preferences = StoredPreferences(
            firstDayOfWeek: _preferences.firstDayOfWeek,
            timeFormat: _preferences.timeFormat,
            defaultCalendarId: _preferences.defaultCalendarId,
            defaultTaskListId: cal?.id,
          ));
    }
  }

  @override
  Widget build(BuildContext context) {
    final account = widget.bootstrap.account;
    final writableCalendars =
        _calendars.where((c) => c.isCalendarKind && !c.readOnly).toList();
    final taskCalendars =
        _calendars.where((c) => c.isTaskKind).toList();

    // Validate stored defaults against current calendar list so deleted
    // calendars/lists don't leave a broken preference.
    final storedCalId = _preferences.defaultCalendarId;
    final defaultCal = storedCalId != null
        ? _findById(writableCalendars, storedCalId)
        : null;

    final storedTaskId = _preferences.defaultTaskListId;
    final defaultTask = storedTaskId != null
        ? _findById(taskCalendars, storedTaskId)
        : null;

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
            if (_loadingPrefs)
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
                value: _preferences.firstDayOfWeek,
                items: FirstDayOfWeek.values
                    .map((v) => DropdownMenuItem(
                          value: v,
                          child: Text(v.displayLabel),
                        ))
                    .toList(),
                onChanged: (v) {
                  if (v != null) _setFirstDayOfWeek(v);
                },
              ),
              CaleeSectionDropdownRow<TimeFormatPref>(
                label: 'Time format',
                value: _preferences.timeFormat,
                items: TimeFormatPref.values
                    .map((v) => DropdownMenuItem(
                          value: v,
                          child: Text(v.displayLabel),
                        ))
                    .toList(),
                onChanged: (v) {
                  if (v != null) _setTimeFormat(v);
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
                  onChanged: _setDefaultCalendar,
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
                  onChanged: _setDefaultTaskList,
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
                      services: widget.bootstrap.services,
                    ),
                  ),
                )
                    .then((_) {
                  if (mounted) _loadAll();
                });
              },
            ),
            CaleeListRow(
              title: 'Family Members',
              subtitle: _openingFamily
                  ? 'Setting up family…'
                  : 'Manage people used for chores',
              leading: _openingFamily
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
              onTap: _openingFamily ? null : _openFamilyMembers,
            ),
          ],
        ),

        const SizedBox(height: CaleeSpacing.sectionSpacing),

        // ── Services ─────────────────────────────────
        CaleeSection(
          title: 'Services',
          children: [
            if (widget.bootstrap.services.isEmpty)
              _EmptyRowText('No services connected.')
            else
              for (final service in widget.bootstrap.services)
                _ServiceRow(service: service),
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
  const _ServiceRow({required this.service});

  final ClientService service;

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
          : const SizedBox.shrink(),
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

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../../data/api/calee_hub_client.dart';
import '../../data/auth/calee_preferences.dart';
import '../../data/models/client_bootstrap.dart';
import '../../data/models/client_calendar.dart';
import '../../ui/calee_theme.dart';
import '../../ui/calee_widgets.dart';
import '../calendar_onboarding/calendar_source_picker_page.dart';
import '../display_setup/connect_display_page.dart';
import '../profile/profile_page.dart';
import 'calendar_collections_page.dart';
import 'family_setup_page.dart';
import 'household_people_page.dart';
import 'recently_deleted_page.dart';
import 'service_details_page.dart';
import '../notifications/calendar_notification_candidates.dart';
import '../notifications/calendar_reminder_coordinator.dart';
import '../notifications/local_calendar_notification_service.dart';
import 'settings_controller.dart';
import 'settings_repository.dart';

class SettingsPage extends StatefulWidget {
  const SettingsPage({
    required this.hubClient,
    required this.accessToken,
    required this.bootstrap,
    required this.onSignOut,
    this.onBootstrapRefreshed,
    this.reminderCoordinator,
    this.onNavigateToCalendar,
    this.preferencesOverride,
    super.key,
  });

  final CaleeHubClient hubClient;
  final String accessToken;
  final ClientBootstrap bootstrap;
  final VoidCallback onSignOut;
  final void Function(ClientBootstrap)? onBootstrapRefreshed;

  /// App-level reminder coordinator. Used to force an independent
  /// upcoming-reminder refresh when the user enables reminders. Null in
  /// contexts (e.g. some tests) that do not exercise reminders.
  final CalendarReminderCoordinator? reminderCoordinator;

  // Called after manual onboarding "View calendar" to switch the home tab.
  final VoidCallback? onNavigateToCalendar;

  /// Test-only override for the local preferences store, so reminder-preference
  /// persistence failures can be simulated in widget tests. Null in production,
  /// where the real [CaleePreferences] is used.
  @visibleForTesting
  final CaleePreferences? preferencesOverride;

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
      preferences: widget.preferencesOverride,
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
      final fresh = await _controller.ensureDefaultFamilyAndRefreshBootstrap();

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
      if (kDebugMode) debugPrint('[SettingsPage] People setup failed: $e\n$st');
      if (kDebugMode) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('People setup error: $e')));
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

  void _openProfile() {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => ProfilePage(
          hubClient: widget.hubClient,
          accessToken: widget.accessToken,
        ),
      ),
    );
  }

  bool _serviceNeedsAttention(ClientService s) =>
      s.hasMissingCalendarCredential ||
      !{'connected', 'active', 'healthy'}.contains(s.accessStatus);

  bool _shouldShowServices(List<ClientService> services) {
    if (services.isEmpty) return false;
    if (kDebugMode) return true;
    if (services.length == 1 && !_serviceNeedsAttention(services[0])) {
      return false;
    }
    return true;
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

  Future<void> _toggleCalendarReminders(bool value) async {
    if (value) {
      final granted = await LocalCalendarNotificationService.instance
          .requestPermissionIfNeeded();

      if (!granted) {
        await _controller.setCalendarRemindersEnabled(false);
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
              'Notification permission is needed for calendar reminders.',
            ),
          ),
        );
        return;
      }

      final persisted = await _controller.setCalendarRemindersEnabled(true);
      if (!persisted) {
        // Enabling did not persist: the controller has already rolled the switch
        // back. Surface the transient error and do NOT start reconciliation
        // (nothing was actually enabled).
        await _showSaveErrorIfAny();
        return;
      }

      // Reminders are scheduled from an independent 30-day upcoming-event
      // window, not the visible calendar month, so force a reconcile now.
      final coordinator = widget.reminderCoordinator;
      if (coordinator != null) {
        unawaited(
          coordinator.refresh(
            accessToken: widget.accessToken,
            reason: CalendarReminderRefreshReason.remindersEnabled,
          ),
        );
      }

      // Show the calendar so the user sees the feature they just enabled.
      widget.onNavigateToCalendar?.call();

      return;
    }

    final persisted = await _controller.setCalendarRemindersEnabled(false);
    if (!persisted) {
      // Disabling did not persist: the switch is rolled back to on. Surface the
      // transient error and do NOT run disable cleanup (reminders are still
      // enabled as far as storage is concerned).
      await _showSaveErrorIfAny();
      return;
    }
    // Cancel only the calendar reminder IDs Calee owns for THIS account (via the
    // manifest) — never a global cancelAll() that would also drop notifications
    // belonging to other Calee features or other accounts on this device. Skip
    // when the account identity is invalid (no owner key can be derived).
    final ownerKey = tryReminderOwnerKey(widget.bootstrap.account.id);
    if (ownerKey != null) {
      await LocalCalendarNotificationService.instance.disableCalendarReminders(
        ownerKey: ownerKey,
        includeLegacyOwnerless: true,
      );
    }
  }

  ClientCalendar? _findById(List<ClientCalendar> list, String id) {
    for (final c in list) {
      if (c.id == id) return c;
    }
    return null;
  }

  Future<void> _showSaveErrorIfAny() async {
    if (!mounted) return;
    if (_controller.preferencesSaveError == null) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text("Couldn't save your preference. Please try again."),
      ),
    );
  }

  Future<void> _setFirstDayOfWeek(FirstDayOfWeek value) async {
    await _controller.setFirstDayOfWeek(value);
    await _showSaveErrorIfAny();
  }

  Future<void> _setTimeFormat(TimeFormatPref value) async {
    await _controller.setTimeFormat(value);
    await _showSaveErrorIfAny();
  }

  Future<void> _setDefaultCalendar(ClientCalendar? calendar) async {
    await _controller.setDefaultCalendar(calendar);
    await _showSaveErrorIfAny();
  }

  Future<void> _setDefaultTaskList(ClientCalendar? calendar) async {
    await _controller.setDefaultTaskList(calendar);
    await _showSaveErrorIfAny();
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
    final remindersEnabled = _controller.calendarRemindersEnabled;
    final reminderUnavailable = _controller.reminderPreferenceUnavailable;
    final reminderSwitchEnabled = _controller.isReminderSwitchEnabled;
    final isLoadingPrefs = _controller.isLoadingPreferences;
    final isOpeningFamily = _controller.isOpeningFamily;
    final loadError = _controller.error;

    final writableCalendars = calendars
        .where((c) => c.isCalendarKind && !c.readOnly)
        .toList();
    final taskCalendars = calendars.where((c) => c.isTaskKind).toList();

    final storedCalId = preferences.defaultCalendarId;
    final defaultCal = storedCalId != null
        ? _findById(writableCalendars, storedCalId)
        : null;

    final storedTaskId = preferences.defaultTaskListId;
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
                  color: CaleeColors.primary.withAlpha(CaleeAlpha.pct10),
                  shape: BoxShape.circle,
                ),
                child: const Icon(
                  Icons.person_outline,
                  size: 18,
                  color: CaleeColors.primary,
                ),
              ),
            ),
            CaleeListRow(
              key: const Key('settings_profile_row'),
              title: 'Personal profile',
              subtitle: 'Name, timezone, and postcode',
              leading: const Icon(
                Icons.manage_accounts_outlined,
                size: 20,
                color: CaleeColors.primary,
              ),
              onTap: _openProfile,
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
            else if (loadError != null)
              _PreferencesLoadError(onRetry: _controller.load)
            else ...[
              CaleeSectionDropdownRow<FirstDayOfWeek>(
                key: const Key('settings_first_day_of_week_row'),
                label: 'First day of week',
                value: preferences.firstDayOfWeek,
                items: FirstDayOfWeek.values
                    .map(
                      (v) => DropdownMenuItem(
                        value: v,
                        child: Text(v.displayLabel),
                      ),
                    )
                    .toList(),
                onChanged: (v) {
                  if (v != null) unawaited(_setFirstDayOfWeek(v));
                },
              ),
              CaleeSectionDropdownRow<TimeFormatPref>(
                key: const Key('settings_time_format_row'),
                label: 'Time format',
                value: preferences.timeFormat,
                items: TimeFormatPref.values
                    .map(
                      (v) => DropdownMenuItem(
                        value: v,
                        child: Text(v.displayLabel),
                      ),
                    )
                    .toList(),
                onChanged: (v) {
                  if (v != null) unawaited(_setTimeFormat(v));
                },
              ),
              if (writableCalendars.length >= 2)
                CaleeSectionDropdownRow<ClientCalendar?>(
                  key: const Key('settings_default_calendar_row'),
                  label: 'Default calendar',
                  value: defaultCal,
                  items: [
                    const DropdownMenuItem(
                      value: null,
                      child: Text('Automatic'),
                    ),
                    ...writableCalendars.map(
                      (c) => DropdownMenuItem(value: c, child: Text(c.name)),
                    ),
                  ],
                  onChanged: (c) => unawaited(_setDefaultCalendar(c)),
                ),
              if (taskCalendars.length >= 2)
                CaleeSectionDropdownRow<ClientCalendar?>(
                  key: const Key('settings_default_task_list_row'),
                  label: 'Default task list',
                  value: defaultTask,
                  items: [
                    const DropdownMenuItem(
                      value: null,
                      child: Text('Automatic'),
                    ),
                    ...taskCalendars.map(
                      (c) => DropdownMenuItem(value: c, child: Text(c.name)),
                    ),
                  ],
                  onChanged: (c) => unawaited(_setDefaultTaskList(c)),
                ),
              CaleeListRow(
                title: 'Calendar reminders',
                subtitle:
                    'Remind me around 10 minutes before upcoming events on this'
                    ' phone. Reminders work best when you open Calee regularly.',
                leading: const Icon(
                  Icons.notifications_outlined,
                  size: 20,
                  color: CaleeColors.primary,
                ),
                trailing: Switch(
                  key: const Key('settings_calendar_reminders_switch'),
                  value: remindersEnabled,
                  onChanged: reminderSwitchEnabled
                      ? (v) => unawaited(_toggleCalendarReminders(v))
                      : null,
                ),
              ),
              if (reminderUnavailable)
                Padding(
                  key: const Key('settings_calendar_reminders_unavailable'),
                  padding: const EdgeInsets.only(
                    left: CaleeSpacing.md,
                    right: CaleeSpacing.md,
                    bottom: CaleeSpacing.sm,
                  ),
                  child: Text(
                    "Couldn't load the reminder setting. Please try again.",
                    style: Theme.of(
                      context,
                    ).textTheme.bodySmall?.copyWith(color: CaleeColors.danger),
                  ),
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
              title: 'Connect a display',
              subtitle: 'Scan the QR code shown on your Calee display.',
              leading: const Icon(
                Icons.qr_code_scanner_outlined,
                size: 20,
                color: CaleeColors.primary,
              ),
              onTap: () {
                Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    builder: (_) => ConnectDisplayPage(
                      hubClient: widget.hubClient,
                      accessToken: widget.accessToken,
                      services: _controller.bootstrap.services,
                      accountId: _controller.bootstrap.account.id,
                      onDone: () => Navigator.of(
                        context,
                      ).popUntil((route) => route.isFirst),
                    ),
                  ),
                );
              },
            ),
            CaleeListRow(
              title: 'Add existing calendars',
              subtitle:
                  'Connect Google, Apple, Outlook, or other calendar links to Calee.',
              leading: const Icon(
                Icons.add_circle_outline,
                size: 20,
                color: CaleeColors.primary,
              ),
              onTap: () {
                Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    settings: const RouteSettings(
                      name: CalendarSourcePickerPage.routeName,
                    ),
                    builder: (_) => CalendarSourcePickerPage(
                      hubClient: widget.hubClient,
                      accessToken: widget.accessToken,
                      services: _controller.bootstrap.services,
                      accountId: _controller.bootstrap.account.id,
                      onDone: () => Navigator.of(context).pop(),
                      onViewCalendar: () {
                        Navigator.of(
                          context,
                        ).popUntil((route) => route.isFirst);
                        widget.onNavigateToCalendar?.call();
                      },
                    ),
                  ),
                );
              },
            ),
            CaleeListRow(
              title: 'Calendars and lists',
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
                          accountId: _controller.bootstrap.account.id,
                          isFamilyUxContext:
                              _controller.bootstrap.isFamilyUxContext,
                        ),
                      ),
                    )
                    .then((_) {
                      if (mounted) _controller.refresh();
                    });
              },
            ),
            CaleeListRow(
              title: 'Recently deleted',
              subtitle: 'Restore deleted calendars, tasks, and chores',
              leading: const Icon(
                Icons.restore_from_trash_outlined,
                size: 20,
                color: CaleeColors.primary,
              ),
              onTap: () {
                Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    builder: (_) => RecentlyDeletedPage(
                      hubClient: widget.hubClient,
                      accessToken: widget.accessToken,
                    ),
                  ),
                );
              },
            ),
            // UX-only: hide People (household/family member management) for
            // organisation/workspace users, matching Chores/Meals gating.
            if (_controller.bootstrap.isFamilyUxContext)
              CaleeListRow(
                title: 'People',
                subtitle: isOpeningFamily
                    ? 'Preparing people…'
                    : 'Manage people for tasks and chores',
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
        if (_shouldShowServices(_controller.bootstrap.services)) ...[
          CaleeSection(
            title: 'Connected services',
            children: [
              for (final service in _controller.bootstrap.services)
                _ServiceRow(
                  service: service,
                  onTap: () => _openServiceDetails(service),
                ),
            ],
          ),
          const SizedBox(height: CaleeSpacing.sectionSpacing),
        ],

        // ── Sign out ─────────────────────────────────
        CaleeSection(
          children: [
            CaleeListRow(
              key: const Key('settings_sign_out_row'),
              title: 'Sign out',
              titleStyle: Theme.of(
                context,
              ).textTheme.bodyLarge?.copyWith(color: CaleeColors.destructive),
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
  const _ServiceRow({required this.service, required this.onTap});

  final ClientService service;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final accessNeedsAttention = !{
      'connected',
      'active',
      'healthy',
    }.contains(service.accessStatus);
    final hasMissing = service.hasMissingCalendarCredential;
    final needsAttention = hasMissing || accessNeedsAttention;
    final subtitle = accessNeedsAttention
        ? 'Service access needs attention'
        : hasMissing
        ? 'Calendar app setup needed'
        : 'Connected';

    return CaleeListRow(
      title: service.displayName,
      subtitle: subtitle,
      leading: Icon(
        Icons.cloud_outlined,
        size: 20,
        color: needsAttention
            ? CaleeColors.dotOrange
            : CaleeColors.textTertiary,
      ),
      trailing: needsAttention
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
// _PreferencesLoadError
// ─────────────────────────────────────────────

class _PreferencesLoadError extends StatelessWidget {
  const _PreferencesLoadError({required this.onRetry});

  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(
        horizontal: CaleeSpacing.md,
        vertical: CaleeSpacing.md,
      ),
      child: Column(
        children: [
          const Icon(
            Icons.error_outline,
            size: 28,
            color: CaleeColors.textTertiary,
          ),
          const SizedBox(height: CaleeSpacing.sm),
          const Text(
            "Couldn't load your preferences.",
            textAlign: TextAlign.center,
            style: TextStyle(color: CaleeColors.textSecondary),
          ),
          const SizedBox(height: CaleeSpacing.sm),
          TextButton(onPressed: onRetry, child: const Text('Retry')),
        ],
      ),
    );
  }
}

import 'package:flutter/material.dart';

import '../../data/api/calee_hub_client.dart';
import '../../data/models/calendar_service_error.dart';
import '../../data/models/calendar_subscription_validation.dart';
import '../../data/models/client_bootstrap.dart';
import '../../data/models/client_calendar.dart';
import '../../data/models/external_calendar_connection.dart';
import '../../ui/calee_design.dart';
import '../calendar/widgets/calendar_error_state.dart';
import '../calendar/widgets/calendar_widget_helpers.dart';
import '../calendar_onboarding/calendar_source_picker_page.dart';
import '../calendar_onboarding/provider_guides/google_calendar_selection_page.dart';

// ─── File-level helpers ───────────────────────────────────────────────────────

String _formatCollectionPreviewDate(DateTime value) {
  final year = value.year.toString().padLeft(4, '0');
  final month = value.month.toString().padLeft(2, '0');
  final day = value.day.toString().padLeft(2, '0');
  return '$year-$month-$day';
}

String _pluralCount(int count, String singular, [String? plural]) {
  return '$count ${count == 1 ? singular : plural ?? '${singular}s'}';
}

/// Returns a display colour for [calendar]. Falls back to a type-based
/// default when no color is set or the stored hex is not a valid 6-digit code.
Color _collectionColor(ClientCalendar calendar) {
  final hex = calendar.color?.trim() ?? '';
  if (hex.isNotEmpty) {
    final normalized = hex.startsWith('#') ? hex : '#$hex';
    if (RegExp(r'^#[0-9A-Fa-f]{6}$').hasMatch(normalized)) {
      final code = int.parse(normalized.substring(1), radix: 16);
      return Color(0xFF000000 | code);
    }
  }
  if (calendar.isTaskKind) return CaleeColors.dotGreen;
  if (calendar.isChoreKind) return CaleeColors.dotOrange;
  return CaleeColors.dotBlue;
}

// ─── Delete preview model ─────────────────────────────────────────────────────

class _CollectionDeletePreview {
  const _CollectionDeletePreview({
    required this.lines,
    required this.rangeDescription,
    required this.itemCountsAvailable,
  });

  const _CollectionDeletePreview.unavailable()
    : lines = const [],
      rangeDescription = '',
      itemCountsAvailable = false;

  final List<String> lines;
  final String rangeDescription;
  final bool itemCountsAvailable;

  bool get hasItems => lines.isNotEmpty;
}

// ─── CalendarCollectionsPage ──────────────────────────────────────────────────

class CalendarCollectionsPage extends StatefulWidget {
  const CalendarCollectionsPage({
    required this.hubClient,
    required this.accessToken,
    required this.services,
    required this.accountId,
    required this.isFamilyUxContext,
    this.initialCreateKind,
    this.autoOpenCreate = false,
    this.autoOpenSubscribe = false,
    this.autoOpenSubscribeForm = false,
    this.initialSubscriptionUrl,
    this.initialSubscriptionName,
    super.key,
  });

  final CaleeHubClient hubClient;
  final String accessToken;
  final List<ClientService> services;
  final String accountId;

  /// UX-only: hides the Chore lists section (and the "Chore list" create
  /// option) for business/workspace accounts, matching Chores/Meals/People
  /// gating elsewhere in the app.
  final bool isFamilyUxContext;
  final String? initialCreateKind;
  final bool autoOpenCreate;
  final bool autoOpenSubscribe;

  /// When true, auto-opens the subscribe sheet with [initialSubscriptionUrl]
  /// and [initialSubscriptionName] pre-filled.
  final bool autoOpenSubscribeForm;
  final String? initialSubscriptionUrl;
  final String? initialSubscriptionName;

  @override
  State<CalendarCollectionsPage> createState() =>
      _CalendarCollectionsPageState();
}

class _CalendarCollectionsPageState extends State<CalendarCollectionsPage> {
  late Future<ClientCalendarList> _future;
  late Future<List<ExternalCalendarConnection>> _connectionsFuture;
  final Set<String> _updatingCalendarIds = {};

  List<ClientService> get _calendarServices {
    return widget.services
        .where(
          (s) =>
              s.serviceType == 'nextcloud_calendar' &&
              s.hasConnectedCalendarCredential,
        )
        .toList();
  }

  @override
  void initState() {
    super.initState();
    _future = _loadCalendars();
    _connectionsFuture = _loadConnections();

    if (widget.autoOpenCreate ||
        widget.autoOpenSubscribe ||
        widget.autoOpenSubscribeForm) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        if (widget.autoOpenSubscribe || widget.autoOpenSubscribeForm) {
          _openSubscribeSheet();
        } else {
          _openCreateSheet();
        }
      });
    }
  }

  Future<ClientCalendarList> _loadCalendars() {
    return widget.hubClient.calendars(accessToken: widget.accessToken);
  }

  Future<List<ExternalCalendarConnection>> _loadConnections() {
    return widget.hubClient.externalCalendarConnections(
      accessToken: widget.accessToken,
    );
  }

  void _reload() {
    setState(() {
      _future = _loadCalendars();
      _connectionsFuture = _loadConnections();
    });
  }

  // ── Connected calendars ──────────────────────────────────────────────────

  /// Picks the connection to surface for management: prefers an active
  /// Google connection, but falls back to a non-revoked one that needs
  /// attention so the user can still find their way to disconnect it.
  ExternalCalendarConnection? _primaryGoogleConnection(
    List<ExternalCalendarConnection> connections,
  ) {
    final google = connections
        .where((c) => c.isGoogle && c.revokedAt == null)
        .toList();
    if (google.isEmpty) return null;
    return google.firstWhere((c) => c.isActive, orElse: () => google.first);
  }

  Future<void> _openGoogleCalendarManagement(
    ExternalCalendarConnection connection,
  ) async {
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        settings: const RouteSettings(name: 'google_calendar_management'),
        builder: (_) => GoogleCalendarSelectionPage(
          hubClient: widget.hubClient,
          accessToken: widget.accessToken,
          connection: connection,
          onViewCalendar: () =>
              Navigator.of(context).popUntil((route) => route.isFirst),
          onDone: () => Navigator.of(context).pop(),
        ),
      ),
    );
    if (mounted) _reload();
  }

  Widget _buildGoogleConnectionRow(ExternalCalendarConnection connection) {
    final needsAttention = !connection.isActive;
    final email = connection.externalAccountEmail?.trim();
    final subtitle = needsAttention
        ? 'Needs attention'
        : (email != null && email.isNotEmpty ? email : 'Connected');

    return CaleeListRow(
      key: const Key('calendar_collections_google_calendar_connection_row'),
      title: 'Google Calendar',
      subtitle: subtitle,
      leading: Icon(
        Icons.event_outlined,
        size: 20,
        color: needsAttention ? CaleeColors.dotOrange : CaleeColors.primary,
      ),
      trailing: needsAttention
          ? const Icon(
              Icons.warning_amber_rounded,
              size: 16,
              color: CaleeColors.dotOrange,
            )
          : null,
      onTap: () => _openGoogleCalendarManagement(connection),
    );
  }

  Widget _buildConnectedCalendarsSection() {
    return FutureBuilder<List<ExternalCalendarConnection>>(
      future: _connectionsFuture,
      builder: (context, snapshot) {
        Widget child;

        if (snapshot.connectionState == ConnectionState.waiting &&
            !snapshot.hasData &&
            !snapshot.hasError) {
          child = const Padding(
            padding: EdgeInsets.symmetric(
              horizontal: CaleeSpacing.md,
              vertical: CaleeSpacing.sm + 4,
            ),
            child: SizedBox(
              width: 18,
              height: 18,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
          );
        } else if (snapshot.hasError) {
          child = Padding(
            padding: const EdgeInsets.symmetric(
              horizontal: CaleeSpacing.md,
              vertical: CaleeSpacing.sm + 4,
            ),
            child: Text(
              'Unable to load connected calendars.',
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                color: CaleeColors.textSecondary,
              ),
            ),
          );
        } else {
          final connections =
              snapshot.data ?? const <ExternalCalendarConnection>[];
          final google = _primaryGoogleConnection(connections);

          child = google == null
              ? Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: CaleeSpacing.md,
                    vertical: CaleeSpacing.sm + 4,
                  ),
                  child: Text(
                    'No connected calendar accounts',
                    style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                      color: CaleeColors.textSecondary,
                    ),
                  ),
                )
              : _buildGoogleConnectionRow(google);
        }

        return CaleeSection(title: 'Connected calendars', children: [child]);
      },
    );
  }

  // ── Create / subscribe ───────────────────────────────────────────────────

  void _openAddActions() {
    CaleeActionSheet.show(
      context: context,
      actions: [
        CaleeAction(
          label: 'Create list or calendar',
          icon: Icons.add_circle_outline,
          onTap: _openCreateSheet,
        ),
        CaleeAction(
          label: 'Add existing calendar',
          icon: Icons.link_rounded,
          onTap: () => _openSourcePicker(context),
        ),
      ],
    );
  }

  Future<void> _openSourcePicker(BuildContext context) async {
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        settings: const RouteSettings(name: 'calendar_source_picker'),
        builder: (_) => CalendarSourcePickerPage(
          hubClient: widget.hubClient,
          accessToken: widget.accessToken,
          services: widget.services,
          accountId: widget.accountId,
          onDone: () {},
          onViewCalendar: () =>
              Navigator.of(context).popUntil((r) => r.isFirst),
        ),
      ),
    );
    if (mounted) _reload();
  }

  Future<void> _openCreateSheet() async {
    final services = _calendarServices;

    if (services.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('No connected calendar service is available.'),
        ),
      );
      return;
    }

    final created = await CaleeBottomSheet.show<bool>(
      context: context,
      title: 'Create list or calendar',
      child: _CollectionFormContent(
        services: services,
        initialPrimaryKind: widget.initialCreateKind ?? 'calendar',
        availableKinds: [
          'calendar',
          'tasks',
          if (widget.isFamilyUxContext) 'chores',
        ],
        onSubmit:
            ({
              required String name,
              required String primaryKind,
              required String? color,
              required ClientService? service,
            }) async {
              final selectedService = service;
              if (selectedService == null) {
                throw const CaleeHubException(
                  statusCode: 0,
                  message: 'Choose a service',
                );
              }
              await widget.hubClient.createCalendar(
                accessToken: widget.accessToken,
                serviceId: selectedService.id,
                name: name,
                primaryKind: primaryKind,
                color: color,
              );
            },
      ),
    );

    if (created == true && mounted) _reload();
  }

  Future<void> _openSubscribeSheet() async {
    final services = _calendarServices;

    if (services.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('No connected calendar service is available.'),
        ),
      );
      return;
    }

    final created = await CaleeBottomSheet.show<bool>(
      context: context,
      title: 'Add calendar link',
      child: _SubscriptionFormContent(
        services: services,
        initialName: widget.initialSubscriptionName,
        initialUrl: widget.initialSubscriptionUrl,
        onCheck:
            ({
              required String name,
              required String url,
              required ClientService service,
            }) {
              return widget.hubClient.validateCalendarSubscription(
                accessToken: widget.accessToken,
                serviceId: service.id,
                name: name,
                url: url,
              );
            },
        onSubmit:
            ({
              required String name,
              required String url,
              required String? color,
              required ClientService? service,
            }) async {
              final selectedService = service;
              if (selectedService == null) {
                throw const CaleeHubException(
                  statusCode: 0,
                  message: 'Choose a service',
                );
              }

              await widget.hubClient.subscribeCalendarFromLink(
                accessToken: widget.accessToken,
                serviceId: selectedService.id,
                name: name,
                url: url,
                color: color,
              );
            },
      ),
    );

    if (created == true && mounted) _reload();
  }

  // ── Edit ──────────────────────────────────────────────────────────────────

  Future<void> _openEditSheet(ClientCalendar calendar) async {
    if (!calendar.capabilities.canEditAppearance ||
        _updatingCalendarIds.contains(calendar.id)) {
      return;
    }

    final updated = await CaleeBottomSheet.show<bool>(
      context: context,
      title: 'Edit list or calendar',
      child: _CollectionFormContent(
        initialName: calendar.name,
        initialColor: calendar.color,
        initialPrimaryKind: calendar.primaryKind,
        allowKindChange: false,
        appearanceMode: calendar.appearanceMode,
        sourceName: calendar.sourceName,
        services: const [],
        onSubmit:
            ({
              required String name,
              required String primaryKind,
              required String? color,
              required ClientService? service,
            }) async {
              // Send only the fields that actually changed — an unchanged
              // field sent anyway would become a permanent local override
              // on the backend. The form disables Save for no-op edits, so
              // a null patch here means nothing to do.
              final patch = buildCalendarAppearancePatch(
                originalName: calendar.name,
                originalColor: calendar.color,
                nextName: name,
                nextColor: color,
              );
              if (patch == null) return;

              if (calendar.hasServerAppearanceContract) {
                await widget.hubClient.updateCalendarAppearance(
                  accessToken: widget.accessToken,
                  calendarId: calendar.id,
                  name: patch.name,
                  color: patch.color,
                );
              } else {
                // Old backend: /appearance doesn't exist. Editing is only
                // reachable without the server contract for a
                // fallback-writable calendar, whose appearance lives in the
                // source metadata — use the legacy endpoint.
                await widget.hubClient.updateCalendar(
                  accessToken: widget.accessToken,
                  calendarId: calendar.id,
                  name: patch.name,
                  color: patch.color,
                );
              }
            },
      ),
    );

    if (updated == true && mounted) _reload();
  }

  // ── Delete ────────────────────────────────────────────────────────────────

  ClientService? _serviceFor(String serviceId) {
    for (final s in widget.services) {
      if (s.id == serviceId) return s;
    }
    return null;
  }

  Future<_CollectionDeletePreview> _loadDeletePreview(
    ClientCalendar calendar,
  ) async {
    final now = DateTime.now();
    final from = _formatCollectionPreviewDate(DateTime(now.year, 1, 1));
    final to = _formatCollectionPreviewDate(DateTime(now.year, 12, 31));
    const rangeDescription = 'the current calendar year';

    try {
      final lines = <String>[];

      if (calendar.supportsEvents) {
        final eventList = await widget.hubClient.events(
          accessToken: widget.accessToken,
          from: from,
          to: to,
        );
        final count = eventList.events
            .where((e) => e.calendarId == calendar.id)
            .length;
        if (count > 0) {
          lines.add(_pluralCount(count, 'visible event occurrence'));
        }
      }

      if (calendar.supportsTasks) {
        final taskList = await widget.hubClient.tasks(
          accessToken: widget.accessToken,
          from: from,
          to: to,
        );
        final count = taskList.tasks
            .where((t) => t.calendarId == calendar.id)
            .length;
        if (count > 0) lines.add(_pluralCount(count, 'task'));
      }

      if (calendar.supportsChores) {
        final choreList = await widget.hubClient.chores(
          accessToken: widget.accessToken,
          from: from,
          to: to,
        );
        final chores = choreList.chores
            .where((c) => c.calendarId == calendar.id)
            .toList();
        final choreCount = chores.where((c) => c.kind == 'baseChore').length;
        final completionRecordCount = chores
            .where((c) => c.kind == 'completionLog')
            .length;
        if (choreCount > 0) lines.add(_pluralCount(choreCount, 'chore'));
        if (completionRecordCount > 0) {
          lines.add(_pluralCount(completionRecordCount, 'completion record'));
        }
      }

      return _CollectionDeletePreview(
        lines: lines,
        rangeDescription: rangeDescription,
        itemCountsAvailable: true,
      );
    } catch (_) {
      return const _CollectionDeletePreview.unavailable();
    }
  }

  Future<void> _deleteCalendar(ClientCalendar calendar) async {
    if ((!calendar.isSubscription && calendar.readOnly) ||
        _updatingCalendarIds.contains(calendar.id)) {
      return;
    }

    final preview = await _loadDeletePreview(calendar);
    if (!mounted) return;

    final service = _serviceFor(calendar.serviceId);
    final supportsRecentlyDeleted = service?.supportsRecentlyDeleted ?? false;

    final restoreNote = supportsRecentlyDeleted
        ? 'This will move the item to Recently deleted.'
              ' You can restore it for a limited time.'
        : 'This connected service does not support restore from Calee yet.';

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(calendar.isSubscription ? 'Remove?' : 'Delete?'),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (calendar.isSubscription) ...[
                const Text(
                  'This will remove the connected calendar from Calee. '
                  'It will not delete events from the original calendar provider.',
                ),
              ] else ...[
                Text('This will delete "${calendar.name}".'),
                const SizedBox(height: 12),
                if (preview.itemCountsAvailable && preview.hasItems) ...[
                  Text('Known items found in ${preview.rangeDescription}:'),
                  const SizedBox(height: 4),
                  ...preview.lines.map(
                    (line) => Padding(
                      padding: const EdgeInsets.only(top: 4),
                      child: Text('• $line'),
                    ),
                  ),
                ] else if (preview.itemCountsAvailable) ...[
                  Text('No items were found in ${preview.rangeDescription}.'),
                ] else ...[
                  const Text('Item counts could not be loaded right now.'),
                ],
                const SizedBox(height: 12),
                const Text(
                  'Older or future items may not be shown in this preview.',
                ),
                const SizedBox(height: 12),
                Text(restoreNote),
              ],
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          TextButton(
            style: TextButton.styleFrom(
              foregroundColor: CaleeColors.destructive,
            ),
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text(
              'Delete',
              style: TextStyle(fontWeight: FontWeight.w600),
            ),
          ),
        ],
      ),
    );

    if (confirmed != true || !mounted) return;

    setState(() {
      _updatingCalendarIds.add(calendar.id);
    });

    try {
      await widget.hubClient.deleteCalendar(
        accessToken: widget.accessToken,
        calendarId: calendar.id,
        confirmDeleteItems: true,
      );
      if (mounted) _reload();
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(_errorMessage(error, 'Unable to delete collection.')),
          ),
        );
      }
    } finally {
      if (mounted) {
        setState(() {
          _updatingCalendarIds.remove(calendar.id);
        });
      }
    }
  }

  // ── Helpers ───────────────────────────────────────────────────────────────

  String _errorMessage(Object error, String fallback) {
    if (error is CaleeHubException && error.message.trim().isNotEmpty) {
      return error.message;
    }
    return fallback;
  }

  List<ClientCalendar> _byKind(
    List<ClientCalendar> calendars,
    String primaryKind,
  ) {
    return calendars.where((c) => c.primaryKind == primaryKind).toList();
  }

  // ── Row builder ───────────────────────────────────────────────────────────

  Widget _buildCollectionRow(ClientCalendar calendar) {
    final isUpdating = _updatingCalendarIds.contains(calendar.id);
    final canRename = calendar.capabilities.canEditAppearance && !isUpdating;
    final canDelete =
        (!calendar.readOnly || calendar.isSubscription) && !isUpdating;
    final dotColor = _collectionColor(calendar);

    final subtitleParts = <String>[
      if (calendar.serviceName.trim().isNotEmpty) calendar.serviceName,
      if (calendar.isSubscription) 'Connected calendar',
      if (calendar.readOnly) 'Read-only',
      if (calendar.appearanceMode == 'unsupported') calendarOwnerManagedMessage,
    ];

    Widget? trailing;
    if (isUpdating) {
      trailing = const SizedBox(
        width: 20,
        height: 20,
        child: CircularProgressIndicator(
          strokeWidth: 2,
          color: CaleeColors.textTertiary,
        ),
      );
    } else if (canRename || canDelete) {
      trailing = _CollectionMenuButton(
        onEdit: canRename ? () => _openEditSheet(calendar) : null,
        onDelete: canDelete ? () => _deleteCalendar(calendar) : null,
      );
    }

    return CaleeListRow(
      title: calendar.name,
      subtitle: subtitleParts.isEmpty ? null : subtitleParts.join(' · '),
      leading: CaleeColorDot(color: dotColor, size: 12),
      onTap: canRename ? () => _openEditSheet(calendar) : null,
      trailing: trailing,
    );
  }

  // ── Section builder ───────────────────────────────────────────────────────

  Widget _buildSection(
    BuildContext context, {
    required String title,
    required List<ClientCalendar> calendars,
    required String emptyMessage,
  }) {
    return CaleeSection(
      title: title,
      children: [
        if (calendars.isEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(
              horizontal: CaleeSpacing.md,
              vertical: CaleeSpacing.sm + 4,
            ),
            child: Text(
              emptyMessage,
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                color: CaleeColors.textSecondary,
              ),
            ),
          )
        else
          for (final calendar in calendars) _buildCollectionRow(calendar),
      ],
    );
  }

  // ── Build ─────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return CaleeScaffold(
      appBar: AppBar(
        title: const Text('Lists & calendars'),
        actions: [
          IconButton(
            icon: const Icon(Icons.add),
            tooltip: 'Add',
            onPressed: _openAddActions,
          ),
        ],
      ),
      body: FutureBuilder<ClientCalendarList>(
        future: _future,
        builder: (context, snapshot) {
          if (snapshot.connectionState == ConnectionState.waiting &&
              !snapshot.hasData) {
            return const Center(child: CircularProgressIndicator());
          }

          if (snapshot.hasError) {
            final error = snapshot.error;
            if (error is CaleeHubException &&
                isCalendarServiceConnectionCode(error.code)) {
              return CalendarServiceConnectionErrorState(
                errors: [CalendarServiceError.fromException(error)],
                onRetry: _reload,
              );
            }
            return CaleeEmptyState(
              icon: Icons.error_outline,
              title: 'Unable to load',
              body: _errorMessage(
                snapshot.error!,
                'Unable to load collections.',
              ),
              action: TextButton(
                onPressed: _reload,
                child: const Text('Try again'),
              ),
            );
          }

          final data = snapshot.data;
          final calendars = data?.calendars ?? const <ClientCalendar>[];
          final serviceErrors =
              data?.serviceErrors ?? const <CalendarServiceError>[];

          if (serviceErrors.isNotEmpty && calendars.isEmpty) {
            return CalendarServiceConnectionErrorState(
              errors: serviceErrors,
              onRetry: _reload,
            );
          }

          return Column(
            children: [
              if (serviceErrors.isNotEmpty)
                CalendarServiceWarningBanner(errors: serviceErrors),
              Expanded(
                child: RefreshIndicator(
                  onRefresh: () async => _reload(),
                  child: ListView(
                    padding: const EdgeInsets.fromLTRB(
                      CaleeSpacing.pagePadding,
                      CaleeSpacing.md,
                      CaleeSpacing.pagePadding,
                      96,
                    ),
                    children: [
                      _buildConnectedCalendarsSection(),
                      const SizedBox(height: CaleeSpacing.sectionSpacing),
                      _buildSection(
                        context,
                        title: 'Calendars',
                        calendars: _byKind(calendars, 'calendar'),
                        emptyMessage: 'No calendars yet.',
                      ),
                      const SizedBox(height: CaleeSpacing.sectionSpacing),
                      _buildSection(
                        context,
                        title: 'Task lists',
                        calendars: _byKind(calendars, 'tasks'),
                        emptyMessage: 'No task lists yet.',
                      ),
                      // UX-only: hide Chore lists for business/workspace
                      // accounts, matching Chores/Meals/People gating.
                      if (widget.isFamilyUxContext) ...[
                        const SizedBox(height: CaleeSpacing.sectionSpacing),
                        _buildSection(
                          context,
                          title: 'Chore lists',
                          calendars: _byKind(calendars, 'chores'),
                          emptyMessage: 'No chore lists yet.',
                        ),
                      ],
                    ],
                  ),
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}

// ─── _CollectionMenuButton ────────────────────────────────────────────────────

class _CollectionMenuButton extends StatelessWidget {
  const _CollectionMenuButton({required this.onEdit, required this.onDelete});

  final VoidCallback? onEdit;
  final VoidCallback? onDelete;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: () => CaleeActionSheet.show(
        context: context,
        actions: [
          if (onEdit != null)
            CaleeAction(
              label: 'Edit Name & Colour',
              icon: Icons.edit_outlined,
              onTap: onEdit!,
            ),
          if (onDelete != null)
            CaleeAction(
              label: 'Delete',
              icon: Icons.delete_outline,
              isDestructive: true,
              onTap: onDelete!,
            ),
        ],
      ),
      child: const Icon(
        Icons.more_horiz_rounded,
        color: CaleeColors.textTertiary,
        size: 22,
      ),
    );
  }
}

// ─── _CollectionFormContent ───────────────────────────────────────────────────

class _CollectionFormContent extends StatefulWidget {
  const _CollectionFormContent({
    required this.services,
    required this.onSubmit,
    this.initialName,
    this.initialColor,
    this.initialPrimaryKind = 'calendar',
    this.allowKindChange = true,
    this.availableKinds = const ['calendar', 'tasks', 'chores'],
    this.appearanceMode,
    this.sourceName,
  });

  final List<ClientService> services;
  final String? initialName;
  final String? initialColor;
  final String initialPrimaryKind;
  final bool allowKindChange;
  final List<String> availableKinds;

  /// Set only when editing an existing calendar (never for creation). Drives
  /// the appearance-editing explanatory copy and the "Name/Colour in Calee"
  /// field labels, matching CalendarDetailSheet's edit view.
  final String? appearanceMode;

  /// The provider/source's own name for the calendar being edited, shown
  /// alongside the name field when it differs from [initialName]. Only
  /// meaningful together with [appearanceMode].
  final String? sourceName;
  final Future<void> Function({
    required String name,
    required String primaryKind,
    required String? color,
    required ClientService? service,
  })
  onSubmit;

  @override
  State<_CollectionFormContent> createState() => _CollectionFormContentState();
}

class _CollectionFormContentState extends State<_CollectionFormContent> {
  final _formKey = GlobalKey<FormState>();
  late final TextEditingController _nameController;
  late final TextEditingController _colorController;

  ClientService? _selectedService;
  late String _selectedKind;
  bool _isSubmitting = false;

  @override
  void initState() {
    super.initState();
    _nameController = TextEditingController(text: widget.initialName ?? '');
    _colorController = TextEditingController(text: widget.initialColor ?? '');
    _selectedService = widget.services.isEmpty ? null : widget.services.first;
    _selectedKind = widget.initialPrimaryKind;
    _nameController.addListener(() => setState(() {}));
    _colorController.addListener(() => setState(() {}));
  }

  @override
  void dispose() {
    _nameController.dispose();
    _colorController.dispose();
    super.dispose();
  }

  String _kindLabel(String kind) {
    switch (kind) {
      case 'tasks':
        return 'Task list';
      case 'chores':
        return 'Chore list';
      default:
        return 'Calendar';
    }
  }

  /// True when editing an existing calendar and neither the name nor the
  /// colour differs from what the form was opened with — there is nothing
  /// to send, so Save stays disabled. Never true during creation.
  bool get _isNoOpEdit {
    if (widget.appearanceMode == null) return false;
    return buildCalendarAppearancePatch(
          originalName: widget.initialName ?? '',
          originalColor: widget.initialColor,
          nextName: _nameController.text,
          nextColor: _colorController.text,
        ) ==
        null;
  }

  Future<void> _submit() async {
    if (_isSubmitting || !_formKey.currentState!.validate()) return;

    setState(() => _isSubmitting = true);

    try {
      await widget.onSubmit(
        name: _nameController.text.trim(),
        primaryKind: _selectedKind,
        color: _colorController.text.trim().isEmpty
            ? null
            : _colorController.text.trim(),
        service: _selectedService,
      );
      if (mounted) Navigator.of(context).pop(true);
    } catch (error) {
      if (mounted) {
        setState(() => _isSubmitting = false);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              error is CaleeHubException
                  ? error.message
                  : 'Unable to save collection.',
            ),
          ),
        );
      }
    }
  }

  /// Explanatory copy for the calendar's appearanceMode, shown only when
  /// editing an existing calendar (never during creation).
  String? get _appearanceEditCopy {
    final mode = widget.appearanceMode;
    return mode == null ? null : calendarAppearanceEditCopy(mode);
  }

  /// Preserves the provider/source's own name for the calendar being
  /// edited, whenever it differs from the name the form was opened with.
  String? get _sourceNameCaption {
    if (widget.appearanceMode == null) return null;
    final sourceName = widget.sourceName?.trim() ?? '';
    if (sourceName.isEmpty || sourceName == widget.initialName) return null;
    return 'Originally "$sourceName" at the source.';
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isEditingExisting = widget.appearanceMode != null;

    return Form(
      key: _formKey,
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (_appearanceEditCopy != null) ...[
              Text(
                _appearanceEditCopy!,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: CaleeColors.textSecondary,
                ),
              ),
              const SizedBox(height: CaleeSpacing.xs),
            ],
            if (_sourceNameCaption != null) ...[
              Text(
                _sourceNameCaption!,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: CaleeColors.textTertiary,
                ),
              ),
              const SizedBox(height: CaleeSpacing.xs),
            ],
            if (_appearanceEditCopy != null || _sourceNameCaption != null)
              const SizedBox(height: CaleeSpacing.sm),
            if (widget.services.length >= 2) ...[
              DropdownButtonFormField<ClientService>(
                initialValue: _selectedService,
                decoration: const InputDecoration(labelText: 'Service'),
                items: [
                  for (final service in widget.services)
                    DropdownMenuItem(
                      value: service,
                      child: Text(service.displayName),
                    ),
                ],
                onChanged: _isSubmitting
                    ? null
                    : (service) => setState(() => _selectedService = service),
                validator: (service) =>
                    service == null ? 'Choose a service' : null,
              ),
              const SizedBox(height: CaleeSpacing.sm + 4),
            ],
            TextFormField(
              controller: _nameController,
              enabled: !_isSubmitting,
              autofocus: true,
              decoration: InputDecoration(
                labelText: isEditingExisting ? 'Name in Calee' : 'Name',
              ),
              validator: (value) =>
                  (value ?? '').trim().isEmpty ? 'Enter a name' : null,
            ),
            const SizedBox(height: CaleeSpacing.sm + 4),
            DropdownButtonFormField<String>(
              initialValue: _selectedKind,
              decoration: const InputDecoration(labelText: 'Type'),
              items: [
                for (final kind in widget.availableKinds)
                  DropdownMenuItem(value: kind, child: Text(_kindLabel(kind))),
              ],
              onChanged: !widget.allowKindChange || _isSubmitting
                  ? null
                  : (kind) {
                      if (kind != null) setState(() => _selectedKind = kind);
                    },
            ),
            if (!widget.allowKindChange) ...[
              const SizedBox(height: CaleeSpacing.xs),
              Text(
                'Type cannot be changed after creation. '
                'Current type: ${_kindLabel(_selectedKind)}.',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: CaleeColors.textSecondary,
                ),
              ),
            ],
            const SizedBox(height: CaleeSpacing.md),
            Text(
              'Color',
              style: theme.textTheme.bodySmall?.copyWith(
                color: CaleeColors.textSecondary,
              ),
            ),
            const SizedBox(height: CaleeSpacing.sm),
            CaleeColorPalettePicker(
              selectedHex: _colorController.text,
              onSelected: (hex) => setState(() => _colorController.text = hex),
            ),
            const SizedBox(height: CaleeSpacing.sm + 4),
            TextFormField(
              controller: _colorController,
              enabled: !_isSubmitting,
              decoration: InputDecoration(
                labelText: isEditingExisting
                    ? 'Colour in Calee'
                    : 'Custom color',
                hintText: '#8BC34A',
              ),
              validator: (value) {
                final color = (value ?? '').trim();
                if (color.isEmpty) return null;
                final normalized = color.startsWith('#') ? color : '#$color';
                if (!RegExp(r'^#[0-9A-Fa-f]{6}$').hasMatch(normalized)) {
                  return 'Use a color like #8BC34A';
                }
                return null;
              },
            ),
            const SizedBox(height: CaleeSpacing.md),
            FilledButton(
              onPressed: _isSubmitting || _isNoOpEdit ? null : _submit,
              child: _isSubmitting
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Text('Save'),
            ),
          ],
        ),
      ),
    );
  }
}

// ─── _SubscriptionFormContent ─────────────────────────────────────────────────

class _SubscriptionFormContent extends StatefulWidget {
  const _SubscriptionFormContent({
    required this.services,
    required this.onCheck,
    required this.onSubmit,
    this.initialName,
    this.initialUrl,
  });

  final List<ClientService> services;
  final String? initialName;
  final String? initialUrl;

  /// Asks the backend to fetch and validate the link. Never called with a
  /// null service — the caller resolves/guards service selection first.
  final Future<CalendarSubscriptionValidationResult> Function({
    required String name,
    required String url,
    required ClientService service,
  })
  onCheck;
  final Future<void> Function({
    required String name,
    required String url,
    required String? color,
    required ClientService? service,
  })
  onSubmit;

  @override
  State<_SubscriptionFormContent> createState() =>
      _SubscriptionFormContentState();
}

class _SubscriptionFormContentState extends State<_SubscriptionFormContent> {
  final _formKey = GlobalKey<FormState>();
  late final TextEditingController _nameController;
  late final TextEditingController _urlController;
  final _colorController = TextEditingController(text: '#007AFF');

  ClientService? _selectedService;
  bool _isSubmitting = false;
  bool _isChecking = false;
  String? _checkError;
  CalendarSubscriptionValidationResult? _validationResult;

  // Snapshot of what the last check (successful or not) was run against, so
  // an edit to name/url/service can invalidate a now-stale check result.
  String? _checkedName;
  String? _checkedUrl;
  String? _checkedServiceId;

  @override
  void initState() {
    super.initState();
    _nameController = TextEditingController(text: widget.initialName ?? '');
    _urlController = TextEditingController(text: widget.initialUrl ?? '');
    _selectedService = widget.services.isEmpty ? null : widget.services.first;
    _colorController.addListener(() => setState(() {}));
    _nameController.addListener(_clearStaleCheck);
    _urlController.addListener(_clearStaleCheck);
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
      setState(() => _checkError = 'Choose a service');
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
      final result = await widget.onCheck(
        name: name,
        url: url,
        service: service,
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
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _isChecking = false;
        _validationResult = null;
        _checkError = error is CaleeHubException
            ? error.message
            : 'Unable to check this calendar link. Please try again.';
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

    setState(() => _isSubmitting = true);

    try {
      await widget.onSubmit(
        name: _nameController.text.trim(),
        url: validation.normalizedUrl ?? _urlController.text.trim(),
        color: _colorController.text.trim().isEmpty
            ? null
            : _colorController.text.trim(),
        service: _selectedService,
      );
      if (mounted) Navigator.of(context).pop(true);
    } catch (error) {
      if (mounted) {
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
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final busy = _isChecking || _isSubmitting;
    final isValidated = _validationResult?.valid == true;

    return Form(
      key: _formKey,
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (widget.services.length >= 2) ...[
              DropdownButtonFormField<ClientService>(
                initialValue: _selectedService,
                decoration: const InputDecoration(labelText: 'Service'),
                items: [
                  for (final service in widget.services)
                    DropdownMenuItem(
                      value: service,
                      child: Text(service.displayName),
                    ),
                ],
                onChanged: busy
                    ? null
                    : (service) => setState(() {
                        _selectedService = service;
                        if (_hasStaleCheck) {
                          _validationResult = null;
                          _checkError = null;
                        }
                      }),
                validator: (service) =>
                    service == null ? 'Choose a service' : null,
              ),
              const SizedBox(height: CaleeSpacing.sm + 4),
            ],
            TextFormField(
              controller: _nameController,
              enabled: !busy,
              autofocus: true,
              textCapitalization: TextCapitalization.words,
              decoration: const InputDecoration(
                labelText: 'Calendar name',
                hintText: 'Shared calendar',
              ),
              validator: (value) {
                final name = (value ?? '').trim();
                if (name.isEmpty) return 'Enter a name';
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
              decoration: const InputDecoration(
                labelText: 'Calendar link',
                hintText: 'https://example.com/calendar.ics',
              ),
              validator: (value) {
                final url = (value ?? '').trim();
                if (url.isEmpty) return 'Enter a calendar link';
                if (!_isAllowedSubscriptionUrl(url)) {
                  return 'This does not look like a calendar link. Paste a calendar link that starts with https:// or webcal://.';
                }
                return null;
              },
            ),
            const SizedBox(height: CaleeSpacing.xs),
            Text(
              'Connected calendars are read-only in Calee. To change events, use the original calendar app or provider.',
              style: theme.textTheme.bodySmall?.copyWith(
                color: CaleeColors.textSecondary,
              ),
            ),
            const SizedBox(height: CaleeSpacing.md),
            Text(
              'Color',
              style: theme.textTheme.bodySmall?.copyWith(
                color: CaleeColors.textSecondary,
              ),
            ),
            const SizedBox(height: CaleeSpacing.sm),
            CaleeColorPalettePicker(
              selectedHex: _colorController.text,
              onSelected: (hex) => setState(() => _colorController.text = hex),
            ),
            const SizedBox(height: CaleeSpacing.sm + 4),
            TextFormField(
              controller: _colorController,
              enabled: !busy,
              decoration: const InputDecoration(
                labelText: 'Custom color',
                hintText: '#007AFF',
              ),
              validator: (value) {
                final color = (value ?? '').trim();
                if (color.isEmpty) return null;
                final normalized = color.startsWith('#') ? color : '#$color';
                if (!RegExp(r'^#[0-9A-Fa-f]{6}$').hasMatch(normalized)) {
                  return 'Use a color like #007AFF';
                }
                return null;
              },
            ),
            const SizedBox(height: CaleeSpacing.md),
            if (_checkError != null) ...[
              _CalendarCheckErrorBanner(message: _checkError!),
              const SizedBox(height: CaleeSpacing.sm + 4),
            ],
            if (isValidated) ...[
              _CalendarCheckPreviewCard(preview: _validationResult!.preview),
              const SizedBox(height: CaleeSpacing.sm + 4),
            ],
            FilledButton(
              onPressed: busy ? null : (isValidated ? _submit : _checkCalendar),
              child: busy
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : Text(isValidated ? 'Add to Calee' : 'Check calendar'),
            ),
          ],
        ),
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

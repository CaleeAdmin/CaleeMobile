import 'package:flutter/material.dart';

import '../../data/api/calee_hub_client.dart';
import '../../data/models/client_bootstrap.dart';
import '../../data/models/client_calendar.dart';
import '../../ui/calee_design.dart';

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
    this.initialCreateKind,
    this.autoOpenCreate = false,
    this.autoOpenSubscribe = false,
    super.key,
  });

  final CaleeHubClient hubClient;
  final String accessToken;
  final List<ClientService> services;
  final String? initialCreateKind;
  final bool autoOpenCreate;
  final bool autoOpenSubscribe;

  @override
  State<CalendarCollectionsPage> createState() =>
      _CalendarCollectionsPageState();
}

class _CalendarCollectionsPageState extends State<CalendarCollectionsPage> {
  late Future<ClientCalendarList> _future;
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

    if (widget.autoOpenCreate || widget.autoOpenSubscribe) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        if (widget.autoOpenSubscribe) {
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

  void _reload() {
    setState(() {
      _future = _loadCalendars();
    });
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
          label: 'Subscribe from link',
          icon: Icons.link_rounded,
          onTap: _openSubscribeSheet,
        ),
      ],
    );
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
      title: 'Subscribe from link',
      child: _SubscriptionFormContent(
        services: services,
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
    if ((!calendar.isSubscription && calendar.readOnly) ||
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
        services: const [],
        onSubmit:
            ({
              required String name,
              required String primaryKind,
              required String? color,
              required ClientService? service,
            }) async {
              await widget.hubClient.updateCalendar(
                accessToken: widget.accessToken,
                calendarId: calendar.id,
                name: name,
                color: color,
              );
            },
      ),
    );

    if (updated == true && mounted) _reload();
  }

  // ── Delete ────────────────────────────────────────────────────────────────

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

    // Keep a custom AlertDialog so the full item-count preview is clearly
    // shown — CaleeDestructiveDialog's single-line body is too limited here.
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete collection permanently?'),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('This will permanently delete "${calendar.name}".'),
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
              const Text(
                'Deleting this collection also deletes the data stored inside it. This cannot be undone.',
              ),
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
              'Delete everything',
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
    final canRename = !calendar.readOnly && !isUpdating;
    final canDelete =
        (!calendar.readOnly || calendar.isSubscription) && !isUpdating;
    final dotColor = _collectionColor(calendar);

    final subtitleParts = <String>[
      if (calendar.serviceName.trim().isNotEmpty) calendar.serviceName,
      if (calendar.isSubscription) 'Subscription',
      if (calendar.readOnly) 'Read-only',
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

          final calendars =
              snapshot.data?.calendars ?? const <ClientCalendar>[];

          return RefreshIndicator(
            onRefresh: () async => _reload(),
            child: ListView(
              padding: const EdgeInsets.fromLTRB(
                CaleeSpacing.pagePadding,
                CaleeSpacing.md,
                CaleeSpacing.pagePadding,
                96,
              ),
              children: [
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
                const SizedBox(height: CaleeSpacing.sectionSpacing),
                _buildSection(
                  context,
                  title: 'Chore lists',
                  calendars: _byKind(calendars, 'chores'),
                  emptyMessage: 'No chore lists yet.',
                ),
              ],
            ),
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
              label: 'Rename',
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
  });

  final List<ClientService> services;
  final String? initialName;
  final String? initialColor;
  final String initialPrimaryKind;
  final bool allowKindChange;
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
    // Rebuild whenever the color text changes so palette swatches update.
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

  bool _isPaletteColorSelected(String hex) {
    return _colorController.text.trim().toUpperCase() == hex.toUpperCase();
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

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Form(
      key: _formKey,
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // Service picker — only shown when creating
            if (widget.services.isNotEmpty) ...[
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

            // Name
            TextFormField(
              controller: _nameController,
              enabled: !_isSubmitting,
              autofocus: true,
              decoration: const InputDecoration(labelText: 'Name'),
              validator: (value) =>
                  (value ?? '').trim().isEmpty ? 'Enter a name' : null,
            ),
            const SizedBox(height: CaleeSpacing.sm + 4),

            // Type
            DropdownButtonFormField<String>(
              initialValue: _selectedKind,
              decoration: const InputDecoration(labelText: 'Type'),
              items: const [
                DropdownMenuItem(value: 'calendar', child: Text('Calendar')),
                DropdownMenuItem(value: 'tasks', child: Text('Task list')),
                DropdownMenuItem(value: 'chores', child: Text('Chore list')),
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

            // Color palette
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
                  _ColorSwatch(
                    hex: hex,
                    color: color,
                    isSelected: _isPaletteColorSelected(hex),
                    onTap: () => setState(() => _colorController.text = hex),
                  ),
              ],
            ),
            const SizedBox(height: CaleeSpacing.sm + 4),

            // Custom hex field
            TextFormField(
              controller: _colorController,
              enabled: !_isSubmitting,
              decoration: const InputDecoration(
                labelText: 'Custom color',
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

            // Save button
            FilledButton(
              onPressed: _isSubmitting ? null : _submit,
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
    required this.onSubmit,
  });

  final List<ClientService> services;
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

  ClientService? _selectedService;
  bool _isSubmitting = false;

  @override
  void initState() {
    super.initState();
    _selectedService = widget.services.isEmpty ? null : widget.services.first;
    _colorController.addListener(() => setState(() {}));
  }

  @override
  void dispose() {
    _nameController.dispose();
    _urlController.dispose();
    _colorController.dispose();
    super.dispose();
  }

  bool _isPaletteColorSelected(String hex) {
    return _colorController.text.trim().toUpperCase() == hex.toUpperCase();
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

    setState(() => _isSubmitting = true);

    try {
      await widget.onSubmit(
        name: _nameController.text.trim(),
        url: _urlController.text.trim(),
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
                  : 'Unable to subscribe from this link.',
            ),
          ),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Form(
      key: _formKey,
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
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
            TextFormField(
              controller: _nameController,
              enabled: !_isSubmitting,
              autofocus: true,
              textCapitalization: TextCapitalization.words,
              decoration: const InputDecoration(
                labelText: 'Name',
                hintText: 'School calendar',
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
              enabled: !_isSubmitting,
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
                  return 'Use a valid http, https, or webcal link';
                }
                return null;
              },
            ),
            const SizedBox(height: CaleeSpacing.xs),
            Text(
              'Subscribed calendars are read-only and stay linked to the source.',
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
            Wrap(
              spacing: CaleeSpacing.sm,
              runSpacing: CaleeSpacing.sm,
              children: [
                for (final (hex, color) in _colorPalette)
                  _ColorSwatch(
                    hex: hex,
                    color: color,
                    isSelected: _isPaletteColorSelected(hex),
                    onTap: () => setState(() => _colorController.text = hex),
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
            FilledButton(
              onPressed: _isSubmitting ? null : _submit,
              child: _isSubmitting
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Text('Subscribe'),
            ),
          ],
        ),
      ),
    );
  }
}

// ─── _ColorSwatch ─────────────────────────────────────────────────────────────

class _ColorSwatch extends StatelessWidget {
  const _ColorSwatch({
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

import 'package:flutter/material.dart';

import '../../data/api/calee_hub_client.dart';
import '../../data/models/client_bootstrap.dart';
import '../../data/models/client_calendar.dart';

class CalendarCollectionsPage extends StatefulWidget {
  const CalendarCollectionsPage({
    required this.hubClient,
    required this.accessToken,
    required this.services,
    this.initialCreateKind,
    this.autoOpenCreate = false,
    super.key,
  });

  final CaleeHubClient hubClient;
  final String accessToken;
  final List<ClientService> services;
  final String? initialCreateKind;
  final bool autoOpenCreate;

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
          (service) =>
              service.serviceType == 'nextcloud_calendar' &&
              service.hasConnectedCalendarCredential,
        )
        .toList();
  }

  @override
  void initState() {
    super.initState();
    _future = _loadCalendars();

    if (widget.autoOpenCreate) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) {
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

  Future<void> _openCreateSheet() async {
    final services = _calendarServices;

    if (services.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
            content: Text('No connected calendar service is available.')),
      );
      return;
    }

    final created = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      builder: (context) => _CollectionFormSheet(
        title: 'Create list or calendar',
        services: services,
        initialPrimaryKind: widget.initialCreateKind ?? 'calendar',
        onSubmit: ({
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

    if (created == true && mounted) {
      _reload();
    }
  }

  Future<void> _openEditSheet(ClientCalendar calendar) async {
    if (calendar.readOnly || _updatingCalendarIds.contains(calendar.id)) {
      return;
    }

    final updated = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      builder: (context) => _CollectionFormSheet(
        title: 'Edit list or calendar',
        initialName: calendar.name,
        initialColor: calendar.color,
        initialPrimaryKind: calendar.primaryKind,
        allowKindChange: false,
        services: const [],
        onSubmit: ({
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

    if (updated == true && mounted) {
      _reload();
    }
  }

  Future<void> _deleteCalendar(ClientCalendar calendar) async {
    if (calendar.readOnly || _updatingCalendarIds.contains(calendar.id)) {
      return;
    }

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete list or calendar?'),
        content: Text(
          'This will permanently delete "${calendar.name}" and all items inside it.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Delete everything'),
          ),
        ],
      ),
    );

    if (confirmed != true || !mounted) {
      return;
    }

    setState(() {
      _updatingCalendarIds.add(calendar.id);
    });

    try {
      await widget.hubClient.deleteCalendar(
        accessToken: widget.accessToken,
        calendarId: calendar.id,
        confirmDeleteItems: true,
      );

      if (mounted) {
        _reload();
      }
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
    return calendars
        .where((calendar) => calendar.primaryKind == primaryKind)
        .toList();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Lists & calendars'),
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _openCreateSheet,
        icon: const Icon(Icons.add),
        label: const Text('Create'),
      ),
      body: FutureBuilder<ClientCalendarList>(
        future: _future,
        builder: (context, snapshot) {
          if (snapshot.connectionState == ConnectionState.waiting &&
              !snapshot.hasData) {
            return const Center(child: CircularProgressIndicator());
          }

          if (snapshot.hasError) {
            return Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Text(
                  _errorMessage(snapshot.error!, 'Unable to load collections.'),
                  textAlign: TextAlign.center,
                ),
              ),
            );
          }

          final calendars =
              snapshot.data?.calendars ?? const <ClientCalendar>[];

          return RefreshIndicator(
            onRefresh: () async => _reload(),
            child: ListView(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 96),
              children: [
                _CollectionSection(
                  title: 'Calendars',
                  emptyMessage: 'No calendars yet.',
                  calendars: _byKind(calendars, 'calendar'),
                  updatingCalendarIds: _updatingCalendarIds,
                  onEdit: _openEditSheet,
                  onDelete: _deleteCalendar,
                ),
                const SizedBox(height: 12),
                _CollectionSection(
                  title: 'Task lists',
                  emptyMessage: 'No task lists yet.',
                  calendars: _byKind(calendars, 'tasks'),
                  updatingCalendarIds: _updatingCalendarIds,
                  onEdit: _openEditSheet,
                  onDelete: _deleteCalendar,
                ),
                const SizedBox(height: 12),
                _CollectionSection(
                  title: 'Chore lists',
                  emptyMessage: 'No chore lists yet.',
                  calendars: _byKind(calendars, 'chores'),
                  updatingCalendarIds: _updatingCalendarIds,
                  onEdit: _openEditSheet,
                  onDelete: _deleteCalendar,
                ),
              ],
            ),
          );
        },
      ),
    );
  }
}

class _CollectionSection extends StatelessWidget {
  const _CollectionSection({
    required this.title,
    required this.emptyMessage,
    required this.calendars,
    required this.updatingCalendarIds,
    required this.onEdit,
    required this.onDelete,
  });

  final String title;
  final String emptyMessage;
  final List<ClientCalendar> calendars;
  final Set<String> updatingCalendarIds;
  final ValueChanged<ClientCalendar> onEdit;
  final ValueChanged<ClientCalendar> onDelete;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
              child: Text(
                title,
                style: Theme.of(context).textTheme.titleMedium,
              ),
            ),
            if (calendars.isEmpty)
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
                child: Text(emptyMessage),
              ),
            for (final calendar in calendars)
              _CollectionTile(
                calendar: calendar,
                isUpdating: updatingCalendarIds.contains(calendar.id),
                onEdit: () => onEdit(calendar),
                onDelete: () => onDelete(calendar),
              ),
          ],
        ),
      ),
    );
  }
}

class _CollectionTile extends StatelessWidget {
  const _CollectionTile({
    required this.calendar,
    required this.isUpdating,
    required this.onEdit,
    required this.onDelete,
  });

  final ClientCalendar calendar;
  final bool isUpdating;
  final VoidCallback onEdit;
  final VoidCallback onDelete;

  IconData get _icon {
    if (calendar.isTaskKind) {
      return Icons.checklist_outlined;
    }

    if (calendar.isChoreKind) {
      return Icons.family_restroom_outlined;
    }

    return Icons.calendar_month_outlined;
  }

  @override
  Widget build(BuildContext context) {
    final disabled = calendar.readOnly || isUpdating;

    return ListTile(
      leading: CircleAvatar(
        child: isUpdating
            ? const SizedBox(
                height: 18,
                width: 18,
                child: CircularProgressIndicator(strokeWidth: 2),
              )
            : Icon(_icon),
      ),
      title: Text(calendar.name),
      subtitle: Text(
        [
          calendar.serviceName,
          if (calendar.color != null && calendar.color!.trim().isNotEmpty)
            calendar.color!,
          if (calendar.readOnly) 'Read-only',
        ].where((value) => value.trim().isNotEmpty).join(' · '),
      ),
      trailing: PopupMenuButton<String>(
        enabled: !disabled,
        onSelected: (value) {
          if (value == 'edit') {
            onEdit();
          }

          if (value == 'delete') {
            onDelete();
          }
        },
        itemBuilder: (context) => const [
          PopupMenuItem(
            value: 'edit',
            child: Text('Rename'),
          ),
          PopupMenuItem(
            value: 'delete',
            child: Text('Delete'),
          ),
        ],
      ),
    );
  }
}

class _CollectionFormSheet extends StatefulWidget {
  const _CollectionFormSheet({
    required this.title,
    required this.services,
    required this.onSubmit,
    this.initialName,
    this.initialColor,
    this.initialPrimaryKind = 'calendar',
    this.allowKindChange = true,
  });

  final String title;
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
  }) onSubmit;

  @override
  State<_CollectionFormSheet> createState() => _CollectionFormSheetState();
}

class _CollectionFormSheetState extends State<_CollectionFormSheet> {
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

  Future<void> _submit() async {
    if (_isSubmitting || !_formKey.currentState!.validate()) {
      return;
    }

    setState(() {
      _isSubmitting = true;
    });

    try {
      await widget.onSubmit(
        name: _nameController.text.trim(),
        primaryKind: _selectedKind,
        color: _colorController.text.trim().isEmpty
            ? null
            : _colorController.text.trim(),
        service: _selectedService,
      );

      if (mounted) {
        Navigator.of(context).pop(true);
      }
    } catch (error) {
      if (mounted) {
        setState(() {
          _isSubmitting = false;
        });

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
    final bottomInset = MediaQuery.viewInsetsOf(context).bottom;

    return SafeArea(
      child: Padding(
        padding: EdgeInsets.fromLTRB(16, 16, 16, 16 + bottomInset),
        child: Form(
          key: _formKey,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  widget.title,
                  style: Theme.of(context).textTheme.titleLarge,
                ),
                const SizedBox(height: 16),
                if (widget.services.isNotEmpty) ...[
                  DropdownButtonFormField<ClientService>(
                    initialValue: _selectedService,
                    decoration: const InputDecoration(
                      labelText: 'Service',
                      border: OutlineInputBorder(),
                    ),
                    items: [
                      for (final service in widget.services)
                        DropdownMenuItem(
                          value: service,
                          child: Text(service.displayName),
                        ),
                    ],
                    onChanged: _isSubmitting
                        ? null
                        : (service) {
                            setState(() {
                              _selectedService = service;
                            });
                          },
                    validator: (service) {
                      if (service == null) {
                        return 'Choose a service';
                      }

                      return null;
                    },
                  ),
                  const SizedBox(height: 12),
                ],
                TextFormField(
                  controller: _nameController,
                  enabled: !_isSubmitting,
                  autofocus: true,
                  decoration: const InputDecoration(
                    labelText: 'Name',
                    border: OutlineInputBorder(),
                  ),
                  validator: (value) {
                    if ((value ?? '').trim().isEmpty) {
                      return 'Enter a name';
                    }

                    return null;
                  },
                ),
                const SizedBox(height: 12),
                DropdownButtonFormField<String>(
                  initialValue: _selectedKind,
                  decoration: const InputDecoration(
                    labelText: 'Type',
                    border: OutlineInputBorder(),
                  ),
                  items: const [
                    DropdownMenuItem(
                      value: 'calendar',
                      child: Text('Calendar'),
                    ),
                    DropdownMenuItem(
                      value: 'tasks',
                      child: Text('Task list'),
                    ),
                    DropdownMenuItem(
                      value: 'chores',
                      child: Text('Chore list'),
                    ),
                  ],
                  onChanged: !widget.allowKindChange || _isSubmitting
                      ? null
                      : (kind) {
                          if (kind != null) {
                            setState(() {
                              _selectedKind = kind;
                            });
                          }
                        },
                ),
                if (!widget.allowKindChange) ...[
                  const SizedBox(height: 8),
                  Text(
                    'Type cannot be changed after creation. Current type: ${_kindLabel(_selectedKind)}.',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ],
                const SizedBox(height: 12),
                TextFormField(
                  controller: _colorController,
                  enabled: !_isSubmitting,
                  decoration: const InputDecoration(
                    labelText: 'Color',
                    hintText: '#8BC34A',
                    border: OutlineInputBorder(),
                  ),
                  validator: (value) {
                    final color = (value ?? '').trim();

                    if (color.isEmpty) {
                      return null;
                    }

                    final normalized =
                        color.startsWith('#') ? color : '#$color';
                    final valid =
                        RegExp(r'^#[0-9A-Fa-f]{6}$').hasMatch(normalized);

                    if (!valid) {
                      return 'Use a color like #8BC34A';
                    }

                    return null;
                  },
                ),
                const SizedBox(height: 16),
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
        ),
      ),
    );
  }
}

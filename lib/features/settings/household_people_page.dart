import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

import '../../data/api/calee_hub_client.dart';
import '../../data/models/client_bootstrap.dart';
import '../../data/models/client_person.dart';
import '../../ui/calee_theme.dart';
import '../../ui/calee_widgets.dart';
import '../people/add_person_sheet.dart';

class HouseholdPeoplePage extends StatefulWidget {
  const HouseholdPeoplePage({
    required this.hubClient,
    required this.accessToken,
    required this.households,
    this.initialHouseholdId,
    this.autoOpenCreate = false,
    super.key,
  });

  final CaleeHubClient hubClient;
  final String accessToken;
  final List<ClientContext> households;
  final String? initialHouseholdId;
  final bool autoOpenCreate;

  @override
  State<HouseholdPeoplePage> createState() => _HouseholdPeoplePageState();
}

class _HouseholdPeoplePageState extends State<HouseholdPeoplePage> {
  ClientContext? _selectedHousehold;
  Future<ClientPersonList>? _future;
  bool _didAutoOpen = false;

  @override
  void initState() {
    super.initState();
    if (widget.households.isNotEmpty) {
      final byId = widget.initialHouseholdId != null
          ? widget.households.cast<ClientContext?>().firstWhere(
              (h) => h!.id == widget.initialHouseholdId,
              orElse: () => null,
            )
          : null;
      _selectedHousehold = byId ?? widget.households.first;
      _future = _loadPeople();
    }

    if (widget.autoOpenCreate) {
      SchedulerBinding.instance.addPostFrameCallback((_) {
        if (mounted && !_didAutoOpen && _selectedHousehold != null) {
          _didAutoOpen = true;
          _openCreateSheet();
        }
      });
    }
  }

  Future<ClientPersonList> _loadPeople() {
    final household = _selectedHousehold;
    if (household == null) {
      return Future.value(const ClientPersonList(people: []));
    }

    return widget.hubClient.people(
      accessToken: widget.accessToken,
      householdId: household.id,
    );
  }

  void _reload() {
    setState(() {
      _future = _loadPeople();
    });
  }

  Future<void> _openCreateSheet() async {
    final household = _selectedHousehold;
    if (household == null) return;

    final saved = await CaleeBottomSheet.show<bool>(
      context: context,
      title: 'Add person',
      child: AddPersonSheet(
        onAdd: (name) => widget.hubClient.createPerson(
          accessToken: widget.accessToken,
          householdId: household.id,
          displayName: name,
        ),
      ),
    );

    if (saved == true && mounted) {
      _reload();
    }
  }

  Future<void> _openEditSheet(ClientPerson person) async {
    final household = _selectedHousehold;
    if (household == null) return;

    final saved = await CaleeBottomSheet.show<bool>(
      context: context,
      title: 'Edit person',
      child: _PersonFormContent(
        initialPerson: person,
        submitLabel: 'Save changes',
        onSubmit:
            ({
              required String displayName,
              required String? avatarColor,
              required String role,
              required int sortOrder,
            }) async {
              await widget.hubClient.updatePerson(
                accessToken: widget.accessToken,
                householdId: household.id,
                personId: person.id,
                displayName: displayName,
                avatarColor: avatarColor,
                role: role,
                sortOrder: sortOrder,
              );
            },
      ),
    );

    if (saved == true && mounted) {
      _reload();
    }
  }

  Future<void> _confirmArchive(ClientPerson person) async {
    final household = _selectedHousehold;
    if (household == null) return;

    final confirmed = await CaleeDestructiveDialog.show(
      context: context,
      title: 'Archive person?',
      body:
          'Archive "${person.displayName}"? They will be hidden from the active people list.',
      confirmLabel: 'Archive',
    );

    if (!confirmed) return;

    try {
      await widget.hubClient.archivePerson(
        accessToken: widget.accessToken,
        householdId: household.id,
        personId: person.id,
      );

      if (!mounted) return;
      _reload();
    } catch (error) {
      if (!mounted) return;
      _showError(error);
    }
  }

  void _openPersonActions(ClientPerson person) {
    CaleeActionSheet.show(
      context: context,
      title: person.displayName,
      actions: [
        CaleeAction(
          label: 'Edit person',
          icon: Icons.edit_outlined,
          onTap: () => _openEditSheet(person),
        ),
        CaleeAction(
          label: 'Archive person',
          icon: Icons.archive_outlined,
          isDestructive: true,
          onTap: () => _confirmArchive(person),
        ),
      ],
    );
  }

  void _showError(Object error) {
    const friendly = 'Could not load people. Please try again.';
    final message = kDebugMode && error is CaleeHubException
        ? '$friendly\nDebug: ${error.debugSummary}'
        : friendly;

    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  Widget build(BuildContext context) {
    final household = _selectedHousehold;

    return CaleeScaffold(
      appBar: AppBar(title: const Text('People')),
      floatingActionButton: household == null
          ? null
          : FloatingActionButton(
              heroTag: 'settings_add_family_member_fab',
              onPressed: _openCreateSheet,
              child: const Icon(Icons.add),
            ),
      body: household == null
          ? const _EmptyPeopleState(
              title: 'No people group yet',
              message:
                  'People can be managed after your Calee account is ready.',
            )
          : ListView(
              padding: const EdgeInsets.symmetric(
                horizontal: CaleeSpacing.pagePadding,
                vertical: CaleeSpacing.md,
              ),
              children: [
                if (widget.households.length > 1) ...[
                  CaleeSection(
                    title: 'Group',
                    children: [
                      CaleeSectionDropdownRow<String>(
                        label: 'Group',
                        value: household.id,
                        items: [
                          for (final item in widget.households)
                            DropdownMenuItem<String>(
                              value: item.id,
                              child: Text(
                                item.name.isNotEmpty
                                    ? item.name
                                    : 'Unnamed group',
                              ),
                            ),
                        ],
                        onChanged: (value) {
                          final next = widget.households
                              .where((item) => item.id == value)
                              .cast<ClientContext?>()
                              .firstOrNull;

                          if (next == null) return;

                          setState(() {
                            _selectedHousehold = next;
                            _future = _loadPeople();
                          });
                        },
                      ),
                    ],
                  ),
                  const SizedBox(height: CaleeSpacing.sectionSpacing),
                ],
                FutureBuilder<ClientPersonList>(
                  future: _future,
                  builder: (context, snapshot) {
                    if (snapshot.connectionState == ConnectionState.waiting) {
                      return const Padding(
                        padding: EdgeInsets.only(top: CaleeSpacing.xl),
                        child: Center(child: CircularProgressIndicator()),
                      );
                    }

                    if (snapshot.hasError) {
                      return CaleeSection(
                        title: 'People',
                        children: [
                          _ErrorRow(
                            message: snapshot.error is CaleeHubException
                                ? (snapshot.error as CaleeHubException).message
                                : 'Could not load people.',
                            onRetry: _reload,
                          ),
                        ],
                      );
                    }

                    final people = snapshot.data?.people ?? const [];

                    return CaleeSection(
                      title: 'People',
                      children: [
                        CaleeListRow(
                          title: 'Add person',
                          subtitle: 'Add a person used for tasks and chores',
                          leading: const Icon(
                            Icons.person_add_alt_1_outlined,
                            size: 20,
                            color: CaleeColors.primary,
                          ),
                          onTap: _openCreateSheet,
                        ),
                        if (people.isEmpty)
                          const _EmptyRowText('No people yet.')
                        else
                          for (final person in people)
                            CaleeListRow(
                              title: person.displayName.isNotEmpty
                                  ? person.displayName
                                  : 'Unnamed person',
                              subtitle:
                                  '${_capitalise(person.role)} · ${_capitalise(person.status)}',
                              leading: _PersonAvatar(person: person),
                              onTap: () => _openPersonActions(person),
                            ),
                      ],
                    );
                  },
                ),
                const SizedBox(height: 96),
              ],
            ),
    );
  }
}

class _PersonFormContent extends StatefulWidget {
  const _PersonFormContent({
    required this.onSubmit,
    required this.submitLabel,
    this.initialPerson,
  });

  final ClientPerson? initialPerson;
  final String submitLabel;
  final Future<void> Function({
    required String displayName,
    required String? avatarColor,
    required String role,
    required int sortOrder,
  })
  onSubmit;

  @override
  State<_PersonFormContent> createState() => _PersonFormContentState();
}

class _PersonFormContentState extends State<_PersonFormContent> {
  late final TextEditingController _displayNameController;
  late final TextEditingController _avatarColorController;
  late final TextEditingController _sortOrderController;
  late String _role;
  bool _saving = false;

  @override
  void initState() {
    super.initState();

    final person = widget.initialPerson;

    _displayNameController = TextEditingController(
      text: person?.displayName ?? '',
    );
    _avatarColorController = TextEditingController(
      text: person?.avatarColor ?? '',
    );
    _sortOrderController = TextEditingController(
      text: (person?.sortOrder ?? 0).toString(),
    );
    _role = person?.role ?? 'member';
  }

  @override
  void dispose() {
    _displayNameController.dispose();
    _avatarColorController.dispose();
    _sortOrderController.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final displayName = _displayNameController.text.trim();
    if (displayName.isEmpty) {
      _showSnack('Name is required.');
      return;
    }

    final sortOrder = int.tryParse(_sortOrderController.text.trim()) ?? 0;
    final avatarColor = _avatarColorController.text.trim();

    setState(() => _saving = true);

    try {
      await widget.onSubmit(
        displayName: displayName,
        avatarColor: avatarColor.isEmpty ? null : avatarColor,
        role: _role,
        sortOrder: sortOrder,
      );

      if (!mounted) return;
      Navigator.of(context).pop(true);
    } catch (error) {
      if (!mounted) return;
      setState(() => _saving = false);

      const friendly = 'Could not save person. Please try again.';
      _showSnack(
        kDebugMode && error is CaleeHubException
            ? '$friendly\nDebug: ${error.debugSummary}'
            : friendly,
      );
    }
  }

  void _showSnack(String message) {
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // ── Person ─────────────────────────────────────────────────────
          CaleeSection(
            children: [
              CaleeSectionTextFormField(
                controller: _displayNameController,
                enabled: !_saving,
                hintText: 'Name',
                textInputAction: TextInputAction.next,
              ),
              CaleeSectionTextFormField(
                controller: _avatarColorController,
                enabled: !_saving,
                hintText: 'Avatar colour  (#FFCC00)',
                textInputAction: TextInputAction.next,
              ),
            ],
          ),
          const SizedBox(height: CaleeSpacing.md),
          // ── Details ────────────────────────────────────────────────────
          CaleeSection(
            title: 'Details',
            children: [
              CaleeSectionDropdownRow<String>(
                label: 'Role',
                value: _role,
                items: const [
                  DropdownMenuItem(value: 'member', child: Text('Member')),
                  DropdownMenuItem(value: 'child', child: Text('Member')),
                  DropdownMenuItem(value: 'parent', child: Text('Manager')),
                ],
                onChanged: (value) {
                  if (value == null) return;
                  setState(() => _role = value);
                },
                enabled: !_saving,
              ),
              CaleeSectionTextFormField(
                controller: _sortOrderController,
                enabled: !_saving,
                hintText: 'Sort order',
                keyboardType: TextInputType.number,
              ),
            ],
          ),
          const SizedBox(height: CaleeSpacing.lg),
          FilledButton(
            onPressed: _saving ? null : _submit,
            child: _saving
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : Text(widget.submitLabel),
          ),
        ],
      ),
    );
  }
}

class _PersonAvatar extends StatelessWidget {
  const _PersonAvatar({required this.person});

  final ClientPerson person;

  @override
  Widget build(BuildContext context) {
    final color =
        _parseColor(person.avatarColor) ??
        CaleeColors.primary.withAlpha(CaleeAlpha.pct10);

    return Container(
      width: 34,
      height: 34,
      decoration: BoxDecoration(color: color, shape: BoxShape.circle),
      child: Center(
        child: Text(
          person.displayName.trim().isEmpty
              ? '?'
              : person.displayName.trim()[0].toUpperCase(),
          style: Theme.of(context).textTheme.labelLarge?.copyWith(
            color: CaleeColors.textPrimary,
            fontWeight: FontWeight.w700,
          ),
        ),
      ),
    );
  }

  Color? _parseColor(String? value) {
    final raw = value?.trim() ?? '';
    if (raw.isEmpty) return null;

    final normalized = raw.startsWith('#') ? raw : '#$raw';
    if (!RegExp(r'^#[0-9A-Fa-f]{6}$').hasMatch(normalized)) {
      return null;
    }

    return Color(0xFF000000 | int.parse(normalized.substring(1), radix: 16));
  }
}

class _ErrorRow extends StatelessWidget {
  const _ErrorRow({required this.message, required this.onRetry});

  final String message;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return CaleeListRow(
      title: message,
      leading: const Icon(
        Icons.error_outline,
        size: 20,
        color: CaleeColors.destructive,
      ),
      trailing: TextButton(onPressed: onRetry, child: const Text('Retry')),
    );
  }
}

class _EmptyPeopleState extends StatelessWidget {
  const _EmptyPeopleState({required this.title, required this.message});

  final String title;
  final String message;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(CaleeSpacing.pagePadding),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(
              Icons.group_outlined,
              size: 40,
              color: CaleeColors.textTertiary,
            ),
            const SizedBox(height: CaleeSpacing.md),
            Text(title, style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: CaleeSpacing.xs),
            Text(
              message,
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                color: CaleeColors.textSecondary,
              ),
              textAlign: TextAlign.center,
            ),
          ],
        ),
      ),
    );
  }
}

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
        style: Theme.of(
          context,
        ).textTheme.bodyMedium?.copyWith(color: CaleeColors.textSecondary),
      ),
    );
  }
}

String _capitalise(String value) {
  if (value.isEmpty) return value;
  return value[0].toUpperCase() + value.substring(1);
}

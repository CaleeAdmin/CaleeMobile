import 'package:flutter/material.dart';

import '../../../data/models/client_calendar.dart';
import '../../../data/models/client_person.dart';
import '../../../shared/recurrence/calee_repeat_picker_sheet.dart';
import '../../../ui/calee_theme.dart';
import '../../../ui/calee_widgets.dart';
import 'chore_widget_helpers.dart';

class CreateChoreSheet extends StatefulWidget {
  const CreateChoreSheet({
    required this.calendars,
    required this.people,
    required this.onCreate,
    super.key,
  });

  final List<ClientCalendar> calendars;
  final List<ClientPerson> people;
  final Future<void> Function({
    required ClientCalendar calendar,
    required String title,
    String? scheduledAt,
    String? description,
    String? recurrence,
    required List<String> assigneePersonIds,
    required int points,
  })
  onCreate;

  @override
  State<CreateChoreSheet> createState() => _CreateChoreSheetState();
}

class _AssigneeRow extends StatelessWidget {
  const _AssigneeRow({
    required this.label,
    required this.selected,
    required this.enabled,
    required this.onTap,
  });

  final String label;
  final bool selected;
  final bool enabled;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: enabled ? onTap : null,
      child: Padding(
        padding: const EdgeInsets.symmetric(
          horizontal: CaleeSpacing.md,
          vertical: 11,
        ),
        child: Row(
          children: [
            Expanded(
              child: Text(
                label,
                style: TextStyle(
                  fontSize: 16,
                  color: enabled
                      ? CaleeColors.textPrimary
                      : CaleeColors.textTertiary,
                ),
              ),
            ),
            if (selected)
              const Icon(Icons.check, size: 20, color: CaleeColors.primary),
          ],
        ),
      ),
    );
  }
}

class _CreateChoreSheetState extends State<CreateChoreSheet> {
  final _formKey = GlobalKey<FormState>();
  final _titleController = TextEditingController();
  final _descriptionController = TextEditingController();

  late ClientCalendar _selectedCalendar;
  DateTime? _selectedDate;
  CaleeRepeatRule _selectedRecurrence = CaleeRepeatRule.none;
  late final TextEditingController _pointsController;
  final Set<String> _selectedPersonIds = {};
  bool _isSubmitting = false;

  @override
  void initState() {
    super.initState();
    _selectedCalendar = widget.calendars.first;
    _pointsController = TextEditingController(text: '1');
  }

  @override
  void dispose() {
    _titleController.dispose();
    _descriptionController.dispose();
    _pointsController.dispose();
    super.dispose();
  }

  Future<void> _pickDate() async {
    final now = DateTime.now();
    final picked = await showDatePicker(
      context: context,
      initialDate: _selectedDate ?? now,
      firstDate: DateTime(now.year - 1),
      lastDate: DateTime(now.year + 5),
    );

    if (picked != null && mounted) {
      setState(() {
        _selectedDate = picked;
      });
    }
  }

  Future<void> _pickRepeat() async {
    final anchorDate = _selectedDate ?? DateTime.now();
    await CaleeRepeatPickerSheet.show(
      context: context,
      current: _selectedRecurrence,
      anchorDate: anchorDate,
      onSelected: (rule) {
        setState(() => _selectedRecurrence = rule);
      },
    );
  }

  Future<void> _submit() async {
    if (_isSubmitting || !_formKey.currentState!.validate()) return;

    final points = int.tryParse(_pointsController.text.trim()) ?? 1;

    setState(() {
      _isSubmitting = true;
    });

    try {
      await widget.onCreate(
        calendar: _selectedCalendar,
        title: _titleController.text.trim(),
        scheduledAt: _selectedDate == null
            ? null
            : formatChoreDate(_selectedDate!),
        description: _descriptionController.text.trim(),
        recurrence: choreRecurrenceToRrule(
          _selectedRecurrence,
          anchorDate: _selectedDate,
        ),
        assigneePersonIds: _selectedPersonIds.toList(),
        points: points,
      );

      if (mounted) {
        Navigator.of(context).pop(true);
      }
    } catch (_) {
      if (mounted) {
        setState(() {
          _isSubmitting = false;
        });

        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Unable to create chore.')),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return CaleeBottomSheet(
      title: 'Add chore',
      child: Form(
        key: _formKey,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              CaleeSection(
                children: [
                  CaleeSectionTextFormField(
                    controller: _titleController,
                    enabled: !_isSubmitting,
                    autofocus: true,
                    hintText: 'Title',
                    textInputAction: TextInputAction.next,
                    validator: (value) {
                      if ((value ?? '').trim().isEmpty) {
                        return 'Enter a chore title';
                      }
                      return null;
                    },
                  ),
                  CaleeSectionDropdownRow<ClientCalendar>(
                    label: 'Chore List',
                    value: _selectedCalendar,
                    enabled: !_isSubmitting,
                    items: widget.calendars
                        .map(
                          (calendar) => DropdownMenuItem(
                            value: calendar,
                            child: Text(
                              [
                                calendar.name,
                                if (calendar.serviceName.trim().isNotEmpty)
                                  calendar.serviceName,
                              ].join(' · '),
                            ),
                          ),
                        )
                        .toList(),
                    onChanged: (value) {
                      if (value != null) {
                        setState(() {
                          _selectedCalendar = value;
                        });
                      }
                    },
                  ),
                ],
              ),
              const SizedBox(height: CaleeSpacing.sectionSpacing),

              CaleeSection(
                children: [
                  CaleeSectionPickerRow(
                    label: 'Due date',
                    value: _selectedDate == null
                        ? 'No date'
                        : '${_selectedDate!.day}/${_selectedDate!.month}/${_selectedDate!.year}',
                    onTap: _isSubmitting ? null : _pickDate,
                    enabled: !_isSubmitting,
                  ),
                  if (_selectedDate != null)
                    InkWell(
                      onTap: _isSubmitting
                          ? null
                          : () {
                              setState(() {
                                _selectedDate = null;
                              });
                            },
                      child: Padding(
                        padding: const EdgeInsets.symmetric(
                          horizontal: CaleeSpacing.md,
                          vertical: 11,
                        ),
                        child: Text(
                          'Clear date',
                          style: TextStyle(
                            fontSize: 16,
                            color: _isSubmitting
                                ? CaleeColors.textTertiary
                                : CaleeColors.primary,
                          ),
                        ),
                      ),
                    ),
                  CaleeSectionPickerRow(
                    label: 'Repeat',
                    value: _selectedRecurrence.label(
                      anchorDate: _selectedDate ?? DateTime.now(),
                    ),
                    onTap: _isSubmitting ? null : _pickRepeat,
                    enabled: !_isSubmitting,
                  ),
                ],
              ),
              const SizedBox(height: CaleeSpacing.sectionSpacing),

              CaleeSection(
                title: 'Create for',
                children: [
                  _AssigneeRow(
                    label: 'For everyone',
                    selected: _selectedPersonIds.isEmpty,
                    enabled: !_isSubmitting,
                    onTap: () {
                      setState(() {
                        _selectedPersonIds.clear();
                      });
                    },
                  ),
                  for (final person in widget.people)
                    _AssigneeRow(
                      label: person.displayName.trim().isNotEmpty
                          ? person.displayName
                          : 'Unnamed',
                      selected: _selectedPersonIds.contains(person.id),
                      enabled: !_isSubmitting,
                      onTap: () {
                        setState(() {
                          if (_selectedPersonIds.contains(person.id)) {
                            _selectedPersonIds.remove(person.id);
                          } else {
                            _selectedPersonIds.add(person.id);
                          }
                        });
                      },
                    ),
                ],
              ),
              const SizedBox(height: CaleeSpacing.sectionSpacing),

              CaleeSection(
                children: [
                  CaleeSectionLabeledTextFormField(
                    label: 'Points',
                    controller: _pointsController,
                    enabled: !_isSubmitting,
                    keyboardType: TextInputType.number,
                    textAlign: TextAlign.right,
                    validator: (value) {
                      final points = int.tryParse((value ?? '').trim());
                      if (!isValidChorePoints(points)) {
                        return 'Enter points from 1 to 100';
                      }
                      return null;
                    },
                  ),
                ],
              ),
              const SizedBox(height: CaleeSpacing.sectionSpacing),

              CaleeSection(
                children: [
                  CaleeSectionTextFormField(
                    controller: _descriptionController,
                    enabled: !_isSubmitting,
                    hintText: 'Notes',
                    minLines: 2,
                    maxLines: 4,
                  ),
                ],
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
                    : Text(
                        _selectedPersonIds.length > 1
                            ? 'Create ${_selectedPersonIds.length} chores'
                            : 'Create chore',
                      ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

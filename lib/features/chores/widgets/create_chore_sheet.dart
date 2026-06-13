import 'package:flutter/material.dart';

import '../../../data/models/client_calendar.dart';
import '../../../data/models/client_person.dart';
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
    required String? assigneePersonId,
    required int points,
  })
  onCreate;

  @override
  State<CreateChoreSheet> createState() => _CreateChoreSheetState();
}

class _CreateChoreSheetState extends State<CreateChoreSheet> {
  final _formKey = GlobalKey<FormState>();
  final _titleController = TextEditingController();
  final _descriptionController = TextEditingController();

  late ClientCalendar _selectedCalendar;
  DateTime? _selectedDate;
  String? _selectedRecurrence;
  late final TextEditingController _pointsController;
  String? _assigneePersonId;
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
        recurrence: choreRecurrenceToRrule(_selectedRecurrence),
        assigneePersonId: _assigneePersonId,
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
                    label: 'Date',
                    value: _selectedDate == null
                        ? 'No Date'
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
                          'Clear Date',
                          style: TextStyle(
                            fontSize: 16,
                            color: _isSubmitting
                                ? CaleeColors.textTertiary
                                : CaleeColors.primary,
                          ),
                        ),
                      ),
                    ),
                  CaleeSectionDropdownRow<String?>(
                    label: 'Repeat',
                    value: _selectedRecurrence,
                    enabled: !_isSubmitting,
                    items: const [
                      DropdownMenuItem<String?>(
                        value: null,
                        child: Text('Does not repeat'),
                      ),
                      DropdownMenuItem<String?>(
                        value: 'daily',
                        child: Text('Daily'),
                      ),
                      DropdownMenuItem<String?>(
                        value: 'weekly',
                        child: Text('Weekly'),
                      ),
                      DropdownMenuItem<String?>(
                        value: 'monthly',
                        child: Text('Monthly'),
                      ),
                    ],
                    onChanged: (value) {
                      setState(() {
                        _selectedRecurrence = value;
                      });
                    },
                  ),
                ],
              ),
              const SizedBox(height: CaleeSpacing.sectionSpacing),

              CaleeSection(
                children: [
                  CaleeSectionDropdownRow<String?>(
                    label: 'Assign to',
                    value: _assigneePersonId,
                    enabled: !_isSubmitting,
                    items: [
                      const DropdownMenuItem<String?>(
                        value: null,
                        child: Text('Unassigned'),
                      ),
                      for (final person in widget.people)
                        DropdownMenuItem<String?>(
                          value: person.id,
                          child: Text(person.displayName),
                        ),
                    ],
                    onChanged: (value) {
                      setState(() {
                        _assigneePersonId = value;
                      });
                    },
                  ),
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
                    : const Text('Create chore'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

import 'package:flutter/material.dart';

import '../../../data/models/client_calendar.dart';
import '../../../ui/calee_theme.dart';
import '../../../ui/calee_widgets.dart';
import 'task_widget_helpers.dart';

class CreateTaskForm extends StatefulWidget {
  const CreateTaskForm({
    required this.taskCalendars,
    required this.onCreate,
    this.initialCalendar,
    this.defaultTaskListId,
    super.key,
  });

  final List<ClientCalendar> taskCalendars;
  final ClientCalendar? initialCalendar;
  final String? defaultTaskListId;
  final Future<void> Function({
    required ClientCalendar taskCalendar,
    required String title,
    String? dueAt,
    String? description,
  })
  onCreate;

  @override
  State<CreateTaskForm> createState() => _CreateTaskFormState();
}

class _CreateTaskFormState extends State<CreateTaskForm> {
  final _formKey = GlobalKey<FormState>();
  final _titleController = TextEditingController();
  final _descriptionController = TextEditingController();

  ClientCalendar? _selectedTaskCalendar;
  DateTime? _selectedDueDate;
  bool _isSubmitting = false;

  @override
  void initState() {
    super.initState();
    // Priority: explicit filter selection > default task list pref > first list
    final initial = widget.initialCalendar;
    if (initial != null &&
        widget.taskCalendars.any((c) => c.id == initial.id)) {
      _selectedTaskCalendar = initial;
    } else if (widget.defaultTaskListId != null) {
      ClientCalendar? found;
      for (final c in widget.taskCalendars) {
        if (c.id == widget.defaultTaskListId) {
          found = c;
          break;
        }
      }
      _selectedTaskCalendar = found ?? widget.taskCalendars.first;
    } else {
      _selectedTaskCalendar = widget.taskCalendars.first;
    }
  }

  @override
  void dispose() {
    _titleController.dispose();
    _descriptionController.dispose();
    super.dispose();
  }

  String _formatDate(DateTime value) {
    final year = value.year.toString().padLeft(4, '0');
    final month = value.month.toString().padLeft(2, '0');
    final day = value.day.toString().padLeft(2, '0');
    return '$year-$month-$day';
  }

  String _dueDateLabel() {
    final d = _selectedDueDate;
    if (d == null) return 'No Date';
    return '${d.day}/${d.month}/${d.year}';
  }

  Future<void> _pickDueDate() async {
    final now = DateTime.now();
    final picked = await showDatePicker(
      context: context,
      initialDate: _selectedDueDate ?? now,
      firstDate: DateTime(now.year - 1),
      lastDate: DateTime(now.year + 5),
    );

    if (picked != null && mounted) {
      setState(() {
        _selectedDueDate = picked;
      });
    }
  }

  Future<void> _submit() async {
    if (_isSubmitting || !_formKey.currentState!.validate()) {
      return;
    }

    final selectedTaskCalendar = _selectedTaskCalendar;
    if (selectedTaskCalendar == null) {
      return;
    }

    setState(() {
      _isSubmitting = true;
    });

    try {
      await widget.onCreate(
        taskCalendar: selectedTaskCalendar,
        title: _titleController.text.trim(),
        dueAt: _selectedDueDate == null ? null : _formatDate(_selectedDueDate!),
        description: _descriptionController.text.trim(),
      );

      if (mounted) {
        Navigator.of(context).pop(true);
      }
    } catch (_) {
      if (mounted) {
        setState(() {
          _isSubmitting = false;
        });

        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('Unable to create task.')));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Form(
      key: _formKey,
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // ── Task ──────────────────────────────────────────────────────
            CaleeSection(
              children: [
                CaleeSectionTextFormField(
                  key: const Key('task_title_field'),
                  controller: _titleController,
                  enabled: !_isSubmitting,
                  autofocus: true,
                  hintText: 'Title',
                  textInputAction: TextInputAction.next,
                  validator: (value) {
                    if ((value ?? '').trim().isEmpty) {
                      return 'Enter a task title';
                    }
                    return null;
                  },
                ),
                CaleeSectionDropdownRow<ClientCalendar>(
                  label: 'Task List',
                  value: _selectedTaskCalendar,
                  enabled: !_isSubmitting,
                  items: widget.taskCalendars
                      .map(
                        (calendar) => DropdownMenuItem(
                          value: calendar,
                          child: Text(calendar.name),
                        ),
                      )
                      .toList(),
                  onChanged: (calendar) {
                    setState(() {
                      _selectedTaskCalendar = calendar;
                    });
                  },
                ),
              ],
            ),
            const SizedBox(height: CaleeSpacing.sectionSpacing),

            // ── Due ───────────────────────────────────────────────────────
            CaleeSection(
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(
                    CaleeSpacing.md,
                    CaleeSpacing.sm,
                    CaleeSpacing.md,
                    CaleeSpacing.xs,
                  ),
                  child: DueDateQuickPicks(
                    selectedDate: _selectedDueDate,
                    enabled: !_isSubmitting,
                    onPick: (date) {
                      setState(() {
                        _selectedDueDate = date;
                      });
                    },
                  ),
                ),
                CaleeSectionPickerRow(
                  label: 'Date',
                  value: _dueDateLabel(),
                  onTap: _isSubmitting ? null : _pickDueDate,
                  enabled: !_isSubmitting,
                ),
              ],
            ),
            const SizedBox(height: CaleeSpacing.sectionSpacing),

            // ── Details ───────────────────────────────────────────────────
            CaleeSection(
              children: [
                CaleeSectionTextFormField(
                  key: const Key('task_description_field'),
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
              key: const Key('task_create_submit_button'),
              onPressed: _isSubmitting ? null : _submit,
              child: _isSubmitting
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Text('Create Task'),
            ),
          ],
        ),
      ),
    );
  }
}

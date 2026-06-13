import 'package:flutter/material.dart';

import '../../../data/models/client_task.dart';
import '../../../ui/calee_theme.dart';
import '../../../ui/calee_widgets.dart';
import 'task_widget_helpers.dart';

class EditTaskForm extends StatefulWidget {
  const EditTaskForm({
    required this.task,
    required this.onUpdate,
    super.key,
  });

  final ClientTask task;
  final Future<void> Function({
    required ClientTask task,
    required String title,
    String? dueAt,
    String? description,
  })
  onUpdate;

  @override
  State<EditTaskForm> createState() => _EditTaskFormState();
}

class _EditTaskFormState extends State<EditTaskForm> {
  final _formKey = GlobalKey<FormState>();
  late final TextEditingController _titleController;
  late final TextEditingController _descriptionController;

  DateTime? _selectedDueDate;
  bool _isSubmitting = false;

  @override
  void initState() {
    super.initState();
    _titleController = TextEditingController(text: widget.task.title);
    _descriptionController = TextEditingController(
      text: widget.task.description ?? '',
    );

    final dueAt = widget.task.dueAt;
    if (dueAt != null && dueAt.trim().isNotEmpty) {
      _selectedDueDate = DateTime.tryParse(dueAt)?.toLocal();
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

    setState(() {
      _isSubmitting = true;
    });

    try {
      await widget.onUpdate(
        task: widget.task,
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

        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Unable to update task.')),
        );
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
                  : const Text('Save Task'),
            ),
          ],
        ),
      ),
    );
  }
}

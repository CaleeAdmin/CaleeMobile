import 'package:flutter/material.dart';

import '../../../data/models/client_chore.dart';
import '../../../data/models/client_chore_metadata.dart';
import '../../../data/models/client_person.dart';
import '../../../ui/calee_theme.dart';
import '../../../ui/calee_widgets.dart';
import 'chore_widget_helpers.dart';

class EditChoreSheet extends StatefulWidget {
  const EditChoreSheet({
    required this.chore,
    required this.people,
    required this.metadata,
    required this.onUpdate,
    required this.onDelete,
    super.key,
  });

  final ClientChore chore;
  final List<ClientPerson> people;
  final ClientChoreMetadata? metadata;
  final Future<void> Function({
    required ClientChore chore,
    required String title,
    String? scheduledAt,
    String? description,
    String? recurrence,
    required String? assigneePersonId,
    required int points,
    required String approvalState,
  })
  onUpdate;
  final Future<void> Function() onDelete;

  @override
  State<EditChoreSheet> createState() => _EditChoreSheetState();
}

class _EditChoreSheetState extends State<EditChoreSheet> {
  final _formKey = GlobalKey<FormState>();
  late final TextEditingController _titleController;
  late final TextEditingController _descriptionController;
  late final TextEditingController _pointsController;

  DateTime? _selectedDate;
  String? _selectedRecurrence;
  String? _assigneePersonId;
  late final String _approvalState;
  bool _isSubmitting = false;

  @override
  void initState() {
    super.initState();
    _titleController = TextEditingController(text: widget.chore.title);
    _descriptionController = TextEditingController(
      text: widget.chore.description ?? '',
    );
    _selectedDate = parseChoreDate(
      widget.chore.scheduledDate ?? widget.chore.scheduledAt,
    );
    _selectedRecurrence = choreRruleToRecurrence(widget.chore.recurrence);

    final activePeopleIds = widget.people.map((person) => person.id).toSet();
    final existingAssignee =
        widget.metadata?.assigneePersonId ?? widget.chore.assigneePersonId;

    _assigneePersonId = activePeopleIds.contains(existingAssignee)
        ? existingAssignee
        : null;
    _approvalState =
        widget.metadata?.approvalState ?? widget.chore.approvalState;
    _pointsController = TextEditingController(
      text: (widget.metadata?.points ?? widget.chore.points).toString(),
    );
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
      await widget.onUpdate(
        chore: widget.chore,
        title: _titleController.text.trim(),
        scheduledAt: _selectedDate == null
            ? null
            : formatChoreDate(_selectedDate!),
        description: _descriptionController.text.trim(),
        recurrence: choreRecurrenceToRrule(_selectedRecurrence),
        assigneePersonId: _assigneePersonId,
        points: points,
        approvalState: _approvalState,
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
          const SnackBar(content: Text('Unable to update chore.')),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return CaleeBottomSheet(
      title: 'Edit chore',
      child: Form(
        key: _formKey,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (widget.chore.isRecurring) ...[
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: CaleeSpacing.md,
                    vertical: CaleeSpacing.sm,
                  ),
                  decoration: BoxDecoration(
                    color: CaleeColors.primary.withAlpha(15),
                    borderRadius: BorderRadius.circular(CaleeRadius.card),
                  ),
                  child: Row(
                    children: [
                      const Icon(
                        Icons.repeat,
                        size: 16,
                        color: CaleeColors.primary,
                      ),
                      const SizedBox(width: CaleeSpacing.sm),
                      Expanded(
                        child: Text(
                          'Repeating chore — changes apply going forward.',
                          style: Theme.of(context).textTheme.bodySmall
                              ?.copyWith(color: CaleeColors.primary),
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: CaleeSpacing.sectionSpacing),
              ],

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
                    : const Text('Save chore'),
              ),
              const SizedBox(height: CaleeSpacing.sectionSpacing),
              const Divider(),
              const SizedBox(height: CaleeSpacing.sm),
              TextButton(
                onPressed: _isSubmitting ? null : widget.onDelete,
                style: TextButton.styleFrom(
                  foregroundColor: CaleeColors.destructive,
                  minimumSize: const Size.fromHeight(44),
                ),
                child: const Text('Delete chore'),
              ),
              const SizedBox(height: CaleeSpacing.md),
            ],
          ),
        ),
      ),
    );
  }
}

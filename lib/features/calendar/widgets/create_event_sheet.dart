import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../../../data/api/calee_hub_client.dart';
import '../../../data/models/client_calendar.dart';
import '../../../ui/calee_design.dart';
import 'calendar_widget_helpers.dart';

class CreateEventSheet extends StatefulWidget {
  const CreateEventSheet({
    required this.calendars,
    required this.onCreate,
    this.initialDate,
    this.initialEvent,
    this.editScope,
    this.defaultCalendarId,
    this.onUpdate,
    super.key,
  });

  final List<ClientCalendar> calendars;
  final DateTime? initialDate;
  final ClientEvent? initialEvent;
  final String? editScope;
  final String? defaultCalendarId;
  final Future<void> Function({
    required ClientCalendar calendar,
    required String title,
    required DateTime startsAt,
    required DateTime endsAt,
    required bool allDay,
    String? location,
    String? description,
    String? recurrence,
  })
  onCreate;
  final Future<void> Function({
    required ClientEvent event,
    required String title,
    required DateTime? startsAt,
    required DateTime? endsAt,
    required bool? allDay,
    String? location,
    String? description,
    String? recurrence,
    String? editScope,
  })?
  onUpdate;

  @override
  State<CreateEventSheet> createState() => _CreateEventSheetState();
}

class _CreateEventSheetState extends State<CreateEventSheet> {
  final _formKey = GlobalKey<FormState>();
  final _titleController = TextEditingController();
  final _locationController = TextEditingController();
  final _descriptionController = TextEditingController();
  final _recurrenceCountController = TextEditingController(text: '10');

  late ClientCalendar _selectedCalendar;
  late DateTime _selectedDate;
  late DateTime _selectedEndDate;
  late TimeOfDay _startTime;
  late TimeOfDay _endTime;
  String _selectedRecurrence = 'none';
  String _recurrenceEnd = 'never';
  late DateTime _recurrenceEndDate;
  bool _allDay = false;
  bool _isSubmitting = false;

  bool get _isEditing => widget.initialEvent != null;
  bool get _isEditingSingleOccurrence =>
      _isEditing &&
      widget.initialEvent!.recurring &&
      widget.editScope == 'occurrence';

  bool get _isEditingRecurringSeriesMetadata =>
      _isEditing &&
      widget.initialEvent!.recurring &&
      widget.editScope == 'series';

  @override
  void initState() {
    super.initState();

    _selectedCalendar = widget.calendars.first;
    if (widget.defaultCalendarId != null) {
      for (final cal in widget.calendars) {
        if (cal.id == widget.defaultCalendarId) {
          _selectedCalendar = cal;
          break;
        }
      }
    }

    final event = widget.initialEvent;
    if (event != null) {
      _titleController.text = event.title;
      _locationController.text = event.location ?? '';
      _descriptionController.text = event.description ?? '';
      _allDay = event.allDay;

      final start =
          DateTime.tryParse(event.startsAt)?.toLocal() ?? DateTime.now();
      final end =
          DateTime.tryParse(event.endsAt)?.toLocal() ??
          start.add(const Duration(hours: 1));

      _selectedDate = DateTime(start.year, start.month, start.day);
      _recurrenceEndDate = _selectedDate.add(const Duration(days: 30));
      _selectedEndDate = event.allDay
          ? DateTime(
              end.year,
              end.month,
              end.day,
            ).subtract(const Duration(days: 1))
          : _selectedDate;

      if (!_isEditingSingleOccurrence) {
        _applyInitialRecurrence(event.recurrence);
      }

      if (_selectedEndDate.isBefore(_selectedDate)) {
        _selectedEndDate = _selectedDate;
      }

      _startTime = TimeOfDay(hour: start.hour, minute: start.minute);
      _endTime = TimeOfDay(hour: end.hour, minute: end.minute);
      return;
    }

    // Use initialDate from calendar selection if provided, else today
    final initial = widget.initialDate;
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    _selectedDate = initial != null
        ? DateTime(initial.year, initial.month, initial.day)
        : today;
    _selectedEndDate = _selectedDate;
    _recurrenceEndDate = _selectedDate.add(const Duration(days: 30));

    // Default times: 9:00–10:00 for future dates, next hour for today
    if (isSameCalendarDay(_selectedDate, today)) {
      final nextHour = now.add(const Duration(hours: 1));
      _startTime = TimeOfDay(hour: nextHour.hour, minute: 0);
      _endTime = TimeOfDay(hour: (nextHour.hour + 1) % 24, minute: 0);
    } else {
      _startTime = const TimeOfDay(hour: 9, minute: 0);
      _endTime = const TimeOfDay(hour: 10, minute: 0);
    }
  }

  @override
  void dispose() {
    _titleController.dispose();
    _locationController.dispose();
    _descriptionController.dispose();
    _recurrenceCountController.dispose();
    super.dispose();
  }

  DateTime _dateTimeFor(TimeOfDay time) {
    return DateTime(
      _selectedDate.year,
      _selectedDate.month,
      _selectedDate.day,
      time.hour,
      time.minute,
    );
  }

  String _dateLabel(DateTime value) {
    return '${value.day}/${value.month}/${value.year}';
  }

  String _timeLabel(TimeOfDay value) {
    final hour = value.hour.toString().padLeft(2, '0');
    final minute = value.minute.toString().padLeft(2, '0');
    return '$hour:$minute';
  }

  Map<String, String> _parseRRule(String? recurrence) {
    final value = (recurrence ?? '').trim();
    if (value.isEmpty) return {};

    final parts = <String, String>{};
    for (final part in value.split(';')) {
      final separator = part.indexOf('=');
      if (separator <= 0 || separator == part.length - 1) continue;
      final key = part.substring(0, separator).trim().toUpperCase();
      final parsedValue = part.substring(separator + 1).trim().toUpperCase();
      parts[key] = parsedValue;
    }
    return parts;
  }

  DateTime? _dateFromRRuleUntil(String? value) {
    if (value == null || value.length < 8) return null;
    final rawDate = value.substring(0, 8);
    final year = int.tryParse(rawDate.substring(0, 4));
    final month = int.tryParse(rawDate.substring(4, 6));
    final day = int.tryParse(rawDate.substring(6, 8));
    if (year == null || month == null || day == null) return null;
    return DateTime(year, month, day);
  }

  void _applyInitialRecurrence(String? recurrence) {
    final parts = _parseRRule(recurrence);
    final frequency = parts['FREQ'];

    _selectedRecurrence = switch (frequency) {
      'DAILY' => 'daily',
      'WEEKLY' => 'weekly',
      'MONTHLY' => 'monthly',
      'YEARLY' => 'yearly',
      _ => 'none',
    };

    final count = parts['COUNT'];
    final until = parts['UNTIL'];

    if (count != null && count.isNotEmpty) {
      _recurrenceEnd = 'count';
      _recurrenceCountController.text = count;
    } else if (until != null && until.isNotEmpty) {
      _recurrenceEnd = 'date';
      final parsedUntil = _dateFromRRuleUntil(until);
      if (parsedUntil != null) {
        _recurrenceEndDate = parsedUntil;
      }
    } else {
      _recurrenceEnd = 'never';
    }
  }

  String? _recurrenceValue() {
    final frequency = switch (_selectedRecurrence) {
      'daily' => 'DAILY',
      'weekly' => 'WEEKLY',
      'monthly' => 'MONTHLY',
      'yearly' => 'YEARLY',
      _ => null,
    };

    if (frequency == null) return null;

    final parts = <String>['FREQ=$frequency'];

    if (_recurrenceEnd == 'count') {
      final count = int.tryParse(_recurrenceCountController.text.trim());
      if (count == null || count < 1) {
        throw const FormatException('Enter a repeat count of at least 1.');
      }
      parts.add('COUNT=$count');
    } else if (_recurrenceEnd == 'date') {
      parts.add('UNTIL=${_formatRRuleUntil(_recurrenceEndDate)}');
    }

    return parts.join(';');
  }

  String _formatRRuleUntil(DateTime value) {
    if (_allDay) {
      final year = value.year.toString().padLeft(4, '0');
      final month = value.month.toString().padLeft(2, '0');
      final day = value.day.toString().padLeft(2, '0');
      return '$year$month$day';
    }

    final localEndOfDay = DateTime(
      value.year,
      value.month,
      value.day,
      23,
      59,
      59,
    );
    final utc = localEndOfDay.toUtc();

    final year = utc.year.toString().padLeft(4, '0');
    final month = utc.month.toString().padLeft(2, '0');
    final day = utc.day.toString().padLeft(2, '0');
    final hour = utc.hour.toString().padLeft(2, '0');
    final minute = utc.minute.toString().padLeft(2, '0');
    final second = utc.second.toString().padLeft(2, '0');

    return '$year$month${day}T$hour$minute${second}Z';
  }

  Future<void> _pickDate() async {
    final picked = await showDatePicker(
      context: context,
      initialDate: _selectedDate,
      firstDate: DateTime(2020),
      lastDate: DateTime(2100),
    );

    if (picked != null && mounted) {
      setState(() {
        _selectedDate = DateTime(picked.year, picked.month, picked.day);
        if (_selectedEndDate.isBefore(_selectedDate)) {
          _selectedEndDate = _selectedDate;
        }
      });
    }
  }

  Future<void> _pickRecurrenceEndDate() async {
    final picked = await showDatePicker(
      context: context,
      initialDate: _recurrenceEndDate.isBefore(_selectedDate)
          ? _selectedDate
          : _recurrenceEndDate,
      firstDate: _selectedDate,
      lastDate: DateTime(2100),
    );

    if (picked != null && mounted) {
      setState(() {
        _recurrenceEndDate = DateTime(picked.year, picked.month, picked.day);
      });
    }
  }

  Future<void> _pickEndDate() async {
    final picked = await showDatePicker(
      context: context,
      initialDate: _selectedEndDate.isBefore(_selectedDate)
          ? _selectedDate
          : _selectedEndDate,
      firstDate: _selectedDate,
      lastDate: DateTime(2100),
    );

    if (picked != null && mounted) {
      setState(() {
        _selectedEndDate = DateTime(picked.year, picked.month, picked.day);
      });
    }
  }

  Future<void> _pickStartTime() async {
    final picked = await showTimePicker(
      context: context,
      initialTime: _startTime,
    );

    if (picked != null && mounted) {
      setState(() {
        _startTime = picked;
      });
    }
  }

  Future<void> _pickEndTime() async {
    final picked = await showTimePicker(
      context: context,
      initialTime: _endTime,
    );

    if (picked != null && mounted) {
      setState(() {
        _endTime = picked;
      });
    }
  }

  Future<void> _submit() async {
    if (_isSubmitting || !_formKey.currentState!.validate()) return;

    final metadataOnly = _isEditingRecurringSeriesMetadata;
    DateTime? startsAt;
    DateTime? endsAt;

    if (!metadataOnly) {
      startsAt = _dateTimeFor(_startTime);
      endsAt = _dateTimeFor(_endTime);

      if (_allDay) {
        if (_selectedEndDate.isBefore(_selectedDate)) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('End date must be on or after start date.'),
            ),
          );
          return;
        }
        endsAt = _selectedEndDate.add(const Duration(days: 1));
      } else if (!endsAt.isAfter(startsAt)) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('End time must be after start time.')),
        );
        return;
      }
    }

    setState(() {
      _isSubmitting = true;
    });

    try {
      final title = _titleController.text.trim();
      final location = _locationController.text.trim().isEmpty
          ? null
          : _locationController.text.trim();
      final description = _descriptionController.text.trim().isEmpty
          ? null
          : _descriptionController.text.trim();

      if (_isEditing) {
        await widget.onUpdate!(
          event: widget.initialEvent!,
          title: title,
          startsAt: startsAt,
          endsAt: endsAt,
          allDay: metadataOnly ? null : _allDay,
          location: location,
          description: description,
          recurrence: _isEditingSingleOccurrence || metadataOnly
              ? null
              : _recurrenceValue(),
          editScope: widget.editScope,
        );
      } else {
        await widget.onCreate(
          calendar: _selectedCalendar,
          title: title,
          startsAt: startsAt!,
          endsAt: endsAt!,
          allDay: _allDay,
          location: location,
          description: description,
          recurrence: _recurrenceValue(),
        );
      }

      if (mounted) {
        Navigator.of(context).pop(true);
      }
    } catch (error) {
      if (mounted) {
        setState(() {
          _isSubmitting = false;
        });

        const friendly = 'Could not save this event. Please try again.';
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              kDebugMode && error is CaleeHubException
                  ? '$friendly\nDebug: ${error.debugSummary}'
                  : friendly,
            ),
          ),
        );
      }
    }
  }

  String get _submitLabel {
    if (!_isEditing) return 'Save Event';
    if (_isEditingSingleOccurrence) return 'Update Event';
    if (widget.initialEvent!.recurring) return 'Update Series';
    return 'Update Event';
  }

  @override
  Widget build(BuildContext context) {
    final bottomInset = MediaQuery.viewInsetsOf(context).bottom;

    final sheetTitle = _isEditing
        ? _isEditingSingleOccurrence
              ? 'Edit this event'
              : _isEditingRecurringSeriesMetadata
              ? 'Edit series details'
              : widget.initialEvent!.recurring
              ? 'Edit series'
              : 'Edit event'
        : 'Add event';

    return SafeArea(
      child: Container(
        color: CaleeColors.scaffoldBackground,
        child: Form(
          key: _formKey,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              // Drag handle
              Center(
                child: Container(
                  width: 36,
                  height: 4,
                  margin: const EdgeInsets.only(top: CaleeSpacing.sm),
                  decoration: BoxDecoration(
                    color: CaleeColors.separatorOpaque,
                    borderRadius: BorderRadius.circular(CaleeRadius.dot),
                  ),
                ),
              ),
              Flexible(
                child: SingleChildScrollView(
                  padding: EdgeInsets.fromLTRB(
                    CaleeSpacing.md,
                    CaleeSpacing.md,
                    CaleeSpacing.md,
                    CaleeSpacing.md + bottomInset,
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      // Sheet title
                      Text(
                        sheetTitle,
                        style: Theme.of(context).textTheme.titleLarge,
                      ),
                      const SizedBox(height: CaleeSpacing.md),

                      // ── Event ─────────────────────────────────────────────
                      CaleeSection(
                        children: [
                          // Title field
                          CaleeSectionTextFormField(
                            controller: _titleController,
                            enabled: !_isSubmitting,
                            autofocus: true,
                            hintText: 'Title',
                            textInputAction: TextInputAction.next,
                            validator: (value) {
                              if ((value ?? '').trim().isEmpty) {
                                return 'Enter a title';
                              }
                              return null;
                            },
                          ),
                          // Calendar picker
                          CaleeSectionDropdownRow<ClientCalendar>(
                            label: 'Calendar',
                            value: _selectedCalendar,
                            items: [
                              for (final cal in widget.calendars)
                                DropdownMenuItem(
                                  value: cal,
                                  child: Text(cal.name),
                                ),
                            ],
                            onChanged: (cal) {
                              if (cal != null) {
                                setState(() => _selectedCalendar = cal);
                              }
                            },
                            enabled: !_isSubmitting && !_isEditing,
                          ),
                        ],
                      ),

                      // ── Time ──────────────────────────────────────────────
                      if (!_isEditingRecurringSeriesMetadata) ...[
                        const SizedBox(height: CaleeSpacing.sectionSpacing),
                        CaleeSection(
                          children: [
                            CaleeSectionSwitchRow(
                              label: 'All day',
                              value: _allDay,
                              enabled: !_isSubmitting,
                              onChanged: (v) => setState(() => _allDay = v),
                            ),
                            if (_allDay) ...[
                              CaleeSectionPickerRow(
                                label: 'Date',
                                value: _dateLabel(_selectedDate),
                                onTap: _isSubmitting ? null : _pickDate,
                                enabled: !_isSubmitting,
                              ),
                              CaleeSectionPickerRow(
                                label: 'End',
                                value: _dateLabel(_selectedEndDate),
                                onTap: _isSubmitting ? null : _pickEndDate,
                                enabled: !_isSubmitting,
                              ),
                            ] else ...[
                              CaleeSectionPickerRow(
                                label: 'Date',
                                value: _dateLabel(_selectedDate),
                                onTap: _isSubmitting ? null : _pickDate,
                                enabled: !_isSubmitting,
                              ),
                              CaleeSectionPickerRow(
                                label: 'Start',
                                value: _timeLabel(_startTime),
                                onTap: _isSubmitting ? null : _pickStartTime,
                                enabled: !_isSubmitting,
                              ),
                              CaleeSectionPickerRow(
                                label: 'End',
                                value: _timeLabel(_endTime),
                                onTap: _isSubmitting ? null : _pickEndTime,
                                enabled: !_isSubmitting,
                              ),
                            ],
                          ],
                        ),
                      ],

                      // ── Repeat ────────────────────────────────────────────
                      if (!_isEditingSingleOccurrence &&
                          !_isEditingRecurringSeriesMetadata) ...[
                        const SizedBox(height: CaleeSpacing.sectionSpacing),
                        CaleeSection(
                          children: [
                            CaleeSectionDropdownRow<String>(
                              label: 'Repeat',
                              value: _selectedRecurrence,
                              items: const [
                                DropdownMenuItem(
                                  value: 'none',
                                  child: Text('Does not repeat'),
                                ),
                                DropdownMenuItem(
                                  value: 'daily',
                                  child: Text('Daily'),
                                ),
                                DropdownMenuItem(
                                  value: 'weekly',
                                  child: Text('Weekly'),
                                ),
                                DropdownMenuItem(
                                  value: 'monthly',
                                  child: Text('Monthly'),
                                ),
                                DropdownMenuItem(
                                  value: 'yearly',
                                  child: Text('Yearly'),
                                ),
                              ],
                              onChanged: (value) {
                                if (value != null) {
                                  setState(() => _selectedRecurrence = value);
                                }
                              },
                              enabled: !_isSubmitting,
                            ),
                            if (_selectedRecurrence != 'none') ...[
                              CaleeSectionDropdownRow<String>(
                                label: 'Ends',
                                value: _recurrenceEnd,
                                items: const [
                                  DropdownMenuItem(
                                    value: 'never',
                                    child: Text('Never'),
                                  ),
                                  DropdownMenuItem(
                                    value: 'date',
                                    child: Text('On date'),
                                  ),
                                  DropdownMenuItem(
                                    value: 'count',
                                    child: Text('After count'),
                                  ),
                                ],
                                onChanged: (value) {
                                  if (value != null) {
                                    setState(() => _recurrenceEnd = value);
                                  }
                                },
                                enabled: !_isSubmitting,
                              ),
                              if (_recurrenceEnd == 'date')
                                CaleeSectionPickerRow(
                                  label: 'Ends on',
                                  value: _dateLabel(_recurrenceEndDate),
                                  onTap: _isSubmitting
                                      ? null
                                      : _pickRecurrenceEndDate,
                                  enabled: !_isSubmitting,
                                ),
                              if (_recurrenceEnd == 'count')
                                CaleeSectionLabeledTextFormField(
                                  label: 'Times',
                                  controller: _recurrenceCountController,
                                  enabled: !_isSubmitting,
                                  keyboardType: TextInputType.number,
                                  textAlign: TextAlign.right,
                                  hintText: '10',
                                  fieldWidth: 80,
                                  validator: (value) {
                                    if (_selectedRecurrence == 'none' ||
                                        _recurrenceEnd != 'count') {
                                      return null;
                                    }
                                    final count = int.tryParse(
                                      (value ?? '').trim(),
                                    );
                                    if (count == null || count < 1) {
                                      return 'Enter a number of at least 1';
                                    }
                                    return null;
                                  },
                                ),
                            ],
                          ],
                        ),
                      ],

                      // ── Series metadata note ───────────────────────────────
                      if (_isEditingRecurringSeriesMetadata) ...[
                        const SizedBox(height: CaleeSpacing.sectionSpacing),
                        Padding(
                          padding: const EdgeInsets.symmetric(
                            horizontal: CaleeSpacing.sm,
                          ),
                          child: Text(
                            'Series date, time, and repeat settings are preserved.',
                            style: Theme.of(context).textTheme.bodySmall
                                ?.copyWith(color: CaleeColors.textSecondary),
                          ),
                        ),
                      ],

                      // ── Details ───────────────────────────────────────────
                      const SizedBox(height: CaleeSpacing.sectionSpacing),
                      CaleeSection(
                        children: [
                          CaleeSectionTextFormField(
                            controller: _locationController,
                            enabled: !_isSubmitting,
                            hintText: 'Location',
                          ),
                          CaleeSectionTextFormField(
                            controller: _descriptionController,
                            enabled: !_isSubmitting,
                            hintText: 'Notes',
                            maxLines: 3,
                          ),
                        ],
                      ),

                      // ── Submit ────────────────────────────────────────────
                      const SizedBox(height: CaleeSpacing.lg),
                      FilledButton(
                        onPressed: _isSubmitting ? null : _submit,
                        child: _isSubmitting
                            ? const SizedBox(
                                width: 18,
                                height: 18,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                ),
                              )
                            : Text(_submitLabel),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

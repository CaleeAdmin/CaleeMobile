import 'package:flutter/material.dart';

import '../../ui/calee_design.dart';
import 'calee_repeat_rule.dart';

class CaleeRepeatPickerSheet extends StatefulWidget {
  const CaleeRepeatPickerSheet({
    required this.current,
    required this.anchorDate,
    required this.onSelected,
    super.key,
  });

  final CaleeRepeatRule current;
  final DateTime anchorDate;
  final ValueChanged<CaleeRepeatRule> onSelected;

  static Future<void> show({
    required BuildContext context,
    required CaleeRepeatRule current,
    required DateTime anchorDate,
    required ValueChanged<CaleeRepeatRule> onSelected,
  }) {
    return showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: CaleeColors.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(
          top: Radius.circular(CaleeRadius.sheet),
        ),
      ),
      builder: (_) => CaleeRepeatPickerSheet(
        current: current,
        anchorDate: anchorDate,
        onSelected: onSelected,
      ),
    );
  }

  @override
  State<CaleeRepeatPickerSheet> createState() => _CaleeRepeatPickerSheetState();
}

class _CaleeRepeatPickerSheetState extends State<CaleeRepeatPickerSheet> {
  late CaleeRepeatRule _selected;
  late Set<int> _customWeekdays;

  static const _weekdayOrder = [
    DateTime.monday,
    DateTime.tuesday,
    DateTime.wednesday,
    DateTime.thursday,
    DateTime.friday,
    DateTime.saturday,
    DateTime.sunday,
  ];

  static const _weekdayLabels = {
    DateTime.monday: 'Mon',
    DateTime.tuesday: 'Tue',
    DateTime.wednesday: 'Wed',
    DateTime.thursday: 'Thu',
    DateTime.friday: 'Fri',
    DateTime.saturday: 'Sat',
    DateTime.sunday: 'Sun',
  };

  @override
  void initState() {
    super.initState();
    _selected = widget.current;
    if (_selected.kind == CaleeRepeatKind.customDays) {
      _customWeekdays = Set<int>.from(_selected.weekdays);
    } else {
      _customWeekdays = {};
    }
  }

  List<_RepeatOption> get _options {
    final anchor = widget.anchorDate;
    return [
      _RepeatOption(
        rule: CaleeRepeatRule.none,
        label: CaleeRepeatRule.none.label(anchorDate: anchor),
      ),
      _RepeatOption(
        rule: CaleeRepeatRule.daily,
        label: CaleeRepeatRule.daily.label(anchorDate: anchor),
      ),
      _RepeatOption(
        rule: CaleeRepeatRule.weekdaysOnly,
        label: CaleeRepeatRule.weekdaysOnly.label(anchorDate: anchor),
      ),
      _RepeatOption(
        rule: const CaleeRepeatRule(kind: CaleeRepeatKind.weekly),
        label: const CaleeRepeatRule(
          kind: CaleeRepeatKind.weekly,
        ).label(anchorDate: anchor),
      ),
      _RepeatOption(
        rule: const CaleeRepeatRule(kind: CaleeRepeatKind.fortnightly),
        label: const CaleeRepeatRule(
          kind: CaleeRepeatKind.fortnightly,
        ).label(anchorDate: anchor),
      ),
      _RepeatOption(
        rule: CaleeRepeatRule.monthly,
        label: CaleeRepeatRule.monthly.label(anchorDate: anchor),
      ),
      _RepeatOption(
        rule: CaleeRepeatRule.yearly,
        label: CaleeRepeatRule.yearly.label(anchorDate: anchor),
      ),
      const _RepeatOption(
        rule: CaleeRepeatRule(kind: CaleeRepeatKind.customDays),
        label: 'Custom days',
      ),
    ];
  }

  bool get _isCustom => _selected.kind == CaleeRepeatKind.customDays;
  bool get _canDone => !_isCustom || _customWeekdays.isNotEmpty;

  void _selectOption(_RepeatOption option) {
    setState(() {
      if (option.rule.kind == CaleeRepeatKind.customDays) {
        _selected = const CaleeRepeatRule(kind: CaleeRepeatKind.customDays);
        if (_customWeekdays.isEmpty &&
            widget.current.kind == CaleeRepeatKind.customDays) {
          _customWeekdays = Set<int>.from(widget.current.weekdays);
        }
      } else {
        _selected = option.rule;
      }
    });
  }

  void _toggleWeekday(int day) {
    setState(() {
      if (_customWeekdays.contains(day)) {
        _customWeekdays.remove(day);
      } else {
        _customWeekdays.add(day);
      }
    });
  }

  void _done() {
    if (!_canDone) return;
    final CaleeRepeatRule result;
    if (_isCustom) {
      result = CaleeRepeatRule(
        kind: CaleeRepeatKind.customDays,
        weekdays: Set<int>.from(_customWeekdays),
      );
    } else {
      result = _selected;
    }
    widget.onSelected(result);
    Navigator.of(context).pop();
  }

  bool _isOptionSelected(_RepeatOption option) {
    if (option.rule.kind == CaleeRepeatKind.customDays) {
      return _selected.kind == CaleeRepeatKind.customDays;
    }
    return _selected == option.rule;
  }

  @override
  Widget build(BuildContext context) {
    final bottomInset = MediaQuery.viewInsetsOf(context).bottom;
    final theme = Theme.of(context);

    return SafeArea(
      child: Padding(
        padding: EdgeInsets.fromLTRB(
          CaleeSpacing.md,
          CaleeSpacing.sm,
          CaleeSpacing.md,
          CaleeSpacing.md + bottomInset,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Center(
              child: Container(
                width: 36,
                height: 4,
                margin: const EdgeInsets.only(bottom: CaleeSpacing.md),
                decoration: BoxDecoration(
                  color: CaleeColors.separatorOpaque,
                  borderRadius: BorderRadius.circular(CaleeRadius.dot),
                ),
              ),
            ),
            Row(
              children: [
                Expanded(
                  child: Text('Repeat', style: theme.textTheme.titleLarge),
                ),
                IconButton(
                  icon: const Icon(Icons.close),
                  onPressed: () => Navigator.of(context).maybePop(),
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints(),
                ),
              ],
            ),
            const SizedBox(height: CaleeSpacing.md),
            Flexible(
              child: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    CaleeSection(
                      children: [
                        for (final option in _options) ...[
                          _OptionRow(
                            label: option.label,
                            selected: _isOptionSelected(option),
                            onTap: () => _selectOption(option),
                          ),
                        ],
                      ],
                    ),
                    if (_isCustom) ...[
                      const SizedBox(height: CaleeSpacing.sectionSpacing),
                      CaleeSection(
                        children: [
                          Padding(
                            padding: const EdgeInsets.symmetric(
                              horizontal: CaleeSpacing.md,
                              vertical: CaleeSpacing.sm,
                            ),
                            child: Wrap(
                              spacing: CaleeSpacing.sm,
                              runSpacing: CaleeSpacing.sm,
                              children: [
                                for (final day in _weekdayOrder)
                                  _WeekdayPill(
                                    label: _weekdayLabels[day]!,
                                    selected: _customWeekdays.contains(day),
                                    onTap: () => _toggleWeekday(day),
                                  ),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ],
                    const SizedBox(height: CaleeSpacing.md),
                    FilledButton(
                      onPressed: _canDone ? _done : null,
                      child: const Text('Done'),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _RepeatOption {
  const _RepeatOption({required this.rule, required this.label});
  final CaleeRepeatRule rule;
  final String label;
}

class _OptionRow extends StatelessWidget {
  const _OptionRow({
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
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
                style: const TextStyle(
                  fontSize: 16,
                  color: CaleeColors.textPrimary,
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

class _WeekdayPill extends StatelessWidget {
  const _WeekdayPill({
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 120),
        constraints: const BoxConstraints(minWidth: 44, minHeight: 44),
        padding: const EdgeInsets.symmetric(
          horizontal: CaleeSpacing.sm,
          vertical: CaleeSpacing.xs,
        ),
        decoration: BoxDecoration(
          color: selected ? CaleeColors.primary : CaleeColors.scaffoldBackground,
          borderRadius: BorderRadius.circular(CaleeRadius.card),
          border: Border.all(
            color: selected ? CaleeColors.primary : CaleeColors.separator,
          ),
        ),
        child: Center(
          child: Text(
            label,
            style: TextStyle(
              fontSize: 15,
              fontWeight: FontWeight.w500,
              color: selected ? Colors.white : CaleeColors.textPrimary,
            ),
          ),
        ),
      ),
    );
  }
}

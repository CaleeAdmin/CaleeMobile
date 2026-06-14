import 'package:flutter/material.dart';

import '../../../ui/calee_design.dart';
import '../widgets/calendar_day_cell.dart';
import '../widgets/calendar_widget_helpers.dart';
import 'calendar_display_event.dart';
import 'read_only_calendar_event_row.dart';

enum CalendarDisplayViewMode { month, agenda }

const _kMonthNames = [
  'January',
  'February',
  'March',
  'April',
  'May',
  'June',
  'July',
  'August',
  'September',
  'October',
  'November',
  'December',
];

const _kFullDayNames = [
  'Sunday',
  'Monday',
  'Tuesday',
  'Wednesday',
  'Thursday',
  'Friday',
  'Saturday',
];

/// A dumb, read-only calendar view (Month + Agenda) that accepts all state
/// and callbacks from its parent. It never fetches data, mutates storage, or
/// exposes create/edit/delete event actions.
class ReadOnlyCalendarView extends StatelessWidget {
  const ReadOnlyCalendarView({
    required this.selectedMonth,
    required this.selectedDay,
    required this.today,
    required this.firstDayOfWeek,
    required this.events,
    required this.viewMode,
    required this.onViewModeChanged,
    required this.onPreviousMonth,
    required this.onNextMonth,
    required this.onGoToToday,
    required this.onSelectDay,
    this.onEventTap,
    this.actionWidgets = const [],
    this.use24h = true,
    super.key,
  });

  final DateTime selectedMonth;
  final DateTime selectedDay;
  final DateTime today;

  /// 0 = Sunday first, 1 = Monday first.
  final int firstDayOfWeek;

  final List<CalendarDisplayEvent> events;
  final CalendarDisplayViewMode viewMode;
  final void Function(CalendarDisplayViewMode) onViewModeChanged;
  final VoidCallback onPreviousMonth;
  final VoidCallback onNextMonth;
  final VoidCallback onGoToToday;
  final void Function(DateTime) onSelectDay;
  final void Function(CalendarDisplayEvent)? onEventTap;

  /// Extra icon buttons / widgets inserted after the Today button in the top bar.
  final List<Widget> actionWidgets;
  final bool use24h;

  // ── Private helpers ────────────────────────────────────────────────────────

  DateTime get _gridStart {
    final first = DateTime(selectedMonth.year, selectedMonth.month);
    final offset = firstDayOfWeek == 1
        ? (first.weekday + 6) % 7
        : first.weekday % 7;
    return first.subtract(Duration(days: offset));
  }

  List<CalendarDisplayEvent> _eventsForDay(DateTime day) {
    final result = events.where((e) => isSameCalendarDay(e.start, day)).toList()
      ..sort((a, b) {
        if (a.allDay != b.allDay) return a.allDay ? -1 : 1;
        return a.start.compareTo(b.start);
      });
    return result;
  }

  String get _monthYearLabel =>
      '${_kMonthNames[selectedMonth.month - 1]} ${selectedMonth.year}';

  String _agendaDateLabel(DateTime day) {
    if (isSameCalendarDay(day, today)) return 'Today';
    final weekday = _kFullDayNames[day.weekday % 7];
    return '$weekday ${day.day} ${_kMonthNames[day.month - 1]}';
  }

  List<String> get _weekdayAbbr => firstDayOfWeek == 1
      ? const ['M', 'T', 'W', 'T', 'F', 'S', 'S']
      : const ['S', 'M', 'T', 'W', 'T', 'F', 'S'];

  // ── Build ──────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final screenHeight = MediaQuery.sizeOf(context).height;
    final compactHeight = screenHeight < 520;
    final veryCompactHeight = screenHeight < 430;

    return Column(
      children: [
        _buildTopBar(
          compactHeight: compactHeight,
          veryCompactHeight: veryCompactHeight,
        ),
        _buildViewSwitcher(),
        if (viewMode == CalendarDisplayViewMode.month) ...[
          _buildWeekdayHeader(compactHeight: compactHeight),
          Flexible(
            fit: FlexFit.loose,
            child: _buildMonthGrid(
              compactHeight: compactHeight,
              veryCompactHeight: veryCompactHeight,
            ),
          ),
          const Divider(height: 1),
          Expanded(
            child: ListView(
              padding: EdgeInsets.zero,
              children: _buildDayAgendaItems(),
            ),
          ),
        ] else ...[
          Expanded(child: _buildAgendaMonthView()),
        ],
      ],
    );
  }

  Widget _buildTopBar({
    bool compactHeight = false,
    bool veryCompactHeight = false,
  }) {
    final outerPad =
        veryCompactHeight ? 2.0 : compactHeight ? 4.0 : CaleeSpacing.xs;
    final navIconMinH = compactHeight ? 36.0 : 44.0;
    final actionIconMinH = compactHeight ? 32.0 : 36.0;

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Padding(
          padding: EdgeInsets.fromLTRB(
            CaleeSpacing.xs,
            outerPad,
            CaleeSpacing.xs,
            0,
          ),
          child: Row(
            children: [
              IconButton(
                onPressed: onPreviousMonth,
                icon: const Icon(Icons.chevron_left),
                iconSize: 24,
                padding: EdgeInsets.zero,
                constraints: BoxConstraints(
                  minWidth: 44,
                  minHeight: navIconMinH,
                ),
                color: CaleeColors.primary,
                tooltip: 'Previous month',
              ),
              Expanded(
                child: Text(
                  _monthYearLabel,
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                    fontSize: 17,
                    fontWeight: FontWeight.w600,
                    color: CaleeColors.textPrimary,
                  ),
                ),
              ),
              IconButton(
                onPressed: onNextMonth,
                icon: const Icon(Icons.chevron_right),
                iconSize: 24,
                padding: EdgeInsets.zero,
                constraints: BoxConstraints(
                  minWidth: 44,
                  minHeight: navIconMinH,
                ),
                color: CaleeColors.primary,
                tooltip: 'Next month',
              ),
            ],
          ),
        ),
        Padding(
          padding: EdgeInsets.fromLTRB(
            CaleeSpacing.sm,
            0,
            CaleeSpacing.xs,
            outerPad,
          ),
          child: Row(
            children: [
              Tooltip(
                message: 'Go to today',
                child: TextButton(
                  onPressed: onGoToToday,
                  style: TextButton.styleFrom(
                    foregroundColor: CaleeColors.primary,
                    padding: const EdgeInsets.symmetric(
                      horizontal: CaleeSpacing.sm,
                      vertical: CaleeSpacing.xs,
                    ),
                    minimumSize: Size(44, actionIconMinH),
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  ),
                  child: const Text(
                    'Today',
                    style: TextStyle(fontSize: 14, fontWeight: FontWeight.w500),
                  ),
                ),
              ),
              const Spacer(),
              ...actionWidgets,
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildViewSwitcher() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        CaleeSpacing.md,
        0,
        CaleeSpacing.md,
        CaleeSpacing.xs,
      ),
      child: SegmentedButton<CalendarDisplayViewMode>(
        segments: const [
          ButtonSegment(
            value: CalendarDisplayViewMode.month,
            label: Text('Month'),
          ),
          ButtonSegment(
            value: CalendarDisplayViewMode.agenda,
            label: Text('Agenda'),
          ),
        ],
        selected: {viewMode},
        onSelectionChanged: (s) => onViewModeChanged(s.first),
        style: ButtonStyle(
          visualDensity: VisualDensity.compact,
          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
        ),
      ),
    );
  }

  Widget _buildWeekdayHeader({bool compactHeight = false}) {
    final vertPad = compactHeight ? 1.0 : 2.0;
    final fontSize = compactHeight ? 11.0 : 12.0;
    return Padding(
      padding: EdgeInsets.symmetric(
        horizontal: CaleeSpacing.xs,
        vertical: vertPad,
      ),
      child: Row(
        children: _weekdayAbbr
            .map(
              (d) => Expanded(
                child: Center(
                  child: Text(
                    d,
                    style: TextStyle(
                      fontSize: fontSize,
                      fontWeight: FontWeight.w500,
                      color: CaleeColors.textSecondary,
                    ),
                  ),
                ),
              ),
            )
            .toList(),
      ),
    );
  }

  Widget _buildMonthGrid({
    bool compactHeight = false,
    bool veryCompactHeight = false,
  }) {
    final gridStart = _gridStart;
    return LayoutBuilder(
      builder: (context, constraints) {
        final cellSize = constraints.maxWidth / 7;
        final desiredHeight = cellSize * 6;
        final height = constraints.hasBoundedHeight
            ? desiredHeight.clamp(0.0, constraints.maxHeight)
            : desiredHeight;
        return SizedBox(
          height: height,
          child: GridView.builder(
            physics: const NeverScrollableScrollPhysics(),
            gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: 7,
            ),
            itemCount: 42,
            itemBuilder: (context, index) {
              final date = gridStart.add(Duration(days: index));
              final dayEvents = _eventsForDay(date);
              final dotColors = dayEvents.take(3).map((e) => e.color).toList();
              return CalendarDayCell(
                date: date,
                isCurrentMonth: date.month == selectedMonth.month,
                isToday: isSameCalendarDay(date, today),
                isSelected: isSameCalendarDay(date, selectedDay),
                dotColors: dotColors,
                eventCount: dayEvents.length,
                compactHeight: compactHeight,
                veryCompactHeight: veryCompactHeight,
                onTap: () => onSelectDay(date),
              );
            },
          ),
        );
      },
    );
  }

  Widget _buildAgendaSectionHeading(String label) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        CaleeSpacing.md,
        CaleeSpacing.sm,
        CaleeSpacing.md,
        2,
      ),
      child: Text(
        label,
        style: const TextStyle(
          fontSize: 11,
          fontWeight: FontWeight.w600,
          color: CaleeColors.textSecondary,
          letterSpacing: 0.4,
        ),
      ),
    );
  }

  List<Widget> _buildDayAgendaItems() {
    final items = <Widget>[];

    items.add(
      Padding(
        padding: const EdgeInsets.fromLTRB(
          CaleeSpacing.md,
          CaleeSpacing.md,
          CaleeSpacing.md,
          CaleeSpacing.xs,
        ),
        child: Text(
          _agendaDateLabel(selectedDay),
          style: TextStyle(
            fontSize: 13,
            fontWeight: FontWeight.w600,
            color: isSameCalendarDay(selectedDay, today)
                ? CaleeColors.primary
                : CaleeColors.textSecondary,
            letterSpacing: 0.2,
          ),
        ),
      ),
    );

    final dayEvents = _eventsForDay(selectedDay);
    final allDayEvents = dayEvents.where((e) => e.allDay).toList();
    final timedEvents = dayEvents.where((e) => !e.allDay).toList();

    if (dayEvents.isEmpty) {
      items.add(
        Padding(
          padding: const EdgeInsets.symmetric(
            horizontal: CaleeSpacing.md,
            vertical: CaleeSpacing.lg,
          ),
          child: Center(
            child: Text(
              'No events this day',
              style: TextStyle(fontSize: 15, color: CaleeColors.textTertiary),
            ),
          ),
        ),
      );
    } else {
      if (allDayEvents.isNotEmpty) {
        items.add(_buildAgendaSectionHeading('All-day'));
        for (final event in allDayEvents) {
          items.add(
            ReadOnlyCalendarEventRow(
              event: event,
              hideTime: true,
              use24h: use24h,
              onTap: onEventTap != null ? () => onEventTap!(event) : null,
            ),
          );
        }
      }
      if (timedEvents.isNotEmpty) {
        items.add(_buildAgendaSectionHeading('Events'));
        for (final event in timedEvents) {
          items.add(
            ReadOnlyCalendarEventRow(
              event: event,
              use24h: use24h,
              onTap: onEventTap != null ? () => onEventTap!(event) : null,
            ),
          );
        }
      }
    }

    items.add(const SizedBox(height: CaleeSpacing.xl));
    return items;
  }

  Widget _buildAgendaMonthView() {
    final month = selectedMonth;
    final daysInMonth = DateUtils.getDaysInMonth(month.year, month.month);
    final dayWidgets = <Widget>[];
    var hasAnyEvent = false;

    for (var d = 1; d <= daysInMonth; d++) {
      final day = DateTime(month.year, month.month, d);
      final dayEvents = _eventsForDay(day);
      if (dayEvents.isEmpty) continue;

      hasAnyEvent = true;
      dayWidgets.add(
        Padding(
          padding: const EdgeInsets.fromLTRB(
            CaleeSpacing.md,
            CaleeSpacing.md,
            CaleeSpacing.md,
            2,
          ),
          child: Text(
            _agendaDateLabel(day),
            style: TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w600,
              color: isSameCalendarDay(day, today)
                  ? CaleeColors.primary
                  : CaleeColors.textSecondary,
              letterSpacing: 0.2,
            ),
          ),
        ),
      );

      final allDay = dayEvents.where((e) => e.allDay).toList();
      final timed = dayEvents.where((e) => !e.allDay).toList();
      for (final event in [...allDay, ...timed]) {
        dayWidgets.add(
          ReadOnlyCalendarEventRow(
            event: event,
            hideTime: event.allDay,
            use24h: use24h,
            onTap: onEventTap != null ? () => onEventTap!(event) : null,
          ),
        );
      }
    }

    if (!hasAnyEvent) {
      return ListView(
        padding: const EdgeInsets.symmetric(vertical: CaleeSpacing.xl),
        children: [
          Center(
            child: Text(
              'No events this month',
              style: TextStyle(fontSize: 15, color: CaleeColors.textTertiary),
            ),
          ),
        ],
      );
    }

    dayWidgets.add(const SizedBox(height: CaleeSpacing.xl));
    return ListView(padding: EdgeInsets.zero, children: dayWidgets);
  }
}

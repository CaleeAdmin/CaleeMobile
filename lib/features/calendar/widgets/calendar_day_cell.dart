import 'package:flutter/material.dart';

import '../../../ui/calee_design.dart';
import 'calendar_widget_helpers.dart';

class CalendarDayCell extends StatelessWidget {
  const CalendarDayCell({
    required this.date,
    required this.isCurrentMonth,
    required this.isToday,
    required this.isSelected,
    required this.dotColors,
    required this.eventCount,
    required this.onTap,
    this.compactHeight = false,
    this.veryCompactHeight = false,
    super.key,
  });

  final DateTime date;
  final bool isCurrentMonth;
  final bool isToday;
  final bool isSelected;
  final List<Color> dotColors;
  final int eventCount;
  final VoidCallback onTap;
  final bool compactHeight;
  final bool veryCompactHeight;

  String get _semanticLabel {
    final parts = <String>[
      '${date.day} ${kCalendarMonthAbbr[date.month - 1]} ${date.year}',
      if (isToday) 'today',
      if (isSelected) 'selected',
      if (eventCount == 1) '1 event',
      if (eventCount > 1) '$eventCount events',
    ];
    return parts.join(', ');
  }

  @override
  Widget build(BuildContext context) {
    final Color numberColor;
    final Color? bgColor;

    if (isToday || isSelected) {
      bgColor = isToday
          ? CaleeColors.primary
          : CaleeColors.primary.withAlpha(CaleeAlpha.pct12);
      numberColor = isToday ? Colors.white : CaleeColors.primary;
    } else if (isCurrentMonth) {
      bgColor = null;
      numberColor = CaleeColors.textPrimary;
    } else {
      bgColor = null;
      numberColor = CaleeColors.textTertiary;
    }

    final double circleSize;
    final double fontSize;
    final double dotSize;
    final double dotGap;
    final double verticalGap;
    final bool showDots;

    if (veryCompactHeight) {
      circleSize = 22;
      fontSize = 12;
      dotSize = 4;
      dotGap = 1.5;
      verticalGap = 0;
      showDots = false;
    } else if (compactHeight) {
      circleSize = 24;
      fontSize = 12;
      dotSize = 4;
      dotGap = 1.5;
      verticalGap = 1;
      showDots = true;
    } else {
      circleSize = 30;
      fontSize = 14;
      dotSize = 5;
      dotGap = 2;
      verticalGap = 3;
      showDots = true;
    }

    return Semantics(
      label: _semanticLabel,
      selected: isSelected,
      button: true,
      child: GestureDetector(
        onTap: onTap,
        behavior: HitTestBehavior.opaque,
        child: ClipRect(
          child: FittedBox(
            fit: BoxFit.scaleDown,
            alignment: Alignment.center,
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  width: circleSize,
                  height: circleSize,
                  decoration: bgColor != null
                      ? BoxDecoration(color: bgColor, shape: BoxShape.circle)
                      : null,
                  alignment: Alignment.center,
                  child: Text(
                    '${date.day}',
                    style: TextStyle(
                      fontSize: fontSize,
                      fontWeight: isToday ? FontWeight.w700 : FontWeight.w400,
                      color: numberColor,
                    ),
                  ),
                ),
                if (verticalGap > 0) SizedBox(height: verticalGap),
                _EventDots(
                  colors: showDots ? dotColors : const [],
                  dotSize: dotSize,
                  gap: dotGap,
                  hidden: !showDots,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _EventDots extends StatelessWidget {
  const _EventDots({
    required this.colors,
    this.dotSize = 5,
    this.gap = 2,
    this.hidden = false,
  });

  final List<Color> colors;
  final double dotSize;
  final double gap;
  final bool hidden;

  @override
  Widget build(BuildContext context) {
    if (hidden) return const SizedBox.shrink();

    if (colors.isEmpty) {
      return SizedBox(height: dotSize);
    }

    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        for (int i = 0; i < colors.length; i++) ...[
          if (i > 0) SizedBox(width: gap),
          Container(
            width: dotSize,
            height: dotSize,
            decoration: BoxDecoration(color: colors[i], shape: BoxShape.circle),
          ),
        ],
      ],
    );
  }
}

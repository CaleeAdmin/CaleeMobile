enum CaleeRepeatKind {
  none,
  daily,
  weekdays,
  weekly,
  fortnightly,
  monthly,
  yearly,
  customDays,
}

class CaleeRepeatRule {
  const CaleeRepeatRule({required this.kind, this.weekdays = const <int>{}});

  final CaleeRepeatKind kind;

  /// DateTime weekday values, Monday=1 ... Sunday=7.
  final Set<int> weekdays;

  static const none = CaleeRepeatRule(kind: CaleeRepeatKind.none);
  static const daily = CaleeRepeatRule(kind: CaleeRepeatKind.daily);
  static const weekdaysOnly = CaleeRepeatRule(
    kind: CaleeRepeatKind.weekdays,
    weekdays: {
      DateTime.monday,
      DateTime.tuesday,
      DateTime.wednesday,
      DateTime.thursday,
      DateTime.friday,
    },
  );
  static const monthly = CaleeRepeatRule(kind: CaleeRepeatKind.monthly);
  static const yearly = CaleeRepeatRule(kind: CaleeRepeatKind.yearly);

  bool get isNone => kind == CaleeRepeatKind.none;

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    if (other is! CaleeRepeatRule) return false;
    return kind == other.kind && _setEquals(weekdays, other.weekdays);
  }

  @override
  int get hashCode {
    final sorted = weekdays.toList()..sort();
    var hash = kind.hashCode;
    for (final day in sorted) {
      hash = Object.hash(hash, day);
    }
    return hash;
  }

  String? toRrule({DateTime? anchorDate}) {
    final anchorWeekday = anchorDate?.weekday ?? DateTime.monday;
    return switch (kind) {
      CaleeRepeatKind.none => null,
      CaleeRepeatKind.daily => 'FREQ=DAILY',
      CaleeRepeatKind.weekdays => 'FREQ=WEEKLY;BYDAY=MO,TU,WE,TH,FR',
      CaleeRepeatKind.weekly =>
        'FREQ=WEEKLY;BYDAY=${_icalWeekday(anchorWeekday)}',
      CaleeRepeatKind.fortnightly =>
        'FREQ=WEEKLY;INTERVAL=2;BYDAY=${_icalWeekday(anchorWeekday)}',
      CaleeRepeatKind.monthly => 'FREQ=MONTHLY',
      CaleeRepeatKind.yearly => 'FREQ=YEARLY',
      CaleeRepeatKind.customDays => _customDaysRrule(weekdays),
    };
  }

  String label({DateTime? anchorDate}) {
    final anchorWeekday = anchorDate?.weekday ?? DateTime.monday;
    return switch (kind) {
      CaleeRepeatKind.none => 'Does not repeat',
      CaleeRepeatKind.daily => 'Daily',
      CaleeRepeatKind.weekdays => 'Weekdays',
      CaleeRepeatKind.weekly => 'Every ${_weekdayName(anchorWeekday)}',
      CaleeRepeatKind.fortnightly =>
        'Every 2 weeks on ${_weekdayName(anchorWeekday)}',
      CaleeRepeatKind.monthly => 'Monthly',
      CaleeRepeatKind.yearly => 'Yearly',
      CaleeRepeatKind.customDays => _customDaysLabel(weekdays),
    };
  }

  static CaleeRepeatRule fromRrule(String? recurrence, {DateTime? anchorDate}) {
    final parts = _parseRrule(recurrence);
    final freq = parts['FREQ'];
    if (freq == null || freq.isEmpty) return none;

    if (freq == 'DAILY') return daily;
    if (freq == 'MONTHLY') return monthly;
    if (freq == 'YEARLY') return yearly;

    if (freq != 'WEEKLY') return none;

    final interval = parts['INTERVAL'];
    final byDay = _parseByDay(parts['BYDAY']);

    if (byDay.isEmpty) {
      return interval == '2'
          ? const CaleeRepeatRule(kind: CaleeRepeatKind.fortnightly)
          : const CaleeRepeatRule(kind: CaleeRepeatKind.weekly);
    }

    if (_setEquals(byDay, weekdaysOnly.weekdays)) return weekdaysOnly;

    if (byDay.length == 1) {
      return interval == '2'
          ? const CaleeRepeatRule(kind: CaleeRepeatKind.fortnightly)
          : const CaleeRepeatRule(kind: CaleeRepeatKind.weekly);
    }

    return CaleeRepeatRule(kind: CaleeRepeatKind.customDays, weekdays: byDay);
  }

  static String labelFromRrule(String? recurrence, {DateTime? anchorDate}) =>
      fromRrule(
        recurrence,
        anchorDate: anchorDate,
      ).label(anchorDate: anchorDate);

  static Map<String, String> _parseRrule(String? recurrence) {
    final value = (recurrence ?? '').trim();
    if (value.isEmpty) return const <String, String>{};

    final parts = <String, String>{};
    for (final part in value.split(';')) {
      final separator = part.indexOf('=');
      if (separator <= 0 || separator == part.length - 1) continue;
      parts[part.substring(0, separator).trim().toUpperCase()] = part
          .substring(separator + 1)
          .trim()
          .toUpperCase();
    }
    return parts;
  }

  static String? _customDaysRrule(Set<int> weekdays) {
    final sorted = weekdays.where((day) => day >= 1 && day <= 7).toList()
      ..sort();
    if (sorted.isEmpty) return null;
    return 'FREQ=WEEKLY;BYDAY=${sorted.map(_icalWeekday).join(',')}';
  }

  static Set<int> _parseByDay(String? value) {
    if (value == null || value.trim().isEmpty) return const <int>{};
    final result = <int>{};
    for (final token in value.split(',')) {
      final day = switch (token.trim().toUpperCase()) {
        'MO' => DateTime.monday,
        'TU' => DateTime.tuesday,
        'WE' => DateTime.wednesday,
        'TH' => DateTime.thursday,
        'FR' => DateTime.friday,
        'SA' => DateTime.saturday,
        'SU' => DateTime.sunday,
        _ => null,
      };
      if (day != null) result.add(day);
    }
    return result;
  }

  static String _icalWeekday(int weekday) {
    return switch (weekday) {
      DateTime.monday => 'MO',
      DateTime.tuesday => 'TU',
      DateTime.wednesday => 'WE',
      DateTime.thursday => 'TH',
      DateTime.friday => 'FR',
      DateTime.saturday => 'SA',
      DateTime.sunday => 'SU',
      _ => 'MO',
    };
  }

  static String _weekdayName(int weekday) {
    return switch (weekday) {
      DateTime.monday => 'Monday',
      DateTime.tuesday => 'Tuesday',
      DateTime.wednesday => 'Wednesday',
      DateTime.thursday => 'Thursday',
      DateTime.friday => 'Friday',
      DateTime.saturday => 'Saturday',
      DateTime.sunday => 'Sunday',
      _ => 'Monday',
    };
  }

  static String _shortWeekdayName(int weekday) {
    return switch (weekday) {
      DateTime.monday => 'Mon',
      DateTime.tuesday => 'Tue',
      DateTime.wednesday => 'Wed',
      DateTime.thursday => 'Thu',
      DateTime.friday => 'Fri',
      DateTime.saturday => 'Sat',
      DateTime.sunday => 'Sun',
      _ => 'Mon',
    };
  }

  static String _customDaysLabel(Set<int> weekdays) {
    final sorted = weekdays.where((day) => day >= 1 && day <= 7).toList()
      ..sort();
    if (sorted.isEmpty) return 'Custom days';
    if (_setEquals(sorted.toSet(), weekdaysOnly.weekdays)) return 'Weekdays';
    if (_setEquals(sorted.toSet(), {DateTime.saturday, DateTime.sunday})) {
      return 'Every weekend';
    }
    if (sorted.length == 1) return 'Every ${_weekdayName(sorted.first)}';
    if (sorted.length == 2) {
      return 'Every ${_weekdayName(sorted.first)} and ${_weekdayName(sorted.last)}';
    }
    final names = sorted.map(_shortWeekdayName).join(', ');
    return 'Every $names';
  }

  static bool _setEquals(Set<int> a, Set<int> b) {
    if (a.length != b.length) return false;
    for (final item in a) {
      if (!b.contains(item)) return false;
    }
    return true;
  }
}

import 'package:flutter_test/flutter_test.dart';

/// Returns true when tapping [tappedDate] should trigger a month switch
/// away from [currentMonth] (always the 1st of the displayed month).
bool shouldSwitchMonth(DateTime tappedDate, DateTime currentMonth) {
  assert(currentMonth.day == 1, 'currentMonth must be the 1st of the month');
  final tapMonth = DateTime(tappedDate.year, tappedDate.month, 1);
  return tapMonth.year != currentMonth.year ||
      tapMonth.month != currentMonth.month;
}

/// Returns the month to switch to when tapping [tappedDate].
DateTime targetMonth(DateTime tappedDate) =>
    DateTime(tappedDate.year, tappedDate.month, 1);

void main() {
  group('shouldSwitchMonth', () {
    final june2026 = DateTime(2026, 6, 1);

    test('returns false for a date in the current month', () {
      expect(shouldSwitchMonth(DateTime(2026, 6, 15), june2026), isFalse);
    });

    test('returns true for a date in the next month', () {
      expect(shouldSwitchMonth(DateTime(2026, 7, 5), june2026), isTrue);
    });

    test('returns true for a date in the previous month', () {
      expect(shouldSwitchMonth(DateTime(2026, 5, 28), june2026), isTrue);
    });

    test('returns true for a date in a different year', () {
      expect(shouldSwitchMonth(DateTime(2025, 12, 31), june2026), isTrue);
    });
  });

  group('targetMonth', () {
    test('returns 1st of the month for a next-month tap', () {
      final target = targetMonth(DateTime(2026, 7, 5));
      expect(target, DateTime(2026, 7, 1));
    });

    test('returns 1st of the month for a previous-month tap', () {
      final target = targetMonth(DateTime(2026, 5, 28));
      expect(target, DateTime(2026, 5, 1));
    });
  });
}

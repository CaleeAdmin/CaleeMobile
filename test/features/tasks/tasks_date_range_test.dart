import 'package:flutter_test/flutter_test.dart';

/// Mirrors the date-range calculation in TasksPage._loadOverview() so we can
/// verify the ±2-year window without spinning up the full widget.
({String from, String to}) tasksDateRange(DateTime now) {
  String fmt(DateTime d) {
    final y = d.year.toString().padLeft(4, '0');
    final m = d.month.toString().padLeft(2, '0');
    final day = d.day.toString().padLeft(2, '0');
    return '$y-$m-$day';
  }

  return (
    from: fmt(DateTime(now.year - 2, 1, 1)),
    to: fmt(DateTime(now.year + 2, 12, 31)),
  );
}

void main() {
  group('tasksDateRange', () {
    test('from is Jan 1 two years before now', () {
      final now = DateTime(2026, 6, 2);
      final range = tasksDateRange(now);
      expect(range.from, '2024-01-01');
    });

    test('to is Dec 31 two years after now', () {
      final now = DateTime(2026, 6, 2);
      final range = tasksDateRange(now);
      expect(range.to, '2028-12-31');
    });

    test('includes Dec 2025 task when current year is 2026', () {
      final now = DateTime(2026, 6, 2);
      final range = tasksDateRange(now);
      final dec2025 = DateTime(2025, 12, 15);
      expect(
        dec2025.isAfter(DateTime.parse('${range.from}T00:00:00')) ||
            dec2025.isAtSameMomentAs(DateTime.parse('${range.from}T00:00:00')),
        isTrue,
        reason: 'Dec 2025 should fall within the loaded range',
      );
    });

    test('includes Jan 2027 task when current year is 2026', () {
      final now = DateTime(2026, 6, 2);
      final range = tasksDateRange(now);
      final jan2027 = DateTime(2027, 1, 15);
      expect(
        jan2027.isBefore(DateTime.parse('${range.to}T23:59:59')) ||
            jan2027.isAtSameMomentAs(DateTime.parse('${range.to}T23:59:59')),
        isTrue,
        reason: 'Jan 2027 should fall within the loaded range',
      );
    });
  });
}

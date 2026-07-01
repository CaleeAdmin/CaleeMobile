import 'package:calee_mobile/shared/recurrence/calee_repeat_rule.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('CaleeRepeatRule', () {
    final sunday = DateTime(2026, 6, 28);

    test('builds simple RRULEs', () {
      expect(CaleeRepeatRule.none.toRrule(anchorDate: sunday), isNull);
      expect(CaleeRepeatRule.daily.toRrule(anchorDate: sunday), 'FREQ=DAILY');
      expect(
        CaleeRepeatRule.weekdaysOnly.toRrule(anchorDate: sunday),
        'FREQ=WEEKLY;BYDAY=MO,TU,WE,TH,FR',
      );
      expect(
        const CaleeRepeatRule(
          kind: CaleeRepeatKind.weekly,
        ).toRrule(anchorDate: sunday),
        'FREQ=WEEKLY;BYDAY=SU',
      );
      expect(
        const CaleeRepeatRule(
          kind: CaleeRepeatKind.fortnightly,
        ).toRrule(anchorDate: sunday),
        'FREQ=WEEKLY;INTERVAL=2;BYDAY=SU',
      );
      expect(
        CaleeRepeatRule.monthly.toRrule(anchorDate: sunday),
        'FREQ=MONTHLY',
      );
      expect(CaleeRepeatRule.yearly.toRrule(anchorDate: sunday), 'FREQ=YEARLY');
    });

    test('builds custom day RRULEs', () {
      const rule = CaleeRepeatRule(
        kind: CaleeRepeatKind.customDays,
        weekdays: {DateTime.monday, DateTime.wednesday, DateTime.friday},
      );
      expect(rule.toRrule(anchorDate: sunday), 'FREQ=WEEKLY;BYDAY=MO,WE,FR');
      expect(rule.label(anchorDate: sunday), 'Every Mon, Wed, Fri');
    });

    test('parses shared mobile and tablet RRULEs', () {
      expect(
        CaleeRepeatRule.fromRrule('FREQ=WEEKLY;BYDAY=MO,TU,WE,TH,FR'),
        CaleeRepeatRule.weekdaysOnly,
      );
      expect(
        CaleeRepeatRule.fromRrule('FREQ=WEEKLY;BYDAY=SU'),
        const CaleeRepeatRule(kind: CaleeRepeatKind.weekly),
      );
      expect(
        CaleeRepeatRule.fromRrule('FREQ=WEEKLY;INTERVAL=2;BYDAY=SU'),
        const CaleeRepeatRule(kind: CaleeRepeatKind.fortnightly),
      );
      expect(
        CaleeRepeatRule.fromRrule('FREQ=WEEKLY;BYDAY=MO,WE,FR'),
        const CaleeRepeatRule(
          kind: CaleeRepeatKind.customDays,
          weekdays: {DateTime.monday, DateTime.wednesday, DateTime.friday},
        ),
      );
    });
  });
}

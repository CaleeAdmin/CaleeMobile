import 'package:flutter_test/flutter_test.dart';
import 'package:timezone/data/latest.dart' as tz_data;
import 'package:timezone/timezone.dart' as tz;

import 'package:calee_mobile/features/calendar/shared/calendar_display_event_adapters.dart';
import 'package:calee_mobile/features/local_subscriber/local_calendar_ics_service.dart';
import 'package:calee_mobile/features/local_subscriber/local_calendar_subscription.dart';

/// End-to-end regression for the phone-only ("Added on this phone only")
/// calendar timezone incident.
///
/// "Have a go day" on the Morley Eagles (Club) calendar is 2:00 PM–4:00 PM on
/// Sunday 9 August 2026 in Australia/Perth. Nextcloud shows 14:00–16:00; the
/// phone-only flow showed 06:00–08:00 — the correct UTC instant, rendered in
/// UTC instead of the device timezone.
///
/// This walks the real path — ICS text → LocalCalendarIcsService →
/// LocalCalendarEvent → calendarDisplayEventFromLocalEvent →
/// CalendarDisplayEvent — and asserts the instant survives parsing and is
/// localized before display.
///
/// A TZID-qualified value is parsed into a package:timezone [tz.TZDateTime],
/// whose `toLocal()` resolves against `tz.local` rather than the process clock,
/// so these tests configure `tz.setLocalLocation` exactly as `main.dart` does
/// on startup. That also makes the Perth expectations below independent of the
/// timezone the test process happens to run in.
///
/// LocalCalendarIcsService.parseBody only keeps events inside a fetch window
/// anchored to "now", so the ICS below reuses the incident's exact wall time
/// and TZID on a nearby date. The literal 9 August 2026 instants are asserted
/// in calendar_display_event_test.dart, which needs no window.
void main() {
  late tz.Location perth;

  setUpAll(() {
    tz_data.initializeTimeZones();
    perth = tz.getLocation('Australia/Perth');
    tz.setLocalLocation(perth);
  });

  const service = LocalCalendarIcsService();

  final subscription = LocalCalendarSubscription(
    id: 'sub_morley',
    title: 'Morley Eagles (Club)',
    url: 'https://example.com/morley.ics',
    source: 'example.com',
    createdAt: DateTime(2024, 1, 1),
  );

  String pad(int value) => value.toString().padLeft(2, '0');

  /// A Perth 14:00–16:00 event a few days out, so it always lands inside the
  /// service's fetch window. Australia/Perth has no DST, so 14:00 there is
  /// always 06:00 UTC.
  ({String ics, tz.TZDateTime day}) buildIncidentIcs() {
    final day = tz.TZDateTime.now(perth).add(const Duration(days: 10));
    final date = '${day.year}${pad(day.month)}${pad(day.day)}';
    final ics = [
      'BEGIN:VCALENDAR',
      'VERSION:2.0',
      'PRODID:-//Nextcloud//Calendar//EN',
      'BEGIN:VEVENT',
      'UID:have-a-go-day@morley.test',
      'SUMMARY:Have a go day',
      'DTSTART;TZID=Australia/Perth:${date}T140000',
      'DTEND;TZID=Australia/Perth:${date}T160000',
      'END:VEVENT',
      'END:VCALENDAR',
    ].join('\r\n');
    return (ics: ics, day: day);
  }

  group('phone-only Perth event', () {
    test('parses to the correct UTC instant', () {
      final events = service.parseBody(buildIncidentIcs().ics, subscription);

      expect(events, hasLength(1));
      final event = events.single;
      expect(event.title, 'Have a go day');
      expect(event.isAllDay, isFalse);
      // 14:00 Perth is 06:00 UTC; 16:00 Perth is 08:00 UTC.
      expect(event.start.toUtc().hour, 6);
      expect(event.end!.toUtc().hour, 8);
    });

    test('is localized before it reaches the shared calendar view', () {
      final event = service
          .parseBody(buildIncidentIcs().ics, subscription)
          .single;
      final display = calendarDisplayEventFromLocalEvent(
        event,
        subscription: subscription,
      );

      expect(display.start.isUtc, isFalse);
      expect(display.end!.isUtc, isFalse);
      // Localizing must not move the instant, only how it is expressed.
      expect(display.start.isAtSameMomentAs(event.start), isTrue);
      expect(display.end!.isAtSameMomentAs(event.end!), isTrue);
      expect(display.allDay, isFalse);
      expect(display.calendarName, 'Morley Eagles (Club)');
      expect(display.readOnly, isTrue);
    });

    test('shows 14:00–16:00 on a Perth device, not 06:00–08:00', () {
      final built = buildIncidentIcs();
      final event = service.parseBody(built.ics, subscription).single;
      final display = calendarDisplayEventFromLocalEvent(
        event,
        subscription: subscription,
      );

      expect(display.start.hour, 14);
      expect(display.start.minute, 0);
      expect(display.end!.hour, 16);
      expect(display.end!.minute, 0);
      expect(display.start.year, built.day.year);
      expect(display.start.month, built.day.month);
      expect(display.start.day, built.day.day);
    });
  });
}

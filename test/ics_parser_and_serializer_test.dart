import 'package:caleesync/common/utils/IcsParser.dart';
import 'package:caleesync/common/utils/IcsSerializer.dart';
import 'package:caleesync/services/calee_server_service.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('IcsParser.parse', () {
    test('parses VEVENT DTSTART instead of VTIMEZONE DTSTART', () {
      const String ics = 'BEGIN:VCALENDAR\r\n'
          'BEGIN:VTIMEZONE\r\n'
          'TZID:Australia/Perth\r\n'
          'BEGIN:STANDARD\r\n'
          'DTSTART:20071027T180000Z\r\n'
          'TZOFFSETFROM:+0800\r\n'
          'TZOFFSETTO:+0800\r\n'
          'END:STANDARD\r\n'
          'END:VTIMEZONE\r\n'
          'BEGIN:VEVENT\r\n'
          'UID:royal-cruise\r\n'
          'SUMMARY:Royal Carribean Cruise\r\n'
          'DTSTART;TZID=Australia/Perth:20261212T160000\r\n'
          'DTEND;TZID=Australia/Perth:20261220T063000\r\n'
          'LOCATION:Fremantle\r\n'
          'END:VEVENT\r\n'
          'END:VCALENDAR\r\n';

      final parsed = IcsParser.parse(ics, 'fallback');

      expect(parsed['uid'], 'royal-cruise');
      expect(parsed['parse_source'], 'VEVENT');
      expect(parsed['dtstart'], DateTime(2026, 12, 12, 16, 0).millisecondsSinceEpoch);
      expect(parsed['dtend'], DateTime(2026, 12, 20, 6, 30).millisecondsSinceEpoch);
      expect((parsed['dtstart_meta'] as Map<String, dynamic>)['tzid'], 'Australia/Perth');
    });

    test('preserves all-day VALUE=DATE metadata', () {
      const String ics = 'BEGIN:VCALENDAR\n'
          'BEGIN:VEVENT\n'
          'UID:allday\n'
          'DTSTART;VALUE=DATE:20261212\n'
          'DTEND;VALUE=DATE:20261213\n'
          'SUMMARY:All Day\n'
          'END:VEVENT\n'
          'END:VCALENDAR\n';

      final parsed = IcsParser.parse(ics, 'fallback');
      final meta = parsed['dtstart_meta'] as Map<String, dynamic>;

      expect(parsed['dtstart'], DateTime(2026, 12, 12).millisecondsSinceEpoch);
      expect(meta['isDateOnly'], isTrue);
      expect((meta['params'] as Map<String, dynamic>)['VALUE'], 'DATE');
    });

    test('preserves UTC date-time metadata', () {
      const String ics = 'BEGIN:VCALENDAR\n'
          'BEGIN:VEVENT\n'
          'UID:utc\n'
          'DTSTART:20261212T080000Z\n'
          'DTEND:20261212T090000Z\n'
          'SUMMARY:UTC Event\n'
          'END:VEVENT\n'
          'END:VCALENDAR\n';

      final parsed = IcsParser.parse(ics, 'fallback');
      final meta = parsed['dtstart_meta'] as Map<String, dynamic>;

      expect(parsed['dtstart'], DateTime.utc(2026, 12, 12, 8).millisecondsSinceEpoch);
      expect(meta['isUtc'], isTrue);
    });

    test('builds recurring instance identity from UID plus RECURRENCE-ID', () {
      const String ics = 'BEGIN:VCALENDAR\n'
          'BEGIN:VEVENT\n'
          'UID:series-1\n'
          'RECURRENCE-ID;TZID=Australia/Perth:20261214T160000\n'
          'DTSTART;TZID=Australia/Perth:20261215T170000\n'
          'DTEND;TZID=Australia/Perth:20261215T180000\n'
          'SUMMARY:Override\n'
          'END:VEVENT\n'
          'END:VCALENDAR\n';

      final parsed = IcsParser.parse(ics, 'fallback');

      expect(parsed['recurrence_id'], '20261214T160000');
      expect(parsed['instance_key'], 'series-1::20261214T160000');
      expect(parsed['dtstart'], DateTime(2026, 12, 15, 17).millisecondsSinceEpoch);
    });

    test('parses Outlook-style UID and returns uid_kind = outlook', () {
      const String ics = 'BEGIN:VCALENDAR\n'
          'BEGIN:VEVENT\n'
          'UID:040000008200E00074C5B7101A82E00800000000A1B2C3D4E5F60708\n'
          'DTSTART:20261212T080000Z\n'
          'DTEND:20261212T090000Z\n'
          'SUMMARY:Outlook Event\n'
          'END:VEVENT\n'
          'END:VCALENDAR\n';

      final parsed = IcsParser.parse(ics, 'fallback');
      expect(parsed['uid_kind'], 'outlook');
      expect(parsed['is_exchange_risk'], isTrue);
    });

    test('marks Exchange-risk when ATTENDEE exists', () {
      const String ics = 'BEGIN:VCALENDAR\n'
          'BEGIN:VEVENT\n'
          'UID:attendee-risk\n'
          'DTSTART:20261212T080000Z\n'
          'DTEND:20261212T090000Z\n'
          'SUMMARY:Attendee Risk\n'
          'ATTENDEE:mailto:test@example.com\n'
          'END:VEVENT\n'
          'END:VCALENDAR\n';

      final parsed = IcsParser.parse(ics, 'fallback');
      expect(parsed['has_attendees'], isTrue);
      expect(parsed['is_exchange_risk'], isTrue);
    });

    test('marks Exchange-risk when ORGANIZER exists', () {
      const String ics = 'BEGIN:VCALENDAR\n'
          'BEGIN:VEVENT\n'
          'UID:organizer-risk\n'
          'DTSTART:20261212T080000Z\n'
          'DTEND:20261212T090000Z\n'
          'SUMMARY:Organizer Risk\n'
          'ORGANIZER:mailto:test@example.com\n'
          'END:VEVENT\n'
          'END:VCALENDAR\n';

      final parsed = IcsParser.parse(ics, 'fallback');
      expect(parsed['has_organizer'], isTrue);
      expect(parsed['is_exchange_risk'], isTrue);
    });

    test('marks Exchange-risk when BEGIN:VALARM exists', () {
      const String ics = 'BEGIN:VCALENDAR\n'
          'BEGIN:VEVENT\n'
          'UID:alarm-risk\n'
          'DTSTART:20261212T080000Z\n'
          'DTEND:20261212T090000Z\n'
          'SUMMARY:Alarm Risk\n'
          'BEGIN:VALARM\n'
          'TRIGGER:-PT15M\n'
          'ACTION:DISPLAY\n'
          'DESCRIPTION:Reminder\n'
          'END:VALARM\n'
          'END:VEVENT\n'
          'END:VCALENDAR\n';

      final parsed = IcsParser.parse(ics, 'fallback');
      expect(parsed['has_alarm'], isTrue);
      expect(parsed['is_exchange_risk'], isTrue);
    });

    test('marks Exchange-risk when Apple Exchange marker exists', () {
      const String ics = 'BEGIN:VCALENDAR\n'
          'BEGIN:VEVENT\n'
          'UID:apple-marker-risk\n'
          'DTSTART:20261212T080000Z\n'
          'DTEND:20261212T090000Z\n'
          'SUMMARY:Apple Marker Risk\n'
          'X-APPLE-CREATOR-IDENTITY:com.apple.exchangesync.exchangesyncd\n'
          'END:VEVENT\n'
          'END:VCALENDAR\n';

      final parsed = IcsParser.parse(ics, 'fallback');
      expect(parsed['has_x_apple_exchange_markers'], isTrue);
      expect(parsed['is_exchange_risk'], isTrue);
    });

    test('marks Exchange-risk when DTSTART has TZID', () {
      const String ics = 'BEGIN:VCALENDAR\n'
          'BEGIN:VEVENT\n'
          'UID:tzid-risk\n'
          'DTSTART;TZID=Asia/Tokyo:20261212T160000\n'
          'DTEND;TZID=Asia/Tokyo:20261212T170000\n'
          'SUMMARY:TZID Risk\n'
          'END:VEVENT\n'
          'END:VCALENDAR\n';

      final parsed = IcsParser.parse(ics, 'fallback');
      expect(parsed['is_exchange_risk'], isTrue);
    });

    test('does not mark plain simple event as Exchange-risk', () {
      const String ics = 'BEGIN:VCALENDAR\n'
          'BEGIN:VEVENT\n'
          'UID:simple-uid\n'
          'DTSTART:20261212T080000Z\n'
          'DTEND:20261212T090000Z\n'
          'SUMMARY:Simple Event\n'
          'END:VEVENT\n'
          'END:VCALENDAR\n';

      final parsed = IcsParser.parse(ics, 'fallback');
      expect(parsed['is_exchange_risk'], isFalse);
      expect(parsed['uid_kind'], 'other');
    });

    test('returns raw_vevent containing BEGIN:VEVENT and END:VEVENT', () {
      const String ics = 'BEGIN:VCALENDAR\n'
          'BEGIN:VEVENT\n'
          'UID:raw-vevent\n'
          'DTSTART:20261212T080000Z\n'
          'DTEND:20261212T090000Z\n'
          'SUMMARY:Raw VEVENT\n'
          'END:VEVENT\n'
          'END:VCALENDAR\n';

      final parsed = IcsParser.parse(ics, 'fallback');
      final rawVevent = parsed['raw_vevent']?.toString() ?? '';
      expect(rawVevent, contains('BEGIN:VEVENT'));
      expect(rawVevent, contains('END:VEVENT'));
    });
  });

  group('IcsSerializer', () {
    test('round-trips rich event fields and timezone-bound local times', () {
      final start = DateTime(2026, 12, 12, 16, 0);
      final end = DateTime(2026, 12, 20, 6, 30);
      final ics = IcsSerializer.toIcs(
        uid: 'royal-cruise',
        summary: 'Royal Carribean Cruise',
        description: 'Ocean view',
        location: 'Fremantle',
        url: 'https://example.com/cruise',
        recurrenceId: '20261214T160000',
        rrule: 'FREQ=DAILY;COUNT=2',
        created: '20260101T010101Z',
        lastModified: '20260102T020202Z',
        dtstartMeta: const {
          'tzid': 'Australia/Perth',
          'params': {'TZID': 'Australia/Perth'},
        },
        dtendMeta: const {
          'tzid': 'Australia/Perth',
          'params': {'TZID': 'Australia/Perth'},
        },
        start: start,
        end: end,
      );

      expect(ics, contains('DTSTART;TZID=Australia/Perth:20261212T160000'));
      expect(ics, contains('DTEND;TZID=Australia/Perth:20261220T063000'));
      expect(ics, contains('LOCATION:Fremantle'));
      expect(ics, contains('RECURRENCE-ID:20261214T160000'));
      expect(ics, contains('RRULE:FREQ=DAILY;COUNT=2'));
    });
  });

  group('CaleeServerService.uploadEventData', () {
    test('blocks implausible ancient-start modern-end payloads before upload', () async {
      final service = CaleeServerService();
      final result = await service.uploadEventData(
        userId: 'user',
        calendarPath: '/remote.php/dav/calendars/user/test/',
        uid: 'broken-event',
        title: 'Broken Event',
        parseSource: 'VEVENT',
        start: DateTime.utc(2007, 10, 27, 18),
        end: DateTime.utc(2026, 12, 20, 6, 30),
      );

      expect(result, isNull);
    });
  });
}

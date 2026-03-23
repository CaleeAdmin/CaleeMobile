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

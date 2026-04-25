import 'package:caleesync/common/utils/IcsParser.dart';
import 'package:caleesync/common/utils/IcsSerializer.dart';
import 'package:caleesync/common/utils/UidGenerator.dart';
import 'package:caleesync/services/calee_server_service.dart';
import 'package:flutter_test/flutter_test.dart';

class _RecordingCaleeServerService extends CaleeServerService {
  String? lastPutIcsData;
  String? lastPutTargetEventPath;
  String? lastPutUid;
  int putCallCount = 0;

  @override
  Future<String?> putEvent({
    required String calendarPath,
    required String uid,
    required String icsData,
    required String userId,
    String? targetEventPath,
  }) async {
    putCallCount += 1;
    lastPutUid = uid;
    lastPutIcsData = icsData;
    lastPutTargetEventPath = targetEventPath;
    return 'etag-test';
  }
}

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
      expect(parsed['dtstart'], DateTime.utc(2026, 12, 12, 8, 0).millisecondsSinceEpoch);
      expect(parsed['dtend'], DateTime.utc(2026, 12, 19, 22, 30).millisecondsSinceEpoch);
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

      expect(parsed['dtstart'], DateTime.utc(2026, 12, 12).millisecondsSinceEpoch);
      expect(parsed['dtend'], DateTime.utc(2026, 12, 13).millisecondsSinceEpoch);
      expect(meta['isDateOnly'], isTrue);
      expect((meta['params'] as Map<String, dynamic>)['VALUE'], 'DATE');
    });

    test('parses Google all-day VALUE=DATE as UTC midnight Android-compatible millis', () {
      const String ics = 'BEGIN:VCALENDAR\n'
          'BEGIN:VEVENT\n'
          'UID:google-all-day\n'
          'DTSTART;VALUE=DATE:20260425\n'
          'DTEND;VALUE=DATE:20260426\n'
          'SUMMARY:Google All Day\n'
          'END:VEVENT\n'
          'END:VCALENDAR\n';

      final parsed = IcsParser.parse(ics, 'fallback');

      expect(parsed['dtstart'], DateTime.utc(2026, 4, 25).millisecondsSinceEpoch);
      expect(parsed['dtend'], DateTime.utc(2026, 4, 26).millisecondsSinceEpoch);

      final startMeta = parsed['dtstart_meta'] as Map<String, dynamic>;
      final endMeta = parsed['dtend_meta'] as Map<String, dynamic>;
      expect(startMeta['isDateOnly'], isTrue);
      expect(endMeta['isDateOnly'], isTrue);
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
      expect(parsed['dtstart'], DateTime.utc(2026, 12, 15, 9).millisecondsSinceEpoch);
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

    test('mergeIntoExistingVevent preserves attendees and organizer', () {
      const String original = 'BEGIN:VEVENT\r\n'
          'UID:evt-1\r\n'
          'DTSTART:20261212T160000Z\r\n'
          'DTEND:20261212T170000Z\r\n'
          'SUMMARY:Old\r\n'
          'ATTENDEE:mailto:a@example.com\r\n'
          'ORGANIZER:mailto:owner@example.com\r\n'
          'END:VEVENT\r\n';

      final merged = IcsSerializer.mergeIntoExistingVevent(
        originalVeventBlock: original,
        uid: 'evt-1',
        summary: 'New Summary',
        start: DateTime.utc(2026, 12, 13, 16),
        end: DateTime.utc(2026, 12, 13, 17),
        dtstartMeta: const {'isUtc': true, 'params': {}, 'tzid': null, 'isDateOnly': false},
        dtendMeta: const {'isUtc': true, 'params': {}, 'tzid': null, 'isDateOnly': false},
      );

      expect(merged, contains('ATTENDEE:mailto:a@example.com'));
      expect(merged, contains('ORGANIZER:mailto:owner@example.com'));
      expect(merged, contains('SUMMARY:New Summary'));
      expect(merged, contains('DTSTART:20261213T160000Z'));
      expect(merged, contains('DTEND:20261213T170000Z'));
    });

    test('mergeIntoExistingVevent preserves VALARM block', () {
      const String original = 'BEGIN:VEVENT\r\n'
          'UID:evt-2\r\n'
          'DTSTART:20261212T160000Z\r\n'
          'DTEND:20261212T170000Z\r\n'
          'SUMMARY:Old\r\n'
          'BEGIN:VALARM\r\n'
          'TRIGGER:-PT15M\r\n'
          'ACTION:DISPLAY\r\n'
          'DESCRIPTION:Reminder\r\n'
          'END:VALARM\r\n'
          'END:VEVENT\r\n';

      final merged = IcsSerializer.mergeIntoExistingVevent(
        originalVeventBlock: original,
        uid: 'evt-2',
        summary: 'Updated',
        description: 'Updated desc',
        start: DateTime.utc(2026, 12, 12, 18),
        end: DateTime.utc(2026, 12, 12, 19),
      );

      expect(merged, contains('BEGIN:VALARM'));
      expect(merged, contains('END:VALARM'));
      expect(merged, contains('SUMMARY:Updated'));
      expect(merged, contains('DESCRIPTION:Updated desc'));
    });

    test('mergeIntoExistingVevent removes optional LOCATION and URL when null', () {
      const String original = 'BEGIN:VEVENT\r\n'
          'UID:evt-3\r\n'
          'DTSTART:20261212T160000Z\r\n'
          'DTEND:20261212T170000Z\r\n'
          'SUMMARY:Old\r\n'
          'LOCATION:Room 1\r\n'
          'URL:https://example.com/old\r\n'
          'END:VEVENT\r\n';

      final merged = IcsSerializer.mergeIntoExistingVevent(
        originalVeventBlock: original,
        uid: 'evt-3',
        summary: 'Updated',
        location: null,
        url: null,
        start: DateTime.utc(2026, 12, 12, 18),
        end: DateTime.utc(2026, 12, 12, 19),
      );

      expect(merged, isNot(contains('LOCATION:')));
      expect(merged, isNot(contains('URL:')));
    });

    test('mergeIntoExistingVevent preserves X-properties', () {
      const String original = 'BEGIN:VEVENT\r\n'
          'UID:evt-4\r\n'
          'DTSTART:20261212T160000Z\r\n'
          'DTEND:20261212T170000Z\r\n'
          'SUMMARY:Old\r\n'
          'X-APPLE-TRAVEL-ADVISORY-BEHAVIOR:AUTOMATIC\r\n'
          'X-MICROSOFT-CDO-BUSYSTATUS:BUSY\r\n'
          'END:VEVENT\r\n';

      final merged = IcsSerializer.mergeIntoExistingVevent(
        originalVeventBlock: original,
        uid: 'evt-4',
        summary: 'Updated',
        start: DateTime.utc(2026, 12, 12, 18),
        end: DateTime.utc(2026, 12, 12, 19),
      );

      expect(merged, contains('X-APPLE-TRAVEL-ADVISORY-BEHAVIOR:AUTOMATIC'));
      expect(merged, contains('X-MICROSOFT-CDO-BUSYSTATUS:BUSY'));
      expect(merged, contains('SUMMARY:Updated'));
    });

    test('mergeIntoExistingVevent keeps recurrence line once when unchanged', () {
      const String original = 'BEGIN:VEVENT\r\n'
          'UID:evt-5\r\n'
          'DTSTART:20261212T160000Z\r\n'
          'DTEND:20261212T170000Z\r\n'
          'SUMMARY:Old\r\n'
          'RRULE:FREQ=DAILY;COUNT=2\r\n'
          'END:VEVENT\r\n';

      final merged = IcsSerializer.mergeIntoExistingVevent(
        originalVeventBlock: original,
        uid: 'evt-5',
        summary: 'Updated',
        rrule: 'FREQ=DAILY;COUNT=2',
        start: DateTime.utc(2026, 12, 12, 18),
        end: DateTime.utc(2026, 12, 12, 19),
      );

      expect(RegExp(r'RRULE:FREQ=DAILY;COUNT=2').allMatches(merged).length, 1);
    });
  });

  group('CaleeServerService.uploadEventData', () {
    test('malformed long UID is repaired before PUT', () async {
      final service = _RecordingCaleeServerService();
      final String longUid = 'X' * 400;

      final result = await service.uploadEventData(
        userId: 'user',
        calendarPath: '/remote.php/dav/calendars/user/test/',
        uid: longUid,
        title: 'Long UID Event',
        start: DateTime.utc(2026, 12, 12, 10),
        end: DateTime.utc(2026, 12, 12, 11),
      );

      expect(result, isNotNull);
      expect(service.lastPutUid, isNot(longUid));
      expect(service.lastPutUid, startsWith('CALEE-REPAIRED-'));
      expect(service.lastPutIcsData, contains('UID:${service.lastPutUid}'));
    });

    test('contaminated UID is repaired before PUT', () async {
      final service = _RecordingCaleeServerService();
      const String contaminatedUid = 'safe-part\r\nATTENDEE:mailto:hijack@example.com';

      final result = await service.uploadEventData(
        userId: 'user',
        calendarPath: '/remote.php/dav/calendars/user/test/',
        uid: contaminatedUid,
        title: 'Contaminated UID Event',
        start: DateTime.utc(2026, 12, 12, 10),
        end: DateTime.utc(2026, 12, 12, 11),
      );

      expect(result, isNotNull);
      expect(service.lastPutUid, isNot(contaminatedUid));
      expect(service.lastPutUid, startsWith('CALEE-REPAIRED-'));
      expect(service.lastPutIcsData, isNot(contains('hijack@example.com')));
    });

    test('same bad UID repairs deterministically across repeated calls', () async {
      final service = _RecordingCaleeServerService();
      const String badUid = 'bad uid with spaces and/slash';
      final String expected = CaleeUid.normalizeForRemoteWrite(badUid);

      final first = await service.uploadEventData(
        userId: 'user',
        calendarPath: '/remote.php/dav/calendars/user/test/',
        uid: badUid,
        title: 'Event One',
        start: DateTime.utc(2026, 12, 12, 10),
        end: DateTime.utc(2026, 12, 12, 11),
      );
      final String? firstUid = service.lastPutUid;

      final second = await service.uploadEventData(
        userId: 'user',
        calendarPath: '/remote.php/dav/calendars/user/test/',
        uid: badUid,
        title: 'Event Two',
        start: DateTime.utc(2026, 12, 13, 10),
        end: DateTime.utc(2026, 12, 13, 11),
      );
      final String? secondUid = service.lastPutUid;

      expect(first, isNotNull);
      expect(second, isNotNull);
      expect(firstUid, expected);
      expect(secondUid, expected);
    });

    test('valid UUID-shaped UID is unchanged', () async {
      final service = _RecordingCaleeServerService();
      const String validUuid = 'ae6c35cc-3203-44d8-a56c-973d48d7e289';

      final result = await service.uploadEventData(
        userId: 'user',
        calendarPath: '/remote.php/dav/calendars/user/test/',
        uid: validUuid,
        title: 'UUID Event',
        start: DateTime.utc(2026, 12, 12, 10),
        end: DateTime.utc(2026, 12, 12, 11),
      );

      expect(result, isNotNull);
      expect(service.lastPutUid, validUuid);
      expect(service.lastPutIcsData, contains('UID:$validUuid'));
    });

    test('existing update with targetEventPath keeps target path while body UID is repaired', () async {
      final service = _RecordingCaleeServerService();
      const String badUid = 'bad uid with spaces';
      const String targetPath = '/remote.php/dav/calendars/user/test/existing.ics';

      final result = await service.uploadEventData(
        userId: 'user',
        calendarPath: '/remote.php/dav/calendars/user/test/',
        uid: badUid,
        title: 'Existing Event',
        parseSource: 'VEVENT',
        start: DateTime.utc(2026, 12, 12, 10),
        end: DateTime.utc(2026, 12, 12, 11),
        targetEventPath: targetPath,
        originalVeventBlock: 'BEGIN:VEVENT\r\nUID:legacy\r\nSUMMARY:Existing\r\nEND:VEVENT\r\n',
      );

      expect(result, isNotNull);
      expect(service.lastPutTargetEventPath, targetPath);
      expect(service.lastPutUid, CaleeUid.normalizeForRemoteWrite(badUid));
      expect(service.lastPutIcsData, contains('UID:${service.lastPutUid}'));
    });

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

    test('existing remote update without original block is refused by default', () async {
      final service = _RecordingCaleeServerService();
      final result = await service.uploadEventData(
        userId: 'user',
        calendarPath: '/remote.php/dav/calendars/user/test/',
        uid: 'evt-default-blocked',
        title: 'Guarded Event',
        parseSource: 'VEVENT',
        start: DateTime.utc(2026, 12, 12, 10),
        end: DateTime.utc(2026, 12, 12, 11),
        targetEventPath: '/remote.php/dav/calendars/user/test/evt-default-blocked.ics',
        originalVeventBlock: null,
        allowMinimalUpdateFallback: false,
      );

      expect(result, isNull);
      expect(service.putCallCount, 0);
    });

    test('existing remote update without original block may use minimal fallback when explicitly allowed', () async {
      final service = _RecordingCaleeServerService();
      final result = await service.uploadEventData(
        userId: 'user',
        calendarPath: '/remote.php/dav/calendars/user/test/',
        uid: 'evt-fallback-allowed',
        title: 'Fallback Event',
        parseSource: 'VEVENT',
        start: DateTime.utc(2026, 12, 12, 10),
        end: DateTime.utc(2026, 12, 12, 11),
        targetEventPath: '/remote.php/dav/calendars/user/test/evt-fallback-allowed.ics',
        originalVeventBlock: null,
        allowMinimalUpdateFallback: true,
      );

      expect(result, isNotNull);
      expect(service.putCallCount, 1);
      expect(service.lastPutTargetEventPath, '/remote.php/dav/calendars/user/test/evt-fallback-allowed.ics');
      expect(service.lastPutIcsData, contains('BEGIN:VEVENT'));
    });
  });
}

import 'package:caleesync/core/platform/pigeon/calendar_api.g.dart';
import 'package:caleesync/entity/SyncContext.dart';
import 'package:caleesync/entity/SyncSummary.dart';
import 'package:caleesync/services/calee_server_service.dart';
import 'package:caleesync/sync/strategy/SyncStrategy.dart';
import 'package:flutter_test/flutter_test.dart';

import 'test_bootstrap.dart';

class _RecordingRemoteGateway extends RemoteItemGateway {
  Map<String, dynamic>? lastUploadArgs;

  @override
  Future<UnifiedEventsSnapshot> fetchUnifiedEventsSnapshot({
    required String calendarPath,
    required bool isSubscription,
  }) {
    throw UnimplementedError();
  }

  @override
  Future<String?> uploadEventData({
    required String userId,
    required String calendarPath,
    required String uid,
    required String title,
    DateTime? start,
    DateTime? end,
    String? description,
    String? location,
    String? url,
    String? recurrenceId,
    String? rrule,
    String? created,
    String? lastModified,
    String? parseSource,
    Map<String, dynamic>? dtstartMeta,
    Map<String, dynamic>? dtendMeta,
    String? targetEventPath,
    String? originalVeventBlock,
    bool allowMinimalUpdateFallback = false,
  }) async {
    lastUploadArgs = {
      'userId': userId,
      'calendarPath': calendarPath,
      'uid': uid,
      'title': title,
      'start': start,
      'end': end,
      'description': description,
      'location': location,
      'dtstartMeta': dtstartMeta,
      'dtendMeta': dtendMeta,
      'targetEventPath': targetEventPath,
      'originalVeventBlock': originalVeventBlock,
      'allowMinimalUpdateFallback': allowMinimalUpdateFallback,
    };
    return 'etag-1';
  }

  @override
  Future<bool> deleteEvent({required String eventPath}) async => true;
}

class _NoopLocalGateway extends LocalItemGateway {
  Map<String, dynamic>? lastCreateOrUpdateArgs;

  @override
  Future<String?> createOrUpdateEvent({
    required String calendarId,
    String? eventId,
    required String uid,
    required String title,
    required int start,
    required int end,
    String? notes,
    String? location,
    String? eventTimezone,
    bool? isAllDay,
  }) async {
    lastCreateOrUpdateArgs = {
      'calendarId': calendarId,
      'eventId': eventId,
      'uid': uid,
      'title': title,
      'start': start,
      'end': end,
      'notes': notes,
      'location': location,
      'eventTimezone': eventTimezone,
      'isAllDay': isAllDay,
    };
    return eventId ?? 'local-1';
  }

  @override
  Future<bool> deleteEvent(String eventId) async => true;

  @override
  Future<List<PlatformItem>> getEvents(String localCalendarId, int start, int end) async => <PlatformItem>[];

  @override
  Future<List<String>> getSystemEventIds(String localCalendarId, int startMs, int endMs) async => <String>[];
}

class _TestSyncStrategy extends SyncStrategy {
  _TestSyncStrategy({required RemoteItemGateway remote, LocalItemGateway? local})
    : _remoteGateway = remote,
      _localGateway = local ?? _NoopLocalGateway();

  final RemoteItemGateway _remoteGateway;
  final LocalItemGateway _localGateway;

  @override
  RemoteItemGateway get remoteGateway => _remoteGateway;

  @override
  LocalItemGateway get localGateway => _localGateway;

  @override
  Future<void> execute(SyncContext ctx, SyncSummary summary) async {}
}

void main() {
  setUpAll(() async {
    await bootstrapTestStorage();
  });

  test('remote update passes vevent_block into upload path', () async {
    final gateway = _RecordingRemoteGateway();
    final strategy = _TestSyncStrategy(remote: gateway);

    final local = PlatformItem(
      uid: 'uid-1',
      title: 'Title',
      notes: 'Notes',
      location: 'Local Room',
      startTime: DateTime.utc(2026, 12, 12, 10).millisecondsSinceEpoch,
      endTime: DateTime.utc(2026, 12, 12, 11).millisecondsSinceEpoch,
      lastModified: DateTime.utc(2026, 12, 12, 9).millisecondsSinceEpoch,
    );

    await strategy.pushLocalEventToRemote(
      local: local,
      remotePath: '/remote.php/dav/calendars/tester/work/',
      localCalendarId: 'cal-1',
      remoteSnapshot: {
        'vevent_block': 'BEGIN:VEVENT\\r\\nUID:uid-1\\r\\nEND:VEVENT\\r\\n',
        'href': '/remote.php/dav/calendars/tester/work/uid-1.ics',
      },
      targetRemoteHref: '/remote.php/dav/calendars/tester/work/uid-1.ics',
    );

    expect(gateway.lastUploadArgs?['targetEventPath'], '/remote.php/dav/calendars/tester/work/uid-1.ics');
    expect(gateway.lastUploadArgs?['originalVeventBlock'], contains('BEGIN:VEVENT'));
  });

  test('create path still uses no originalVeventBlock', () async {
    final gateway = _RecordingRemoteGateway();
    final strategy = _TestSyncStrategy(remote: gateway);

    final local = PlatformItem(
      uid: 'uid-2',
      title: 'Title',
      startTime: DateTime.utc(2026, 12, 12, 10).millisecondsSinceEpoch,
      endTime: DateTime.utc(2026, 12, 12, 11).millisecondsSinceEpoch,
      lastModified: DateTime.utc(2026, 12, 12, 9).millisecondsSinceEpoch,
    );

    await strategy.pushLocalEventToRemote(
      local: local,
      remotePath: '/remote.php/dav/calendars/tester/work/',
      localCalendarId: 'cal-1',
      remoteSnapshot: null,
      targetRemoteHref: null,
    );

    expect(gateway.lastUploadArgs?['originalVeventBlock'], isNull);
  });

  test('pushLocalEventToRemote synthesizes VALUE=DATE for local all-day create', () async {
    final gateway = _RecordingRemoteGateway();
    final strategy = _TestSyncStrategy(remote: gateway);

    final DateTime start = DateTime(2026, 3, 25, 0, 0, 0);
    final DateTime end = DateTime(2026, 3, 25, 23, 59, 59);
    final local = PlatformItem(
      uid: 'uid-allday',
      title: 'All-day',
      isAllDay: true,
      startTime: start.millisecondsSinceEpoch,
      endTime: end.millisecondsSinceEpoch,
    );

    await strategy.pushLocalEventToRemote(
      local: local,
      remotePath: '/remote.php/dav/calendars/tester/work/',
      localCalendarId: 'cal-1',
      remoteSnapshot: null,
      targetRemoteHref: null,
    );

    final Map<String, dynamic>? dtstartMeta = gateway.lastUploadArgs?['dtstartMeta'] as Map<String, dynamic>?;
    final Map<String, dynamic>? dtendMeta = gateway.lastUploadArgs?['dtendMeta'] as Map<String, dynamic>?;
    expect(dtstartMeta, isNotNull);
    expect(dtendMeta, isNotNull);
    expect(dtstartMeta?['isDateOnly'], isTrue);
    expect(dtendMeta?['isDateOnly'], isTrue);
    expect((dtstartMeta?['params'] as Map?)?['VALUE'], 'DATE');
    expect((dtendMeta?['params'] as Map?)?['VALUE'], 'DATE');
    expect(gateway.lastUploadArgs?['start'], DateTime(2026, 3, 25));
    expect(gateway.lastUploadArgs?['end'], DateTime(2026, 3, 26));
  });

  test('pushLocalEventToRemote synthesizes TZID for local timed create', () async {
    final gateway = _RecordingRemoteGateway();
    final strategy = _TestSyncStrategy(remote: gateway);

    final local = PlatformItem(
      uid: 'uid-tz',
      title: 'Timed',
      isAllDay: false,
      eventTimezone: 'Asia/Tokyo',
      startTime: DateTime(2026, 3, 25, 9).millisecondsSinceEpoch,
      endTime: DateTime(2026, 3, 25, 10).millisecondsSinceEpoch,
    );

    await strategy.pushLocalEventToRemote(
      local: local,
      remotePath: '/remote.php/dav/calendars/tester/work/',
      localCalendarId: 'cal-1',
      remoteSnapshot: null,
      targetRemoteHref: null,
    );

    final Map<String, dynamic>? dtstartMeta = gateway.lastUploadArgs?['dtstartMeta'] as Map<String, dynamic>?;
    final Map<String, dynamic>? dtendMeta = gateway.lastUploadArgs?['dtendMeta'] as Map<String, dynamic>?;
    expect(dtstartMeta?['tzid'], 'Asia/Tokyo');
    expect(dtendMeta?['tzid'], 'Asia/Tokyo');
    expect(dtstartMeta?['isDateOnly'], isFalse);
    expect(dtendMeta?['isDateOnly'], isFalse);
  });

  test('pushLocalEventToRemote prefers meaningful remote meta over local synth', () async {
    final gateway = _RecordingRemoteGateway();
    final strategy = _TestSyncStrategy(remote: gateway);

    final local = PlatformItem(
      uid: 'uid-remote-meta',
      title: 'Timed',
      isAllDay: false,
      eventTimezone: 'Australia/Perth',
      startTime: DateTime(2026, 3, 25, 9).millisecondsSinceEpoch,
      endTime: DateTime(2026, 3, 25, 10).millisecondsSinceEpoch,
    );

    await strategy.pushLocalEventToRemote(
      local: local,
      remotePath: '/remote.php/dav/calendars/tester/work/',
      localCalendarId: 'cal-1',
      remoteSnapshot: {
        'dtstart_meta': {'isUtc': true, 'params': <String, dynamic>{}, 'tzid': null},
        'dtend_meta': {'isUtc': true, 'params': <String, dynamic>{}, 'tzid': null},
      },
      targetRemoteHref: null,
    );

    final Map<String, dynamic>? dtstartMeta = gateway.lastUploadArgs?['dtstartMeta'] as Map<String, dynamic>?;
    final Map<String, dynamic>? dtendMeta = gateway.lastUploadArgs?['dtendMeta'] as Map<String, dynamic>?;
    expect(dtstartMeta?['isUtc'], isTrue);
    expect(dtendMeta?['isUtc'], isTrue);
    expect(dtstartMeta?['tzid'], isNull);
    expect(dtendMeta?['tzid'], isNull);
  });

  test('pushLocalEventToRemote falls back to local synth when remote meta missing', () async {
    final gateway = _RecordingRemoteGateway();
    final strategy = _TestSyncStrategy(remote: gateway);

    final local = PlatformItem(
      uid: 'uid-remote-missing-meta',
      title: 'Timed',
      isAllDay: false,
      eventTimezone: 'Australia/Perth',
      startTime: DateTime(2026, 3, 25, 9).millisecondsSinceEpoch,
      endTime: DateTime(2026, 3, 25, 10).millisecondsSinceEpoch,
    );

    await strategy.pushLocalEventToRemote(
      local: local,
      remotePath: '/remote.php/dav/calendars/tester/work/',
      localCalendarId: 'cal-1',
      remoteSnapshot: {
        'dtstart_meta': null,
        'dtend_meta': null,
      },
      targetRemoteHref: null,
    );

    final Map<String, dynamic>? dtstartMeta = gateway.lastUploadArgs?['dtstartMeta'] as Map<String, dynamic>?;
    final Map<String, dynamic>? dtendMeta = gateway.lastUploadArgs?['dtendMeta'] as Map<String, dynamic>?;
    expect(dtstartMeta?['tzid'], 'Australia/Perth');
    expect(dtendMeta?['tzid'], 'Australia/Perth');
  });

  test('rich existing remote event with missing vevent_block is blocked', () async {
    final gateway = _RecordingRemoteGateway();
    final strategy = _TestSyncStrategy(remote: gateway);
    final local = PlatformItem(
      uid: 'C4975D9D-34B2-4D21-8AC9-874A96685F7F',
      title: 'Title',
      startTime: DateTime.utc(2026, 12, 12, 10).millisecondsSinceEpoch,
      endTime: DateTime.utc(2026, 12, 12, 11).millisecondsSinceEpoch,
    );

    final result = await strategy.pushLocalEventToRemote(
      local: local,
      remotePath: '/remote.php/dav/calendars/tester/work/',
      localCalendarId: 'cal-1',
      remoteSnapshot: {
        'parse_source': 'VEVENT',
        'calendar_data': 'BEGIN:VEVENT\r\nATTENDEE:mailto:a@example.com\r\nEND:VEVENT\r\n',
        'vevent_block': null,
      },
      targetRemoteHref: '/remote.php/dav/calendars/tester/work/uid-rich.ics',
    );

    expect(result, isNull);
    expect(gateway.lastUploadArgs, isNull);
  });

  test('exchange-style UID with missing vevent_block is blocked', () async {
    final gateway = _RecordingRemoteGateway();
    final strategy = _TestSyncStrategy(remote: gateway);
    final local = PlatformItem(
      uid: '040000008200E00074C5B7101A82E00800000000',
      title: 'Title',
      startTime: DateTime.utc(2026, 12, 12, 10).millisecondsSinceEpoch,
      endTime: DateTime.utc(2026, 12, 12, 11).millisecondsSinceEpoch,
    );

    final result = await strategy.pushLocalEventToRemote(
      local: local,
      remotePath: '/remote.php/dav/calendars/tester/work/',
      localCalendarId: 'cal-1',
      remoteSnapshot: {
        'parse_source': 'VEVENT',
        'uid': '040000008200E00074C5B7101A82E00800000000',
        'calendar_data': 'BEGIN:VEVENT\r\nUID:040000008200E00074C5B7101A82E00800000000\r\nEND:VEVENT\r\n',
        'vevent_block': null,
      },
      targetRemoteHref: '/remote.php/dav/calendars/tester/work/uid-exchange.ics',
    );

    expect(result, isNull);
    expect(gateway.lastUploadArgs, isNull);
  });

  test('simple UUID existing remote event may allow minimal fallback', () async {
    final gateway = _RecordingRemoteGateway();
    final strategy = _TestSyncStrategy(remote: gateway);
    final local = PlatformItem(
      uid: 'C4975D9D-34B2-4D21-8AC9-874A96685F7F',
      title: 'Title',
      startTime: DateTime.utc(2026, 12, 12, 10).millisecondsSinceEpoch,
      endTime: DateTime.utc(2026, 12, 12, 11).millisecondsSinceEpoch,
    );

    final result = await strategy.pushLocalEventToRemote(
      local: local,
      remotePath: '/remote.php/dav/calendars/tester/work/',
      localCalendarId: 'cal-1',
      remoteSnapshot: {
        'parse_source': 'VEVENT',
        'uid': 'C4975D9D-34B2-4D21-8AC9-874A96685F7F',
        'calendar_data': 'BEGIN:VEVENT\r\nUID:C4975D9D-34B2-4D21-8AC9-874A96685F7F\r\nEND:VEVENT\r\n',
        'vevent_block': null,
        'rrule': '',
        'recurrence_id': '',
      },
      targetRemoteHref: '/remote.php/dav/calendars/tester/work/uid-simple.ics',
    );

    expect(result, isNotNull);
    expect(gateway.lastUploadArgs?['allowMinimalUpdateFallback'], isTrue);
  });

  test('recurring existing remote event with missing vevent_block is blocked', () async {
    final gateway = _RecordingRemoteGateway();
    final strategy = _TestSyncStrategy(remote: gateway);
    final local = PlatformItem(
      uid: 'C4975D9D-34B2-4D21-8AC9-874A96685F7F',
      title: 'Title',
      startTime: DateTime.utc(2026, 12, 12, 10).millisecondsSinceEpoch,
      endTime: DateTime.utc(2026, 12, 12, 11).millisecondsSinceEpoch,
    );

    final result = await strategy.pushLocalEventToRemote(
      local: local,
      remotePath: '/remote.php/dav/calendars/tester/work/',
      localCalendarId: 'cal-1',
      remoteSnapshot: {
        'parse_source': 'VEVENT',
        'uid': 'C4975D9D-34B2-4D21-8AC9-874A96685F7F',
        'rrule': 'FREQ=DAILY;COUNT=2',
        'vevent_block': null,
      },
      targetRemoteHref: '/remote.php/dav/calendars/tester/work/uid-recurring.ics',
    );

    expect(result, isNull);
    expect(gateway.lastUploadArgs, isNull);
  });

  test('uid backfill local rewrite preserves location timezone allDay', () async {
    final gateway = _RecordingRemoteGateway();
    final localGateway = _NoopLocalGateway();
    final strategy = _TestSyncStrategy(remote: gateway, local: localGateway);

    final local = PlatformItem(
      uid: '',
      localId: 'evt-1',
      title: 'No uid',
      notes: 'notes',
      location: 'Room 7',
      eventTimezone: 'Asia/Tokyo',
      isAllDay: true,
      startTime: DateTime(2026, 3, 25).millisecondsSinceEpoch,
      endTime: DateTime(2026, 3, 26).millisecondsSinceEpoch,
    );

    await strategy.pushLocalEventToRemote(
      local: local,
      remotePath: '/remote.php/dav/calendars/tester/work/',
      localCalendarId: 'cal-1',
      remoteSnapshot: null,
      targetRemoteHref: null,
    );

    expect(localGateway.lastCreateOrUpdateArgs?['location'], 'Room 7');
    expect(localGateway.lastCreateOrUpdateArgs?['eventTimezone'], 'Asia/Tokyo');
    expect(localGateway.lastCreateOrUpdateArgs?['isAllDay'], isTrue);
  });
}

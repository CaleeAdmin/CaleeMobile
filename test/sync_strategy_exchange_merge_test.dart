import 'package:caleesync/common/app_constant.dart';
import 'package:caleesync/common/utils/mmkv_utils.dart';
import 'package:caleesync/core/platform/pigeon/calendar_api.g.dart';
import 'package:caleesync/entity/SyncContext.dart';
import 'package:caleesync/entity/SyncSummary.dart';
import 'package:caleesync/services/calee_server_service.dart';
import 'package:caleesync/sync/strategy/SyncStrategy.dart';
import 'package:flutter_test/flutter_test.dart';

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
  }) async {
    lastUploadArgs = {
      'userId': userId,
      'calendarPath': calendarPath,
      'uid': uid,
      'title': title,
      'description': description,
      'location': location,
      'targetEventPath': targetEventPath,
      'originalVeventBlock': originalVeventBlock,
    };
    return 'etag-1';
  }

  @override
  Future<bool> deleteEvent({required String eventPath}) async => true;
}

class _NoopLocalGateway extends LocalItemGateway {
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
  }) async => eventId ?? 'local-1';

  @override
  Future<bool> deleteEvent(String eventId) async => true;

  @override
  Future<List<PlatformItem>> getEvents(String localCalendarId, int start, int end) async => <PlatformItem>[];
}

class _TestSyncStrategy extends SyncStrategy {
  _TestSyncStrategy({required RemoteItemGateway remote}) {
    remoteGateway = remote;
    localGateway = _NoopLocalGateway();
  }

  @override
  Future<void> execute(SyncContext ctx, SyncSummary summary) async {}
}

void main() {
  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    await MMKVUtils.instance.init(id: 'sync_strategy_exchange_merge_test');
    MMKVUtils.instance.setString(AppConstant.loginNameKey, 'tester');
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
}

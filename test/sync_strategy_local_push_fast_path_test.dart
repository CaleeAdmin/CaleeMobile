import 'package:caleesync/common/app_constant.dart';
import 'package:caleesync/common/utils/mmkv_utils.dart';
import 'package:caleesync/core/platform/pigeon/calendar_api.g.dart';
import 'package:caleesync/data/database_helper.dart';
import 'package:caleesync/entity/SyncContext.dart';
import 'package:caleesync/entity/SyncSummary.dart';
import 'package:caleesync/sync/SyncEnum.dart';
import 'package:caleesync/sync/strategy/SyncStrategy.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite/sqflite.dart';

import 'test_bootstrap.dart';

class _CountingRemoteGateway extends RemoteItemGateway {
  int fetchCount = 0;
  int uploadCount = 0;
  int deleteCount = 0;

  @override
  Future<UnifiedEventsSnapshot> fetchUnifiedEventsSnapshot({
    required String calendarPath,
    required bool isSubscription,
  }) async {
    fetchCount++;
    return const UnifiedEventsSnapshot(
      events: <Map<String, Object?>>[],
      statusCode: 200,
      fetchSucceeded: true,
      parseProducedZeroEvents: false,
    );
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
    uploadCount++;
    return 'etag-created';
  }

  @override
  Future<bool> deleteEvent({required String eventPath}) async {
    deleteCount++;
    return true;
  }
}

class _RecordingLocalGateway extends LocalItemGateway {
  _RecordingLocalGateway({required this.events});

  final List<PlatformItem> events;
  int deleteCount = 0;

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
  }) async => 'local-created';

  @override
  Future<bool> deleteEvent(String eventId) async {
    deleteCount++;
    return true;
  }

  @override
  Future<List<PlatformItem>> getEvents(String localCalendarId, int start, int end) async => events;

  @override
  Future<List<String>> getSystemEventIds(String localCalendarId, int startMs, int endMs) async =>
      events.map((e) => e.localId ?? '').where((id) => id.isNotEmpty).toList();
}

class _TestSyncStrategy extends SyncStrategy {
  _TestSyncStrategy({
    required RemoteItemGateway remote,
    required LocalItemGateway local,
  })  : _remoteGateway = remote,
        _localGateway = local;

  final RemoteItemGateway _remoteGateway;
  final LocalItemGateway _localGateway;

  @override
  RemoteItemGateway get remoteGateway => _remoteGateway;

  @override
  LocalItemGateway get localGateway => _localGateway;

  @override
  Future<void> execute(SyncContext ctx, SyncSummary summary) async {}
}

Future<void> _seedBase(Database db) async {
  await db.insert('remote_collections', {
    'id': 10,
    'account_name': 'tester',
    'collection_type': 'calendar',
    'remote_path': '/calendars/tester/home/',
    'display_name': 'Home',
    'synced_ctag': 'ctag-old',
    'sync_mode': SyncBindingMode.twoWay,
    'is_subscription': 0,
    'origin_kind': SyncBindingOrigin.remote,
  });

  await db.insert('collection_states', {
    'remote_collection_id': 10,
    'is_enabled': 1,
    'updated_at': DateTime.now().millisecondsSinceEpoch,
  });
}

SyncContext _ctx({bool useFastPath = true}) {
  return SyncContext(
    remoteCollectionId: 10,
    localCalendarId: 'local-1',
    remotePath: '/calendars/tester/home/',
    accountName: 'tester',
    displayName: 'Home',
    color: '#00ff00',
    syncMode: SyncBindingMode.twoWay,
    action: SyncAction.fullSyncBidi,
    ctag: 'ctag-new',
    extra: {
      'binding_id': 22,
      'binding_role': SyncBindingRole.mirror,
      'sync_gate_reason': null,
      'bootstrap_required': false,
      'safe_first_sync': false,
      'use_local_push_fast_path': useFastPath,
    },
  );
}

void main() {
  bool sqliteReady = false;

  setUpAll(() async {
    try {
      await bootstrapTestStorage();
      MMKVUtils.instance.setString(AppConstant.loginNameKey, 'tester');
      MMKVUtils.instance.setString(AppConstant.appPasswordKey, 'app-password');
      sqliteReady = true;
    } catch (_) {
      sqliteReady = false;
    }
  });

  Future<Database> resetDb() async {
    if (!sqliteReady) {
      throw StateError('sqflite platform plugin is unavailable in this test environment.');
    }
    await DatabaseHelper.instance.deleteMyDatabase();
    return DatabaseHelper.instance.database;
  }

  group('local pending-push fast path', () {
    test('local-only fast path skips remote snapshot fetch', () async {
      if (!sqliteReady) {
        markTestSkipped('sqflite platform plugin is unavailable in this test environment.');
        return;
      }
      final db = await resetDb();
      await _seedBase(db);
      await db.insert('sync_items', {
        'remote_collection_id': 10,
        'item_type': 'event',
        'remote_uid': '',
        'remote_href': '',
        'local_item_id': 'local-1',
        'sync_status': SyncItemStatus.pendingPush,
        'dtstart': 1700000000000,
        'dtend': 1700003600000,
        'last_mtime': 100,
      });

      final remote = _CountingRemoteGateway();
      final local = _RecordingLocalGateway(
        events: <PlatformItem>[
          PlatformItem(
            localId: 'local-1',
            uid: 'uid-local-1',
            title: 'Fast Path Event',
            startTime: 1700000000000,
            endTime: 1700003600000,
            lastModified: 200,
          ),
        ],
      );
      final strategy = _TestSyncStrategy(remote: remote, local: local);

      await strategy.runUnifiedSync(_ctx(), SyncSummary(), mode: UnifiedSyncMode.bidi);

      expect(remote.fetchCount, 0);
      expect(remote.uploadCount, 1);
    });

    test('pendingPush row is pushed and marked synced', () async {
      if (!sqliteReady) {
        markTestSkipped('sqflite platform plugin is unavailable in this test environment.');
        return;
      }
      final db = await resetDb();
      await _seedBase(db);
      await db.insert('sync_items', {
        'remote_collection_id': 10,
        'item_type': 'event',
        'remote_uid': '',
        'remote_href': '',
        'local_item_id': 'local-1',
        'sync_status': SyncItemStatus.pendingPush,
        'dtstart': 1700000000000,
        'dtend': 1700003600000,
        'last_mtime': 100,
      });

      final remote = _CountingRemoteGateway();
      final local = _RecordingLocalGateway(
        events: <PlatformItem>[
          PlatformItem(
            localId: 'local-1',
            uid: 'uid-local-1',
            title: 'Fast Path Event',
            startTime: 1700000000000,
            endTime: 1700003600000,
            lastModified: 200,
          ),
        ],
      );
      final strategy = _TestSyncStrategy(remote: remote, local: local);

      await strategy.runUnifiedSync(_ctx(), SyncSummary(), mode: UnifiedSyncMode.bidi);

      final rows = await db.query('sync_items', where: 'remote_collection_id = ?', whereArgs: [10]);
      expect(rows, hasLength(1));
      expect(rows.first['sync_status'], SyncItemStatus.synced);
      expect((rows.first['remote_uid']?.toString() ?? ''), isNotEmpty);
      expect((rows.first['remote_href']?.toString() ?? ''), isNotEmpty);
    });

    test('fast path does not update synced_ctag', () async {
      if (!sqliteReady) {
        markTestSkipped('sqflite platform plugin is unavailable in this test environment.');
        return;
      }
      final db = await resetDb();
      await _seedBase(db);
      await db.insert('sync_items', {
        'remote_collection_id': 10,
        'item_type': 'event',
        'remote_uid': '',
        'remote_href': '',
        'local_item_id': 'local-1',
        'sync_status': SyncItemStatus.pendingPush,
        'dtstart': 1700000000000,
        'dtend': 1700003600000,
        'last_mtime': 100,
      });

      final strategy = _TestSyncStrategy(
        remote: _CountingRemoteGateway(),
        local: _RecordingLocalGateway(
          events: <PlatformItem>[
            PlatformItem(
              localId: 'local-1',
              uid: 'uid-local-1',
              title: 'Fast Path Event',
              startTime: 1700000000000,
              endTime: 1700003600000,
              lastModified: 200,
            ),
          ],
        ),
      );

      await strategy.runUnifiedSync(_ctx(), SyncSummary(), mode: UnifiedSyncMode.bidi);

      final row = (await db.query('remote_collections', where: 'id = ?', whereArgs: [10])).first;
      expect(row['synced_ctag'], 'ctag-old');
    });

    test('missing local event falls back to full path', () async {
      if (!sqliteReady) {
        markTestSkipped('sqflite platform plugin is unavailable in this test environment.');
        return;
      }
      final db = await resetDb();
      await _seedBase(db);
      await db.insert('sync_items', {
        'remote_collection_id': 10,
        'item_type': 'event',
        'remote_uid': '',
        'remote_href': '',
        'local_item_id': 'local-missing',
        'sync_status': SyncItemStatus.pendingPush,
        'dtstart': 1700000000000,
        'dtend': 1700003600000,
        'last_mtime': 100,
      });

      final remote = _CountingRemoteGateway();
      final local = _RecordingLocalGateway(
        events: <PlatformItem>[
          PlatformItem(
            localId: 'local-other',
            uid: 'uid-other',
            title: 'Other',
            startTime: 1700000000000,
            endTime: 1700003600000,
            lastModified: 200,
          ),
        ],
      );
      final strategy = _TestSyncStrategy(remote: remote, local: local);

      await strategy.runUnifiedSync(_ctx(), SyncSummary(), mode: UnifiedSyncMode.bidi);

      expect(remote.fetchCount, 1);
    });

    test('fast path never performs delete inference', () async {
      if (!sqliteReady) {
        markTestSkipped('sqflite platform plugin is unavailable in this test environment.');
        return;
      }
      final db = await resetDb();
      await _seedBase(db);
      await db.insert('sync_items', {
        'remote_collection_id': 10,
        'item_type': 'event',
        'remote_uid': 'uid-local-1',
        'remote_href': '/calendars/tester/home/uid-local-1.ics',
        'local_item_id': 'local-1',
        'sync_status': SyncItemStatus.pendingPush,
        'dtstart': 1700000000000,
        'dtend': 1700003600000,
        'last_mtime': 100,
      });

      final remote = _CountingRemoteGateway();
      final local = _RecordingLocalGateway(
        events: <PlatformItem>[
          PlatformItem(
            localId: 'local-1',
            uid: 'uid-local-1',
            title: 'Fast Path Event',
            startTime: 1700000000000,
            endTime: 1700003600000,
            lastModified: 200,
          ),
        ],
      );
      final strategy = _TestSyncStrategy(remote: remote, local: local);

      await strategy.runUnifiedSync(_ctx(), SyncSummary(), mode: UnifiedSyncMode.bidi);

      expect(remote.deleteCount, 0);
      expect(local.deleteCount, 0);
    });
  });
}

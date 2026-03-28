import 'package:caleesync/core/platform/pigeon/calendar_api.g.dart';
import 'package:caleesync/data/database_helper.dart';
import 'package:caleesync/entity/SyncContext.dart';
import 'package:caleesync/entity/SyncSummary.dart';
import 'package:caleesync/services/calee_server_service.dart';
import 'package:caleesync/sync/SyncEnum.dart';
import 'package:caleesync/sync/strategy/SyncStrategy.dart';
import 'package:caleesync/sync/sync_gate_reason.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite/sqflite.dart';

import 'test_bootstrap.dart';

class _FakeRemoteGateway extends RemoteItemGateway {
  _FakeRemoteGateway(this.snapshot);

  final UnifiedEventsSnapshot snapshot;

  @override
  Future<UnifiedEventsSnapshot> fetchUnifiedEventsSnapshot({
    required String calendarPath,
    required bool isSubscription,
  }) async => snapshot;

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
  }) async => 'etag-created';

  @override
  Future<bool> deleteEvent({required String eventPath}) async => true;
}

class _FakeLocalGateway extends LocalItemGateway {
  _FakeLocalGateway({
    this.events = const <PlatformItem>[],
    this.createResult = 'local-created',
  });

  final List<PlatformItem> events;
  final String? createResult;

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
  }) async => createResult;

  @override
  Future<bool> deleteEvent(String eventId) async => true;

  @override
  Future<List<PlatformItem>> getEvents(String localCalendarId, int start, int end) async => events;

  @override
  Future<List<String>> getSystemEventIds(String localCalendarId, int startMs, int endMs) async => <String>[];
}

class _TestSyncStrategy extends SyncStrategy {
  _TestSyncStrategy({
    required RemoteItemGateway remote,
    required LocalItemGateway local,
  }) : _remoteGateway = remote,
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

class _FailingPullSyncStrategy extends _TestSyncStrategy {
  _FailingPullSyncStrategy({
    required super.remote,
    required super.local,
  });

  @override
  Future<RemotePullResult?> pullRemoteEventToLocal({
    required Map<String, dynamic> remote,
    required String localCalendarId,
    required String? existingLocalId,
    required bool isSubscription,
  }) async {
    return null;
  }
}

SyncContext _ctx() {
  return SyncContext(
    remoteCollectionId: 10,
    localCalendarId: 'local-1',
    remotePath: '/calendars/tester/home/',
    accountName: 'tester',
    displayName: 'Home',
    color: '#00ff00',
    syncMode: SyncBindingMode.twoWay,
    action: SyncAction.fullSyncPull,
    ctag: 'ctag-new',
    extra: {
      'binding_id': 20,
      'binding_role': SyncBindingRole.mirror,
      'sync_gate_reason': SyncGateReason.safeFirstSync,
      'bootstrap_required': true,
      'safe_first_sync': true,
    },
  );
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
    'sync_gate_reason': SyncGateReason.safeFirstSync,
    'is_enabled': 1,
    'updated_at': DateTime.now().millisecondsSinceEpoch,
  });
}

Future<Map<String, Object?>> _loadProgress(Database db) async {
  final remote = (await db.query('remote_collections', where: 'id = ?', whereArgs: [10])).first;
  final state = (await db.query('collection_states', where: 'remote_collection_id = ?', whereArgs: [10])).first;
  return {
    'synced_ctag': remote['synced_ctag'],
    'sync_gate_reason': state['sync_gate_reason'],
  };
}

void main() {
  bool sqliteReady = false;

  setUpAll(() async {
    try {
      await bootstrapTestStorage();
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

  group('safe_first_sync commit gating', () {
    test('bootstrap partial mapping coverage keeps synced_ctag and sync gate', () async {
      if (!sqliteReady) {
        markTestSkipped('sqflite platform plugin is unavailable in this test environment.');
        return;
      }

      final db = await resetDb();
      await _seedBase(db);
      await db.insert('sync_items', {
        'remote_collection_id': 10,
        'item_type': 'event',
        'remote_uid': 'uid-1',
        'remote_href': '/calendars/tester/home/uid-1.ics',
        'local_item_id': 'local-uid-1',
        'last_etag': 'etag-1',
        'last_mtime': 100,
        'sync_status': SyncItemStatus.synced,
      });

      final strategy = _TestSyncStrategy(
        remote: _FakeRemoteGateway(
          const UnifiedEventsSnapshot(
            events: [
              {
                'instance_key': 'uid-1',
                'remote_uid': 'uid-1',
                'etag': 'etag-1',
                'href': '/calendars/tester/home/uid-1.ics',
              },
              {
                'instance_key': 'uid-2',
                'remote_uid': 'uid-2',
                'etag': 'etag-2',
                'href': '/calendars/tester/home/uid-2.ics',
              },
            ],
            statusCode: 200,
            fetchSucceeded: true,
            parseProducedZeroEvents: false,
          ),
        ),
        local: _FakeLocalGateway(
          events: <PlatformItem>[
            PlatformItem(localId: 'local-uid-1', uid: 'uid-1', lastModified: 100),
          ],
          createResult: null,
        ),
      );

      await strategy.runUnifiedSync(
        _ctx(),
        SyncSummary(),
        mode: UnifiedSyncMode.pull,
        bootstrap: true,
      );

      final progress = await _loadProgress(db);
      expect(progress['synced_ctag'], 'ctag-old');
      expect(progress['sync_gate_reason'], SyncGateReason.safeFirstSync);
    });

    test('bootstrap full coverage updates synced_ctag and clears sync gate', () async {
      if (!sqliteReady) {
        markTestSkipped('sqflite platform plugin is unavailable in this test environment.');
        return;
      }

      final db = await resetDb();
      await _seedBase(db);
      await db.insert('sync_items', {
        'remote_collection_id': 10,
        'item_type': 'event',
        'remote_uid': 'uid-1',
        'remote_href': '/calendars/tester/home/uid-1.ics',
        'local_item_id': 'local-uid-1',
        'last_etag': 'etag-1',
        'last_mtime': 100,
        'sync_status': SyncItemStatus.synced,
      });

      final strategy = _TestSyncStrategy(
        remote: _FakeRemoteGateway(
          const UnifiedEventsSnapshot(
            events: [
              {
                'instance_key': 'uid-1',
                'remote_uid': 'uid-1',
                'etag': 'etag-1',
                'href': '/calendars/tester/home/uid-1.ics',
              },
            ],
            statusCode: 200,
            fetchSucceeded: true,
            parseProducedZeroEvents: false,
          ),
        ),
        local: _FakeLocalGateway(
          events: <PlatformItem>[
            PlatformItem(localId: 'local-uid-1', uid: 'uid-1', lastModified: 100),
          ],
        ),
      );

      await strategy.runUnifiedSync(
        _ctx(),
        SyncSummary(),
        mode: UnifiedSyncMode.pull,
        bootstrap: true,
      );

      final progress = await _loadProgress(db);
      expect(progress['synced_ctag'], 'ctag-new');
      expect(progress['sync_gate_reason'], isNull);
    });

    test('failed pullRemoteEventToLocal during bootstrap keeps synced_ctag and sync gate', () async {
      if (!sqliteReady) {
        markTestSkipped('sqflite platform plugin is unavailable in this test environment.');
        return;
      }

      final db = await resetDb();
      await _seedBase(db);

      final strategy = _FailingPullSyncStrategy(
        remote: _FakeRemoteGateway(
          const UnifiedEventsSnapshot(
            events: [
              {
                'instance_key': 'uid-new',
                'remote_uid': 'uid-new',
                'etag': 'etag-new',
                'href': '/calendars/tester/home/uid-new.ics',
              },
            ],
            statusCode: 200,
            fetchSucceeded: true,
            parseProducedZeroEvents: false,
          ),
        ),
        local: _FakeLocalGateway(),
      );

      await strategy.runUnifiedSync(
        _ctx(),
        SyncSummary(),
        mode: UnifiedSyncMode.pull,
        bootstrap: true,
      );

      final progress = await _loadProgress(db);
      expect(progress['synced_ctag'], 'ctag-old');
      expect(progress['sync_gate_reason'], SyncGateReason.safeFirstSync);
    });
  });
}

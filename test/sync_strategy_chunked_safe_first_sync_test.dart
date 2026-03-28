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

class _StatefulLocalGateway extends LocalItemGateway {
  final Map<String, PlatformItem> _eventsByUid = <String, PlatformItem>{};

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
    final String localId = eventId ?? 'local-$uid';
    _eventsByUid[uid] = PlatformItem(
      localId: localId,
      uid: uid,
      title: title,
      notes: notes,
      location: location,
      startTime: start,
      endTime: end,
      eventTimezone: eventTimezone,
      isAllDay: isAllDay,
      lastModified: DateTime.now().millisecondsSinceEpoch,
    );
    return localId;
  }

  @override
  Future<bool> deleteEvent(String eventId) async {
    _eventsByUid.removeWhere((_, PlatformItem event) => event.localId == eventId);
    return true;
  }

  @override
  Future<List<PlatformItem>> getEvents(String localCalendarId, int start, int end) async {
    return _eventsByUid.values.toList();
  }

  @override
  Future<List<String>> getSystemEventIds(String localCalendarId, int startMs, int endMs) async {
    return _eventsByUid.values.map((PlatformItem event) => event.localId ?? '').where((id) => id.isNotEmpty).toList();
  }
}

class _TestSyncStrategy extends SyncStrategy {
  _TestSyncStrategy({required RemoteItemGateway remote, required LocalItemGateway local})
    : _remoteGateway = remote,
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

UnifiedEventsSnapshot _largeSnapshot(int count) {
  return UnifiedEventsSnapshot(
    events: List<Map<String, dynamic>>.generate(
      count,
      (int i) => <String, dynamic>{
        'instance_key': 'uid-$i',
        'remote_uid': 'uid-$i',
        'etag': 'etag-$i',
        'href': '/calendars/tester/home/uid-$i.ics',
        'summary': 'event-$i',
        'description': 'desc-$i',
        'dtstart': 1700000000000 + (i * 60000),
        'dtend': 1700003600000 + (i * 60000),
      },
    ),
    statusCode: 200,
    fetchSucceeded: true,
    parseProducedZeroEvents: false,
  );
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

  test('safe-first-sync chunked bootstrap keeps gate/ctag until final pass', () async {
    if (!sqliteReady) {
      markTestSkipped('sqflite platform plugin is unavailable in this test environment.');
      return;
    }

    final db = await resetDb();
    await _seedBase(db);

    final local = _StatefulLocalGateway();
    final strategy = _TestSyncStrategy(
      remote: _FakeRemoteGateway(_largeSnapshot(70)),
      local: local,
    );

    final firstSummary = SyncSummary();
    await strategy.runUnifiedSync(
      _ctx(),
      firstSummary,
      mode: UnifiedSyncMode.pull,
      bootstrap: true,
    );

    expect(firstSummary.continuationQueued, isTrue);
    final int firstPassMappings = Sqflite.firstIntValue(
          await db.rawQuery('SELECT COUNT(*) FROM sync_items WHERE remote_collection_id = 10'),
        ) ??
        0;
    expect(firstPassMappings, lessThan(70));

    final firstProgress = await _loadProgress(db);
    expect(firstProgress['synced_ctag'], 'ctag-old');
    expect(firstProgress['sync_gate_reason'], SyncGateReason.safeFirstSync);

    final secondSummary = SyncSummary();
    await strategy.runUnifiedSync(
      _ctx(),
      secondSummary,
      mode: UnifiedSyncMode.pull,
      bootstrap: true,
    );

    expect(secondSummary.continuationQueued, isFalse);
    final int secondPassMappings = Sqflite.firstIntValue(
          await db.rawQuery('SELECT COUNT(*) FROM sync_items WHERE remote_collection_id = 10'),
        ) ??
        0;
    expect(secondPassMappings, 70);

    final secondProgress = await _loadProgress(db);
    expect(secondProgress['synced_ctag'], 'ctag-new');
    expect(secondProgress['sync_gate_reason'], isNull);
  });
}

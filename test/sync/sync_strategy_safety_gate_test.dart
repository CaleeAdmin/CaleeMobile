import 'dart:io';

import 'package:caleesync/core/platform/pigeon/calendar_api.g.dart';
import 'package:caleesync/data/database_helper.dart';
import 'package:caleesync/entity/SyncContext.dart';
import 'package:caleesync/entity/SyncSummary.dart';
import 'package:caleesync/services/calee_server_service.dart';
import 'package:caleesync/sync/SyncEnum.dart';
import 'package:caleesync/sync/strategy/SyncStrategy.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite/sqflite.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

class _FakeLocalGateway extends LocalItemGateway {
  final List<PlatformItem> events;
  int deletes = 0;

  _FakeLocalGateway(this.events);

  @override
  Future<String?> createOrUpdateEvent({required String calendarId, String? eventId, required String uid, required String title, required int start, required int end, String? notes}) async => eventId ?? uid;

  @override
  Future<bool> deleteEvent(String eventId) async {
    deletes++;
    return true;
  }

  @override
  Future<List<PlatformItem>> getEvents(String localCalendarId, int start, int end) async => events;
}

class _FakeRemoteGateway extends RemoteItemGateway {
  final UnifiedEventsSnapshot snapshot;
  int deletes = 0;

  _FakeRemoteGateway(this.snapshot);

  @override
  Future<bool> deleteEvent({required String eventPath}) async {
    deletes++;
    return true;
  }

  @override
  Future<UnifiedEventsSnapshot> fetchUnifiedEventsSnapshot({required String calendarPath, required bool isSubscription}) async => snapshot;

  @override
  Future<String?> uploadEventData({required String userId, required String calendarPath, required String uid, required String title, DateTime? start, DateTime? end, String? targetEventPath}) async => 'etag';
}

class _TestStrategy extends SyncStrategy {
  _TestStrategy({required this.allowOverride, required this.local, required this.remote});

  final bool allowOverride;
  final _FakeLocalGateway local;
  final _FakeRemoteGateway remote;

  @override
  late final LocalItemGateway localGateway = local;

  @override
  late final RemoteItemGateway remoteGateway = remote;

  @override
  bool isMassDeletionOverrideEnabled(int bindingId) => allowOverride;

  @override
  Future<void> execute(SyncContext ctx, SyncSummary summary) async {}
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Database db;

  setUpAll(() async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  setUp(() async {
    await DatabaseHelper.instance.close();
    final dbPath = await databaseFactory.getDatabasesPath();
    final file = File(p.join(dbPath, 'caleesync.db'));
    if (await file.exists()) {
      await file.delete();
    }
    db = await DatabaseHelper.instance.database;
  });

  test('mass deletion safety blocks deletes unless override enabled', () async {
    await db.insert('remote_collections', {
      'id': 10,
      'account_name': 'u1',
      'collection_type': 'calendar',
      'remote_path': '/c/10',
      'display_name': 'r',
      'color': '#fff',
      'sync_mode': SyncBindingMode.twoWay,
      'is_enabled': 1,
    });
    await db.insert('local_bindings', {
      'id': 10,
      'remote_collection_id': 10,
      'local_collection_id': 'loc-10',
      'binding_origin': SyncBindingOrigin.remote,
    });

    for (var i = 0; i < 10; i++) {
      await db.insert('sync_items', {
        'remote_collection_id': 10,
        'remote_uid': 'uid-$i',
        'local_item_id': 'local-$i',
        'remote_href': '/c/10/uid-$i.ics',
        'last_etag': 'e1',
        'sync_status': SyncItemStatus.synced,
      });
    }

    final remote = _FakeRemoteGateway(const UnifiedEventsSnapshot(events: [], statusCode: 200, fetchSucceeded: true, parseProducedZeroEvents: true));
    final local = _FakeLocalGateway(List.generate(10, (i) => PlatformItem(localId: 'local-$i', uid: 'uid-$i', title: 't$i', startTime: 1, endTime: 2, lastModified: 5)));
    final ctx = SyncContext(
      remoteCollectionId: 10,
      localCalendarId: 'loc-10',
      remotePath: '/c/10',
      accountName: 'u1',
      displayName: 'r',
      color: '#fff',
      syncMode: SyncBindingMode.twoWay,
      action: SyncAction.fullSyncBidi,
      extra: {'binding_id': 10, 'binding_origin': SyncBindingOrigin.remote},
    );

    final summaryBlocked = SyncSummary();
    await _TestStrategy(allowOverride: false, local: local, remote: remote)
        .runUnifiedSync(ctx, summaryBlocked, mode: UnifiedSyncMode.bidi);
    expect(summaryBlocked.bindingOutcomes[10], SyncOutcomeStatus.safetyGateBlockedDeletions);
    expect(local.deletes, 0);
    expect(remote.deletes, 0);

    final summaryAllowed = SyncSummary();
    await _TestStrategy(allowOverride: true, local: local, remote: remote)
        .runUnifiedSync(ctx, summaryAllowed, mode: UnifiedSyncMode.bidi);
    expect(local.deletes + remote.deletes, greaterThan(0));
  });
}

import 'dart:io';

import 'package:caleesync/data/database_helper.dart';
import 'package:caleesync/data/sync_repository.dart';
import 'package:caleesync/entity/SyncContext.dart';
import 'package:caleesync/entity/SyncSummary.dart';
import 'package:caleesync/entity/sync_run_record.dart';
import 'package:caleesync/services/calee_auth_service.dart';
import 'package:caleesync/services/calee_server_service.dart';
import 'package:caleesync/sync/SyncEngine.dart';
import 'package:caleesync/sync/SyncEnum.dart';
import 'package:caleesync/sync/sync_item_executor.dart';
import 'package:caleesync/sync/sync_item_planner.dart';
import 'package:caleesync/sync/sync_run_recorder.dart';
import 'package:caleesync/sync/strategy/SyncStrategy.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite/sqflite.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

class _FakeRepo extends SyncRepository {
  @override
  Future<void> scanLocalCalendars(String userId) async {}

  @override
  Future<int> countEnabledCalendarBindings(String accountName) async => 1;
}

class _FakeServer extends CaleeServerService {
  @override
  Future<List<Map<String, dynamic>>> scanRemoteCalendars({required String serverUrl, required String userId}) async =>
      [
        {'remote_path': '/c/1', 'ctag': 'c2', 'display_name': 'Remote', 'color': '#fff'}
      ];
}

class _FakePlanner extends SyncItemPlanner {
  _FakePlanner(this._items);
  final List<SyncContext> _items;

  @override
  Future<List<SyncContext>> generateSyncItems(String userId, List<Map<String, dynamic>> remoteResults) async => _items;
}

class _FakeExecutor extends SyncItemExecutor {
  _FakeExecutor(this.db);
  final Database db;

  @override
  Future<void> execute(SyncContext ctx, SyncSummary summary) async {
    await db.insert('sync_items', {
      'remote_collection_id': ctx.remoteCollectionId,
      'remote_uid': 'uid-1',
      'local_item_id': 'local-1',
      'remote_href': '/c/1/uid-1.ics',
      'last_etag': 'e1',
      'sync_status': SyncItemStatus.synced,
    });
    summary.success++;
  }
}

class _FakeRecorder extends SyncRunRecorder {
  SyncRunMode? mode;
  SyncRunTrigger? trigger;
  SyncRunResult? result;
  bool started = false;

  @override
  Future<void> startRun({required SyncRunMode mode, required SyncRunTrigger trigger}) async {
    started = true;
    this.mode = mode;
    this.trigger = trigger;
  }

  @override
  Future<void> finalizeAndPersist(SyncRunResult result) async {
    this.result = result;
  }
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

  test('executeFullSync plans, executes, and records run', () async {
    final ctx = SyncContext(
      remoteCollectionId: 1,
      localCalendarId: 'local-c1',
      remotePath: '/c/1',
      accountName: 'u1',
      displayName: 'Remote',
      color: '#fff',
      syncMode: SyncBindingMode.twoWay,
      action: SyncAction.fullSyncBidi,
      extra: {'binding_id': 1, 'binding_origin': SyncBindingOrigin.remote},
    );
    final recorder = _FakeRecorder();

    final engine = SyncEngine(
      repo: _FakeRepo(),
      serverService: _FakeServer(),
      authService: CaleeAuthService(serverBaseUrl: 'https://example.com'),
      planner: _FakePlanner([ctx]),
      executor: _FakeExecutor(db),
      runRecorder: recorder,
      loginNameReader: () => 'u1',
    );

    final summary = await engine.executeFullSync(trigger: SyncRunTrigger.manual);

    expect(summary.success, 1);
    expect(recorder.started, isTrue);
    expect(recorder.mode, SyncRunMode.twoWay);
    expect(recorder.trigger, SyncRunTrigger.manual);
    expect(recorder.result, SyncRunResult.success);

    final rows = await db.query('sync_items', where: 'remote_collection_id=?', whereArgs: [1]);
    expect(rows.length, 1);
    expect(rows.first['remote_uid'], 'uid-1');
  });

  test('repairDuplicateMappings keeps deterministic winner and removes duplicates', () async {
    await db.insert('remote_collections', {
      'id': 2,
      'account_name': 'u1',
      'collection_type': 'calendar',
      'remote_path': '/c/2',
      'display_name': 'R2',
      'color': '#fff',
      'sync_mode': SyncBindingMode.twoWay,
      'is_enabled': 1,
    });

    await db.insert('sync_items', {
      'remote_collection_id': 2,
      'remote_uid': 'dupe',
      'local_item_id': 'l-1',
      'remote_href': '/c/2/dupe.ics',
      'sync_status': SyncItemStatus.synced,
    });
    await db.insert('sync_items', {
      'remote_collection_id': 2,
      'remote_uid': 'dupe',
      'local_item_id': '',
      'remote_href': '',
      'sync_status': SyncItemStatus.synced,
    });

    final strategy = _RepairHarness();
    final before = await db.query('sync_items', where: 'remote_collection_id=?', whereArgs: [2]);
    final result = await strategy.repair(db, 2, before);

    expect(result.length, 1);
    expect(result.first['local_item_id'], 'l-1');
    expect(result.first['remote_href'], '/c/2/dupe.ics');
  });
}

class _RepairHarness extends SyncStrategy {
  @override
  Future<void> execute(SyncContext ctx, SyncSummary summary) async {}

  Future<List<Map<String, dynamic>>> repair(Database db, int remoteCollectionId, List<Map<String, dynamic>> mappedRecords) async {
    final out = await repairDuplicateMappingsPublic(db, remoteCollectionId, mappedRecords);
    return (out['records'] as List).cast<Map<String, dynamic>>();
  }
}

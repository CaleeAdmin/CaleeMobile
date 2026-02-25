import 'dart:io';

import 'package:caleesync/core/platform/pigeon/calendar_api.g.dart';
import 'package:caleesync/data/database_helper.dart';
import 'package:caleesync/sync/SyncEnum.dart';
import 'package:caleesync/sync/force_sync_registry.dart';
import 'package:caleesync/sync/sync_gate_reason.dart';
import 'package:caleesync/sync/sync_item_planner.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

class _FakeCalendarApi extends NativeCalendarApi {
  _FakeCalendarApi(this._calendars);
  final List<PlatformCalendar?> _calendars;

  @override
  Future<List<PlatformCalendar?>> getCalendars() async => _calendars;
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

  Future<void> seedBinding({
    int id = 1,
    required String remotePath,
    String localCollectionId = 'local-1',
    int bindingOrigin = SyncBindingOrigin.remote,
    int syncMode = SyncBindingMode.readOnly,
    bool isSubscription = false,
    String syncedCtag = 'c1',
  }) async {
    await db.insert('remote_collections', {
      'id': id,
      'account_name': 'u1',
      'collection_type': 'calendar',
      'remote_path': remotePath,
      'display_name': 'Remote',
      'color': '#fff',
      'synced_ctag': syncedCtag,
      'sync_mode': syncMode,
      'is_enabled': 1,
      'is_subscription': isSubscription ? 1 : 0,
    });
    await db.insert('local_bindings', {
      'id': id,
      'remote_collection_id': id,
      'local_collection_id': localCollectionId,
      'binding_origin': bindingOrigin,
      'sync_gate_reason': 'stale_gate',
    });
  }

  Future<String?> gateReasonFor(int id) async {
    final rows = await db.query('local_bindings', columns: ['sync_gate_reason'], where: 'id=?', whereArgs: [id]);
    return rows.first['sync_gate_reason']?.toString();
  }

  test('eligibility failures persist sync_gate_reason and return no context', () async {
    await seedBinding(remotePath: '/cal/1', localCollectionId: 'missing');
    final planner = SyncItemPlanner(
      nativeApi: _FakeCalendarApi([]),
      authValidator: (_) => false,
    );

    var out = await planner.generateSyncItems('u1', [
      {'remote_path': '/cal/1', 'ctag': 'c1', 'display_name': 'Remote', 'color': '#fff'},
    ]);
    expect(out, isEmpty);
    expect(await gateReasonFor(1), SyncGateReason.authInvalid);

    await db.update('remote_collections', {'remote_path': ''}, where: 'id=1');
    out = await SyncItemPlanner(
      nativeApi: _FakeCalendarApi([PlatformCalendar(id: 'local-1', supportsEvents: true)]),
      authValidator: (_) => true,
    ).generateSyncItems('u1', [
      {'remote_path': '/cal/1', 'ctag': 'c1'},
    ]);
    expect(out, isEmpty);
    expect(await gateReasonFor(1), SyncGateReason.bindingInvalid);
  });

  test('eligible row clears sync_gate_reason', () async {
    await seedBinding(remotePath: '/cal/1');
    final planner = SyncItemPlanner(
      nativeApi: _FakeCalendarApi([PlatformCalendar(id: 'local-1', supportsEvents: true)]),
      authValidator: (_) => true,
    );
    final out = await planner.generateSyncItems('u1', [
      {'remote_path': '/cal/1', 'ctag': 'new', 'display_name': 'Remote2', 'color': '#000'},
    ]);
    expect(out, isNotEmpty);
    expect(await gateReasonFor(1), isNull);
  });

  test('change detection and force/bootstrap rules', () async {
    await seedBinding(remotePath: '/cal/1', localCollectionId: 'local-1', syncMode: SyncBindingMode.twoWay);
    await seedBinding(id: 2, remotePath: '/cal/2', localCollectionId: 'local-2', syncMode: SyncBindingMode.readOnly, bindingOrigin: SyncBindingOrigin.remote);
    await seedBinding(id: 3, remotePath: '/cal/3', localCollectionId: 'local-3', syncMode: SyncBindingMode.readOnly, bindingOrigin: SyncBindingOrigin.local);

    await db.insert('sync_items', {
      'remote_collection_id': 2,
      'remote_uid': 'u-2',
      'local_item_id': 'l-2',
      'remote_href': '/cal/2/u-2.ics',
      'sync_status': SyncItemStatus.synced,
    });
    await db.insert('sync_items', {
      'remote_collection_id': 3,
      'remote_uid': 'u-3',
      'local_item_id': 'l-3',
      'remote_href': '/cal/3/u-3.ics',
      'sync_status': SyncItemStatus.synced,
    });

    final planner = SyncItemPlanner(
      nativeApi: _FakeCalendarApi([
        PlatformCalendar(id: 'local-1', supportsEvents: true),
        PlatformCalendar(id: 'local-2', supportsEvents: true),
        PlatformCalendar(id: 'local-3', supportsEvents: true),
      ]),
      authValidator: (_) => true,
    );

    final remote = [
      {'remote_path': '/cal/1', 'ctag': 'c1', 'display_name': 'd', 'color': '#f'},
      {'remote_path': '/cal/2', 'ctag': 'c1', 'display_name': 'Remote', 'color': '#fff'},
      {'remote_path': '/cal/3', 'ctag': 'c1', 'display_name': 'Remote', 'color': '#fff'},
    ];

    var out = await planner.generateSyncItems('u1', remote);
    expect(out.where((e) => e.remoteCollectionId == 1).length, 1, reason: 'twoWay always syncs');
    expect(out.where((e) => e.remoteCollectionId == 2), isEmpty, reason: 'one-way remote waits for remote/meta changes');
    expect(out.where((e) => e.remoteCollectionId == 3), isEmpty, reason: 'one-way local waits for local/meta changes');

    ForceSyncRegistry.requestForceSyncForCollection(2);
    out = await planner.generateSyncItems('u1', remote);
    expect(out.where((e) => e.remoteCollectionId == 2).length, 1);

    final out2 = await planner.generateSyncItems('u1', remote);
    expect(out2.where((e) => e.remoteCollectionId == 2), isEmpty, reason: 'force consumed once');

    expect(out.where((e) => e.remoteCollectionId == 1).isNotEmpty, isTrue, reason: 'bootstrap required for empty sync_items table');
  });
}

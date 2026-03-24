import 'package:caleesync/common/app_constant.dart';
import 'package:caleesync/common/utils/mmkv_utils.dart';
import 'package:caleesync/core/platform/pigeon/calendar_api.g.dart';
import 'package:caleesync/data/database_helper.dart';
import 'package:caleesync/entity/SyncContext.dart';
import 'package:caleesync/sync/SyncEnum.dart';
import 'package:caleesync/sync/force_sync_registry.dart';
import 'package:caleesync/sync/sync_item_planner.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite/sqflite.dart';

import 'test_bootstrap.dart';

class _FakeNativeCalendarApi extends NativeCalendarApi {
  _FakeNativeCalendarApi(this._calendars);

  final List<PlatformCalendar?> _calendars;

  @override
  Future<List<PlatformCalendar?>> getCalendars() async => _calendars;
}

class _FakeDatabaseHelper implements DatabaseHelper {
  _FakeDatabaseHelper(this._db);

  final Database _db;

  @override
  Future<Database> get database async => _db;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FakeDatabase implements Database {
  _FakeDatabase({
    required this.collectionRows,
    required this.localChanged,
    required this.bootstrapRequired,
  });

  final List<Map<String, dynamic>> collectionRows;
  final bool localChanged;
  final bool bootstrapRequired;

  @override
  Future<List<Map<String, Object?>>> rawQuery(String sql, [List<Object?>? arguments]) async {
    if (sql.contains('FROM remote_collections rc')) {
      return collectionRows;
    }

    if (sql.contains('sync_status = ${SyncItemStatus.pendingPush}')) {
      return localChanged
          ? <Map<String, Object?>>[
              <String, Object?>{'1': 1},
            ]
          : const <Map<String, Object?>>[];
    }

    if (sql.contains('SELECT COUNT(1) AS count')) {
      return <Map<String, Object?>>[
        <String, Object?>{'count': bootstrapRequired ? 0 : 1},
      ];
    }

    throw UnsupportedError('Unexpected rawQuery SQL: $sql');
  }

  @override
  Future<int> insert(
    String table,
    Map<String, Object?> values, {
    String? nullColumnHack,
    ConflictAlgorithm? conflictAlgorithm,
  }) async {
    return 1;
  }

  @override
  Future<int> update(
    String table,
    Map<String, Object?> values, {
    String? where,
    List<Object?>? whereArgs,
    ConflictAlgorithm? conflictAlgorithm,
  }) async {
    return 1;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

Map<String, dynamic> _baseCollectionRow() {
  return <String, dynamic>{
    'id': 10,
    'account_name': 'tester',
    'remote_path': '/calendars/tester/home/',
    'display_name': 'Home',
    'color': '#00ff00',
    'synced_ctag': 'ctag-1',
    'sync_mode': SyncBindingMode.twoWay,
    'state_is_enabled': 1,
    'is_subscription': 0,
    'origin_kind': SyncBindingOrigin.remote,
    'binding_id': 22,
    'binding_role': SyncBindingRole.mirror,
    'local_collection_id': 'local-home',
    'sync_gate_reason': null,
  };
}

Map<String, dynamic> _remoteCalendar({
  required bool remoteChanged,
  required bool metaChanged,
}) {
  return <String, dynamic>{
    'remote_path': '/calendars/tester/home/',
    'ctag': remoteChanged ? 'ctag-2' : 'ctag-1',
    'display_name': metaChanged ? 'Home Updated' : 'Home',
    'color': metaChanged ? '#ff0000' : '#00ff00',
  };
}

Future<List<SyncContext>> _planTwoWay({
  required bool remoteChanged,
  required bool localChanged,
  required bool metaChanged,
  required bool force,
  required bool bootstrapRequired,
}) async {
  final _FakeDatabase db = _FakeDatabase(
    collectionRows: <Map<String, dynamic>>[_baseCollectionRow()],
    localChanged: localChanged,
    bootstrapRequired: bootstrapRequired,
  );

  final SyncItemPlanner planner = SyncItemPlanner(
    dbHelper: _FakeDatabaseHelper(db),
    nativeApi: _FakeNativeCalendarApi(<PlatformCalendar?>[
      PlatformCalendar(
        id: 'local-home',
        supportsEvents: true,
        isReadOnly: false,
      ),
    ]),
  );

  if (force) {
    ForceSyncRegistry.requestForceSyncForCollection(10);
  }

  return planner.generateSyncItems(
    'tester',
    <Map<String, dynamic>>[_remoteCalendar(remoteChanged: remoteChanged, metaChanged: metaChanged)],
  );
}

void main() {
  bool mmkvReady = false;

  setUpAll(() async {
    try {
      await bootstrapTestStorage();
      MMKVUtils.instance.setString(AppConstant.loginNameKey, 'tester');
      MMKVUtils.instance.setString(AppConstant.appPasswordKey, 'app-password');
      mmkvReady = true;
    } catch (_) {
      mmkvReady = false;
    }
  });

  group('SyncItemPlanner two-way planner gate', () {
    setUp(() {
      if (!mmkvReady) {
        markTestSkipped('MMKV platform plugin is unavailable in this test environment.');
      }
    });
    test('skips unchanged two-way calendar when not forced and no bootstrap', () async {
      final contexts = await _planTwoWay(
        remoteChanged: false,
        localChanged: false,
        metaChanged: false,
        force: false,
        bootstrapRequired: false,
      );

      expect(contexts, isEmpty);
    });

    test('syncs when remoteChanged for two-way calendar', () async {
      final contexts = await _planTwoWay(
        remoteChanged: true,
        localChanged: false,
        metaChanged: false,
        force: false,
        bootstrapRequired: false,
      );

      expect(contexts, hasLength(1));
      expect(contexts.first.action, SyncAction.fullSyncBidi);
    });

    test('syncs when localChanged for two-way calendar', () async {
      final contexts = await _planTwoWay(
        remoteChanged: false,
        localChanged: true,
        metaChanged: false,
        force: false,
        bootstrapRequired: false,
      );

      expect(contexts, hasLength(1));
      expect(contexts.first.action, SyncAction.fullSyncBidi);
    });

    test('syncs when metaChanged for two-way calendar', () async {
      final contexts = await _planTwoWay(
        remoteChanged: false,
        localChanged: false,
        metaChanged: true,
        force: false,
        bootstrapRequired: false,
      );

      expect(contexts, hasLength(1));
      expect(contexts.first.action, SyncAction.fullSyncBidi);
    });

    test('syncs unchanged two-way calendar when force is requested', () async {
      final contexts = await _planTwoWay(
        remoteChanged: false,
        localChanged: false,
        metaChanged: false,
        force: true,
        bootstrapRequired: false,
      );

      expect(contexts, hasLength(1));
      expect(contexts.first.action, SyncAction.fullSyncBidi);
    });

    test('syncs unchanged two-way calendar when bootstrap is required', () async {
      final contexts = await _planTwoWay(
        remoteChanged: false,
        localChanged: false,
        metaChanged: false,
        force: false,
        bootstrapRequired: true,
      );

      expect(contexts, hasLength(1));
      expect(contexts.first.action, SyncAction.fullSyncBidi);
    });
  });
}

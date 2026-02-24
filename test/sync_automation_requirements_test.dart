import 'dart:io';

import 'package:caleesync/core/platform/pigeon/calendar_api.g.dart';
import 'package:caleesync/data/database_helper.dart';
import 'package:caleesync/entity/SyncContext.dart';
import 'package:caleesync/entity/SyncSummary.dart';
import 'package:caleesync/sync/SyncEnum.dart';
import 'package:caleesync/sync/force_sync_registry.dart';
import 'package:caleesync/sync/background_sync_scheduler.dart';
import 'package:caleesync/sync/strategy/SyncStrategy.dart';
import 'package:caleesync/sync/sync_item_planner.dart';
import 'package:caleesync/services/calee_server_service.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite/sqflite.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Database db;
  late SyncItemPlanner planner;

  setUpAll(() async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    await DatabaseHelper.instance.deleteMyDatabase();
    db = await DatabaseHelper.instance.database;
    planner = SyncItemPlanner(nativeApi: _FakeNativeCalendarApi(calendars: [PlatformCalendar(id: 'local-1')]));
  });

  setUp(() async {
    await db.delete('sync_items');
    await db.delete('local_bindings');
    await db.delete('remote_collections');
  });

  Future<void> seedBinding({
    required int remoteId,
    int isEnabled = 1,
    int syncMode = SyncBindingMode.readOnly,
    int bindingOrigin = SyncBindingOrigin.remote,
    String syncedCtag = 'same',
  }) async {
    await db.insert('remote_collections', {
      'id': remoteId,
      'account_name': 'alice',
      'collection_type': 'calendar',
      'remote_path': '/cal/$remoteId',
      'display_name': 'Calendar $remoteId',
      'color': '#fff',
      'synced_ctag': syncedCtag,
      'sync_mode': syncMode,
      'is_enabled': isEnabled,
      'is_subscription': 0,
    });
    await db.insert('local_bindings', {
      'remote_collection_id': remoteId,
      'local_collection_id': 'local-1',
      'binding_origin': bindingOrigin,
    });
  }

  test('disabled binding never produces sync context', () async {
    await seedBinding(remoteId: 1, isEnabled: 0);
    final contexts = await planner.generateSyncItems('alice', [
      {'remote_path': '/cal/1', 'ctag': 'same', 'display_name': 'Calendar 1', 'color': '#fff'}
    ]);
    expect(contexts, isEmpty);
  });

  test('two-way mode always produces context even with no change', () async {
    await seedBinding(remoteId: 2, syncMode: SyncBindingMode.twoWay);
    await db.insert('sync_items', {
      'remote_collection_id': 2,
      'item_type': 'event',
      'remote_uid': 'u1',
      'local_item_id': 'l1',
      'sync_status': SyncItemStatus.synced,
    });

    final contexts = await planner.generateSyncItems('alice', [
      {'remote_path': '/cal/2', 'ctag': 'same', 'display_name': 'Calendar 2', 'color': '#fff'}
    ]);
    expect(contexts.length, 1);
    expect(contexts.first.action, SyncAction.fullSyncBidi);
  });

  test('one-way pull ignores local-only changes', () async {
    await seedBinding(remoteId: 3, bindingOrigin: SyncBindingOrigin.remote);
    await db.insert('sync_items', {
      'remote_collection_id': 3,
      'item_type': 'event',
      'remote_uid': 'u1',
      'local_item_id': 'l1',
      'sync_status': SyncItemStatus.pendingPush,
    });

    final contexts = await planner.generateSyncItems('alice', [
      {'remote_path': '/cal/3', 'ctag': 'same', 'display_name': 'Calendar 3', 'color': '#fff'}
    ]);
    expect(contexts, isEmpty);
  });

  test('one-way push ignores remote-only changes', () async {
    await seedBinding(remoteId: 4, bindingOrigin: SyncBindingOrigin.local, syncedCtag: 'old');
    await db.insert('sync_items', {
      'remote_collection_id': 4,
      'item_type': 'event',
      'remote_uid': 'u1',
      'local_item_id': 'l1',
      'sync_status': SyncItemStatus.synced,
    });

    final contexts = await planner.generateSyncItems('alice', [
      {'remote_path': '/cal/4', 'ctag': 'new', 'display_name': 'Calendar 4', 'color': '#fff'}
    ]);
    expect(contexts, isEmpty);
  });

  test('bootstrap and force sync are each consumed once', () async {
    await seedBinding(remoteId: 5, bindingOrigin: SyncBindingOrigin.remote);

    final bootstrap = await planner.generateSyncItems('alice', [
      {'remote_path': '/cal/5', 'ctag': 'same', 'display_name': 'Calendar 5', 'color': '#fff'}
    ]);
    expect(bootstrap.length, 1);

    await db.insert('sync_items', {
      'remote_collection_id': 5,
      'item_type': 'event',
      'remote_uid': 'u1',
      'local_item_id': 'l1',
      'sync_status': SyncItemStatus.synced,
    });

    ForceSyncRegistry.requestForceSyncForCollection(5);
    final forced = await planner.generateSyncItems('alice', [
      {'remote_path': '/cal/5', 'ctag': 'same', 'display_name': 'Calendar 5', 'color': '#fff'}
    ]);
    final normal = await planner.generateSyncItems('alice', [
      {'remote_path': '/cal/5', 'ctag': 'same', 'display_name': 'Calendar 5', 'color': '#fff'}
    ]);

    expect(forced.length, 1);
    expect(normal, isEmpty);
  });

  test('duplicate mapping repair keeps one deterministic row per UID', () async {
    final strategy = _TestSyncStrategy(
      localGateway: _FakeLocalGateway(),
      remoteGateway: _FakeRemoteGateway(snapshot: const UnifiedEventsSnapshot(events: [], statusCode: 200, fetchSucceeded: true, parseProducedZeroEvents: true)),
    );

    await db.insert('sync_items', {'remote_collection_id': 6, 'remote_uid': 'u1', 'local_item_id': 'l1', 'remote_href': '/a.ics', 'sync_status': 3});
    await db.insert('sync_items', {'remote_collection_id': 6, 'remote_uid': 'u1', 'local_item_id': 'l2', 'remote_href': '', 'sync_status': 3});

    final before = await db.query('sync_items', where: 'remote_collection_id = ?', whereArgs: [6]);
    final after = await strategy.repairDuplicateMappings(db, 6, before);

    final kept = after.records.where((row) => row['remote_uid'] == 'u1').toList();
    expect(kept.length, 1);
    expect(kept.first['local_item_id'], 'l1');
  });

  test('uid integrity: push generates uid and persists locally', () async {
    final local = _FakeLocalGateway();
    final remote = _FakeRemoteGateway(snapshot: const UnifiedEventsSnapshot(events: [], statusCode: 200, fetchSucceeded: true, parseProducedZeroEvents: true));
    final strategy = _TestSyncStrategy(localGateway: local, remoteGateway: remote);

    final result = await strategy.pushLocalEventToRemote(
      local: PlatformItem(localId: 'local-event', uid: '', title: 'A', startTime: 1, endTime: 2),
      remotePath: '/cal/uid',
      localCalendarId: 'local-1',
    );

    expect(result, isNotNull);
    expect(local.lastUpsertedUid, isNotEmpty);
    expect(remote.lastUploadedUid, local.lastUpsertedUid);
  });

  test('mass deletion safety and untrusted snapshot block destructive operations', () async {
    final local = _FakeLocalGateway(localEvents: []);
    final remote = _FakeRemoteGateway(
      snapshot: const UnifiedEventsSnapshot(events: [], statusCode: 500, fetchSucceeded: false, parseProducedZeroEvents: true),
    );
    final strategy = _TestSyncStrategy(localGateway: local, remoteGateway: remote);

    for (int i = 0; i < 12; i++) {
      await db.insert('sync_items', {
        'remote_collection_id': 7,
        'remote_uid': 'uid-$i',
        'local_item_id': 'local-$i',
        'sync_status': 3,
      });
    }

    final summary = SyncSummary();
    final ctx = SyncContext(
      remoteCollectionId: 7,
      localCalendarId: 'local-1',
      remotePath: '/cal/7',
      accountName: 'alice',
      displayName: 'Cal 7',
      color: '#fff',
      syncMode: 0,
      action: SyncAction.fullSyncPull,
      extra: const {'binding_id': 0, 'binding_origin': SyncBindingOrigin.remote},
    );

    await strategy.runUnifiedSync(ctx, summary, mode: UnifiedSyncMode.pull);

    expect(local.deletedIds, isEmpty);
    expect(remote.deletedHrefs, isEmpty);
    expect(summary.bindingOutcomes.values, contains(SyncOutcomeStatus.safetyGateBlockedDeletions));
  });

  test('build pipeline runs flutter tests', () {
    final workflow = File('.github/workflows/build-signed-apk.yml').readAsStringSync();
    expect(workflow, contains('Run test suite'));
    expect(workflow, contains('flutter test'));
  });

  test('workmanager uniqueness and background result mapping contract is encoded in android worker', () {
    final worker = File('android/app/src/main/kotlin/com/viso/caleesync/BackgroundSyncWorker.kt').readAsStringSync();
    expect(worker, contains('PERIODIC_UNIQUE'));
    expect(worker, contains('ONE_OFF_UNIQUE'));
    expect(worker, contains('ExistingPeriodicWorkPolicy.UPDATE'));
    expect(worker, contains('ExistingWorkPolicy.KEEP'));
    expect(worker, contains('"success" -> Result.success()'));
    expect(worker, contains('"retry" -> Result.retry()'));
    expect(worker, contains('Result.failure'));
  });

  test('background scheduler uses unique one-off name in channel payload', () async {
    const channel = MethodChannel('caleesync/background_sync');
    MethodCall? captured;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      captured = call;
      return null;
    });

    await BackgroundSyncScheduler.scheduleOneOff(reason: 'manual', expedited: false);

    expect(captured?.method, 'enqueueOneOff');
    expect((captured?.arguments as Map)['uniqueName'], 'CaleeSyncOneTimeWorker');
  });
}

class _FakeNativeCalendarApi extends NativeCalendarApi {
  _FakeNativeCalendarApi({required this.calendars});

  final List<PlatformCalendar?> calendars;

  @override
  Future<List<PlatformCalendar?>> getCalendars() async => calendars;
}

class _TestSyncStrategy extends SyncStrategy {
  _TestSyncStrategy({required this.localGateway, required this.remoteGateway});

  @override
  final LocalItemGateway localGateway;

  @override
  final RemoteItemGateway remoteGateway;

  @override
  Future<void> execute(SyncContext ctx, SyncSummary summary) async {}
}

class _FakeLocalGateway extends LocalItemGateway {
  _FakeLocalGateway({this.localEvents = const []});

  final List<PlatformItem> localEvents;
  String lastUpsertedUid = '';
  final List<String> deletedIds = [];

  @override
  Future<String?> createOrUpdateEvent({required String calendarId, String? eventId, required String uid, required String title, required int start, required int end, String? notes}) async {
    lastUpsertedUid = uid;
    return eventId ?? 'generated-local-id';
  }

  @override
  Future<bool> deleteEvent(String eventId) async {
    deletedIds.add(eventId);
    return true;
  }

  @override
  Future<List<PlatformItem>> getEvents(String calendarId, int startMs, int endMs) async => localEvents;
}

class _FakeRemoteGateway extends RemoteItemGateway {
  _FakeRemoteGateway({required this.snapshot});

  final UnifiedEventsSnapshot snapshot;
  final List<String> deletedHrefs = [];
  String lastUploadedUid = '';

  @override
  Future<bool> deleteEvent({required String eventPath}) async {
    deletedHrefs.add(eventPath);
    return true;
  }

  @override
  Future<UnifiedEventsSnapshot> fetchUnifiedEventsSnapshot({required String calendarPath, required bool isSubscription}) async => snapshot;

  @override
  Future<String?> uploadEventData({required String userId, required String calendarPath, required String uid, required String title, DateTime? start, DateTime? end, String? targetEventPath}) async {
    lastUploadedUid = uid;
    return 'etag';
  }
}

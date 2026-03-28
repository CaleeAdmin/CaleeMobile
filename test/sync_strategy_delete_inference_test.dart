import 'package:caleesync/core/platform/pigeon/calendar_api.g.dart';
import 'package:caleesync/entity/SyncContext.dart';
import 'package:caleesync/entity/SyncSummary.dart';
import 'package:caleesync/sync/SyncEnum.dart';
import 'package:caleesync/sync/strategy/SyncStrategy.dart';
import 'package:flutter_test/flutter_test.dart';


class _TestSyncStrategy extends SyncStrategy {
  _TestSyncStrategy({LocalItemGateway? gateway}) : _localGateway = gateway ?? _FakeLocalItemGateway(events: const []);

  final LocalItemGateway _localGateway;

  @override
  LocalItemGateway get localGateway => _localGateway;

  @override
  Future<void> execute(SyncContext ctx, SyncSummary summary) async {}
}

class _FakeLocalItemGateway extends LocalItemGateway {
  _FakeLocalItemGateway({
    required this.events,
    this.systemIds = const <String>[],
    this.shouldThrowOnGetSystemIds = false,
  });

  final List<PlatformItem> events;
  final List<String> systemIds;
  final bool shouldThrowOnGetSystemIds;
  String? lastCalendarId;
  int? lastStartMs;
  int? lastEndMs;

  @override
  Future<List<PlatformItem>> getEvents(String localCalendarId, int start, int end) async => events;

  @override
  Future<List<String>> getSystemEventIds(String localCalendarId, int startMs, int endMs) async {
    lastCalendarId = localCalendarId;
    lastStartMs = startMs;
    lastEndMs = endMs;
    if (shouldThrowOnGetSystemIds) {
      throw Exception('system id enumeration failed');
    }
    return systemIds;
  }

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
  }) async => null;

  @override
  Future<bool> deleteEvent(String eventId) async => false;
}

void main() {
  group('SyncStrategy delete inference authority', () {
    final rules = UnifiedModeRules.forMode(UnifiedSyncMode.bidi);

    test('skips remote delete when local absence is not trusted', () {
      final strategy = _TestSyncStrategy();
      final action = strategy.decideCanonicalActionForTesting(
        uid: 'uid-1',
        remote: {'etag': 'r1'},
        mapping: {'remote_uid': 'uid-1'},
        local: null,
        bindingRole: SyncBindingRole.mirror,
        rules: rules,
        bootstrap: false,
        canDeleteRemoteFromMissingLocal: false,
        canDeleteLocalFromMissingRemote: true,
      );

      expect(action, SyncItemAction.skip);
    });

    test('keeps remote delete when local absence is trusted', () {
      final strategy = _TestSyncStrategy();
      final action = strategy.decideCanonicalActionForTesting(
        uid: 'uid-1',
        remote: {'etag': 'r1'},
        mapping: {'remote_uid': 'uid-1'},
        local: null,
        bindingRole: SyncBindingRole.mirror,
        rules: rules,
        bootstrap: false,
        canDeleteRemoteFromMissingLocal: true,
        canDeleteLocalFromMissingRemote: true,
      );

      expect(action, SyncItemAction.deleteRemote);
    });

    test('skips local delete when remote absence is not trusted', () {
      final strategy = _TestSyncStrategy();
      final action = strategy.decideCanonicalActionForTesting(
        uid: 'uid-2',
        remote: null,
        mapping: {'remote_uid': 'uid-2'},
        local: PlatformItem(localId: 'l-2', uid: 'uid-2', lastModified: 100),
        bindingRole: SyncBindingRole.mirror,
        rules: rules,
        bootstrap: false,
        canDeleteRemoteFromMissingLocal: true,
        canDeleteLocalFromMissingRemote: false,
      );

      expect(action, SyncItemAction.skip);
    });

    test('keeps local delete when remote snapshot is trusted', () {
      final strategy = _TestSyncStrategy();
      final action = strategy.decideCanonicalActionForTesting(
        uid: 'uid-2',
        remote: null,
        mapping: {'remote_uid': 'uid-2'},
        local: PlatformItem(localId: 'l-2', uid: 'uid-2', lastModified: 100),
        bindingRole: SyncBindingRole.mirror,
        rules: rules,
        bootstrap: false,
        canDeleteRemoteFromMissingLocal: true,
        canDeleteLocalFromMissingRemote: true,
      );

      expect(action, SyncItemAction.deleteLocal);
    });
  });

  group('SyncStrategy loadLocalEvents trust flag', () {
    test('marks local snapshot complete when ranged system IDs cover all fetched events', () async {
      final gateway = _FakeLocalItemGateway(
        events: [PlatformItem(localId: 'l-1', uid: 'uid-1')],
        systemIds: ['l-1'],
      );
      final strategy = _TestSyncStrategy(gateway: gateway);

      final snapshot = await strategy.loadLocalEvents(
        'cal-1',
        rangeStartMs: 1000,
        rangeEndMs: 2000,
      );

      expect(snapshot.rangedSystemIds, {'l-1'});
      expect(snapshot.snapshotCoverageComplete, isTrue);
      expect(snapshot.canInferDeletesFromLocalAbsence, isTrue);
    });

    test('marks local snapshot incomplete when ranged system IDs miss fetched event ids', () async {
      final gateway = _FakeLocalItemGateway(
        events: [
          PlatformItem(localId: 'l-1', uid: 'uid-1'),
          PlatformItem(localId: 'l-2', uid: 'uid-2'),
        ],
        systemIds: ['l-1'],
      );
      final strategy = _TestSyncStrategy(gateway: gateway);

      final snapshot = await strategy.loadLocalEvents(
        'cal-1',
        rangeStartMs: 1000,
        rangeEndMs: 2000,
      );

      expect(snapshot.snapshotCoverageComplete, isFalse);
      expect(snapshot.canInferDeletesFromLocalAbsence, isFalse);
    });

    test('marks local snapshot incomplete when ranged system ID enumeration throws', () async {
      final gateway = _FakeLocalItemGateway(
        events: [PlatformItem(localId: 'l-1', uid: 'uid-1')],
        shouldThrowOnGetSystemIds: true,
      );
      final strategy = _TestSyncStrategy(gateway: gateway);

      final snapshot = await strategy.loadLocalEvents(
        'cal-1',
        rangeStartMs: 1000,
        rangeEndMs: 2000,
      );

      expect(snapshot.rangedSystemIds, isEmpty);
      expect(snapshot.snapshotCoverageComplete, isFalse);
      expect(snapshot.canInferDeletesFromLocalAbsence, isFalse);
    });

    test('passes exact sync window to ranged system ID enumeration', () async {
      final gateway = _FakeLocalItemGateway(
        events: [PlatformItem(localId: 'l-1', uid: 'uid-1')],
        systemIds: ['l-1'],
      );
      final strategy = _TestSyncStrategy(gateway: gateway);

      await strategy.loadLocalEvents(
        'cal-window',
        rangeStartMs: 1111,
        rangeEndMs: 2222,
      );

      expect(gateway.lastCalendarId, 'cal-window');
      expect(gateway.lastStartMs, 1111);
      expect(gateway.lastEndMs, 2222);
    });
  });
}

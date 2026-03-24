import 'package:caleesync/core/platform/pigeon/calendar_api.g.dart';
import 'package:caleesync/entity/SyncContext.dart';
import 'package:caleesync/entity/SyncSummary.dart';
import 'package:caleesync/sync/SyncEnum.dart';
import 'package:caleesync/sync/strategy/SyncStrategy.dart';
import 'package:flutter_test/flutter_test.dart';

class _TestSyncStrategy extends SyncStrategy {
  @override
  Future<void> execute(SyncContext ctx, SyncSummary summary) async {}
}

void main() {
  group('Exchange-safe canonical planning', () {
    final strategy = _TestSyncStrategy();
    final rules = UnifiedModeRules.forMode(UnifiedSyncMode.bidi);

    SyncItemAction decide({
      required Map<String, dynamic>? remote,
      required Map<String, dynamic>? mapping,
      required PlatformItem? local,
    }) {
      return strategy.decideCanonicalActionForTesting(
        uid: 'uid-1',
        remote: remote,
        mapping: mapping,
        local: local,
        bindingRole: SyncBindingRole.ownerLink,
        rules: rules,
        bootstrap: false,
      );
    }

    test('plans createLocal for exchange-risk remote-only item', () {
      final action = decide(
        remote: {'etag': 'r1', 'is_exchange_risk': 1},
        mapping: null,
        local: null,
      );

      expect(action, SyncItemAction.createLocal);
    });

    test('plans deleteLocal for exchange-risk local-only mapped item', () {
      final action = decide(
        remote: null,
        mapping: {
          'remote_uid': 'uid-1',
          'is_exchange_risk': true,
          'last_etag': 'r1',
          'summary': 'mapped',
          'description': 'mapped',
          'dtstart': 100,
          'dtend': 200,
          'last_mtime': 1000,
        },
        local: PlatformItem(
          localId: 'local-1',
          uid: 'uid-1',
          title: 'mapped',
          notes: 'mapped',
          startTime: 100,
          endTime: 200,
          lastModified: 1000,
        ),
      );

      expect(action, SyncItemAction.deleteLocal);
    });

    test('plans skip for exchange-risk local-changed and remote-unchanged item', () {
      final action = decide(
        remote: {'etag': 'r1', 'is_exchange_risk': 1},
        mapping: {
          'remote_uid': 'uid-1',
          'is_exchange_risk': 1,
          'last_etag': 'r1',
          'summary': 'mapped',
          'description': 'mapped',
          'dtstart': 100,
          'dtend': 200,
          'last_mtime': 1000,
        },
        local: PlatformItem(
          localId: 'local-1',
          uid: 'uid-1',
          title: 'locally changed',
          notes: 'mapped',
          startTime: 100,
          endTime: 200,
          lastModified: 1001,
        ),
      );

      expect(action, SyncItemAction.skip);
    });

    test('plans updateLocal for exchange-risk remote-changed and local-unchanged item', () {
      final action = decide(
        remote: {'etag': 'r2', 'is_exchange_risk': true},
        mapping: {
          'remote_uid': 'uid-1',
          'is_exchange_risk': 1,
          'last_etag': 'r1',
          'summary': 'mapped',
          'description': 'mapped',
          'dtstart': 100,
          'dtend': 200,
          'last_mtime': 1000,
        },
        local: PlatformItem(
          localId: 'local-1',
          uid: 'uid-1',
          title: 'mapped',
          notes: 'mapped',
          startTime: 100,
          endTime: 200,
          lastModified: 1000,
        ),
      );

      expect(action, SyncItemAction.updateLocal);
    });

    test('plans updateLocal for exchange-risk conflict (both changed)', () {
      final action = decide(
        remote: {'etag': 'r2', 'is_exchange_risk': true},
        mapping: {
          'remote_uid': 'uid-1',
          'is_exchange_risk': true,
          'last_etag': 'r1',
          'summary': 'mapped',
          'description': 'mapped',
          'dtstart': 100,
          'dtend': 200,
          'last_mtime': 1000,
        },
        local: PlatformItem(
          localId: 'local-1',
          uid: 'uid-1',
          title: 'locally changed',
          notes: 'mapped',
          startTime: 100,
          endTime: 200,
          lastModified: 1001,
        ),
      );

      expect(action, SyncItemAction.updateLocal);
    });
  });
}

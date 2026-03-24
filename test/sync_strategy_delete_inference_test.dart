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
  group('SyncStrategy delete inference authority', () {
    final strategy = _TestSyncStrategy();
    final rules = UnifiedModeRules.forMode(UnifiedSyncMode.bidi);

    test('skips remote delete when local absence is not trusted', () {
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
}

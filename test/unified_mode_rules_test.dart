import 'package:caleesync/sync/SyncEnum.dart';
import 'package:caleesync/sync/strategy/SyncStrategy.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('UnifiedModeRules.forMode', () {
    test('pull mode only allows local mutations and skip', () {
      final rules = UnifiedModeRules.forMode(UnifiedSyncMode.pull);

      expect(
        rules.allowedActions,
        equals({
          SyncItemAction.createLocal,
          SyncItemAction.updateLocal,
          SyncItemAction.deleteLocal,
          SyncItemAction.skip,
        }),
      );
      expect(rules.onRemoteOnlyMapped, SyncItemAction.createLocal);
      expect(rules.onRemoteOnlyUnmapped, SyncItemAction.createLocal);
      expect(rules.onLocalOnlyMapped, SyncItemAction.deleteLocal);
      expect(rules.onLocalOnlyUnmapped, SyncItemAction.skip);
      expect(rules.onRemoteChanged, SyncItemAction.updateLocal);
      expect(rules.onLocalChanged, SyncItemAction.skip);
      expect(rules.onConflictLocalWins, SyncItemAction.updateLocal);
      expect(rules.onConflictRemoteWins, SyncItemAction.updateLocal);
    });

    test('push mode only allows remote mutations and skip', () {
      final rules = UnifiedModeRules.forMode(UnifiedSyncMode.push);

      expect(
        rules.allowedActions,
        equals({
          SyncItemAction.createRemote,
          SyncItemAction.updateRemote,
          SyncItemAction.deleteRemote,
          SyncItemAction.skip,
        }),
      );
      expect(rules.onRemoteOnlyMapped, SyncItemAction.deleteRemote);
      expect(rules.onRemoteOnlyUnmapped, SyncItemAction.skip);
      expect(rules.onLocalOnlyMapped, SyncItemAction.createRemote);
      expect(rules.onLocalOnlyUnmapped, SyncItemAction.createRemote);
      expect(rules.onRemoteChanged, SyncItemAction.skip);
      expect(rules.onLocalChanged, SyncItemAction.updateRemote);
      expect(rules.onConflictLocalWins, SyncItemAction.updateRemote);
      expect(rules.onConflictRemoteWins, SyncItemAction.updateRemote);
    });

    test('bidi mode allows local and remote mutations plus skip', () {
      final rules = UnifiedModeRules.forMode(UnifiedSyncMode.bidi);

      expect(
        rules.allowedActions,
        equals({
          SyncItemAction.createLocal,
          SyncItemAction.updateLocal,
          SyncItemAction.deleteLocal,
          SyncItemAction.createRemote,
          SyncItemAction.updateRemote,
          SyncItemAction.deleteRemote,
          SyncItemAction.skip,
        }),
      );
      expect(rules.onRemoteOnlyMapped, SyncItemAction.deleteRemote);
      expect(rules.onRemoteOnlyUnmapped, SyncItemAction.createLocal);
      expect(rules.onLocalOnlyMapped, SyncItemAction.deleteLocal);
      expect(rules.onLocalOnlyUnmapped, SyncItemAction.createRemote);
      expect(rules.onRemoteChanged, SyncItemAction.updateLocal);
      expect(rules.onLocalChanged, SyncItemAction.updateRemote);
      expect(rules.onConflictLocalWins, SyncItemAction.updateRemote);
      expect(rules.onConflictRemoteWins, SyncItemAction.updateLocal);
    });
  });
}

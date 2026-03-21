import 'package:caleesync/entity/SyncContext.dart';
import 'package:caleesync/sync/SyncEnum.dart';
import 'package:caleesync/sync/force_sync_registry.dart';
import 'package:caleesync/sync/sync_gate_reason.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('ForceSyncRegistry', () {
    test('tracks pending force-sync requests per collection id', () {
      ForceSyncRegistry.requestForceSyncForCollection(101);

      expect(ForceSyncRegistry.consumeForceSyncForCollection(101), isTrue);
      expect(ForceSyncRegistry.consumeForceSyncForCollection(101), isFalse);
    });

    test('ignores invalid collection ids', () {
      ForceSyncRegistry.requestForceSyncForCollection(0);
      ForceSyncRegistry.requestForceSyncForCollection(-10);

      expect(ForceSyncRegistry.consumeForceSyncForCollection(0), isFalse);
      expect(ForceSyncRegistry.consumeForceSyncForCollection(-10), isFalse);
    });

    test('deduplicates repeated requests for same collection id', () {
      ForceSyncRegistry.requestForceSyncForCollection(202);
      ForceSyncRegistry.requestForceSyncForCollection(202);

      expect(ForceSyncRegistry.consumeForceSyncForCollection(202), isTrue);
      expect(ForceSyncRegistry.consumeForceSyncForCollection(202), isFalse);
    });
  });

  group('SyncContext copyWith for calendar binding state', () {
    test('copyWith preserves values when fields are not overridden', () {
      final original = SyncContext(
        remoteCollectionId: 1,
        localCalendarId: 'local-1',
        remotePath: '/cal/1',
        accountName: 'user@example.com',
        displayName: 'Work',
        color: '#FF0000',
        syncMode: SyncBindingMode.twoWay,
        syncStatus: 1,
        action: SyncAction.fullSyncBidi,
        ctag: 'ctag-1',
        isSubscription: false,
        extra: const {'binding': 'ok'},
      );

      final copy = original.copyWith();

      expect(copy.remoteCollectionId, original.remoteCollectionId);
      expect(copy.localCalendarId, original.localCalendarId);
      expect(copy.remotePath, original.remotePath);
      expect(copy.accountName, original.accountName);
      expect(copy.displayName, original.displayName);
      expect(copy.color, original.color);
      expect(copy.syncMode, original.syncMode);
      expect(copy.syncStatus, original.syncStatus);
      expect(copy.action, original.action);
      expect(copy.ctag, original.ctag);
      expect(copy.isSubscription, original.isSubscription);
      expect(copy.extra, original.extra);
    });

    test('copyWith updates targeted binding fields only', () {
      final original = SyncContext(
        remoteCollectionId: 2,
        localCalendarId: 'local-2',
        remotePath: '/cal/2',
        accountName: 'user@example.com',
        displayName: 'Personal',
        color: '#00FF00',
        syncMode: SyncBindingMode.readOnly,
        action: SyncAction.fullSyncPull,
      );

      final copy = original.copyWith(
        localCalendarId: 'local-2b',
        syncMode: SyncBindingMode.twoWay,
        action: SyncAction.fullSyncBidi,
        extra: const {'relinked': true},
      );

      expect(copy.remoteCollectionId, original.remoteCollectionId);
      expect(copy.remotePath, original.remotePath);
      expect(copy.localCalendarId, 'local-2b');
      expect(copy.syncMode, SyncBindingMode.twoWay);
      expect(copy.action, SyncAction.fullSyncBidi);
      expect(copy.extra, const {'relinked': true});
    });
  });

  group('SyncGateReason deterministic set', () {
    test('contains critical calendar-binding reasons', () {
      expect(SyncGateReason.deterministicReasons.contains(SyncGateReason.bindingInvalid), isTrue);
      expect(SyncGateReason.deterministicReasons.contains(SyncGateReason.localCalendarMissing), isTrue);
      expect(SyncGateReason.deterministicReasons.contains(SyncGateReason.remoteCollectionMissing), isTrue);
      expect(SyncGateReason.deterministicReasons.contains(SyncGateReason.repairRequired), isTrue);
      expect(SyncGateReason.deterministicReasons.contains(SyncGateReason.authInvalid), isTrue);
      expect(SyncGateReason.deterministicReasons.contains(SyncGateReason.environmentBlocked), isTrue);
      expect(SyncGateReason.deterministicReasons.contains(SyncGateReason.subscriptionReadonlyViolation), isTrue);
      expect(SyncGateReason.deterministicReasons.contains(SyncGateReason.safeFirstSync), isTrue);
    });
  });
}

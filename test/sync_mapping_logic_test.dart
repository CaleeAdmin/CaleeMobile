import 'package:caleesync/entity/sync_run_record.dart';
import 'package:caleesync/sync/SyncEnum.dart';
import 'package:caleesync/sync/sync_run_recorder.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('mapSyncErrorCode', () {
    test('maps network related errors', () {
      expect(mapSyncErrorCode('Socket timeout on network layer'), SyncErrorCode.networkUnavailable);
    });

    test('maps auth related errors', () {
      expect(mapSyncErrorCode('HTTP 401 unauthorized'), SyncErrorCode.authExpired);
      expect(mapSyncErrorCode('auth token expired'), SyncErrorCode.authExpired);
    });

    test('maps calendar missing errors', () {
      expect(mapSyncErrorCode('404 calendar not found'), SyncErrorCode.remoteCalendarMissing);
    });

    test('maps permission errors', () {
      expect(mapSyncErrorCode('permission denied by provider'), SyncErrorCode.permissionDenied);
    });

    test('maps parse and server response errors', () {
      expect(mapSyncErrorCode('xml parse error'), SyncErrorCode.parseOrServerResponse);
      expect(mapSyncErrorCode('unexpected status code 500'), SyncErrorCode.parseOrServerResponse);
    });

    test('maps db mapping conflict errors', () {
      expect(mapSyncErrorCode('sqlite constraint failed'), SyncErrorCode.dbOrMappingConflict);
      expect(mapSyncErrorCode('mapping conflict detected'), SyncErrorCode.dbOrMappingConflict);
    });

    test('maps local provider errors', () {
      expect(mapSyncErrorCode('provider bridge unavailable'), SyncErrorCode.localProviderFailure);
    });

    test('falls back to unknown for unmatched errors', () {
      expect(mapSyncErrorCode('something unrelated happened'), SyncErrorCode.unknown);
    });
  });

  group('mapRunModeFromAction', () {
    test('maps action to expected run mode', () {
      expect(mapRunModeFromAction(SyncAction.fullSyncPull), SyncRunMode.pull);
      expect(mapRunModeFromAction(SyncAction.fullSyncPush), SyncRunMode.push);
      expect(mapRunModeFromAction(SyncAction.fullSyncBidi), SyncRunMode.twoWay);
    });
  });
}

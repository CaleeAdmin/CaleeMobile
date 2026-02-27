import 'package:caleesync/sync/sync_gate_reason.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('SyncGateReason.toUiMessage', () {
    test('returns expected mapped message for deterministic reason', () {
      expect(
        SyncGateReason.toUiMessage(SyncGateReason.authInvalid),
        'Authentication invalid. Sign in again to resume.',
      );
    });

    test('returns formatted fallback for unknown reason', () {
      expect(
        SyncGateReason.toUiMessage('network_congested'),
        'Sync paused (network congested).',
      );
    });

    test('returns null for null and empty reason', () {
      expect(SyncGateReason.toUiMessage(null), isNull);
      expect(SyncGateReason.toUiMessage(''), isNull);
    });
  });
}

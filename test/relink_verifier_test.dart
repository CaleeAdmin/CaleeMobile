import 'package:caleesync/core/platform/pigeon/calendar_api.g.dart';
import 'package:caleesync/services/calee_server_service.dart';
import 'package:caleesync/sync/relink_verifier.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('RelinkVerifier.verify', () {
    test('returns indeterminate when both remote and local snapshots are empty', () async {
      final verifier = RelinkVerifier(
        fetchRemoteSnapshot: (_, __) async => const UnifiedEventsSnapshot(
          events: <Map<String, dynamic>>[],
          statusCode: 200,
          fetchSucceeded: true,
          parseProducedZeroEvents: true,
        ),
        fetchLocalEvents: (_, __, ___) async => <PlatformItem?>[],
      );

      final result = await verifier.verify(
        remotePath: '/users/demo/calendar/',
        localCalendarId: 'local-1',
      );

      expect(result.outcome, RelinkVerificationOutcome.unavailable);
      expect(result.passed, isFalse);
      expect(result.confidenceScore, isNull);
      expect(result.isIndeterminate, isTrue);
    });

    test('passes when there is a clear event match', () async {
      final verifier = RelinkVerifier(
        fetchRemoteSnapshot: (_, __) async => UnifiedEventsSnapshot(
          events: <Map<String, dynamic>>[
            {
              'summary': 'Project Kickoff',
              'dtstart': DateTime.utc(2025, 1, 2, 9).millisecondsSinceEpoch,
              'dtend': DateTime.utc(2025, 1, 2, 10).millisecondsSinceEpoch,
            },
          ],
          statusCode: 200,
          fetchSucceeded: true,
          parseProducedZeroEvents: false,
        ),
        fetchLocalEvents: (_, __, ___) async => <PlatformItem?>[
          PlatformItem(
            title: 'Project Kickoff',
            startTime: DateTime.utc(2025, 1, 2, 9).millisecondsSinceEpoch,
            endTime: DateTime.utc(2025, 1, 2, 10).millisecondsSinceEpoch,
          ),
        ],
      );

      final result = await verifier.verify(
        remotePath: '/users/demo/calendar/',
        localCalendarId: 'local-2',
      );

      expect(result.outcome, RelinkVerificationOutcome.passed);
      expect(result.passed, isTrue);
      expect(result.isIndeterminate, isFalse);
      expect(result.confidenceScore, 100);
    });

    test('uses subscription fetch mode when verifying subscription relink', () async {
      bool? capturedIsSubscription;
      final verifier = RelinkVerifier(
        fetchRemoteSnapshot: (_, isSubscription) async {
          capturedIsSubscription = isSubscription;
          return UnifiedEventsSnapshot(
            events: <Map<String, dynamic>>[
              {
                'summary': 'Subscription Event',
                'dtstart': DateTime.utc(2025, 1, 2, 9).millisecondsSinceEpoch,
                'dtend': DateTime.utc(2025, 1, 2, 10).millisecondsSinceEpoch,
              },
            ],
            statusCode: 200,
            fetchSucceeded: true,
            parseProducedZeroEvents: false,
          );
        },
        fetchLocalEvents: (_, __, ___) async => <PlatformItem?>[
          PlatformItem(
            title: 'Subscription Event',
            startTime: DateTime.utc(2025, 1, 2, 9).millisecondsSinceEpoch,
            endTime: DateTime.utc(2025, 1, 2, 10).millisecondsSinceEpoch,
          ),
        ],
      );

      final result = await verifier.verify(
        remotePath: '/users/demo/calendar/',
        localCalendarId: 'local-sub',
        isSubscription: true,
      );

      expect(capturedIsSubscription, isTrue);
      expect(result.outcome, RelinkVerificationOutcome.passed);
      expect(result.passed, isTrue);
    });


    test('returns unavailable when local sample is empty even if remote has events', () async {
      final verifier = RelinkVerifier(
        fetchRemoteSnapshot: (_, __) async => UnifiedEventsSnapshot(
          events: <Map<String, dynamic>>[
            {
              'summary': 'Remote-only event',
              'dtstart': DateTime.utc(2025, 1, 2, 9).millisecondsSinceEpoch,
            },
          ],
          statusCode: 200,
          fetchSucceeded: true,
          parseProducedZeroEvents: false,
        ),
        fetchLocalEvents: (_, __, ___) async => <PlatformItem?>[],
      );

      final result = await verifier.verify(
        remotePath: '/users/demo/calendar/',
        localCalendarId: 'local-empty',
      );

      expect(result.outcome, RelinkVerificationOutcome.unavailable);
      expect(result.confidenceScore, isNull);
    });

    test('returns failed with low confidence when there is comparable mismatch evidence', () async {
      final verifier = RelinkVerifier(
        fetchRemoteSnapshot: (_, __) async => UnifiedEventsSnapshot(
          events: List<Map<String, dynamic>>.generate(6, (idx) {
            final start = DateTime.utc(2025, 1, idx + 1, 9).millisecondsSinceEpoch;
            return {
              'summary': 'Remote Event $idx',
              'dtstart': start,
              'dtend': start + const Duration(hours: 1).inMilliseconds,
            };
          }),
          statusCode: 200,
          fetchSucceeded: true,
          parseProducedZeroEvents: false,
        ),
        fetchLocalEvents: (_, __, ___) async => List<PlatformItem?>.generate(6, (idx) {
          final start = DateTime.utc(2025, 2, idx + 1, 13).millisecondsSinceEpoch;
          return PlatformItem(
            title: 'Different Local $idx',
            startTime: start,
            endTime: start + const Duration(hours: 2).inMilliseconds,
          );
        }),
      );

      final result = await verifier.verify(
        remotePath: '/users/demo/calendar/',
        localCalendarId: 'local-mismatch',
      );

      expect(result.outcome, RelinkVerificationOutcome.failed);
      expect(result.confidenceScore, isNotNull);
      expect(result.confidenceScore!, lessThan(50));
      expect(result.passed, isFalse);
    });
  });
}


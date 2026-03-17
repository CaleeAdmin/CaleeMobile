import 'package:caleesync/core/platform/pigeon/calendar_api.g.dart';
import 'package:caleesync/services/calee_server_service.dart';
import 'package:caleesync/sync/relink_verifier.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  int _epochFromNow({int days = 0, int hours = 0}) {
    return DateTime.now().toUtc().add(Duration(days: days, hours: hours)).millisecondsSinceEpoch;
  }

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
      final int start = _epochFromNow(days: 2);
      final verifier = RelinkVerifier(
        fetchRemoteSnapshot: (_, __) async => UnifiedEventsSnapshot(
          events: <Map<String, dynamic>>[
            {
              'summary': 'Project Kickoff',
              'dtstart': start,
              'dtend': start + const Duration(hours: 1).inMilliseconds,
            },
          ],
          statusCode: 200,
          fetchSucceeded: true,
          parseProducedZeroEvents: false,
        ),
        fetchLocalEvents: (_, __, ___) async => <PlatformItem?>[
          PlatformItem(
            title: 'Project Kickoff',
            startTime: start,
            endTime: start + const Duration(hours: 1).inMilliseconds,
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
      final int start = _epochFromNow(days: 3);
      final verifier = RelinkVerifier(
        fetchRemoteSnapshot: (_, isSubscription) async {
          capturedIsSubscription = isSubscription;
          return UnifiedEventsSnapshot(
            events: <Map<String, dynamic>>[
              {
                'summary': 'Subscription Event',
                'dtstart': start,
                'dtend': start + const Duration(hours: 1).inMilliseconds,
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
            startTime: start,
            endTime: start + const Duration(hours: 1).inMilliseconds,
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
              'dtstart': _epochFromNow(days: 4),
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
            final start = _epochFromNow(days: idx + 1, hours: 9);
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
          final start = _epochFromNow(days: idx + 10, hours: 13);
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

    test('filters remote events to same bounded window used for local fetch', () async {
      int? capturedStartMs;
      int? capturedEndMs;
      final int outsidePast = _epochFromNow(days: -120);
      final int insideFuture = _epochFromNow(days: 20);
      final verifier = RelinkVerifier(
        fetchRemoteSnapshot: (_, __) async => UnifiedEventsSnapshot(
          events: <Map<String, dynamic>>[
            {
              'summary': 'Old Event',
              'dtstart': outsidePast,
              'dtend': outsidePast + const Duration(hours: 1).inMilliseconds,
            },
            {
              'summary': 'Upcoming Event',
              'dtstart': insideFuture,
              'dtend': insideFuture + const Duration(hours: 1).inMilliseconds,
            },
          ],
          statusCode: 200,
          fetchSucceeded: true,
          parseProducedZeroEvents: false,
        ),
        fetchLocalEvents: (_, startMs, endMs) async {
          capturedStartMs = startMs;
          capturedEndMs = endMs;
          return <PlatformItem?>[
            PlatformItem(
              title: 'Upcoming Event',
              startTime: insideFuture,
              endTime: insideFuture + const Duration(hours: 1).inMilliseconds,
            ),
          ];
        },
      );

      final result = await verifier.verify(
        remotePath: '/users/demo/calendar/',
        localCalendarId: 'local-window',
      );

      expect(capturedStartMs, isNotNull);
      expect(capturedEndMs, isNotNull);
      expect(capturedEndMs!, greaterThan(DateTime.now().toUtc().millisecondsSinceEpoch));
      expect(result.outcome, RelinkVerificationOutcome.passed);
      expect(result.confidenceScore, 100);
    });

    test('subscription and non-subscription follow same verification window scope', () async {
      final int insideFuture = _epochFromNow(days: 15);
      Future<UnifiedEventsSnapshot> remote(_, __) async => UnifiedEventsSnapshot(
            events: <Map<String, dynamic>>[
              {
                'summary': 'Window Scoped Event',
                'dtstart': insideFuture,
                'dtend': insideFuture + const Duration(hours: 1).inMilliseconds,
              },
            ],
            statusCode: 200,
            fetchSucceeded: true,
            parseProducedZeroEvents: false,
          );

      Future<List<PlatformItem?>> local(_, __, ___) async => <PlatformItem?>[
            PlatformItem(
              title: 'Window Scoped Event',
              startTime: insideFuture,
              endTime: insideFuture + const Duration(hours: 1).inMilliseconds,
            ),
          ];

      final normalVerifier = RelinkVerifier(fetchRemoteSnapshot: remote, fetchLocalEvents: local);
      final subscriptionVerifier = RelinkVerifier(fetchRemoteSnapshot: remote, fetchLocalEvents: local);

      final normalResult = await normalVerifier.verify(
        remotePath: '/users/demo/calendar/',
        localCalendarId: 'local-normal',
        isSubscription: false,
      );
      final subscriptionResult = await subscriptionVerifier.verify(
        remotePath: '/users/demo/calendar/',
        localCalendarId: 'local-subscription',
        isSubscription: true,
      );

      expect(normalResult.outcome, RelinkVerificationOutcome.passed);
      expect(subscriptionResult.outcome, RelinkVerificationOutcome.passed);
      expect(normalResult.confidenceScore, subscriptionResult.confidenceScore);
    });
  });
}

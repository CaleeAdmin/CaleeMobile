import 'package:flutter_test/flutter_test.dart';

import 'package:calee_mobile/data/models/account_deletion_status.dart';

/// A complete projection, exactly the nine fields
/// `account_deletion_status_fields()` allows.
Map<String, dynamic> projection({
  String state = 'requested',
  bool isTerminal = false,
  bool restorable = true,
  Object? reasonCode,
  Object? completedAt,
  Object? restoredAt,
  Object? requestedAt = '2026-09-01T02:03:04.123456Z',
}) {
  return <String, dynamic>{
    'operationId': 'op_01HZY',
    'state': state,
    'isTerminal': isTerminal,
    'reasonCode': reasonCode,
    'restorable': restorable,
    'requestedAt': requestedAt,
    'completedAt': completedAt,
    'restoredAt': restoredAt,
    'completionWindowMessage':
        'Your deletion request has been received and is being processed.',
  };
}

void main() {
  group('AccountDeletionStatus.fromJson', () {
    test('parses every field of the bounded projection', () {
      final status = AccountDeletionStatus.fromJson(
        projection(
          state: 'completed',
          isTerminal: true,
          restorable: false,
          reasonCode: 'VERIFICATION_FAILED',
          completedAt: '2026-09-02T05:06:07.000000Z',
          restoredAt: '2026-09-03T08:09:10.000000Z',
        ),
      );

      expect(status.operationId, 'op_01HZY');
      expect(status.state, 'completed');
      expect(status.isTerminal, isTrue);
      expect(status.restorable, isFalse);
      expect(status.reasonCode, 'VERIFICATION_FAILED');
      expect(status.requestedAt, DateTime.utc(2026, 9, 1, 2, 3, 4, 123, 456));
      expect(status.completedAt, DateTime.utc(2026, 9, 2, 5, 6, 7));
      expect(status.restoredAt, DateTime.utc(2026, 9, 3, 8, 9, 10));
      expect(
        status.completionWindowMessage,
        'Your deletion request has been received and is being processed.',
      );
    });

    test('renders the Hub completion-window message, never a numeric SLA', () {
      final status = AccountDeletionStatus.fromJson(projection());

      // The Hub deliberately publishes no numeric window: calee-hub-core #458
      // has not timed real end-to-end operations, so no figure has been earned.
      expect(status.completionWindowMessage, isNot(contains('24')));
      expect(status.completionWindowMessage, isNot(contains('hour')));
      expect(status.completionWindowMessage, isNot(contains('day')));
    });

    test('handles null timestamps and a null reason code', () {
      final status = AccountDeletionStatus.fromJson(projection());

      expect(status.reasonCode, isNull);
      expect(status.completedAt, isNull);
      expect(status.restoredAt, isNull);
      expect(status.requestedAt, isNotNull);
    });

    test('an unparseable timestamp becomes null, not a parse failure', () {
      // The state string decides what happened; a date this build cannot read
      // must not cost the customer the whole status screen.
      final status = AccountDeletionStatus.fromJson(
        projection(requestedAt: 'not-a-date', completedAt: 42),
      );

      expect(status.requestedAt, isNull);
      expect(status.completedAt, isNull);
      expect(status.state, 'requested');
    });

    test('an absent completion-window message becomes null', () {
      final json = projection()..remove('completionWindowMessage');

      expect(
        AccountDeletionStatus.fromJson(json).completionWindowMessage,
        isNull,
      );
    });
  });

  group('lifecycle semantics', () {
    test('completed is the only state read as completed', () {
      final status = AccountDeletionStatus.fromJson(
        projection(
          state: 'completed',
          isTerminal: true,
          restorable: false,
          completedAt: '2026-09-02T05:06:07.000000Z',
        ),
      );

      expect(status.isCompleted, isTrue);
      expect(status.isRestored, isFalse);
      expect(status.isProcessing, isFalse);
      expect(status.isUnrecognisedState, isFalse);
      expect(status.knownState, AccountDeletionState.completed);
    });

    test('restored is terminal and is NOT completion', () {
      final status = AccountDeletionStatus.fromJson(
        projection(
          state: 'restored',
          isTerminal: true,
          restorable: false,
          restoredAt: '2026-09-03T08:09:10.000000Z',
        ),
      );

      expect(status.isRestored, isTrue);
      expect(
        status.isCompleted,
        isFalse,
        reason: 'restored means the deletion did NOT happen',
      );
      expect(status.isTerminal, isTrue);
      expect(status.isProcessing, isFalse);
    });

    test('isTerminal alone never means success', () {
      for (final state in ['completed', 'restored']) {
        final status = AccountDeletionStatus.fromJson(
          projection(state: state, isTerminal: true, restorable: false),
        );
        expect(status.isTerminal, isTrue);
        expect(status.isCompleted, state == 'completed');
      }
    });

    test('no nonterminal state is ever read as success', () {
      const nonterminal = [
        'requested',
        'quiescing',
        'deleting',
        'failed_retryable',
        'support_required',
      ];

      for (final state in nonterminal) {
        final status = AccountDeletionStatus.fromJson(projection(state: state));

        expect(status.isCompleted, isFalse, reason: state);
        expect(status.isRestored, isFalse, reason: state);
        expect(status.isProcessing, isTrue, reason: state);
        expect(status.isUnrecognisedState, isFalse, reason: state);
      }
    });

    test('support_required is recognised and still not an ending', () {
      final status = AccountDeletionStatus.fromJson(
        projection(state: 'support_required'),
      );

      expect(status.requiresSupport, isTrue);
      expect(status.isCompleted, isFalse);
      expect(status.isTerminal, isFalse);
    });

    test('an unknown future state can never become success', () {
      final status = AccountDeletionStatus.fromJson(
        projection(state: 'transcended_v2'),
      );

      expect(status.state, 'transcended_v2');
      expect(status.knownState, isNull);
      expect(status.isUnrecognisedState, isTrue);
      expect(status.isCompleted, isFalse);
      expect(status.isRestored, isFalse);
      expect(
        status.isProcessing,
        isFalse,
        reason: 'this build cannot claim to know what an unseen state is doing',
      );
    });

    test('an unknown state flagged terminal is still not success', () {
      // The dangerous shape: a future terminal state, seen by an old build.
      final status = AccountDeletionStatus.fromJson(
        projection(
          state: 'abandoned',
          isTerminal: true,
          restorable: false,
          completedAt: '2026-09-02T05:06:07.000000Z',
        ),
      );

      expect(status.isTerminal, isTrue);
      expect(status.isCompleted, isFalse);
      expect(status.isRestored, isFalse);
      expect(status.isUnrecognisedState, isTrue);
    });

    test('the wire vocabulary matches the Hub state machine', () {
      expect(AccountDeletionState.values.map((s) => s.wireName).toSet(), {
        'requested',
        'quiescing',
        'deleting',
        'failed_retryable',
        'support_required',
        'completed',
        'restored',
      });
      expect(AccountDeletionState.values.where((s) => s.isTerminal).toSet(), {
        AccountDeletionState.completed,
        AccountDeletionState.restored,
      });
    });
  });

  group('malformed required fields fail safely', () {
    test('a missing operationId is a parse failure', () {
      final json = projection()..remove('operationId');
      expect(
        () => AccountDeletionStatus.fromJson(json),
        throwsA(isA<FormatException>()),
      );
    });

    test('a missing or blank state is a parse failure', () {
      for (final bad in <Object?>[null, '', '   ', 7]) {
        final json = projection()..['state'] = bad;
        expect(
          () => AccountDeletionStatus.fromJson(json),
          throwsA(isA<FormatException>()),
          reason: 'state=$bad',
        );
      }
    });

    test('a non-boolean isTerminal or restorable is a parse failure', () {
      for (final key in ['isTerminal', 'restorable']) {
        final json = projection()..[key] = 'true';
        expect(
          () => AccountDeletionStatus.fromJson(json),
          throwsA(isA<FormatException>()),
          reason: key,
        );
      }
    });

    test('an empty body never constructs a completed-looking status', () {
      expect(
        () => AccountDeletionStatus.fromJson(<String, dynamic>{}),
        throwsA(isA<FormatException>()),
      );
    });
  });

  group('AccountDeletionRequestResult.fromJson', () {
    test('parses the status projection alongside the two request booleans', () {
      final result = AccountDeletionRequestResult.fromJson(
        projection()
          ..['created'] = true
          ..['recoveryCredentialMatched'] = true,
      );

      expect(result.created, isTrue);
      expect(result.recoveryCredentialMatched, isTrue);
      expect(result.status.state, 'requested');
      expect(result.status.operationId, 'op_01HZY');
    });

    test('a replay reports created: false without being a second deletion', () {
      final result = AccountDeletionRequestResult.fromJson(
        projection()
          ..['created'] = false
          ..['recoveryCredentialMatched'] = true,
      );

      expect(result.created, isFalse);
      expect(result.status.operationId, 'op_01HZY');
    });

    test('unmatched recovery material is reported, not hidden', () {
      final result = AccountDeletionRequestResult.fromJson(
        projection()
          ..['created'] = false
          ..['recoveryCredentialMatched'] = false,
      );

      expect(result.recoveryCredentialMatched, isFalse);
    });

    test('a body missing either boolean is a parse failure', () {
      for (final key in ['created', 'recoveryCredentialMatched']) {
        final json = projection()
          ..['created'] = true
          ..['recoveryCredentialMatched'] = true
          ..remove(key);

        expect(
          () => AccountDeletionRequestResult.fromJson(json),
          throwsA(isA<FormatException>()),
          reason: key,
        );
      }
    });
  });

  test('toString carries no field outside the bounded projection', () {
    final rendered = AccountDeletionStatus.fromJson(projection()).toString();

    expect(rendered, contains('op_01HZY'));
    expect(rendered, contains('requested'));
    expect(rendered, isNot(contains('@')));
  });
}

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:calee_mobile/data/account_deletion/account_deletion_failure.dart';
import 'package:calee_mobile/data/api/calee_hub_client.dart';

CaleeHubException hubError(int statusCode, String? code) =>
    CaleeHubException(statusCode: statusCode, code: code, message: 'refused');

void main() {
  group('AccountDeletionRequestFailure classification', () {
    test('maps every stable Hub code from the deletion request route', () {
      const expected = <(int, String), AccountDeletionRequestFailureKind>{
        (400, 'DELETION_CONFIRMATION_REQUIRED'):
            AccountDeletionRequestFailureKind.confirmationRejected,
        (400, 'DELETION_RECOVERY_MATERIAL_INVALID'):
            AccountDeletionRequestFailureKind.recoveryMaterialRejected,
        (409, 'DELETION_RECOVERY_MATERIAL_CONFLICT'):
            AccountDeletionRequestFailureKind.recoveryMaterialConflict,
        (401, 'DELETION_REAUTH_REQUIRED'):
            AccountDeletionRequestFailureKind.reauthenticationRequired,
        (409, 'DELETION_REAUTH_UNSUPPORTED'):
            AccountDeletionRequestFailureKind.reauthenticationUnsupported,
        (409, 'MANAGED_ACCOUNT_OFFBOARDING_REQUIRED'):
            AccountDeletionRequestFailureKind.managedAccount,
        (503, 'DELETION_UNAVAILABLE'):
            AccountDeletionRequestFailureKind.temporarilyUnavailable,
        (401, 'UNAUTHORIZED'): AccountDeletionRequestFailureKind.unauthorized,
        (500, 'UNKNOWN_ERROR'):
            AccountDeletionRequestFailureKind.outcomeUnknown,
      };

      expected.forEach((wire, kind) {
        final failure = AccountDeletionRequestFailure.fromError(
          hubError(wire.$1, wire.$2),
        );
        expect(failure.kind, kind, reason: wire.$2);
        expect(failure.statusCode, wire.$1, reason: wire.$2);
        expect(failure.code, wire.$2, reason: wire.$2);
      });
    });

    test('a transport failure is an UNKNOWN outcome', () {
      for (final code in ['TIMEOUT', 'NETWORK_ERROR']) {
        final failure = AccountDeletionRequestFailure.fromError(
          hubError(0, code),
        );

        expect(failure.kind, AccountDeletionRequestFailureKind.outcomeUnknown);
        expect(
          failure.isPreAcceptance,
          isFalse,
          reason: 'the Hub may have committed before the answer was lost',
        );
      }
    });

    test('a dropped connection classifies rather than escaping', () {
      // dart:io raises this directly when a response is cut off, so it never
      // becomes a CaleeHubException -- and it is exactly the lost-response case.
      final failure = AccountDeletionRequestFailure.fromError(
        const HttpException(
          'Connection closed before full header was received',
        ),
      );

      expect(failure.kind, AccountDeletionRequestFailureKind.outcomeUnknown);
      expect(failure.isPreAcceptance, isFalse);
      expect(failure.isRetryableWithSameCredential, isTrue);
    });

    test('a malformed 2xx body is an UNKNOWN outcome', () {
      final failure = AccountDeletionRequestFailure.fromError(
        hubError(0, 'DELETION_RESPONSE_MALFORMED'),
      );

      expect(failure.kind, AccountDeletionRequestFailureKind.outcomeUnknown);
      expect(failure.isPreAcceptance, isFalse);
    });

    test('an unrecognised future code is an UNKNOWN outcome', () {
      final failure = AccountDeletionRequestFailure.fromError(
        hubError(418, 'DELETION_SOMETHING_NEW'),
      );

      expect(failure.kind, AccountDeletionRequestFailureKind.outcomeUnknown);
      expect(failure.isPreAcceptance, isFalse);
    });
  });

  group('what a failure permits', () {
    test('only proven pre-acceptance refusals report nothing was created', () {
      const preAcceptance = {
        AccountDeletionRequestFailureKind.confirmationRejected,
        AccountDeletionRequestFailureKind.recoveryMaterialRejected,
        AccountDeletionRequestFailureKind.recoveryMaterialConflict,
        AccountDeletionRequestFailureKind.reauthenticationRequired,
        AccountDeletionRequestFailureKind.reauthenticationUnsupported,
        AccountDeletionRequestFailureKind.managedAccount,
        AccountDeletionRequestFailureKind.unauthorized,
      };

      for (final kind in AccountDeletionRequestFailureKind.values) {
        final failure = AccountDeletionRequestFailure(
          kind: kind,
          statusCode: 0,
        );
        expect(
          failure.isPreAcceptance,
          preAcceptance.contains(kind),
          reason: '$kind',
        );
      }
    });

    test('503 is NOT treated as proof that nothing was created', () {
      // A lock-wait timeout and an unresolved operation conflict both arise on
      // the insert path, so "the Hub said 503" is not evidence of absence.
      final failure = AccountDeletionRequestFailure.fromError(
        hubError(503, 'DELETION_UNAVAILABLE'),
      );

      expect(failure.isPreAcceptance, isFalse);
      expect(failure.isRetryableWithSameCredential, isTrue);
    });

    test('only a recovery-id conflict calls for fresh material', () {
      for (final kind in AccountDeletionRequestFailureKind.values) {
        final failure = AccountDeletionRequestFailure(
          kind: kind,
          statusCode: 0,
        );
        expect(
          failure.requiresFreshRecoveryMaterial,
          kind == AccountDeletionRequestFailureKind.recoveryMaterialConflict,
          reason: '$kind',
        );
      }
    });

    test('an unknown outcome is retryable with the SAME credential', () {
      // Never "retry by generating another credential": that is how a customer
      // ends up with two operations and a credential for neither.
      final failure = AccountDeletionRequestFailure.fromError(
        hubError(0, 'TIMEOUT'),
      );

      expect(failure.isRetryableWithSameCredential, isTrue);
      expect(failure.requiresFreshRecoveryMaterial, isFalse);
    });

    test('a re-auth failure is not retryable without new input', () {
      final failure = AccountDeletionRequestFailure.fromError(
        hubError(401, 'DELETION_REAUTH_REQUIRED'),
      );

      expect(failure.isPreAcceptance, isTrue);
      expect(failure.isRetryableWithSameCredential, isFalse);
    });

    test('toString carries no customer data', () {
      final rendered = AccountDeletionRequestFailure.fromError(
        const CaleeHubException(
          statusCode: 401,
          code: 'DELETION_REAUTH_REQUIRED',
          message: 'Confirm your password to continue with account deletion.',
          requestId: 'req_123',
        ),
      ).toString();

      expect(rendered, contains('DELETION_REAUTH_REQUIRED'));
      expect(rendered, contains('req_123'));
      expect(rendered, isNot(contains('password')));
    });
  });

  group('AccountDeletionStatusFailure classification', () {
    test('404 is the one answer for malformed, unknown and wrong material', () {
      final failure = AccountDeletionStatusFailure.fromError(
        hubError(404, 'DELETION_OPERATION_NOT_FOUND'),
      );

      expect(failure.kind, AccountDeletionStatusFailureKind.notFound);
      expect(failure.statusCode, 404);
    });

    test('anything else is simply a read to try again', () {
      for (final error in <Object>[
        hubError(500, 'UNKNOWN_ERROR'),
        hubError(0, 'TIMEOUT'),
        hubError(0, 'DELETION_STATUS_MALFORMED'),
        const HttpException('Connection closed'),
      ]) {
        expect(
          AccountDeletionStatusFailure.fromError(error).kind,
          AccountDeletionStatusFailureKind.unavailable,
          reason: '$error',
        );
      }
    });
  });
}

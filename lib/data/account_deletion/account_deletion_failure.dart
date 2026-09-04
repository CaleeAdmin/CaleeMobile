import '../api/calee_hub_client.dart';

/// Classification of Hub answers to the two Account Deletion V1 routes (#556).
///
/// The Hub's public error codes ARE the client contract -- see the mapping in
/// `calee-hub-core@c520740795205a32117d9ba047f88b0ff557aeb6`,
/// `public/lib/routes_client_api_account_deletion.php`, whose own comment says
/// CaleeMobile#556 branches on them. This file is that branch, written once, so
/// the controller and UI slice never re-derives it from a status code.
///
/// THE PROPERTY THAT MATTERS is [AccountDeletionRequestFailure.isPreAcceptance]:
/// whether the Hub is known to have refused BEFORE committing an operation. Only
/// then is it true that nothing was created. Everything else -- a 503, a 500, a
/// timeout, a closed socket, a killed app -- leaves the outcome UNKNOWN, and an
/// unknown outcome must be resolved by reading the deletion-only status
/// endpoint with the stored credential, never by minting a second credential
/// and never by discarding the first.

/// What the Hub said about `POST /client/v1/account-deletions`.
enum AccountDeletionRequestFailureKind {
  /// 400 `DELETION_CONFIRMATION_REQUIRED`. The exact phrase was missing or
  /// wrong. This client sends it verbatim, so in practice this means a contract
  /// drift rather than customer input.
  confirmationRejected,

  /// 400 `DELETION_RECOVERY_MATERIAL_INVALID`. The minted material did not
  /// satisfy the Hub's format rules.
  recoveryMaterialRejected,

  /// 409 `DELETION_RECOVERY_MATERIAL_CONFLICT`. The recovery id already names
  /// an operation belonging to a DIFFERENT account, so it was refused outright
  /// rather than reused. This is the ONE case where fresh material is the
  /// correct remedy -- see [requiresFreshRecoveryMaterial].
  recoveryMaterialConflict,

  /// 401 `DELETION_REAUTH_REQUIRED`. The password was absent, wrong, or too old
  /// to authorise something irreversible. The Hub answers all three identically
  /// on purpose, so this client must not claim to know which.
  reauthenticationRequired,

  /// 409 `DELETION_REAUTH_UNSUPPORTED`. This account cannot re-authenticate in
  /// the app at all; the customer needs support.
  reauthenticationUnsupported,

  /// 409 `MANAGED_ACCOUNT_OFFBOARDING_REQUIRED`. An organisation owns this
  /// account's lifecycle; self-service deletion is the wrong path.
  managedAccount,

  /// 401 with any other code (`UNAUTHORIZED`). The bearer token, not the
  /// password, was refused.
  unauthorized,

  /// 503 `DELETION_UNAVAILABLE`. Retryable, and the Hub means it: the request
  /// endpoint is idempotent, so retrying with the SAME credential either
  /// creates the operation or recovers the one that now exists.
  temporarilyUnavailable,

  /// Everything else: 500, a malformed 2xx body, a timeout, a dropped socket.
  ///
  /// THE OUTCOME IS UNKNOWN. The operation may be durably committed. This is
  /// the case the whole recovery contract exists for.
  outcomeUnknown,
}

/// A classified failure of the deletion REQUEST route.
class AccountDeletionRequestFailure {
  const AccountDeletionRequestFailure({
    required this.kind,
    required this.statusCode,
    this.code,
    this.requestId,
  });

  /// Classifies anything thrown by [CaleeHubClient.requestAccountDeletion].
  ///
  /// Takes `Object`, not [CaleeHubException], deliberately. The client wraps
  /// timeouts and socket failures, but a connection dropped mid-response
  /// surfaces as a raw `HttpException` from `dart:io` -- and that is precisely
  /// the lost-response case, so it must classify, not crash.
  ///
  /// Unrecognised codes and unrecognised error types both fall through to
  /// [AccountDeletionRequestFailureKind.outcomeUnknown], which is the fail-safe
  /// direction: something this build has never seen must never be assumed to
  /// mean "nothing happened".
  factory AccountDeletionRequestFailure.fromError(Object error) {
    if (error is! CaleeHubException) {
      return const AccountDeletionRequestFailure(
        kind: AccountDeletionRequestFailureKind.outcomeUnknown,
        statusCode: 0,
      );
    }
    return AccountDeletionRequestFailure(
      kind: _kindFor(error),
      statusCode: error.statusCode,
      code: error.code,
      requestId: error.requestId,
    );
  }

  final AccountDeletionRequestFailureKind kind;

  /// 0 for a transport failure that never reached the Hub, or never got an
  /// answer back from it.
  final int statusCode;

  /// The Hub's stable public error code, when it sent one.
  final String? code;

  /// The Hub's request id, for support. Never contains customer data.
  final String? requestId;

  static AccountDeletionRequestFailureKind _kindFor(CaleeHubException error) {
    switch (error.code) {
      case 'DELETION_CONFIRMATION_REQUIRED':
        return AccountDeletionRequestFailureKind.confirmationRejected;
      case 'DELETION_RECOVERY_MATERIAL_INVALID':
        return AccountDeletionRequestFailureKind.recoveryMaterialRejected;
      case 'DELETION_RECOVERY_MATERIAL_CONFLICT':
        return AccountDeletionRequestFailureKind.recoveryMaterialConflict;
      case 'DELETION_REAUTH_REQUIRED':
        return AccountDeletionRequestFailureKind.reauthenticationRequired;
      case 'DELETION_REAUTH_UNSUPPORTED':
        return AccountDeletionRequestFailureKind.reauthenticationUnsupported;
      case 'MANAGED_ACCOUNT_OFFBOARDING_REQUIRED':
        return AccountDeletionRequestFailureKind.managedAccount;
      case 'DELETION_UNAVAILABLE':
        return AccountDeletionRequestFailureKind.temporarilyUnavailable;
    }
    if (error.statusCode == 401) {
      return AccountDeletionRequestFailureKind.unauthorized;
    }
    return AccountDeletionRequestFailureKind.outcomeUnknown;
  }

  /// True only when the Hub is KNOWN to have refused before creating an
  /// operation, so it is a fact -- not a hope -- that nothing was committed.
  ///
  /// Derived from the order of checks in
  /// `client_api_request_account_deletion()`: confirmation, recovery format,
  /// re-authentication and the managed-account interlock all run before
  /// `account_deletion_request()`, and bearer authentication runs before the
  /// handler at all. The recovery-id conflict is raised when the insert was
  /// REJECTED because the handle names another account's operation, so nothing
  /// was created for this one either.
  ///
  /// 503 and 500 are deliberately excluded. A lock-wait timeout and an
  /// unresolved operation conflict both arise on the insert path, so "the Hub
  /// said 503" is not evidence that nothing exists.
  bool get isPreAcceptance {
    switch (kind) {
      case AccountDeletionRequestFailureKind.confirmationRejected:
      case AccountDeletionRequestFailureKind.recoveryMaterialRejected:
      case AccountDeletionRequestFailureKind.recoveryMaterialConflict:
      case AccountDeletionRequestFailureKind.reauthenticationRequired:
      case AccountDeletionRequestFailureKind.reauthenticationUnsupported:
      case AccountDeletionRequestFailureKind.managedAccount:
      case AccountDeletionRequestFailureKind.unauthorized:
        return true;
      case AccountDeletionRequestFailureKind.temporarilyUnavailable:
      case AccountDeletionRequestFailureKind.outcomeUnknown:
        return false;
    }
  }

  /// The one failure that means the stored handle can never be used: it belongs
  /// to somebody else's operation. Every other failure must reuse the material
  /// already persisted -- "retry by generating another credential" is how a
  /// customer ends up with two operations and a credential for neither.
  bool get requiresFreshRecoveryMaterial =>
      kind == AccountDeletionRequestFailureKind.recoveryMaterialConflict;

  /// Whether re-sending the identical request, with the SAME credential, is the
  /// correct next move. Safe because the Hub's request path is idempotent: a
  /// replay recovers the operation it already committed.
  bool get isRetryableWithSameCredential =>
      kind == AccountDeletionRequestFailureKind.temporarilyUnavailable ||
      kind == AccountDeletionRequestFailureKind.outcomeUnknown;

  @override
  String toString() =>
      'AccountDeletionRequestFailure(kind: $kind, statusCode: $statusCode, '
      'code: $code, requestId: $requestId)';
}

/// What the Hub said about `POST /client/v1/account-deletions/status`.
enum AccountDeletionStatusFailureKind {
  /// 404 `DELETION_OPERATION_NOT_FOUND`. ONE answer for malformed, unknown and
  /// wrong material, so the route cannot be used as an oracle. This client
  /// therefore cannot tell those apart either, and must not pretend to.
  notFound,

  /// 500, a malformed body, a timeout, a dropped socket. Read again later; this
  /// says nothing about the operation.
  unavailable,
}

/// A classified failure of the deletion-only STATUS route.
class AccountDeletionStatusFailure {
  const AccountDeletionStatusFailure({
    required this.kind,
    required this.statusCode,
    this.code,
    this.requestId,
  });

  /// Takes `Object` for the same reason [AccountDeletionRequestFailure
  /// .fromError] does: a dropped connection is a raw `HttpException`, and a
  /// status read that could not complete is simply a read to try again.
  factory AccountDeletionStatusFailure.fromError(Object error) {
    if (error is! CaleeHubException) {
      return const AccountDeletionStatusFailure(
        kind: AccountDeletionStatusFailureKind.unavailable,
        statusCode: 0,
      );
    }
    return AccountDeletionStatusFailure(
      kind: error.code == 'DELETION_OPERATION_NOT_FOUND'
          ? AccountDeletionStatusFailureKind.notFound
          : AccountDeletionStatusFailureKind.unavailable,
      statusCode: error.statusCode,
      code: error.code,
      requestId: error.requestId,
    );
  }

  final AccountDeletionStatusFailureKind kind;
  final int statusCode;
  final String? code;
  final String? requestId;

  @override
  String toString() =>
      'AccountDeletionStatusFailure(kind: $kind, statusCode: $statusCode, '
      'code: $code, requestId: $requestId)';
}

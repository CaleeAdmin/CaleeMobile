// ignore_for_file: prefer_initializing_formals
import 'package:flutter/foundation.dart';

import '../../data/account_deletion/account_deletion_failure.dart';
import '../../data/account_deletion/account_deletion_recovery_credential.dart';
import '../../data/account_deletion/account_deletion_recovery_store.dart';
import '../../data/api/calee_hub_client.dart';
import '../../data/models/account_deletion_status.dart';
import 'account_deletion_account_cleanup.dart';

/// The Account Deletion V1 lifecycle, in one place (#556).
///
/// Widgets ask this object what to show and tell it what the customer did.
/// They never call the Hub, never touch the secure store, and never re-derive
/// the error policy: `AccountDeletionRequestFailure.isPreAcceptance`,
/// `requiresFreshRecoveryMaterial` and `isRetryableWithSameCredential` are the
/// only classification in the app, and this controller is their only consumer.
///
/// THE TWO INVARIANTS EVERYTHING ELSE HANGS OFF:
///
///  1. RECOVERY MATERIAL IS DURABLY VERIFIED BEFORE THE FIRST POST. The
///     credential is minted (or loaded), written through
///     [AccountDeletionRecoveryStore.save]'s write-then-read-back, and only
///     then does anything irreversible travel. A credential still in flight to
///     the Keychain when the response is lost is a credential the customer
///     does not have.
///
///  2. ONLY A PROVEN PRE-ACCEPTANCE REFUSAL MEANS "NOTHING HAPPENED". A 503, a
///     500, a timeout, a dropped socket or a malformed 2xx leaves the outcome
///     UNKNOWN. The operation may be committed, so the app must not return the
///     customer to ordinary signed-in Calee, must not mint a second credential,
///     and must resolve what happened through the recovery-only status route.

/// Where the deletion lifecycle currently is.
///
/// Read [ownsAppSurface] rather than matching on individual members when
/// deciding whether ordinary Calee UX may be shown: a phase added later must
/// not silently fall back into the signed-in app.
enum AccountDeletionPhase {
  /// No deletion has been attempted, or the last one ended and its state has
  /// been cleared. Ordinary Calee UX.
  inactive,

  /// Persisting recovery material, or waiting on the first request. Ordinary
  /// Calee UX continues underneath the deletion screen: nothing is known yet.
  submitting,

  /// The Hub is KNOWN to have refused before creating an operation, so it is a
  /// fact that nothing was committed. The customer stays signed in.
  refused,

  /// The outcome is not known and the customer is still on the deletion screen
  /// with the means to retry the identical request with the SAME credential.
  ///
  /// Distinct from [unresolved]: here the retry is still available, so the app
  /// offers it before falling back to the recovery-only path.
  retryable,

  /// An operation is known to exist and is still running. NEVER success --
  /// `requested`, `quiescing`, `deleting`, `failed_retryable`,
  /// `support_required` and any state this build does not recognise all land
  /// here.
  tracking,

  /// Recovery material is stored for an operation whose existence has not been
  /// confirmed. Neither "deleted" nor "nothing happened"; the recovery-only
  /// status route is the only way out.
  unresolved,

  /// The operation exists but this device cannot follow it: the Hub holds
  /// different recovery material, or the stored record is present and
  /// unreadable. A bounded support state -- never a silent credential rotation
  /// and never presented as safely recoverable.
  unrecoverable,

  /// Hub state exactly `completed`. THE ONLY SUCCESSFUL OUTCOME.
  completed,

  /// Hub state exactly `restored`. Terminal, and deletion did NOT happen.
  restored,
}

/// Why a deletion could not be started, when it is a FACT that nothing was
/// created. One member per situation the customer can act on differently --
/// the UI renders guidance from this, never from a status code.
enum AccountDeletionRefusalReason {
  /// The password was absent, wrong, or too old. The Hub answers all three
  /// identically on purpose, so the app must not claim to know which.
  reauthenticationRejected,

  /// This account cannot re-authenticate in the app at all.
  reauthenticationUnsupported,

  /// An organisation owns this account's lifecycle.
  managedAccount,

  /// The bearer token, not the password, was refused.
  sessionExpired,

  /// The Hub rejected the confirmation phrase or the recovery material format.
  /// Both are contract drift, not customer error: this client sends the phrase
  /// verbatim and validates the material before it travels.
  contractRejected,

  /// The secure store could not durably hold the recovery material, so nothing
  /// was sent. Refusing here is the point of invariant 1.
  recoveryMaterialUnavailable,
}

/// Orchestrates Settings -> Delete account -> submission -> recovery ->
/// terminal handling.
class AccountDeletionController extends ChangeNotifier {
  AccountDeletionController({
    required CaleeHubClient hubClient,
    required Future<void> Function() endOrdinarySession,
    AccountDeletionRecoveryStore recoveryStore =
        const AccountDeletionRecoveryStore(),
    AccountDeletionRecoveryCredentialGenerator? credentialGenerator,
    AccountDeletionAccountCleanup? accountCleanup,
    AccountDeletionCleanupTargetStore cleanupTargets =
        const AccountDeletionCleanupTargetStore(),
  }) : _hubClient = hubClient,
       _endOrdinarySession = endOrdinarySession,
       _recoveryStore = recoveryStore,
       _credentialGenerator =
           credentialGenerator ?? AccountDeletionRecoveryCredentialGenerator(),
       _accountCleanup = accountCleanup ?? LocalAccountDeletionCleanup(),
       _cleanupTargets = cleanupTargets;

  final CaleeHubClient _hubClient;

  /// Ends ordinary signed-in Calee UX through the app's EXISTING session
  /// lifecycle. Deliberately a callback rather than a [SessionController]
  /// reference: this controller must not be able to invent a second
  /// authentication mechanism, and the deletion recovery record is not
  /// [SessionStore]'s to clear.
  final Future<void> Function() _endOrdinarySession;

  final AccountDeletionRecoveryStore _recoveryStore;
  final AccountDeletionRecoveryCredentialGenerator _credentialGenerator;
  final AccountDeletionAccountCleanup _accountCleanup;
  final AccountDeletionCleanupTargetStore _cleanupTargets;

  AccountDeletionPhase _phase = AccountDeletionPhase.inactive;
  AccountDeletionStatus? _status;
  AccountDeletionRefusalReason? _refusalReason;
  AccountDeletionRequestFailure? _requestFailure;
  AccountDeletionStatusFailure? _statusFailure;
  AccountDeletionRecoveryCredential? _credential;
  AccountDeletionCleanupReport _cleanupReport =
      AccountDeletionCleanupReport.none;
  bool _busy = false;
  bool _operationConfirmed = false;
  bool _recoveryCredentialMismatch = false;

  /// True when a local storage failure stopped [restore] from finding out
  /// whether anything is pending. Not evidence of a deletion, so ordinary UX
  /// continues -- but the read is worth retrying (the app shell does so on
  /// resume) rather than assuming an empty store forever.
  bool _restoreDeferred = false;

  AccountDeletionPhase get phase => _phase;

  /// The Hub's bounded projection for the tracked operation, or null.
  AccountDeletionStatus? get status => _status;

  AccountDeletionRefusalReason? get refusalReason => _refusalReason;
  AccountDeletionRequestFailure? get requestFailure => _requestFailure;
  AccountDeletionStatusFailure? get statusFailure => _statusFailure;

  /// Whether a network or storage call is in flight.
  bool get isBusy => _busy;

  bool get restoreDeferred => _restoreDeferred;

  /// True when the Hub answered with an operation bound to DIFFERENT recovery
  /// material. The stored credential will not open the status route, and this
  /// client deliberately does not rebind or rotate to hide that.
  bool get recoveryCredentialMismatch => _recoveryCredentialMismatch;

  /// What the completed-deletion cleanup actually removed. Log-safe.
  AccountDeletionCleanupReport get cleanupReport => _cleanupReport;

  /// The PUBLIC recovery handle, for a support conversation. Never the secret.
  String? get recoveryIdForSupport => _credential?.recoveryId;

  /// The Hub's operation id once one is known, for a support conversation.
  String? get operationIdForSupport => _status?.operationId;

  /// The Hub's own approved wording about how long deletion may take.
  ///
  /// Rendered, never composed: there is no published numeric SLA and this
  /// client must not invent one.
  String? get completionWindowMessage => _status?.completionWindowMessage;

  /// Whether the deletion lifecycle -- not the signed-in app -- owns the whole
  /// screen.
  ///
  /// True for every phase in which an operation may exist. Ordinary Calee UX,
  /// ordinary sign-in and the Guest experience are all suppressed while this
  /// holds, which is what stops normal Hub credentials from reopening the app
  /// merely to look at deletion status.
  bool get ownsAppSurface {
    switch (_phase) {
      case AccountDeletionPhase.tracking:
      case AccountDeletionPhase.unresolved:
      case AccountDeletionPhase.unrecoverable:
      case AccountDeletionPhase.completed:
      case AccountDeletionPhase.restored:
        return true;
      case AccountDeletionPhase.inactive:
      case AccountDeletionPhase.submitting:
      case AccountDeletionPhase.refused:
      case AccountDeletionPhase.retryable:
        return false;
    }
  }

  /// THE ONLY PLACE THIS APP CONCLUDES A DELETION SUCCEEDED.
  bool get isDeletionCompleted => _phase == AccountDeletionPhase.completed;

  /// Terminal, and deletion did NOT complete.
  bool get isDeletionRestored => _phase == AccountDeletionPhase.restored;

  /// Whether the customer may walk away from an unconfirmed request.
  ///
  /// Offered ONLY once the Hub itself has answered `DELETION_OPERATION_NOT_FOUND`
  /// for material this client minted and sent. That answer is not an oracle --
  /// the route deliberately cannot distinguish unknown from wrong material --
  /// so it never becomes "deleted" and never becomes "nothing happened" on its
  /// own. It does mean the alternative to a customer decision is trapping them
  /// on this screen forever, and signing in again is itself the honest test:
  /// it fails if the account really is going away, and succeeds if it is not.
  bool get canAbandonUnconfirmedRequest =>
      _phase == AccountDeletionPhase.unresolved &&
      !_operationConfirmed &&
      _statusFailure?.kind == AccountDeletionStatusFailureKind.notFound;

  // ── Cold launch ───────────────────────────────────────────────────────────

  /// Decides, from LOCAL state only, whether a deletion owns this launch.
  ///
  /// Called before ordinary session restoration so precedence is settled
  /// without a network round trip: a pending operation must not be hidden
  /// behind login/onboarding, and a device with no recovery material must not
  /// pay for a status read it does not need. [refreshStatus] does the network
  /// part afterwards, off the startup path.
  Future<void> restore() async {
    _restoreDeferred = false;

    final AccountDeletionRecoveryRecord? record;
    try {
      record = await _recoveryStore.load();
    } on AccountDeletionRecoveryStoreException {
      // Present, but this build cannot read it. Something IS pending and the
      // handle is gone, so fail closed into the bounded support state rather
      // than letting ordinary sign-in paper over a deletion in progress.
      _credential = null;
      _statusFailure = null;
      _set(AccountDeletionPhase.unrecoverable);
      await _endOrdinarySession();
      return;
    } catch (_) {
      // The secure store itself was unreachable, so nothing is known either
      // way. An unreadable Keychain is not evidence of a deletion: keep
      // ordinary UX and let the app shell retry the read later.
      _restoreDeferred = true;
      return;
    }

    if (record == null) {
      _set(AccountDeletionPhase.inactive);
      return;
    }

    _credential = record.credential;
    // An operation id was only ever written from a Hub response, so its
    // presence is proof the operation exists. Without one the launch is
    // unresolved until the status route says otherwise -- never "finished".
    _operationConfirmed = record.operationId != null;
    _set(
      _operationConfirmed
          ? AccountDeletionPhase.tracking
          : AccountDeletionPhase.unresolved,
    );

    // Normal Hub access/refresh credentials must not let the customer back
    // into the signed-in app just to watch this. The recovery record lives
    // outside SessionStore precisely so this call cannot take it with it.
    await _endOrdinarySession();
  }

  // ── Submission ────────────────────────────────────────────────────────────

  /// Persists recovery material, then requests permanent deletion.
  ///
  /// [password] is used once, for the Hub's recent re-authentication check, and
  /// is never stored, never logged and never put in an exception. [accountId]
  /// is remembered ONLY so a completion observed days later can clean up the
  /// right account instead of falling back to a device-wide wipe.
  Future<void> submit({
    required String accessToken,
    required String password,
    required String accountId,
  }) async {
    if (_busy) return;
    _busy = true;
    _requestFailure = null;
    _refusalReason = null;
    _statusFailure = null;
    _set(AccountDeletionPhase.submitting);

    try {
      final AccountDeletionRecoveryCredential credential;
      try {
        credential = await _ensureDurableCredential();
      } catch (_) {
        // INVARIANT 1. Nothing has been sent, so this is a proven
        // pre-acceptance refusal: the customer stays signed in, untouched.
        _refuse(AccountDeletionRefusalReason.recoveryMaterialUnavailable);
        return;
      }

      await _post(
        credential: credential,
        accessToken: accessToken,
        password: password,
        accountId: accountId,
      );
    } finally {
      _busy = false;
      notifyListeners();
    }
  }

  /// Loads the stored credential, or mints and durably persists a new one.
  ///
  /// NEVER mints over material that already exists. A stored credential is the
  /// handle to an operation that may already be committed; replacing it because
  /// a response was lost is exactly how a customer ends up with two operations
  /// and a credential for neither.
  ///
  /// Throws when the material cannot be made durable -- including when a record
  /// is present but unreadable, which is a support case, not an empty store.
  Future<AccountDeletionRecoveryCredential> _ensureDurableCredential() async {
    final existing = await _recoveryStore.load();
    if (existing != null) {
      _credential = existing.credential;
      return existing.credential;
    }

    final minted = _credentialGenerator.generate();
    // Write-then-read-back. This future completing is the signal that
    // something irreversible may now be attempted.
    await _recoveryStore.saveCredential(minted);
    _credential = minted;
    return minted;
  }

  Future<void> _post({
    required AccountDeletionRecoveryCredential credential,
    required String accessToken,
    required String password,
    required String accountId,
  }) async {
    final AccountDeletionRequestResult result;
    try {
      result = await _hubClient.requestAccountDeletion(
        accessToken: accessToken,
        password: password,
        recoveryCredential: credential,
      );
    } catch (error) {
      await _handleRequestFailure(
        AccountDeletionRequestFailure.fromError(error),
        credential: credential,
        accountId: accountId,
      );
      return;
    }

    await _handleAcceptance(
      result,
      credential: credential,
      accountId: accountId,
    );
  }

  /// The Hub answered. An operation exists -- `created: false` merely means
  /// this request replayed onto the one that already did.
  Future<void> _handleAcceptance(
    AccountDeletionRequestResult result, {
    required AccountDeletionRecoveryCredential credential,
    required String accountId,
  }) async {
    _status = result.status;
    _operationConfirmed = true;
    _recoveryCredentialMismatch = !result.recoveryCredentialMatched;
    _requestFailure = null;
    _refusalReason = null;

    // Convenience metadata only: recovery does not depend on it, so a failure
    // to record it is not a failed deletion.
    try {
      await _recoveryStore.recordOperationId(
        credential: credential,
        operationId: result.status.operationId,
      );
    } catch (_) {
      // See above -- the credential is already durable.
    }
    await _cleanupTargets.remember(accountId);

    // POST-ACCEPTANCE AUTH BOUNDARY.
    await _endOrdinarySession();

    if (await _applyTerminalState(result.status)) return;

    if (_recoveryCredentialMismatch) {
      // The Hub holds different material for this account's operation and
      // deliberately does not rebind, so the credential just sent will not
      // open the status route. Do not rotate, and do not present this as
      // safely recoverable.
      _set(AccountDeletionPhase.unrecoverable);
      return;
    }

    _set(AccountDeletionPhase.tracking);
  }

  Future<void> _handleRequestFailure(
    AccountDeletionRequestFailure failure, {
    required AccountDeletionRecoveryCredential credential,
    required String accountId,
  }) async {
    _requestFailure = failure;

    if (failure.requiresFreshRecoveryMaterial) {
      // THE ONE case the model proves the stored handle can never be used: it
      // names another account's operation, so nothing was created for this one
      // and replacing the material is the correct remedy rather than a guess.
      try {
        await _recoveryStore.clear();
        final fresh = _credentialGenerator.generate();
        await _recoveryStore.saveCredential(fresh);
        _credential = fresh;
      } catch (_) {
        _refuse(AccountDeletionRefusalReason.recoveryMaterialUnavailable);
        return;
      }
      // Fresh material is durable, but nothing destructive is replayed behind
      // the customer's back: they confirm again.
      _set(AccountDeletionPhase.retryable);
      return;
    }

    if (failure.isPreAcceptance) {
      // A FACT that nothing was committed. Stay in ordinary signed-in UX and
      // keep the material: it is well-formed and unused, and discarding it
      // here would be a rotation the classification does not justify.
      _refuse(_refusalFor(failure.kind));
      return;
    }

    // 503 or unknown: the operation MAY be committed. Same credential, no
    // second operation, and resolve through the recovery-only status route.
    _set(AccountDeletionPhase.retryable);
    await _readStatus(credential);
    if (_operationConfirmed) {
      // The status route found it, so it was accepted after all.
      await _cleanupTargets.remember(accountId);
      await _endOrdinarySession();
    }
  }

  /// Leaves the in-place retry without retrying.
  ///
  /// The outcome is still unknown, so this is a fail-closed exit rather than a
  /// return to ordinary Calee: the recovery-only surface takes over and normal
  /// credentials stop working. The credential is preserved.
  Future<void> leaveRetry() async {
    if (_phase != AccountDeletionPhase.retryable) return;
    _set(AccountDeletionPhase.unresolved);
    await _endOrdinarySession();
    await refreshStatus();
  }

  /// Dismisses a proven pre-acceptance refusal and returns to ordinary UX.
  void dismissRefusal() {
    if (_phase != AccountDeletionPhase.refused) return;
    _requestFailure = null;
    _refusalReason = null;
    _set(AccountDeletionPhase.inactive);
  }

  // ── Recovery-only status ──────────────────────────────────────────────────

  /// Reads the operation's state with the stored credential and NO bearer
  /// token.
  ///
  /// This is the surface that has to keep working once the Keycloak identity is
  /// quiesced or gone, so it must never be gated on a session.
  Future<void> refreshStatus() async {
    final credential = _credential;
    if (credential == null || _busy) return;
    _busy = true;
    notifyListeners();
    try {
      await _readStatus(credential);
    } finally {
      _busy = false;
      notifyListeners();
    }
  }

  Future<void> _readStatus(AccountDeletionRecoveryCredential credential) async {
    final AccountDeletionStatus status;
    try {
      status = await _hubClient.accountDeletionStatus(
        recoveryCredential: credential,
      );
    } catch (error) {
      _statusFailure = AccountDeletionStatusFailure.fromError(error);
      if (!_operationConfirmed && _phase != AccountDeletionPhase.retryable) {
        // Still nothing proven either way.
        _set(AccountDeletionPhase.unresolved);
      } else {
        notifyListeners();
      }
      return;
    }

    _statusFailure = null;
    _status = status;
    _operationConfirmed = true;

    try {
      await _recoveryStore.recordOperationId(
        credential: credential,
        operationId: status.operationId,
      );
    } catch (_) {
      // Convenience metadata; the credential is what recovers the operation.
    }

    if (await _applyTerminalState(status)) return;

    // requested / quiescing / deleting / failed_retryable / support_required,
    // and any state this build has never seen. None of them is success.
    _set(AccountDeletionPhase.tracking);
  }

  /// Applies `completed` or `restored`, and reports whether either matched.
  ///
  /// Reads [AccountDeletionStatus.isCompleted] and [AccountDeletionStatus
  /// .isRestored], which are exact matches on the wire string -- never
  /// `isTerminal`, which is also true for `restored` and would be true for a
  /// future terminal state this build has never heard of.
  ///
  /// Awaits its own terminal handling rather than firing it off, so the phase
  /// and the cleanup that belongs to it always land together: a customer can
  /// never be shown "deleted" while the state it describes is still on the
  /// device.
  Future<bool> _applyTerminalState(AccountDeletionStatus status) async {
    if (status.isCompleted) {
      // Deletion actually happened, and the Hub's manifest-driven verification
      // passed. This is the ONE path that touches account-scoped local state.
      _set(AccountDeletionPhase.completed);
      final accountId = await _cleanupTargets.load();
      if (accountId != null) {
        _cleanupReport = await _accountCleanup.clearAccountState(accountId);
      }
      // ORDER MATTERS. The recovery material is retired only once the state it
      // was protecting has actually been dealt with, so an interruption
      // mid-cleanup leaves the operation still findable rather than orphaned.
      await _clearDeletionOnlyState();
      notifyListeners();
      return true;
    }
    if (status.isRestored) {
      // The Hub stopped before the first irreversible step and restored
      // access. Deletion did NOT happen, so the account keeps everything: only
      // the deletion-only transient state goes.
      _set(AccountDeletionPhase.restored);
      await _clearDeletionOnlyState();
      notifyListeners();
      return true;
    }
    return false;
  }

  /// Removes the deletion-only record and the cleanup target, and NOTHING
  /// else. Never called because a request timed out, a socket closed or the
  /// app was killed.
  Future<void> _clearDeletionOnlyState() async {
    try {
      await _recoveryStore.clear();
    } catch (_) {
      // Best-effort: the operation is terminal, so a lingering record is a
      // nuisance rather than a correctness problem.
    }
    await _cleanupTargets.clear();
    _credential = null;
  }

  /// Acknowledges a terminal outcome and hands the app back to ordinary UX.
  ///
  /// Only ever called from [AccountDeletionPhase.completed] or
  /// [AccountDeletionPhase.restored]: a nonterminal state has nothing to
  /// acknowledge, and letting it be dismissed would be exactly the "quietly
  /// stopped tracking a live deletion" bug the recovery contract prevents.
  void acknowledgeTerminalOutcome() {
    if (_phase != AccountDeletionPhase.completed &&
        _phase != AccountDeletionPhase.restored) {
      return;
    }
    _status = null;
    _statusFailure = null;
    _requestFailure = null;
    _refusalReason = null;
    _operationConfirmed = false;
    _recoveryCredentialMismatch = false;
    _set(AccountDeletionPhase.inactive);
  }

  /// Gives up on a request the Hub says it has never heard of.
  ///
  /// Guarded by [canAbandonUnconfirmedRequest], so it cannot run for an
  /// operation this app has actually seen, nor while the status route is
  /// merely unreachable. Clears the deletion-only state and returns the
  /// customer to ordinary sign-in.
  Future<void> abandonUnconfirmedRequest() async {
    if (!canAbandonUnconfirmedRequest) return;
    await _clearDeletionOnlyState();
    _status = null;
    _statusFailure = null;
    _requestFailure = null;
    _operationConfirmed = false;
    _set(AccountDeletionPhase.inactive);
  }

  // ── Internals ─────────────────────────────────────────────────────────────

  void _refuse(AccountDeletionRefusalReason reason) {
    _refusalReason = reason;
    _set(AccountDeletionPhase.refused);
  }

  static AccountDeletionRefusalReason _refusalFor(
    AccountDeletionRequestFailureKind kind,
  ) {
    switch (kind) {
      case AccountDeletionRequestFailureKind.reauthenticationRequired:
        return AccountDeletionRefusalReason.reauthenticationRejected;
      case AccountDeletionRequestFailureKind.reauthenticationUnsupported:
        return AccountDeletionRefusalReason.reauthenticationUnsupported;
      case AccountDeletionRequestFailureKind.managedAccount:
        return AccountDeletionRefusalReason.managedAccount;
      case AccountDeletionRequestFailureKind.unauthorized:
        return AccountDeletionRefusalReason.sessionExpired;
      case AccountDeletionRequestFailureKind.confirmationRejected:
      case AccountDeletionRequestFailureKind.recoveryMaterialRejected:
      case AccountDeletionRequestFailureKind.recoveryMaterialConflict:
        return AccountDeletionRefusalReason.contractRejected;
      // Neither of these is pre-acceptance, so neither can reach here; they
      // are listed so a new kind cannot be added without revisiting this.
      case AccountDeletionRequestFailureKind.temporarilyUnavailable:
      case AccountDeletionRequestFailureKind.outcomeUnknown:
        return AccountDeletionRefusalReason.contractRejected;
    }
  }

  void _set(AccountDeletionPhase phase) {
    _phase = phase;
    notifyListeners();
  }
}

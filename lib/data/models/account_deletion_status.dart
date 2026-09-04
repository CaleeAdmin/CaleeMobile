/// The Account Deletion V1 client models (CaleeMobile #556).
///
/// These mirror EXACTLY the bounded projection the Hub publishes from
/// `account_deletion_status_fields()` in
/// `calee-hub-core@c520740795205a32117d9ba047f88b0ff557aeb6`
/// (`public/lib/core_account_deletion_status.php`). Nothing is added: the
/// backend deliberately withholds the account id, the email, any downstream
/// identifier, the manifest, operator notes and raw failure detail from this
/// surface, and a mobile model that invented extra fields would be modelling a
/// contract that does not exist.
library;

/// Every state an operation may hold, per `account_deletion_states()`.
///
/// The wire string is authoritative -- this enum is a convenience over it, not
/// a replacement for it. A backend that grows an eighth state must NOT make
/// this client mis-read it, which is why [AccountDeletionStatus.knownState] is
/// nullable and why every success predicate below is written as an explicit
/// match on the one state that means what it says.
enum AccountDeletionState {
  requested('requested'),
  quiescing('quiescing'),
  deleting('deleting'),
  failedRetryable('failed_retryable'),
  supportRequired('support_required'),
  completed('completed'),
  restored('restored');

  const AccountDeletionState(this.wireName);

  /// The exact string the Hub sends.
  final String wireName;

  /// The two truthful endings, and the only two
  /// (`account_deletion_terminal_states()`).
  bool get isTerminal =>
      this == AccountDeletionState.completed ||
      this == AccountDeletionState.restored;

  /// The state for [wireName], or null when this build does not recognise it.
  ///
  /// Null rather than a fallback member so that "we do not know what this is"
  /// can never be spelled the same way as "we know this is finished".
  static AccountDeletionState? fromWireName(String wireName) {
    for (final state in AccountDeletionState.values) {
      if (state.wireName == wireName) return state;
    }
    return null;
  }
}

/// The bounded, deletion-only status projection.
///
/// Constructed only through [AccountDeletionStatus.fromJson], which throws a
/// [FormatException] rather than defaulting a structurally required field. A
/// model that silently defaulted `state` would produce an object whose
/// [isCompleted] answer was invented, and this is the one screen a customer
/// reads after their ordinary access to Calee is gone.
class AccountDeletionStatus {
  const AccountDeletionStatus({
    required this.operationId,
    required this.state,
    required this.isTerminal,
    required this.restorable,
    this.reasonCode,
    this.requestedAt,
    this.completedAt,
    this.restoredAt,
    this.completionWindowMessage,
  });

  /// Parses the Hub's `data` object.
  ///
  /// Required and strict: `operationId`, `state`, `isTerminal`, `restorable`.
  /// Optional and defensive: the three timestamps, `reasonCode` and
  /// `completionWindowMessage`.
  ///
  /// Timestamps that are absent, of the wrong type or unparseable become null
  /// instead of failing the parse. They are display metadata; refusing to
  /// surface a whole status because a date did not parse would break the one
  /// recovery path this contract exists to keep working, and the state string
  /// -- not a timestamp -- is what decides what happened.
  factory AccountDeletionStatus.fromJson(Map<String, dynamic> json) {
    return AccountDeletionStatus(
      operationId: _requiredNonEmptyString(json, 'operationId'),
      state: _requiredNonEmptyString(json, 'state'),
      isTerminal: _requiredBool(json, 'isTerminal'),
      restorable: _requiredBool(json, 'restorable'),
      reasonCode: _optionalNonEmptyString(json, 'reasonCode'),
      requestedAt: _optionalTimestamp(json, 'requestedAt'),
      completedAt: _optionalTimestamp(json, 'completedAt'),
      restoredAt: _optionalTimestamp(json, 'restoredAt'),
      completionWindowMessage: _optionalNonEmptyString(
        json,
        'completionWindowMessage',
      ),
    );
  }

  /// The Hub's operation id. Opaque; never minted by this client.
  final String operationId;

  /// The raw state string, exactly as the Hub sent it. AUTHORITATIVE.
  ///
  /// Kept as a String rather than an enum so an unrecognised future state
  /// stays representable and reportable instead of being coerced into
  /// something this build happens to know.
  final String state;

  /// The Hub's own terminality flag.
  ///
  /// NOT a success signal. `restored` is terminal and means deletion did NOT
  /// happen; a future terminal state would be terminal and mean something this
  /// build has never heard of. Read [isCompleted] to ask about success.
  final bool isTerminal;

  /// Whether the Hub says this operation may still be restored.
  final bool restorable;

  /// A stable failure category, or null. Never raw exception text.
  final String? reasonCode;

  final DateTime? requestedAt;
  final DateTime? completedAt;
  final DateTime? restoredAt;

  /// The Hub's own approved wording about how long deletion may take.
  ///
  /// Rendered, never composed. There is no published numeric SLA (calee-hub-core
  /// #458 has not established one), so this client must not turn this into
  /// "24 hours" or any other figure nobody has measured.
  final String? completionWindowMessage;

  /// The recognised state, or null when the Hub sent one this build predates.
  AccountDeletionState? get knownState =>
      AccountDeletionState.fromWireName(state);

  /// True when the Hub sent a state this build does not recognise.
  ///
  /// Fail-safe by construction: such a status is neither [isCompleted] nor
  /// [isRestored] nor [isProcessing], so no caller can accidentally read it as
  /// an ending.
  bool get isUnrecognisedState => knownState == null;

  /// PERMANENT DELETION COMPLETED, and backend verification passed.
  ///
  /// The single place this client is allowed to conclude that. An exact match
  /// on the one state that means it -- not `isTerminal`, not "not restored",
  /// not a default.
  bool get isCompleted => knownState == AccountDeletionState.completed;

  /// Deletion did NOT complete: the operation was restored.
  bool get isRestored => knownState == AccountDeletionState.restored;

  /// A recognised, still-running state.
  ///
  /// False for an unrecognised state on purpose: "still running" is a claim,
  /// and this client cannot make it about a state it has never seen.
  bool get isProcessing {
    final known = knownState;
    return known != null && !known.isTerminal;
  }

  /// Only an operator can advance this operation.
  bool get requiresSupport =>
      knownState == AccountDeletionState.supportRequired;

  /// Redacted by construction -- the projection carries no secret, but this
  /// keeps status objects safe to interpolate into a log line.
  @override
  String toString() =>
      'AccountDeletionStatus(operationId: $operationId, state: $state, '
      'isTerminal: $isTerminal, restorable: $restorable)';
}

/// The response to `POST /client/v1/account-deletions`.
///
/// Composition rather than inheritance: the two booleans are about THIS
/// request, the projection is about the operation, and flattening them would
/// invite a caller to read `created` as if it described the operation.
class AccountDeletionRequestResult {
  const AccountDeletionRequestResult({
    required this.status,
    required this.created,
    required this.recoveryCredentialMatched,
  });

  /// Parses the Hub's `data` object for the request endpoint.
  ///
  /// [created] and [recoveryCredentialMatched] are required, not defaulted: a
  /// 2xx that omits them is a contract deviation, and the honest answer is to
  /// raise it rather than to guess. Callers must treat that failure as an
  /// UNKNOWN outcome (the operation may well exist) and resolve it through the
  /// deletion-only status endpoint -- never by minting fresh recovery material.
  factory AccountDeletionRequestResult.fromJson(Map<String, dynamic> json) {
    return AccountDeletionRequestResult(
      status: AccountDeletionStatus.fromJson(json),
      created: _requiredBool(json, 'created'),
      recoveryCredentialMatched: _requiredBool(
        json,
        'recoveryCredentialMatched',
      ),
    );
  }

  final AccountDeletionStatus status;

  /// False on a replay. HTTP 201 creates; HTTP 200 resolves the operation that
  /// already existed. A replay is NOT a second deletion.
  final bool created;

  /// False when the Hub already held DIFFERENT recovery material for this
  /// account's operation.
  ///
  /// The Hub deliberately does not rebind, so when this is false the credential
  /// this client just sent will NOT open the status endpoint, and the operation
  /// can only be followed with whatever material the Hub still holds.
  final bool recoveryCredentialMatched;

  @override
  String toString() =>
      'AccountDeletionRequestResult(created: $created, '
      'recoveryCredentialMatched: $recoveryCredentialMatched, status: $status)';
}

String _requiredNonEmptyString(Map<String, dynamic> json, String key) {
  final value = json[key];
  if (value is! String || value.trim().isEmpty) {
    throw FormatException('Account deletion status field "$key" is missing.');
  }
  return value.trim();
}

bool _requiredBool(Map<String, dynamic> json, String key) {
  final value = json[key];
  if (value is! bool) {
    throw FormatException('Account deletion status field "$key" is missing.');
  }
  return value;
}

String? _optionalNonEmptyString(Map<String, dynamic> json, String key) {
  final value = json[key];
  if (value is! String || value.trim().isEmpty) return null;
  return value.trim();
}

DateTime? _optionalTimestamp(Map<String, dynamic> json, String key) {
  final value = json[key];
  if (value is! String || value.trim().isEmpty) return null;
  return DateTime.tryParse(value.trim())?.toUtc();
}

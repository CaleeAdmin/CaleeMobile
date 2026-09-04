// Shared doubles and fixtures for the Account Deletion V1 slice (#556).
//
// Deliberately thin. Everything real -- the failure classification, the
// write-then-verify store, the status projection -- is the code under test;
// these only stand in for the platform secure store, the Hub and the local
// caches.

import 'package:calee_mobile/data/account_deletion/account_deletion_recovery_credential.dart';
import 'package:calee_mobile/data/account_deletion/account_deletion_recovery_store.dart';
import 'package:calee_mobile/data/api/calee_hub_client.dart';
import 'package:calee_mobile/data/models/account_deletion_status.dart';
import 'package:calee_mobile/features/account_deletion/account_deletion_account_cleanup.dart';
import 'package:calee_mobile/features/account_deletion/account_deletion_controller.dart';

/// Obviously-fake, correctly-shaped material. Matches the fixture style the
/// #580 store tests already use.
const AccountDeletionRecoveryCredential storedCredential =
    AccountDeletionRecoveryCredential(
      recoveryId: 'Rk1tZXN0Q3JlZGVudGlhbA',
      recoverySecret: 'U2VjcmV0Rm9yVGVzdHNPbmx5Tm90QVJlYWxDcmVkZW50',
    );

/// A deterministic entropy source, so the minted credential is predictable.
/// Values are spread so the Hub's degeneracy floor is comfortably cleared.
List<int> deterministicBytes(int byteCount) =>
    List<int>.generate(byteCount, (i) => (i * 7 + 3) % 256, growable: false);

AccountDeletionRecoveryCredentialGenerator deterministicGenerator() =>
    AccountDeletionRecoveryCredentialGenerator(randomBytes: deterministicBytes);

/// An in-memory stand-in for the platform secure store.
class FakeDeletionSecureStorage implements AccountDeletionSecureStorage {
  FakeDeletionSecureStorage([Map<String, String>? seed]) : values = {...?seed};

  final Map<String, String> values;
  final List<String> deletedKeys = <String>[];

  /// Simulates a write that silently does not stick, which is exactly what the
  /// store's read-back exists to catch.
  bool dropWrites = false;

  @override
  Future<String?> read(String key) async => values[key];

  @override
  Future<void> write(String key, String value) async {
    if (dropWrites) return;
    values[key] = value;
  }

  @override
  Future<void> delete(String key) async {
    deletedKeys.add(key);
    values.remove(key);
  }

  bool get holdsRecoveryRecord =>
      values.containsKey(AccountDeletionRecoveryStore.recoveryRecordKey);

  String? get rawRecoveryRecord =>
      values[AccountDeletionRecoveryStore.recoveryRecordKey];
}

/// A Hub whose two deletion answers are scripted per call.
class FakeDeletionHubClient extends CaleeHubClient {
  FakeDeletionHubClient({this.onRequest, this.onStatus})
    : super(baseUri: Uri.parse('http://localhost'));

  /// Answers `POST /client/v1/account-deletions`.
  Future<AccountDeletionRequestResult> Function(int callIndex)? onRequest;

  /// Answers `POST /client/v1/account-deletions/status`.
  Future<AccountDeletionStatus> Function(int callIndex)? onStatus;

  final List<String> requestPasswords = <String>[];
  final List<String> requestAccessTokens = <String>[];
  final List<AccountDeletionRecoveryCredential> requestCredentials =
      <AccountDeletionRecoveryCredential>[];
  final List<AccountDeletionRecoveryCredential> statusCredentials =
      <AccountDeletionRecoveryCredential>[];

  /// Runs immediately before the request is answered, so a test can assert on
  /// the world AS IT WAS when the irreversible call was made -- which is how
  /// "persisted before the first POST" is provable rather than assumed.
  void Function()? beforeRequestAnswered;

  int get requestCount => requestCredentials.length;
  int get statusCount => statusCredentials.length;

  @override
  Future<AccountDeletionRequestResult> requestAccountDeletion({
    required String accessToken,
    required String password,
    required AccountDeletionRecoveryCredential recoveryCredential,
  }) async {
    final index = requestCredentials.length;
    requestCredentials.add(recoveryCredential);
    requestPasswords.add(password);
    requestAccessTokens.add(accessToken);
    beforeRequestAnswered?.call();
    final handler = onRequest;
    if (handler == null) {
      throw const CaleeHubException(statusCode: 500, message: 'unscripted');
    }
    return handler(index);
  }

  @override
  Future<AccountDeletionStatus> accountDeletionStatus({
    required AccountDeletionRecoveryCredential recoveryCredential,
  }) async {
    final index = statusCredentials.length;
    statusCredentials.add(recoveryCredential);
    final handler = onStatus;
    if (handler == null) {
      throw const CaleeHubException(statusCode: 500, message: 'unscripted');
    }
    return handler(index);
  }
}

/// Records that the ordinary session was ended, without needing a real one.
class SessionEndRecorder {
  int calls = 0;
  bool get wasEnded => calls > 0;
  Future<void> end() async => calls++;
}

/// Records account-scoped cleanup instead of touching device state.
class RecordingAccountCleanup implements AccountDeletionAccountCleanup {
  final List<String> clearedAccountIds = <String>[];

  @override
  Future<AccountDeletionCleanupReport> clearAccountState(
    String accountId,
  ) async {
    clearedAccountIds.add(accountId);
    return const AccountDeletionCleanupReport(
      accountScopedPreferencesCleared: true,
      onboardingStatusCleared: true,
      reminderPreferenceCleared: true,
      remindersCancelled: 2,
    );
  }
}

/// Builds a status projection with the wire fields the Hub actually sends.
///
/// [state] is passed through verbatim so a test can supply a state this build
/// has never heard of, which is the point of several of them.
AccountDeletionStatus statusFor(
  String state, {
  String operationId = 'op_TEST',
  bool? isTerminal,
  bool restorable = true,
  String? completionWindowMessage,
  String? completedAt,
}) {
  return AccountDeletionStatus.fromJson(<String, dynamic>{
    'operationId': operationId,
    'state': state,
    'isTerminal': isTerminal ?? const {'completed', 'restored'}.contains(state),
    'restorable': restorable,
    'requestedAt': '2026-09-01T02:03:04Z',
    if (completedAt != null) 'completedAt': completedAt,
    if (completionWindowMessage != null)
      'completionWindowMessage': completionWindowMessage,
  });
}

AccountDeletionRequestResult acceptedResult({
  String state = 'requested',
  bool created = true,
  bool recoveryCredentialMatched = true,
  String? completionWindowMessage,
}) {
  return AccountDeletionRequestResult(
    status: statusFor(state, completionWindowMessage: completionWindowMessage),
    created: created,
    recoveryCredentialMatched: recoveryCredentialMatched,
  );
}

/// Assembles a controller over the doubles above.
({
  AccountDeletionController controller,
  FakeDeletionSecureStorage storage,
  SessionEndRecorder session,
  RecordingAccountCleanup cleanup,
  FakeCleanupTargetStore targets,
})
buildController({
  required FakeDeletionHubClient hub,
  FakeDeletionSecureStorage? storage,
  String? seedCleanupTarget,
}) {
  final store = storage ?? FakeDeletionSecureStorage();
  final session = SessionEndRecorder();
  final cleanup = RecordingAccountCleanup();
  final targets = FakeCleanupTargetStore(seed: seedCleanupTarget);
  return (
    controller: AccountDeletionController(
      hubClient: hub,
      endOrdinarySession: session.end,
      recoveryStore: AccountDeletionRecoveryStore(storage: store),
      credentialGenerator: deterministicGenerator(),
      accountCleanup: cleanup,
      cleanupTargets: targets,
    ),
    storage: store,
    session: session,
    cleanup: cleanup,
    targets: targets,
  );
}

/// An in-memory cleanup-target store, so controller tests never reach
/// SharedPreferences.
class FakeCleanupTargetStore implements AccountDeletionCleanupTargetStore {
  FakeCleanupTargetStore({String? seed}) : _accountId = seed;

  String? _accountId;
  int clearCalls = 0;

  String? get accountId => _accountId;

  @override
  Future<String?> load() async => _accountId;

  @override
  Future<void> remember(String accountId) async => _accountId = accountId;

  @override
  Future<void> clear() async {
    clearCalls++;
    _accountId = null;
  }
}

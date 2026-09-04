import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import 'account_deletion_recovery_credential.dart';

/// Secure, narrowly scoped persistence for deletion recovery material (#556).
///
/// WHY THIS IS NOT [SessionStore]. After the Hub accepts a deletion, the
/// ordinary access and refresh tokens must become removable -- the account is
/// quiescing, and by completion the Keycloak identity behind them is gone. The
/// recovery credential has to OUTLIVE exactly that: a lost first response, a
/// quiesced account, dead Keycloak credentials, a permanently deleted account,
/// and an app restart. Storing it beside the session tokens would tie its
/// lifetime to the one thing it exists to survive.
///
/// WHAT IS DELIBERATELY NOT STORED HERE: the password (used once for recent
/// re-authentication and never persisted), the Hub access token, the Hub
/// refresh token, the email address, the display name, the deletion manifest,
/// raw failure messages, and arbitrary response JSON. The record is the two
/// random values plus, once known, the Hub's operation id.

/// The one exception this store raises.
///
/// Never carries the recovery secret, and never carries platform error text
/// that might.
class AccountDeletionRecoveryStoreException implements Exception {
  const AccountDeletionRecoveryStoreException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// The narrow key/value seam this store writes through.
///
/// Exists so tests can drive the store without a platform channel, and so the
/// store's own rules (write-then-verify, single-key delete) are testable. It is
/// NOT a place to weaken production storage: the only shipped implementation is
/// [FlutterSecureAccountDeletionStorage].
abstract class AccountDeletionSecureStorage {
  Future<String?> read(String key);
  Future<void> write(String key, String value);
  Future<void> delete(String key);
}

/// The production implementation, on the platform secure store.
///
/// Matches [SessionStore]'s `const FlutterSecureStorage()` configuration
/// deliberately: this slice changes where deletion material lives, not how the
/// app configures the Keychain/Keystore.
class FlutterSecureAccountDeletionStorage
    implements AccountDeletionSecureStorage {
  const FlutterSecureAccountDeletionStorage();

  static const FlutterSecureStorage _secureStorage = FlutterSecureStorage();

  @override
  Future<String?> read(String key) => _secureStorage.read(key: key);

  @override
  Future<void> write(String key, String value) =>
      _secureStorage.write(key: key, value: value);

  /// Deletes ONE key. There is no `deleteAll()` here and there must never be:
  /// this store shares the secure store with the Hub session tokens, and a
  /// global wipe would sign the customer out of an account they are in the
  /// middle of deleting.
  @override
  Future<void> delete(String key) => _secureStorage.delete(key: key);
}

/// What is persisted for one in-flight deletion.
class AccountDeletionRecoveryRecord {
  const AccountDeletionRecoveryRecord({
    required this.credential,
    this.operationId,
  });

  final AccountDeletionRecoveryCredential credential;

  /// The Hub's operation id, once a response has carried one.
  ///
  /// Bounded, safe metadata that genuinely helps: it lets support and logs
  /// refer to the operation without anyone handling the secret. Null until the
  /// first response arrives -- and recovery does NOT depend on it, which is the
  /// point: the credential alone is enough to find the operation again.
  final String? operationId;

  Map<String, dynamic> toJson() => <String, dynamic>{
    'recoveryId': credential.recoveryId,
    'recoverySecret': credential.recoverySecret,
    if (operationId != null) 'operationId': operationId,
  };

  /// Throws [AccountDeletionRecoveryStoreException] when the stored value
  /// cannot be read as a record. The caller must NOT respond by deleting it:
  /// unreadable-but-present is a support case, not an empty store.
  factory AccountDeletionRecoveryRecord.fromJson(Map<String, dynamic> json) {
    final recoveryId = json['recoveryId'];
    final recoverySecret = json['recoverySecret'];
    if (recoveryId is! String ||
        recoveryId.isEmpty ||
        recoverySecret is! String ||
        recoverySecret.isEmpty) {
      throw const AccountDeletionRecoveryStoreException(
        'Stored deletion recovery material is incomplete.',
      );
    }
    final operationId = json['operationId'];
    return AccountDeletionRecoveryRecord(
      credential: AccountDeletionRecoveryCredential(
        recoveryId: recoveryId,
        recoverySecret: recoverySecret,
      ),
      operationId: operationId is String && operationId.trim().isNotEmpty
          ? operationId.trim()
          : null,
    );
  }

  /// Redacts the secret via [AccountDeletionRecoveryCredential.toString].
  @override
  String toString() =>
      'AccountDeletionRecoveryRecord(operationId: $operationId, '
      'credential: $credential)';

  @override
  bool operator ==(Object other) =>
      other is AccountDeletionRecoveryRecord &&
      other.credential == credential &&
      other.operationId == operationId;

  @override
  int get hashCode => Object.hash(credential, operationId);
}

/// Loads, saves and clears the deletion recovery record.
class AccountDeletionRecoveryStore {
  const AccountDeletionRecoveryStore({
    this.storage = const FlutterSecureAccountDeletionStorage(),
  });

  /// The injected seam. Production leaves this at the platform secure store;
  /// tests substitute an in-memory double so the store's own rules can be
  /// asserted without a platform channel.
  final AccountDeletionSecureStorage storage;

  /// The ONE key this store owns. Versioned so a future record shape can be
  /// introduced without misreading this one.
  static const String recoveryRecordKey = 'calee_account_deletion_recovery_v1';

  /// The pending record, or null when no deletion is in flight.
  ///
  /// Call this at startup. A null answer means "nothing pending"; an exception
  /// means "something is pending and this build cannot read it", which are
  /// different situations and must not be collapsed into one.
  Future<AccountDeletionRecoveryRecord?> load() async {
    final raw = await storage.read(recoveryRecordKey);
    if (raw == null || raw.trim().isEmpty) return null;

    final Object? decoded;
    try {
      decoded = jsonDecode(raw);
    } on FormatException {
      // The raw value is deliberately not quoted into the message: it holds
      // the recovery secret.
      throw const AccountDeletionRecoveryStoreException(
        'Stored deletion recovery material could not be decoded.',
      );
    }
    if (decoded is! Map<String, dynamic>) {
      throw const AccountDeletionRecoveryStoreException(
        'Stored deletion recovery material is not a record.',
      );
    }
    return AccountDeletionRecoveryRecord.fromJson(decoded);
  }

  /// Persists freshly minted material.
  ///
  /// MUST complete before the first `POST /client/v1/account-deletions` is
  /// attempted. That ordering is the whole contract: once the Hub commits the
  /// operation, this credential is the only way back to it, and material that
  /// was still in flight to the Keychain when the response was lost is material
  /// the customer does not have.
  Future<void> saveCredential(AccountDeletionRecoveryCredential credential) =>
      save(AccountDeletionRecoveryRecord(credential: credential));

  /// Records the Hub's operation id alongside the credential.
  ///
  /// Takes the credential too, so this is an upsert rather than a
  /// read-modify-write: a record that somehow went missing is restored rather
  /// than left absent, and there is no ordering in which this call can lose the
  /// credential.
  ///
  /// A failure here is NOT a failed deletion. The operation id is convenience
  /// metadata; the credential already persisted is what recovers the operation.
  Future<void> recordOperationId({
    required AccountDeletionRecoveryCredential credential,
    required String operationId,
  }) => save(
    AccountDeletionRecoveryRecord(
      credential: credential,
      operationId: operationId,
    ),
  );

  /// Writes [record], then READS IT BACK and verifies it.
  ///
  /// The read-back is not ceremony. This future completing is the signal the
  /// caller uses to decide it may now do something irreversible, so "the write
  /// silently did nothing" has to be impossible to mistake for success.
  Future<void> save(AccountDeletionRecoveryRecord record) async {
    await storage.write(recoveryRecordKey, jsonEncode(record.toJson()));

    final AccountDeletionRecoveryRecord? persisted;
    try {
      persisted = await load();
    } on AccountDeletionRecoveryStoreException {
      throw const AccountDeletionRecoveryStoreException(
        'Deletion recovery material could not be stored securely.',
      );
    }
    if (persisted != record) {
      throw const AccountDeletionRecoveryStoreException(
        'Deletion recovery material could not be stored securely.',
      );
    }
  }

  /// Removes the deletion recovery record, and NOTHING else.
  ///
  /// Only after terminal handling. It must never run because a request timed
  /// out, a socket closed, the app was killed or the outcome was unknown: the
  /// operation may well have been committed, and this record is the only way
  /// left to read it.
  Future<void> clear() => storage.delete(recoveryRecordKey);
}

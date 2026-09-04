import 'dart:convert';
import 'dart:math';

/// The deletion recovery credential, and the CSPRNG that mints it (#556).
///
/// WHY THIS EXISTS. The customer taps Delete account. The Hub commits the
/// operation. The response is lost -- flaky network, app killed, phone
/// rebooted. By the time this app asks again the Keycloak identity that would
/// have authenticated it may be quiesced, and after completion it will not
/// exist at all. So the client mints two independent random values BEFORE its
/// first POST and persists them: they are the only thing that can still read
/// the operation once ordinary authentication has stopped working.
///
/// Contract source: `calee-hub-core@c520740795205a32117d9ba047f88b0ff557aeb6`,
/// `public/lib/core_account_deletion_recovery.php` and
/// `docs/architecture/ACCOUNT_DELETION_LIFECYCLE_V1.md` section 6.

/// Draws [byteCount] bytes. Production draws from [Random.secure]; tests inject
/// a deterministic source so generation can be asserted exactly.
typedef AccountDeletionRandomBytes = List<int> Function(int byteCount);

/// One deletion recovery credential: a public handle and a private secret.
///
/// The two halves are INDEPENDENT random values, never one derived from the
/// other. The Hub stores the handle verbatim under a unique index (so a client
/// that lost the response can still find its operation) and stores only a
/// password_hash() over an HMAC pre-hash of the secret. Deriving one from the
/// other would hand an offline attacker a fast, indexable shortcut past the
/// KDF that is the whole point of the design.
class AccountDeletionRecoveryCredential {
  const AccountDeletionRecoveryCredential({
    required this.recoveryId,
    required this.recoverySecret,
  });

  /// PUBLIC opaque handle. Names exactly one operation; naming is not
  /// authorising. Must never be derived from an email, an account id or
  /// anything else about the customer -- the Hub stores it verbatim in an
  /// indexed column.
  final String recoveryId;

  /// PRIVATE. The credential that actually authorises the deletion-only status
  /// read.
  ///
  /// Never log it, never put it in an exception message, never send it in a URL
  /// or query string, and never attach it as a bearer token: no Calee route but
  /// `POST /client/v1/account-deletions/status` consults it, and presenting it
  /// as a bearer token earns an ordinary 401.
  final String recoverySecret;

  /// base64url, unpadded: `A-Z a-z 0-9 _ -`. The Hub rejects anything else.
  static final RegExp _base64UrlAlphabet = RegExp(r'^[A-Za-z0-9_-]+$');

  /// 16 random bytes -> 22 unpadded base64url characters.
  static const int recoveryIdByteLength = 16;

  /// 32 random bytes -> 43 unpadded base64url characters, which is where the
  /// Hub's floor comes from: 43 characters is the shortest base64url string
  /// that 256 bits can fit in.
  static const int recoverySecretByteLength = 32;

  static const int minRecoveryIdLength = 22;
  static const int maxRecoveryIdLength = 190;
  static const int minRecoverySecretLength = 43;
  static const int maxRecoverySecretLength = 512;

  /// The Hub's degeneracy floor (`count(array_unique(...)) < 8`). It is not an
  /// entropy estimate -- a correct one is impossible from a single sample --
  /// but it does catch the failure that matters here: an entropy source that
  /// has broken and is handing out constant bytes.
  static const int minDistinctCharacters = 8;

  /// Why [value] is unusable as a recovery handle, or null when it is fine.
  static String? recoveryIdProblem(String value) => _problem(
    value,
    minLength: minRecoveryIdLength,
    maxLength: maxRecoveryIdLength,
    label: 'recoveryId',
  );

  /// Why [value] is unusable as a recovery secret, or null when it is fine.
  ///
  /// The returned message names the FIELD and the rule, never the value.
  static String? recoverySecretProblem(String value) => _problem(
    value,
    minLength: minRecoverySecretLength,
    maxLength: maxRecoverySecretLength,
    label: 'recoverySecret',
  );

  /// Why this credential would be refused, or null when both halves are
  /// well-formed. Mirrors the Hub's own accept rules so a malformed credential
  /// is caught before anything destructive is attempted.
  String? get formatProblem =>
      recoveryIdProblem(recoveryId) ?? recoverySecretProblem(recoverySecret);

  bool get isWellFormed => formatProblem == null;

  static String? _problem(
    String value, {
    required int minLength,
    required int maxLength,
    required String label,
  }) {
    if (value.length < minLength || value.length > maxLength) {
      return '$label must be $minLength to $maxLength characters.';
    }
    if (!_base64UrlAlphabet.hasMatch(value)) {
      return '$label must be unpadded base64url.';
    }
    if (value.split('').toSet().length < minDistinctCharacters) {
      return '$label does not look randomly generated.';
    }
    return null;
  }

  /// Redacts the secret. The handle is public by design and is what correlates
  /// a support conversation with an operation, so it stays legible.
  @override
  String toString() =>
      'AccountDeletionRecoveryCredential(recoveryId: $recoveryId, '
      'recoverySecret: <redacted>)';

  @override
  bool operator ==(Object other) =>
      other is AccountDeletionRecoveryCredential &&
      other.recoveryId == recoveryId &&
      other.recoverySecret == recoverySecret;

  @override
  int get hashCode => Object.hash(recoveryId, recoverySecret);
}

/// Mints [AccountDeletionRecoveryCredential]s.
///
/// Production uses [Random.secure]. There is deliberately NO fallback to
/// `Random()`: a platform with no secure source must fail loudly rather than
/// hand a customer a guessable credential for their own deletion.
class AccountDeletionRecoveryCredentialGenerator {
  AccountDeletionRecoveryCredentialGenerator({
    AccountDeletionRandomBytes? randomBytes,
  }) : _randomBytes = randomBytes ?? _secureRandomBytes;

  final AccountDeletionRandomBytes _randomBytes;

  /// Mints a fresh credential.
  ///
  /// The handle and the secret come from TWO SEPARATE draws, so neither is a
  /// function of the other.
  ///
  /// Throws [StateError] if the entropy source returns the wrong number of
  /// bytes, or if the encoded result would not satisfy the Hub's format rules
  /// -- which is what a source stuck on a constant looks like. The message
  /// never contains the generated material.
  AccountDeletionRecoveryCredential generate() {
    final recoveryId = _encode(
      AccountDeletionRecoveryCredential.recoveryIdByteLength,
    );
    final recoverySecret = _encode(
      AccountDeletionRecoveryCredential.recoverySecretByteLength,
    );

    final credential = AccountDeletionRecoveryCredential(
      recoveryId: recoveryId,
      recoverySecret: recoverySecret,
    );
    final problem = credential.formatProblem;
    if (problem != null) {
      throw StateError(
        'Generated deletion recovery material was rejected before use: '
        '$problem',
      );
    }
    return credential;
  }

  String _encode(int byteCount) {
    final bytes = _randomBytes(byteCount);
    if (bytes.length != byteCount) {
      throw StateError(
        'Deletion recovery entropy source returned ${bytes.length} bytes, '
        'expected $byteCount.',
      );
    }
    return _unpaddedBase64Url(bytes);
  }

  /// base64url with the `=` padding removed, which is what the Hub's alphabet
  /// check accepts.
  static String _unpaddedBase64Url(List<int> bytes) {
    final encoded = base64UrlEncode(bytes);
    var end = encoded.length;
    while (end > 0 && encoded.codeUnitAt(end - 1) == 0x3D) {
      end--;
    }
    return encoded.substring(0, end);
  }

  static List<int> _secureRandomBytes(int byteCount) {
    return List<int>.generate(
      byteCount,
      (_) => _secureRandom.nextInt(256),
      growable: false,
    );
  }
}

/// Lazily created, so a platform without a secure source only throws if
/// deletion is actually attempted.
final Random _secureRandom = Random.secure();

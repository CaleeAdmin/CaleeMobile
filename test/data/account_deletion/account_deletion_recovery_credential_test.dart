import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';

import 'package:calee_mobile/data/account_deletion/account_deletion_recovery_credential.dart';

/// The Hub's accepted alphabet: unpadded base64url.
final RegExp base64UrlAlphabet = RegExp(r'^[A-Za-z0-9_-]+$');

/// Decodes an unpadded base64url string back to bytes, so a test can prove
/// WHICH draw a value came from rather than merely that it looks random.
List<int> decodeUnpaddedBase64Url(String value) {
  final padding = (4 - value.length % 4) % 4;
  return base64Url.decode(value + '=' * padding);
}

void main() {
  group('AccountDeletionRecoveryCredentialGenerator', () {
    test('mints a 22-character recoveryId from 16 bytes', () {
      final credential = AccountDeletionRecoveryCredentialGenerator(
        randomBytes: countingBytes(),
      ).generate();

      expect(
        AccountDeletionRecoveryCredential.recoveryIdByteLength,
        16,
        reason: 'the Hub sizes its 22-character floor from 16 bytes',
      );
      expect(credential.recoveryId, hasLength(22));
      expect(decodeUnpaddedBase64Url(credential.recoveryId), hasLength(16));
    });

    test('mints a 43-character recoverySecret from 32 bytes', () {
      final credential = AccountDeletionRecoveryCredentialGenerator(
        randomBytes: countingBytes(),
      ).generate();

      expect(
        AccountDeletionRecoveryCredential.recoverySecretByteLength,
        32,
        reason: '43 characters is the shortest base64url 256 bits fits in',
      );
      expect(credential.recoverySecret, hasLength(43));
      expect(decodeUnpaddedBase64Url(credential.recoverySecret), hasLength(32));
    });

    test('both halves use only the permitted base64url alphabet', () {
      // Many draws, because the offending characters ('+', '/') only appear for
      // particular byte values and a single sample can miss them.
      for (var i = 0; i < 200; i++) {
        final credential = AccountDeletionRecoveryCredentialGenerator()
            .generate();
        expect(base64UrlAlphabet.hasMatch(credential.recoveryId), isTrue);
        expect(base64UrlAlphabet.hasMatch(credential.recoverySecret), isTrue);
      }
    });

    test('neither half carries base64 padding', () {
      for (var i = 0; i < 200; i++) {
        final credential = AccountDeletionRecoveryCredentialGenerator()
            .generate();
        expect(credential.recoveryId, isNot(contains('=')));
        expect(credential.recoverySecret, isNot(contains('=')));
      }
    });

    test('the id and the secret come from two separate draws', () {
      final requested = <int>[];
      final generator = AccountDeletionRecoveryCredentialGenerator(
        randomBytes: countingBytes(onRequest: requested.add),
      );

      final credential = generator.generate();

      // Two draws, of the two documented sizes, in order.
      expect(requested, [16, 32]);

      // And the bytes are DISJOINT: the counting source hands out 0,1,2,... so
      // the secret starting at 16 proves it is not a re-encoding, a slice or
      // any other derivation of the handle.
      expect(
        decodeUnpaddedBase64Url(credential.recoveryId),
        List<int>.generate(16, (i) => i),
      );
      expect(
        decodeUnpaddedBase64Url(credential.recoverySecret),
        List<int>.generate(32, (i) => (16 + i) % 256),
      );
    });

    test('the secret is not derivable from the handle', () {
      final credential = AccountDeletionRecoveryCredentialGenerator()
          .generate();

      expect(credential.recoverySecret, isNot(credential.recoveryId));
      expect(
        credential.recoverySecret,
        isNot(startsWith(credential.recoveryId)),
      );
      expect(credential.recoveryId, isNot(contains(credential.recoverySecret)));
    });

    test('repeated secure generation never repeats a pair', () {
      // Uniqueness of independently drawn values -- deliberately NOT a
      // statistical entropy estimate, which is not possible from samples.
      final generator = AccountDeletionRecoveryCredentialGenerator();
      final ids = <String>{};
      final secrets = <String>{};

      for (var i = 0; i < 250; i++) {
        final credential = generator.generate();
        expect(ids.add(credential.recoveryId), isTrue);
        expect(secrets.add(credential.recoverySecret), isTrue);
      }
    });

    test('a broken entropy source is refused, not shipped', () {
      // A source stuck on a constant encodes to 'AAAA...', which the Hub's
      // degeneracy floor rejects. Better to fail here than to hand a customer a
      // guessable credential for their own deletion.
      final generator = AccountDeletionRecoveryCredentialGenerator(
        randomBytes: (count) => List<int>.filled(count, 0),
      );

      expect(generator.generate, throwsA(isA<StateError>()));
    });

    test('a short entropy draw is refused', () {
      final generator = AccountDeletionRecoveryCredentialGenerator(
        randomBytes: (count) => List<int>.generate(count - 1, (i) => i + 1),
      );

      expect(generator.generate, throwsA(isA<StateError>()));
    });
  });

  group('AccountDeletionRecoveryCredential', () {
    test('toString redacts the secret and keeps the public handle', () {
      const credential = AccountDeletionRecoveryCredential(
        recoveryId: 'AbCdEfGhIjKlMnOpQrStUv',
        recoverySecret: 'ZyXwVuTsRqPoNmLkJiHgFeDcBa9876543210_-AbCdE',
      );

      final rendered = credential.toString();

      expect(rendered, isNot(contains(credential.recoverySecret)));
      expect(rendered, contains('<redacted>'));
      expect(rendered, contains(credential.recoveryId));
    });

    test('accepts well-formed material', () {
      final credential = AccountDeletionRecoveryCredentialGenerator()
          .generate();

      expect(credential.formatProblem, isNull);
      expect(credential.isWellFormed, isTrue);
    });

    test('rejects material the Hub would reject', () {
      // Too short.
      expect(
        AccountDeletionRecoveryCredential.recoveryIdProblem('AbCdEfGhIj'),
        isNotNull,
      );
      expect(
        AccountDeletionRecoveryCredential.recoverySecretProblem(
          'AbCdEfGhIjKlMnOpQrStUv',
        ),
        isNotNull,
      );
      // Padded / standard-base64 characters.
      expect(
        AccountDeletionRecoveryCredential.recoveryIdProblem(
          'AbCdEfGhIjKlMnOpQrStU=',
        ),
        isNotNull,
      );
      expect(
        AccountDeletionRecoveryCredential.recoveryIdProblem(
          'AbCdEfGhIjKlMnOpQrSt+/',
        ),
        isNotNull,
      );
      // Long enough and correctly encoded, but degenerate.
      expect(
        AccountDeletionRecoveryCredential.recoveryIdProblem(
          'AAAAAAAAAAAAAAAAAAAAAA',
        ),
        isNotNull,
      );
    });

    test('a rejection message never quotes the value', () {
      const secret = 'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA';

      final problem = AccountDeletionRecoveryCredential.recoverySecretProblem(
        secret,
      );

      expect(problem, isNotNull);
      expect(problem, isNot(contains(secret)));
    });
  });
}

/// A deterministic byte source handing out 0, 1, 2, ... across calls, so a test
/// can tell one draw from the next.
AccountDeletionRandomBytes countingBytes({
  void Function(int count)? onRequest,
}) {
  var next = 0;
  return (int count) {
    onRequest?.call(count);
    return List<int>.generate(count, (_) => next++ % 256, growable: false);
  };
}

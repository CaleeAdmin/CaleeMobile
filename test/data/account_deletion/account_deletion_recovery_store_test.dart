import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:calee_mobile/data/account_deletion/account_deletion_recovery_credential.dart';
import 'package:calee_mobile/data/account_deletion/account_deletion_recovery_store.dart';

/// Obviously-fake, correctly-shaped material.
const AccountDeletionRecoveryCredential testCredential =
    AccountDeletionRecoveryCredential(
      recoveryId: 'Rk1tZXN0Q3JlZGVudGlhbA',
      recoverySecret: 'U2VjcmV0Rm9yVGVzdHNPbmx5Tm90QVJlYWxDcmVkZW50',
    );

/// An in-memory stand-in for the platform secure store.
///
/// The seam exists so the store's OWN rules are testable; production is still
/// [FlutterSecureAccountDeletionStorage] and nothing here weakens it.
class FakeSecureStorage implements AccountDeletionSecureStorage {
  FakeSecureStorage([Map<String, String>? seed]) : values = {...?seed};

  final Map<String, String> values;
  final List<String> deleted = <String>[];

  /// Simulates a write that silently does not stick.
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
    deleted.add(key);
    values.remove(key);
  }
}

void main() {
  group('AccountDeletionRecoveryStore', () {
    test('round-trips freshly minted material', () async {
      final storage = FakeSecureStorage();
      final store = AccountDeletionRecoveryStore(storage: storage);

      await store.saveCredential(testCredential);
      final loaded = await store.load();

      expect(loaded, isNotNull);
      expect(loaded!.credential, testCredential);
      expect(loaded.credential.recoveryId, testCredential.recoveryId);
      expect(loaded.credential.recoverySecret, testCredential.recoverySecret);
      expect(loaded.operationId, isNull);
    });

    test('survives a store rebuild, which is what an app restart is', () async {
      final storage = FakeSecureStorage();

      await AccountDeletionRecoveryStore(
        storage: storage,
      ).saveCredential(testCredential);

      // A second store over the same platform storage: the credential is still
      // there before any operation id was ever received.
      final afterRestart = await AccountDeletionRecoveryStore(
        storage: storage,
      ).load();

      expect(afterRestart?.credential, testCredential);
    });

    test('records the operation id without losing the credential', () async {
      final storage = FakeSecureStorage();
      final store = AccountDeletionRecoveryStore(storage: storage);

      await store.saveCredential(testCredential);
      await store.recordOperationId(
        credential: testCredential,
        operationId: 'op_01HZY',
      );

      final loaded = await store.load();
      expect(loaded!.operationId, 'op_01HZY');
      expect(loaded.credential, testCredential);
    });

    test('load returns null when nothing is pending', () async {
      final store = AccountDeletionRecoveryStore(storage: FakeSecureStorage());

      expect(await store.load(), isNull);
    });

    test('clear removes the deletion record and NOTHING else', () async {
      final storage = FakeSecureStorage({
        'calee_hub_access_token': 'an-access-token',
        'calee_hub_refresh_token': 'a-refresh-token',
        'some_other_feature_key': 'untouched',
      });
      final store = AccountDeletionRecoveryStore(storage: storage);
      await store.saveCredential(testCredential);

      await store.clear();

      expect(await store.load(), isNull);
      expect(storage.deleted, [AccountDeletionRecoveryStore.recoveryRecordKey]);
      expect(storage.values.keys, {
        'calee_hub_access_token',
        'calee_hub_refresh_token',
        'some_other_feature_key',
      });
    });

    test('the deletion key is its own, never a session token key', () async {
      // Session tokens must stay removable while this record survives, so the
      // two must not share a key.
      expect(
        AccountDeletionRecoveryStore.recoveryRecordKey,
        isNot('calee_hub_access_token'),
      );
      expect(
        AccountDeletionRecoveryStore.recoveryRecordKey,
        isNot('calee_hub_refresh_token'),
      );
    });

    test('a write that does not stick is reported, not assumed', () async {
      // This future completing is what a caller uses to decide it may now do
      // something irreversible.
      final storage = FakeSecureStorage()..dropWrites = true;
      final store = AccountDeletionRecoveryStore(storage: storage);

      await expectLater(
        store.saveCredential(testCredential),
        throwsA(isA<AccountDeletionRecoveryStoreException>()),
      );
    });

    test(
      'present-but-unreadable material is raised, not silently empty',
      () async {
        // "Nothing pending" and "something pending this build cannot read" are
        // different situations, and collapsing them would quietly strand a
        // customer mid-deletion.
        final storage = FakeSecureStorage({
          AccountDeletionRecoveryStore.recoveryRecordKey: 'not json at all',
        });

        await expectLater(
          AccountDeletionRecoveryStore(storage: storage).load(),
          throwsA(isA<AccountDeletionRecoveryStoreException>()),
        );
        expect(
          storage.deleted,
          isEmpty,
          reason: 'unreadable material must never be auto-deleted',
        );
      },
    );

    test('an incomplete record is raised rather than half-loaded', () async {
      final storage = FakeSecureStorage({
        AccountDeletionRecoveryStore.recoveryRecordKey: jsonEncode({
          'recoveryId': testCredential.recoveryId,
        }),
      });

      await expectLater(
        AccountDeletionRecoveryStore(storage: storage).load(),
        throwsA(isA<AccountDeletionRecoveryStoreException>()),
      );
    });

    test('an exception never quotes the stored secret', () async {
      final storage = FakeSecureStorage({
        AccountDeletionRecoveryStore.recoveryRecordKey:
            '{"recoverySecret":"${testCredential.recoverySecret}"',
      });

      try {
        await AccountDeletionRecoveryStore(storage: storage).load();
        fail('expected an AccountDeletionRecoveryStoreException');
      } on AccountDeletionRecoveryStoreException catch (error) {
        expect(
          error.toString(),
          isNot(contains(testCredential.recoverySecret)),
        );
      }
    });
  });

  group('what is persisted', () {
    test(
      'the record holds exactly the recovery material, nothing more',
      () async {
        final storage = FakeSecureStorage();
        await AccountDeletionRecoveryStore(storage: storage).recordOperationId(
          credential: testCredential,
          operationId: 'op_01HZY',
        );

        final stored =
            jsonDecode(
                  storage.values[AccountDeletionRecoveryStore
                      .recoveryRecordKey]!,
                )
                as Map<String, dynamic>;

        expect(stored.keys.toSet(), {
          'recoveryId',
          'recoverySecret',
          'operationId',
        });
      },
    );

    test(
      'no password, session token, email or manifest is ever stored',
      () async {
        final storage = FakeSecureStorage();
        await AccountDeletionRecoveryStore(storage: storage).recordOperationId(
          credential: testCredential,
          operationId: 'op_01HZY',
        );

        final blob = storage
            .values[AccountDeletionRecoveryStore.recoveryRecordKey]!
            .toLowerCase();

        for (final forbidden in [
          'password',
          'accesstoken',
          'refreshtoken',
          'email',
          'displayname',
          'manifest',
        ]) {
          expect(blob, isNot(contains(forbidden)), reason: forbidden);
        }
      },
    );

    test('the record model has no password field at all', () {
      const record = AccountDeletionRecoveryRecord(credential: testCredential);

      expect(record.toJson().keys.toSet(), {'recoveryId', 'recoverySecret'});
    });

    test('toString redacts the secret', () {
      const record = AccountDeletionRecoveryRecord(
        credential: testCredential,
        operationId: 'op_01HZY',
      );

      expect(record.toString(), isNot(contains(testCredential.recoverySecret)));
      expect(record.toString(), contains('<redacted>'));
    });
  });

  group('source guarantees', () {
    // Comment lines are stripped so the rules below can be EXPLAINED in the
    // source without the explanation satisfying its own guard.
    final source =
        File('lib/data/account_deletion/account_deletion_recovery_store.dart')
            .readAsLinesSync()
            .where((line) => !line.trimLeft().startsWith('//'))
            .join('\n');

    test('never wipes storage globally', () {
      // deleteAll() would sign the customer out of the account they are in the
      // middle of deleting, and take the recovery credential with it.
      expect(source, isNot(contains('deleteAll')));
      expect(source, isNot(contains('SharedPreferences')));
    });

    test('deletes exactly one key, its own', () {
      expect(source, contains("'calee_account_deletion_recovery_v1'"));
      expect(source, contains('storage.delete(recoveryRecordKey)'));
      expect(source, isNot(contains("'calee_hub_access_token'")));
      expect(source, isNot(contains("'calee_hub_refresh_token'")));
    });

    test('stores no password field', () {
      expect(source, isNot(contains("'password'")));
      expect(source, isNot(contains('accessToken')));
      expect(source, isNot(contains('refreshToken')));
    });

    test('production storage is the platform secure store', () {
      expect(source, contains('package:flutter_secure_storage'));
      expect(source, contains('FlutterSecureStorage()'));
    });
  });
}

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:calee_mobile/data/account_deletion/account_deletion_failure.dart';
import 'package:calee_mobile/data/account_deletion/account_deletion_recovery_credential.dart';
import 'package:calee_mobile/data/account_deletion/account_deletion_recovery_store.dart';
import 'package:calee_mobile/data/api/calee_hub_client.dart';

/// The whole reason the recovery contract exists, driven end to end.
///
/// The customer taps Delete account. The Hub COMMITS the operation. The
/// response is lost. The app restarts. Ordinary authentication no longer works.
/// The persisted credential must still find the operation.

/// In-memory stand-in for the platform secure store, deliberately shared across
/// two [AccountDeletionRecoveryStore] instances so an app restart is modelled
/// honestly: the process object goes, the stored bytes do not.
class FakeSecureStorage implements AccountDeletionSecureStorage {
  final Map<String, String> values = <String, String>{};
  final List<String> deleted = <String>[];

  @override
  Future<String?> read(String key) async => values[key];

  @override
  Future<void> write(String key, String value) async => values[key] = value;

  @override
  Future<void> delete(String key) async {
    deleted.add(key);
    values.remove(key);
  }
}

void main() {
  test('a committed request survives a lost response and an app restart', () async {
    final storage = FakeSecureStorage();
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));

    final paths = <String>[];
    final statusAuthorization = <String?>[];
    Map<String, dynamic>? statusBody;

    server.listen((req) async {
      paths.add(req.uri.path);
      final raw = await utf8.decodeStream(req);

      if (req.uri.path == '/client/v1/account-deletions') {
        // The Hub has committed the operation. The customer's phone never
        // learns that: the connection dies before any header arrives.
        final socket = await req.response.detachSocket(writeHeaders: false);
        socket.destroy();
        return;
      }

      statusAuthorization.add(
        req.headers.value(HttpHeaders.authorizationHeader),
      );
      statusBody = jsonDecode(raw) as Map<String, dynamic>;
      req.response.statusCode = HttpStatus.ok;
      req.response.headers.contentType = ContentType.json;
      req.response.write(
        jsonEncode({
          'data': {
            'operationId': 'op_01HZY',
            'state': 'quiescing',
            'isTerminal': false,
            'reasonCode': null,
            'restorable': true,
            'requestedAt': '2026-09-01T02:03:04.123456Z',
            'completedAt': null,
            'restoredAt': null,
            'completionWindowMessage':
                'Your deletion request has been received and is being processed.',
          },
          'meta': {'apiVersion': 'client/v1'},
        }),
      );
      await req.response.close();
    });

    final baseUri = Uri.parse('http://127.0.0.1:${server.port}');

    // 1-2. Mint, then PERSIST -- before anything destructive is attempted.
    final credential = AccountDeletionRecoveryCredentialGenerator().generate();
    await AccountDeletionRecoveryStore(
      storage: storage,
    ).saveCredential(credential);
    expect(
      storage.values[AccountDeletionRecoveryStore.recoveryRecordKey],
      isNotNull,
      reason: 'the credential must be durable BEFORE the first POST',
    );

    // 3-4. Submit. The Hub commits; the answer never arrives.
    Object? thrown;
    try {
      await CaleeHubClient(baseUri: baseUri).requestAccountDeletion(
        accessToken: 'hub-access-token',
        password: 'the-customers-password',
        recoveryCredential: credential,
      );
      fail('expected the lost response to surface as an error');
    } catch (error) {
      thrown = error;
    }

    final failure = AccountDeletionRequestFailure.fromError(thrown);
    expect(failure.kind, AccountDeletionRequestFailureKind.outcomeUnknown);
    expect(
      failure.isPreAcceptance,
      isFalse,
      reason: 'a lost response is never evidence that nothing was created',
    );
    expect(failure.requiresFreshRecoveryMaterial, isFalse);
    expect(failure.isRetryableWithSameCredential, isTrue);

    // 5. NOTHING was deleted. This is the rule the whole contract rests on.
    expect(storage.deleted, isEmpty);
    expect(
      storage.values[AccountDeletionRecoveryStore.recoveryRecordKey],
      isNotNull,
    );

    // 6. The app restarts: a brand new store over the same secure storage.
    final afterRestart = await AccountDeletionRecoveryStore(
      storage: storage,
    ).load();
    expect(afterRestart, isNotNull);
    expect(afterRestart!.credential, credential);

    // 7. Ordinary authentication may be gone by now, so the status read carries
    //    no bearer token -- only the recovered credential.
    final status = await CaleeHubClient(
      baseUri: baseUri,
    ).accountDeletionStatus(recoveryCredential: afterRestart.credential);

    expect(status.operationId, 'op_01HZY');
    expect(status.state, 'quiescing');
    expect(status.isProcessing, isTrue);
    expect(status.isCompleted, isFalse);

    expect(paths, [
      '/client/v1/account-deletions',
      '/client/v1/account-deletions/status',
    ]);
    expect(statusAuthorization, [isNull]);
    expect(statusBody, {
      'recoveryId': credential.recoveryId,
      'recoverySecret': credential.recoverySecret,
    });

    // The SAME material recovered the SAME operation. No second credential was
    // minted, and no second deletion operation exists.
    expect(afterRestart.credential.recoveryId, credential.recoveryId);
  });

  test(
    'a replayed request recovers the operation instead of creating another',
    () async {
      // The other half of the lost-response contract: when the app can still
      // authenticate, re-submitting the identical request is safe. The Hub
      // answers 200 with created: false.
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));

      final bodies = <Map<String, dynamic>>[];
      server.listen((req) async {
        bodies.add(
          jsonDecode(await utf8.decodeStream(req)) as Map<String, dynamic>,
        );
        req.response.statusCode = HttpStatus.ok;
        req.response.headers.contentType = ContentType.json;
        req.response.write(
          jsonEncode({
            'data': {
              'operationId': 'op_01HZY',
              'state': 'requested',
              'isTerminal': false,
              'reasonCode': null,
              'restorable': true,
              'requestedAt': '2026-09-01T02:03:04.123456Z',
              'completedAt': null,
              'restoredAt': null,
              'completionWindowMessage':
                  'Your deletion request has been received and is being processed.',
              'created': false,
              'recoveryCredentialMatched': true,
            },
            'meta': {'apiVersion': 'client/v1'},
          }),
        );
        await req.response.close();
      });

      final credential = AccountDeletionRecoveryCredentialGenerator()
          .generate();
      final result =
          await CaleeHubClient(
            baseUri: Uri.parse('http://127.0.0.1:${server.port}'),
          ).requestAccountDeletion(
            accessToken: 'hub-access-token',
            password: 'the-customers-password',
            recoveryCredential: credential,
          );

      expect(
        result.created,
        isFalse,
        reason: 'a replay is not a second deletion operation',
      );
      expect(result.recoveryCredentialMatched, isTrue);
      expect(result.status.operationId, 'op_01HZY');
      expect(bodies.single['recoveryId'], credential.recoveryId);
    },
  );
}

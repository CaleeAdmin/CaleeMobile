// Unit tests for the Account Deletion V1 lifecycle controller (#556).
//
// The properties asserted here are the ones a customer's account depends on:
// material is durable before anything irreversible is sent; only a PROVEN
// pre-acceptance refusal is treated as "nothing happened"; a lost response
// never mints a second credential; and `completed` is the only success.

import 'dart:convert';
import 'dart:io';

import 'package:calee_mobile/data/account_deletion/account_deletion_failure.dart';
import 'package:calee_mobile/data/account_deletion/account_deletion_recovery_credential.dart';
import 'package:calee_mobile/data/account_deletion/account_deletion_recovery_store.dart';
import 'package:calee_mobile/data/api/calee_hub_client.dart';
import 'package:calee_mobile/features/account_deletion/account_deletion_controller.dart';
import 'package:flutter_test/flutter_test.dart';

import 'account_deletion_fixtures.dart';

void main() {
  group('durability before the first request', () {
    test(
      'persists and verifies recovery material BEFORE the first POST',
      () async {
        String? recordAtPostTime;
        final hub = FakeDeletionHubClient(
          onRequest: (_) async => acceptedResult(),
        );
        final fixture = buildController(hub: hub);
        hub.beforeRequestAnswered = () {
          // Read the store as it stood at the moment the irreversible call was
          // made -- not afterwards, when a late write would look identical.
          recordAtPostTime = fixture.storage.rawRecoveryRecord;
        };

        await fixture.controller.submit(
          accessToken: 'tok',
          password: 'hunter2',
          accountId: 'acct_1',
        );

        expect(
          recordAtPostTime,
          isNotNull,
          reason: 'the credential must be durable before the POST, not after',
        );
        final decoded = jsonDecode(recordAtPostTime!) as Map<String, dynamic>;
        expect(decoded['recoveryId'], hub.requestCredentials.single.recoveryId);
        expect(
          decoded['recoverySecret'],
          hub.requestCredentials.single.recoverySecret,
        );
      },
    );

    test(
      'refuses without sending anything when the write cannot be verified',
      () async {
        final hub = FakeDeletionHubClient(
          onRequest: (_) async => acceptedResult(),
        );
        final storage = FakeDeletionSecureStorage()..dropWrites = true;
        final fixture = buildController(hub: hub, storage: storage);

        await fixture.controller.submit(
          accessToken: 'tok',
          password: 'hunter2',
          accountId: 'acct_1',
        );

        expect(hub.requestCount, 0, reason: 'nothing may be sent');
        expect(fixture.controller.phase, AccountDeletionPhase.refused);
        expect(
          fixture.controller.refusalReason,
          AccountDeletionRefusalReason.recoveryMaterialUnavailable,
        );
        expect(fixture.session.wasEnded, isFalse);
      },
    );

    test(
      'reuses stored material instead of minting a second credential',
      () async {
        final hub = FakeDeletionHubClient(
          onRequest: (_) async => acceptedResult(),
        );
        final storage = FakeDeletionSecureStorage({
          AccountDeletionRecoveryStore.recoveryRecordKey: jsonEncode({
            'recoveryId': storedCredential.recoveryId,
            'recoverySecret': storedCredential.recoverySecret,
          }),
        });
        final fixture = buildController(hub: hub, storage: storage);

        await fixture.controller.submit(
          accessToken: 'tok',
          password: 'hunter2',
          accountId: 'acct_1',
        );

        expect(hub.requestCredentials.single, storedCredential);
      },
    );
  });

  group('pre-acceptance refusals keep the customer signed in', () {
    Future<void> expectStaysSignedIn(
      String code,
      int statusCode,
      AccountDeletionRefusalReason expected,
    ) async {
      final hub = FakeDeletionHubClient(
        onRequest: (_) async => throw CaleeHubException(
          statusCode: statusCode,
          code: code,
          message: 'test',
        ),
      );
      final fixture = buildController(hub: hub);

      await fixture.controller.submit(
        accessToken: 'tok',
        password: 'wrong',
        accountId: 'acct_1',
      );

      expect(fixture.controller.phase, AccountDeletionPhase.refused);
      expect(fixture.controller.refusalReason, expected);
      expect(
        fixture.controller.ownsAppSurface,
        isFalse,
        reason: 'ordinary signed-in UX must continue',
      );
      expect(fixture.session.wasEnded, isFalse);
      expect(
        fixture.storage.holdsRecoveryRecord,
        isTrue,
        reason: 'well-formed unused material is not rotated on a refusal',
      );
      expect(hub.statusCount, 0, reason: 'nothing exists to resolve');
    }

    test('rejected re-authentication', () async {
      await expectStaysSignedIn(
        'DELETION_REAUTH_REQUIRED',
        401,
        AccountDeletionRefusalReason.reauthenticationRejected,
      );
    });

    test('managed account offboarding', () async {
      await expectStaysSignedIn(
        'MANAGED_ACCOUNT_OFFBOARDING_REQUIRED',
        409,
        AccountDeletionRefusalReason.managedAccount,
      );
    });

    test('re-authentication unsupported', () async {
      await expectStaysSignedIn(
        'DELETION_REAUTH_UNSUPPORTED',
        409,
        AccountDeletionRefusalReason.reauthenticationUnsupported,
      );
    });

    test('an expired bearer token', () async {
      await expectStaysSignedIn(
        'UNAUTHORIZED',
        401,
        AccountDeletionRefusalReason.sessionExpired,
      );
    });

    test('a refusal can be dismissed back to ordinary UX', () async {
      final hub = FakeDeletionHubClient(
        onRequest: (_) async => throw const CaleeHubException(
          statusCode: 401,
          code: 'DELETION_REAUTH_REQUIRED',
          message: 'test',
        ),
      );
      final fixture = buildController(hub: hub);
      await fixture.controller.submit(
        accessToken: 'tok',
        password: 'wrong',
        accountId: 'acct_1',
      );

      fixture.controller.dismissRefusal();

      expect(fixture.controller.phase, AccountDeletionPhase.inactive);
    });
  });

  group('acceptance', () {
    test('ends ordinary signed-in UX and starts tracking', () async {
      final hub = FakeDeletionHubClient(
        onRequest: (_) async => acceptedResult(state: 'quiescing'),
      );
      final fixture = buildController(hub: hub);

      await fixture.controller.submit(
        accessToken: 'tok',
        password: 'hunter2',
        accountId: 'acct_1',
      );

      expect(fixture.controller.phase, AccountDeletionPhase.tracking);
      expect(fixture.controller.ownsAppSurface, isTrue);
      expect(fixture.session.calls, 1);
      expect(fixture.targets.accountId, 'acct_1');
      expect(
        fixture.controller.isDeletionCompleted,
        isFalse,
        reason: 'an accepted request is not a completed deletion',
      );
      expect(
        fixture.storage.holdsRecoveryRecord,
        isTrue,
        reason: 'ending the session must not take the recovery record',
      );
    });

    test('records the Hub operation id alongside the credential', () async {
      final hub = FakeDeletionHubClient(
        onRequest: (_) async => acceptedResult(),
      );
      final fixture = buildController(hub: hub);

      await fixture.controller.submit(
        accessToken: 'tok',
        password: 'hunter2',
        accountId: 'acct_1',
      );

      final stored =
          jsonDecode(fixture.storage.rawRecoveryRecord!)
              as Map<String, dynamic>;
      expect(stored['operationId'], 'op_TEST');
    });

    test('a replay is not a second deletion', () async {
      final hub = FakeDeletionHubClient(
        onRequest: (_) async => acceptedResult(created: false),
      );
      final fixture = buildController(hub: hub);

      await fixture.controller.submit(
        accessToken: 'tok',
        password: 'hunter2',
        accountId: 'acct_1',
      );

      expect(fixture.controller.phase, AccountDeletionPhase.tracking);
      expect(hub.requestCount, 1);
    });

    test('a credential the Hub did not match becomes a bounded support state, '
        'not a silent rotation', () async {
      final hub = FakeDeletionHubClient(
        onRequest: (_) async =>
            acceptedResult(recoveryCredentialMatched: false),
      );
      final fixture = buildController(hub: hub);
      final before = fixture.storage.rawRecoveryRecord;

      await fixture.controller.submit(
        accessToken: 'tok',
        password: 'hunter2',
        accountId: 'acct_1',
      );

      expect(fixture.controller.phase, AccountDeletionPhase.unrecoverable);
      expect(fixture.controller.recoveryCredentialMismatch, isTrue);
      expect(fixture.controller.ownsAppSurface, isTrue);
      expect(
        fixture.session.wasEnded,
        isTrue,
        reason: 'the operation was accepted, so ordinary UX still ends',
      );
      expect(
        hub.requestCount,
        1,
        reason: 'no second request is attempted to rebind the credential',
      );
      expect(before, isNot(equals(fixture.storage.rawRecoveryRecord)));
      expect(
        fixture.controller.recoveryIdForSupport,
        hub.requestCredentials.single.recoveryId,
        reason: 'the PUBLIC handle is what a support conversation quotes',
      );
    });
  });

  group('unknown outcomes', () {
    test(
      'a dropped connection preserves the credential and resolves by status',
      () async {
        final minted = <AccountDeletionRecoveryCredential>[];
        final hub = FakeDeletionHubClient(
          onRequest: (_) async => throw const HttpException('closed'),
          onStatus: (_) async => throw const CaleeHubException(
            statusCode: 404,
            code: 'DELETION_OPERATION_NOT_FOUND',
            message: 'test',
          ),
        );
        final fixture = buildController(hub: hub);

        await fixture.controller.submit(
          accessToken: 'tok',
          password: 'hunter2',
          accountId: 'acct_1',
        );
        minted.addAll(hub.requestCredentials);

        expect(fixture.controller.phase, AccountDeletionPhase.retryable);
        expect(
          fixture.controller.requestFailure!.isPreAcceptance,
          isFalse,
          reason: 'a dropped socket is never proof that nothing happened',
        );
        expect(
          hub.statusCount,
          1,
          reason: 'the recovery-only route is how an unknown outcome resolves',
        );
        expect(hub.statusCredentials.single, minted.single);
        expect(fixture.storage.holdsRecoveryRecord, isTrue);
        expect(
          fixture.storage.deletedKeys,
          isEmpty,
          reason: 'a lost response must never discard recovery material',
        );
      },
    );

    test(
      'a 503 retries with the SAME credential and never mints a second',
      () async {
        final hub = FakeDeletionHubClient(
          onRequest: (index) async {
            if (index == 0) {
              throw const CaleeHubException(
                statusCode: 503,
                code: 'DELETION_UNAVAILABLE',
                message: 'test',
              );
            }
            return acceptedResult();
          },
          onStatus: (_) async => throw const CaleeHubException(
            statusCode: 404,
            code: 'DELETION_OPERATION_NOT_FOUND',
            message: 'test',
          ),
        );
        final fixture = buildController(hub: hub);

        await fixture.controller.submit(
          accessToken: 'tok',
          password: 'hunter2',
          accountId: 'acct_1',
        );
        expect(fixture.controller.phase, AccountDeletionPhase.retryable);

        await fixture.controller.submit(
          accessToken: 'tok',
          password: 'hunter2',
          accountId: 'acct_1',
        );

        expect(hub.requestCount, 2);
        expect(
          hub.requestCredentials[0],
          hub.requestCredentials[1],
          reason: 'the idempotent retry is the SAME credential',
        );
        expect(fixture.controller.phase, AccountDeletionPhase.tracking);
      },
    );

    test('a lost response whose operation exists becomes tracking', () async {
      final hub = FakeDeletionHubClient(
        onRequest: (_) async => throw const CaleeHubException(
          statusCode: 0,
          code: 'DELETION_RESPONSE_MALFORMED',
          message: 'test',
        ),
        onStatus: (_) async => statusFor('deleting'),
      );
      final fixture = buildController(hub: hub);

      await fixture.controller.submit(
        accessToken: 'tok',
        password: 'hunter2',
        accountId: 'acct_1',
      );

      expect(fixture.controller.phase, AccountDeletionPhase.tracking);
      expect(fixture.controller.ownsAppSurface, isTrue);
      expect(fixture.session.wasEnded, isTrue);
      expect(fixture.targets.accountId, 'acct_1');
    });

    test(
      'leaving the retry falls closed to the recovery-only surface',
      () async {
        final hub = FakeDeletionHubClient(
          onRequest: (_) async => throw const HttpException('closed'),
          onStatus: (_) async => throw const CaleeHubException(
            statusCode: 500,
            code: 'SERVER_ERROR',
            message: 'test',
          ),
        );
        final fixture = buildController(hub: hub);
        await fixture.controller.submit(
          accessToken: 'tok',
          password: 'hunter2',
          accountId: 'acct_1',
        );

        await fixture.controller.leaveRetry();

        expect(fixture.controller.phase, AccountDeletionPhase.unresolved);
        expect(fixture.controller.ownsAppSurface, isTrue);
        expect(
          fixture.session.wasEnded,
          isTrue,
          reason: 'an unresolved outcome must not keep ordinary Calee open',
        );
        expect(fixture.storage.holdsRecoveryRecord, isTrue);
      },
    );

    test(
      'the recovery-material conflict is the ONE case that mints fresh material',
      () async {
        final hub = FakeDeletionHubClient(
          onRequest: (_) async => throw const CaleeHubException(
            statusCode: 409,
            code: 'DELETION_RECOVERY_MATERIAL_CONFLICT',
            message: 'test',
          ),
        );
        final storage = FakeDeletionSecureStorage({
          AccountDeletionRecoveryStore.recoveryRecordKey: jsonEncode({
            'recoveryId': storedCredential.recoveryId,
            'recoverySecret': storedCredential.recoverySecret,
          }),
        });
        final fixture = buildController(hub: hub, storage: storage);

        await fixture.controller.submit(
          accessToken: 'tok',
          password: 'hunter2',
          accountId: 'acct_1',
        );

        expect(fixture.controller.phase, AccountDeletionPhase.retryable);
        expect(
          fixture.controller.requestFailure!.requiresFreshRecoveryMaterial,
          isTrue,
        );
        final replacement =
            jsonDecode(storage.rawRecoveryRecord!) as Map<String, dynamic>;
        expect(
          replacement['recoveryId'],
          isNot(storedCredential.recoveryId),
          reason: 'the conflicting handle names another account\'s operation',
        );
        expect(
          hub.requestCount,
          1,
          reason: 'nothing destructive is replayed behind the customer',
        );
      },
    );
  });

  group('cold launch', () {
    test('no recovery material leaves ordinary startup alone', () async {
      final hub = FakeDeletionHubClient();
      final fixture = buildController(hub: hub);

      await fixture.controller.restore();

      expect(fixture.controller.phase, AccountDeletionPhase.inactive);
      expect(fixture.controller.ownsAppSurface, isFalse);
      expect(fixture.session.wasEnded, isFalse);
      expect(hub.statusCount, 0);
    });

    test(
      'a stored credential restores the deletion path and ends ordinary UX',
      () async {
        final hub = FakeDeletionHubClient(
          onStatus: (_) async => statusFor('quiescing'),
        );
        final storage = FakeDeletionSecureStorage({
          AccountDeletionRecoveryStore.recoveryRecordKey: jsonEncode({
            'recoveryId': storedCredential.recoveryId,
            'recoverySecret': storedCredential.recoverySecret,
          }),
        });
        final fixture = buildController(hub: hub, storage: storage);

        await fixture.controller.restore();

        expect(fixture.controller.phase, AccountDeletionPhase.unresolved);
        expect(fixture.controller.ownsAppSurface, isTrue);
        expect(fixture.session.wasEnded, isTrue);

        await fixture.controller.refreshStatus();

        expect(fixture.controller.phase, AccountDeletionPhase.tracking);
        expect(hub.statusCredentials.single, storedCredential);
      },
    );

    test(
      'a record carrying an operation id restores straight to tracking',
      () async {
        final hub = FakeDeletionHubClient(
          onStatus: (_) async => statusFor('deleting'),
        );
        final storage = FakeDeletionSecureStorage({
          AccountDeletionRecoveryStore.recoveryRecordKey: jsonEncode({
            'recoveryId': storedCredential.recoveryId,
            'recoverySecret': storedCredential.recoverySecret,
            'operationId': 'op_KNOWN',
          }),
        });
        final fixture = buildController(hub: hub, storage: storage);

        await fixture.controller.restore();

        expect(fixture.controller.phase, AccountDeletionPhase.tracking);
        expect(fixture.controller.ownsAppSurface, isTrue);
      },
    );

    test('a present-but-unreadable record fails closed to support', () async {
      final hub = FakeDeletionHubClient();
      final storage = FakeDeletionSecureStorage({
        AccountDeletionRecoveryStore.recoveryRecordKey: 'not json at all',
      });
      final fixture = buildController(hub: hub, storage: storage);

      await fixture.controller.restore();

      expect(fixture.controller.phase, AccountDeletionPhase.unrecoverable);
      expect(fixture.session.wasEnded, isTrue);
      expect(
        storage.holdsRecoveryRecord,
        isTrue,
        reason: 'unreadable-but-present is a support case, not an empty store',
      );
    });
  });

  group('status states', () {
    Future<AccountDeletionController> trackingWith(String state) async {
      final hub = FakeDeletionHubClient(
        onRequest: (_) async => acceptedResult(),
        onStatus: (_) async => statusFor(state),
      );
      final fixture = buildController(hub: hub);
      await fixture.controller.submit(
        accessToken: 'tok',
        password: 'hunter2',
        accountId: 'acct_1',
      );
      await fixture.controller.refreshStatus();
      return fixture.controller;
    }

    for (final state in const [
      'requested',
      'quiescing',
      'deleting',
      'failed_retryable',
      'support_required',
    ]) {
      test('$state is never success', () async {
        final controller = await trackingWith(state);

        expect(controller.phase, AccountDeletionPhase.tracking);
        expect(controller.isDeletionCompleted, isFalse);
        expect(controller.isDeletionRestored, isFalse);
        expect(controller.status!.isCompleted, isFalse);
      });
    }

    test('an unknown future state fails closed and is never success', () async {
      final controller = await trackingWith('shredding_the_backups');

      expect(controller.phase, AccountDeletionPhase.tracking);
      expect(controller.isDeletionCompleted, isFalse);
      expect(controller.status!.isUnrecognisedState, isTrue);
      expect(
        controller.status!.isProcessing,
        isFalse,
        reason: 'the client cannot claim to know what an unseen state means',
      );
    });

    test('a terminal-flagged unknown state is still not success', () async {
      final hub = FakeDeletionHubClient(
        onRequest: (_) async => acceptedResult(),
        onStatus: (_) async => statusFor('purged', isTerminal: true),
      );
      final fixture = buildController(hub: hub);
      await fixture.controller.submit(
        accessToken: 'tok',
        password: 'hunter2',
        accountId: 'acct_1',
      );

      await fixture.controller.refreshStatus();

      expect(fixture.controller.isDeletionCompleted, isFalse);
      expect(fixture.controller.phase, AccountDeletionPhase.tracking);
      expect(
        fixture.storage.holdsRecoveryRecord,
        isTrue,
        reason: 'nothing is retired for a state this build cannot read',
      );
      expect(fixture.cleanup.clearedAccountIds, isEmpty);
    });

    test(
      'an unreachable status route changes nothing about the operation',
      () async {
        final hub = FakeDeletionHubClient(
          onRequest: (_) async => acceptedResult(state: 'deleting'),
          onStatus: (_) async => throw const CaleeHubException(
            statusCode: 500,
            code: 'SERVER',
            message: 'test',
          ),
        );
        final fixture = buildController(hub: hub);
        await fixture.controller.submit(
          accessToken: 'tok',
          password: 'hunter2',
          accountId: 'acct_1',
        );

        await fixture.controller.refreshStatus();

        expect(fixture.controller.phase, AccountDeletionPhase.tracking);
        expect(
          fixture.controller.statusFailure!.kind,
          AccountDeletionStatusFailureKind.unavailable,
        );
        expect(fixture.controller.isDeletionCompleted, isFalse);
      },
    );
  });

  group('terminal handling', () {
    test('completed is the only success, and cleans up selectively', () async {
      final hub = FakeDeletionHubClient(
        onRequest: (_) async => acceptedResult(),
        onStatus: (_) async => statusFor('completed'),
      );
      final fixture = buildController(hub: hub);
      await fixture.controller.submit(
        accessToken: 'tok',
        password: 'hunter2',
        accountId: 'acct_1',
      );

      await fixture.controller.refreshStatus();

      expect(fixture.controller.phase, AccountDeletionPhase.completed);
      expect(fixture.controller.isDeletionCompleted, isTrue);
      expect(fixture.cleanup.clearedAccountIds, ['acct_1']);
      expect(fixture.controller.cleanupReport.remindersCancelled, 2);
      expect(
        fixture.storage.deletedKeys,
        contains(AccountDeletionRecoveryStore.recoveryRecordKey),
        reason: 'recovery material is retired only once genuinely obsolete',
      );
      expect(fixture.targets.clearCalls, greaterThan(0));
    });

    test('restored is terminal but is NOT deletion success', () async {
      final hub = FakeDeletionHubClient(
        onRequest: (_) async => acceptedResult(),
        onStatus: (_) async => statusFor('restored'),
      );
      final fixture = buildController(hub: hub);
      await fixture.controller.submit(
        accessToken: 'tok',
        password: 'hunter2',
        accountId: 'acct_1',
      );

      await fixture.controller.refreshStatus();

      expect(fixture.controller.phase, AccountDeletionPhase.restored);
      expect(fixture.controller.isDeletionCompleted, isFalse);
      expect(fixture.controller.isDeletionRestored, isTrue);
      expect(
        fixture.cleanup.clearedAccountIds,
        isEmpty,
        reason: 'the account still exists, so nothing of its is removed',
      );
      expect(
        fixture.storage.deletedKeys,
        contains(AccountDeletionRecoveryStore.recoveryRecordKey),
        reason: 'deletion-only transient state goes',
      );
    });

    test('acknowledging a terminal outcome returns to ordinary UX', () async {
      final hub = FakeDeletionHubClient(
        onRequest: (_) async => acceptedResult(),
        onStatus: (_) async => statusFor('restored'),
      );
      final fixture = buildController(hub: hub);
      await fixture.controller.submit(
        accessToken: 'tok',
        password: 'hunter2',
        accountId: 'acct_1',
      );
      await fixture.controller.refreshStatus();

      fixture.controller.acknowledgeTerminalOutcome();

      expect(fixture.controller.phase, AccountDeletionPhase.inactive);
      expect(fixture.controller.ownsAppSurface, isFalse);
    });

    test('a nonterminal state cannot be acknowledged away', () async {
      final hub = FakeDeletionHubClient(
        onRequest: (_) async => acceptedResult(state: 'support_required'),
      );
      final fixture = buildController(hub: hub);
      await fixture.controller.submit(
        accessToken: 'tok',
        password: 'hunter2',
        accountId: 'acct_1',
      );

      fixture.controller.acknowledgeTerminalOutcome();

      expect(fixture.controller.phase, AccountDeletionPhase.tracking);
      expect(fixture.controller.ownsAppSurface, isTrue);
    });
  });

  group('abandoning an unconfirmed request', () {
    test('is offered only after the Hub itself answered not-found', () async {
      // The Hub is unreachable at first, and only later answers for itself.
      var hubAnswersNotFound = false;
      final hub = FakeDeletionHubClient(
        onRequest: (_) async => throw const HttpException('closed'),
        onStatus: (_) async => throw CaleeHubException(
          statusCode: hubAnswersNotFound ? 404 : 500,
          code: hubAnswersNotFound ? 'DELETION_OPERATION_NOT_FOUND' : 'SERVER',
          message: 'test',
        ),
      );
      final fixture = buildController(hub: hub);
      await fixture.controller.submit(
        accessToken: 'tok',
        password: 'hunter2',
        accountId: 'acct_1',
      );
      await fixture.controller.leaveRetry();

      expect(
        fixture.controller.canAbandonUnconfirmedRequest,
        isFalse,
        reason: 'an unreachable Hub is not an answer',
      );

      hubAnswersNotFound = true;
      await fixture.controller.refreshStatus();

      expect(fixture.controller.canAbandonUnconfirmedRequest, isTrue);

      await fixture.controller.abandonUnconfirmedRequest();

      expect(fixture.controller.phase, AccountDeletionPhase.inactive);
      expect(fixture.storage.holdsRecoveryRecord, isFalse);
    });

    test('is never offered for an operation this app has seen', () async {
      final hub = FakeDeletionHubClient(
        onRequest: (_) async => acceptedResult(),
        onStatus: (index) async {
          if (index == 0) return statusFor('deleting');
          throw const CaleeHubException(
            statusCode: 404,
            code: 'DELETION_OPERATION_NOT_FOUND',
            message: 'test',
          );
        },
      );
      final fixture = buildController(hub: hub);
      await fixture.controller.submit(
        accessToken: 'tok',
        password: 'hunter2',
        accountId: 'acct_1',
      );
      await fixture.controller.refreshStatus();
      await fixture.controller.refreshStatus();

      expect(fixture.controller.canAbandonUnconfirmedRequest, isFalse);
      expect(fixture.controller.phase, AccountDeletionPhase.tracking);

      await fixture.controller.abandonUnconfirmedRequest();

      expect(
        fixture.storage.holdsRecoveryRecord,
        isTrue,
        reason: 'a confirmed operation is never abandoned',
      );
    });
  });

  group('the status route carries no bearer token', () {
    test('a controller-driven status read sends the credential in the body and '
        'no Authorization header', () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));

      final authorizationHeaders = <String?>[];
      Map<String, dynamic>? receivedBody;

      server.listen((req) async {
        final raw = await utf8.decodeStream(req);
        authorizationHeaders.add(
          req.headers.value(HttpHeaders.authorizationHeader),
        );
        receivedBody = jsonDecode(raw) as Map<String, dynamic>;
        req.response.statusCode = HttpStatus.ok;
        req.response.headers.contentType = ContentType.json;
        req.response.write(
          jsonEncode({
            'data': {
              'operationId': 'op_01HZY',
              'state': 'quiescing',
              'isTerminal': false,
              'restorable': true,
            },
            'meta': {'apiVersion': 'client/v1'},
          }),
        );
        await req.response.close();
      });

      final hub = CaleeHubClient(
        baseUri: Uri.parse('http://127.0.0.1:${server.port}'),
      );
      addTearDown(hub.resetTransport);

      final storage = FakeDeletionSecureStorage({
        AccountDeletionRecoveryStore.recoveryRecordKey: jsonEncode({
          'recoveryId': storedCredential.recoveryId,
          'recoverySecret': storedCredential.recoverySecret,
        }),
      });
      final session = SessionEndRecorder();
      final controller = AccountDeletionController(
        hubClient: hub,
        endOrdinarySession: session.end,
        recoveryStore: AccountDeletionRecoveryStore(storage: storage),
        accountCleanup: RecordingAccountCleanup(),
        cleanupTargets: FakeCleanupTargetStore(),
      );

      await controller.restore();
      await controller.refreshStatus();

      expect(controller.phase, AccountDeletionPhase.tracking);
      expect(
        authorizationHeaders,
        everyElement(isNull),
        reason: 'the status route must keep working once the identity is gone',
      );
      expect(receivedBody!['recoveryId'], storedCredential.recoveryId);
      expect(receivedBody!['recoverySecret'], storedCredential.recoverySecret);
    });
  });

  group('completion window', () {
    test('is the Hub message, never a figure this client composed', () async {
      const hubMessage =
          'Most deletions finish within a few days. Calee will email you when '
          'yours is done.';
      final hub = FakeDeletionHubClient(
        onRequest: (_) async =>
            acceptedResult(completionWindowMessage: hubMessage),
      );
      final fixture = buildController(hub: hub);

      await fixture.controller.submit(
        accessToken: 'tok',
        password: 'hunter2',
        accountId: 'acct_1',
      );

      expect(fixture.controller.completionWindowMessage, hubMessage);
    });

    test('is simply absent when the Hub sends none', () async {
      final hub = FakeDeletionHubClient(
        onRequest: (_) async => acceptedResult(),
      );
      final fixture = buildController(hub: hub);

      await fixture.controller.submit(
        accessToken: 'tok',
        password: 'hunter2',
        accountId: 'acct_1',
      );

      expect(fixture.controller.completionWindowMessage, isNull);
    });
  });

  group('secrets', () {
    test('the password is used once and never retained', () async {
      final hub = FakeDeletionHubClient(
        onRequest: (_) async => acceptedResult(),
      );
      final fixture = buildController(hub: hub);

      await fixture.controller.submit(
        accessToken: 'tok',
        password: 'hunter2',
        accountId: 'acct_1',
      );

      expect(hub.requestPasswords, ['hunter2']);
      expect(
        fixture.storage.values.values.join(),
        isNot(contains('hunter2')),
        reason: 'the password is never persisted',
      );
      expect(fixture.controller.toString(), isNot(contains('hunter2')));
    });

    test(
      'the recovery secret never reaches a rendered or logged string',
      () async {
        final hub = FakeDeletionHubClient(
          onRequest: (_) async => acceptedResult(),
        );
        final storage = FakeDeletionSecureStorage({
          AccountDeletionRecoveryStore.recoveryRecordKey: jsonEncode({
            'recoveryId': storedCredential.recoveryId,
            'recoverySecret': storedCredential.recoverySecret,
          }),
        });
        final fixture = buildController(hub: hub, storage: storage);
        await fixture.controller.submit(
          accessToken: 'tok',
          password: 'hunter2',
          accountId: 'acct_1',
        );

        expect(
          fixture.controller.recoveryIdForSupport,
          storedCredential.recoveryId,
        );
        expect(
          fixture.controller.status.toString(),
          isNot(contains(storedCredential.recoverySecret)),
        );
        expect(
          fixture.controller.requestFailure?.toString() ?? '',
          isNot(contains(storedCredential.recoverySecret)),
        );
      },
    );
  });
}

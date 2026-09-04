import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:calee_mobile/data/account_deletion/account_deletion_recovery_credential.dart';
import 'package:calee_mobile/data/api/calee_hub_client.dart';

/// Obviously-fake, correctly-shaped material. No real credential appears in
/// this suite or in its output.
const AccountDeletionRecoveryCredential testCredential =
    AccountDeletionRecoveryCredential(
      recoveryId: 'Rk1tZXN0Q3JlZGVudGlhbA',
      recoverySecret: 'U2VjcmV0Rm9yVGVzdHNPbmx5Tm90QVJlYWxDcmVkZW50',
    );

/// One captured request.
class CapturedRequest {
  CapturedRequest({
    required this.method,
    required this.uri,
    required this.authorization,
    required this.body,
  });

  final String method;
  final Uri uri;
  final String? authorization;
  final Map<String, dynamic> body;
}

/// A loopback Hub that answers each request from [responses] in order.
class FakeHub {
  FakeHub._(this._server, this.requests);

  final HttpServer _server;
  final List<CapturedRequest> requests;

  Uri get baseUri => Uri.parse('http://127.0.0.1:${_server.port}');

  Future<void> close() => _server.close(force: true);

  static Future<FakeHub> start(
    List<({int status, Map<String, dynamic> body})> responses,
  ) async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final requests = <CapturedRequest>[];
    var index = 0;

    server.listen((req) async {
      final raw = await utf8.decodeStream(req);
      requests.add(
        CapturedRequest(
          method: req.method,
          uri: req.uri,
          authorization: req.headers.value(HttpHeaders.authorizationHeader),
          body: raw.isEmpty
              ? const <String, dynamic>{}
              : jsonDecode(raw) as Map<String, dynamic>,
        ),
      );

      final response =
          responses[index < responses.length ? index : responses.length - 1];
      index++;

      req.response.statusCode = response.status;
      req.response.headers.contentType = ContentType.json;
      req.response.write(jsonEncode(response.body));
      await req.response.close();
    });

    return FakeHub._(server, requests);
  }
}

Map<String, dynamic> successEnvelope(Map<String, dynamic> data) => {
  'data': data,
  'meta': {
    'serverTime': '2026-09-01T00:00:00+00:00',
    'apiVersion': 'client/v1',
  },
};

Map<String, dynamic> errorEnvelope(String code, String message) => {
  'error': {'code': code, 'message': message},
  'meta': {
    'serverTime': '2026-09-01T00:00:00+00:00',
    'apiVersion': 'client/v1',
  },
};

Map<String, dynamic> statusProjection({
  String state = 'requested',
  bool isTerminal = false,
  bool restorable = true,
}) => {
  'operationId': 'op_01HZY',
  'state': state,
  'isTerminal': isTerminal,
  'reasonCode': null,
  'restorable': restorable,
  'requestedAt': '2026-09-01T02:03:04.123456Z',
  'completedAt': null,
  'restoredAt': null,
  'completionWindowMessage':
      'Your deletion request has been received and is being processed.',
};

void main() {
  late FakeHub hub;

  tearDown(() async {
    await hub.close();
  });

  group('CaleeHubClient.requestAccountDeletion', () {
    test(
      'POSTs the exact contract body to /client/v1/account-deletions',
      () async {
        hub = await FakeHub.start([
          (
            status: HttpStatus.created,
            body: successEnvelope(
              statusProjection()
                ..['created'] = true
                ..['recoveryCredentialMatched'] = true,
            ),
          ),
        ]);

        await CaleeHubClient(baseUri: hub.baseUri).requestAccountDeletion(
          accessToken: 'hub-access-token',
          password: 'the-customers-password',
          recoveryCredential: testCredential,
        );

        expect(hub.requests, hasLength(1));
        final request = hub.requests.single;
        expect(request.method, 'POST');
        expect(request.uri.path, '/client/v1/account-deletions');
        expect(request.authorization, 'Bearer hub-access-token');
        expect(request.body, {
          'confirmation': 'DELETE MY CALEE ACCOUNT',
          'password': 'the-customers-password',
          'recoveryId': testCredential.recoveryId,
          'recoverySecret': testCredential.recoverySecret,
        });
      },
    );

    test('sends the exact destructive confirmation phrase', () {
      // Pinned to account_deletion_confirmation_phrase(). The Hub compares it
      // with hash_equals after a trim, so nothing but this string is accepted.
      expect(
        CaleeHubClient.accountDeletionConfirmationPhrase,
        'DELETE MY CALEE ACCOUNT',
      );
    });

    test('never puts the credential in the URL or query string', () async {
      hub = await FakeHub.start([
        (
          status: HttpStatus.created,
          body: successEnvelope(
            statusProjection()
              ..['created'] = true
              ..['recoveryCredentialMatched'] = true,
          ),
        ),
      ]);

      await CaleeHubClient(baseUri: hub.baseUri).requestAccountDeletion(
        accessToken: 'hub-access-token',
        password: 'the-customers-password',
        recoveryCredential: testCredential,
      );

      final uri = hub.requests.single.uri;
      expect(uri.query, isEmpty);
      expect(uri.toString(), isNot(contains(testCredential.recoverySecret)));
      expect(uri.toString(), isNot(contains(testCredential.recoveryId)));
    });

    test('parses the status projection and both request booleans', () async {
      hub = await FakeHub.start([
        (
          status: HttpStatus.created,
          body: successEnvelope(
            statusProjection()
              ..['created'] = true
              ..['recoveryCredentialMatched'] = true,
          ),
        ),
      ]);

      final result = await CaleeHubClient(baseUri: hub.baseUri)
          .requestAccountDeletion(
            accessToken: 'hub-access-token',
            password: 'the-customers-password',
            recoveryCredential: testCredential,
          );

      expect(result.created, isTrue);
      expect(result.recoveryCredentialMatched, isTrue);
      expect(result.status.operationId, 'op_01HZY');
      expect(result.status.state, 'requested');
      expect(result.status.isCompleted, isFalse);
      expect(result.status.restorable, isTrue);
      expect(
        result.status.completionWindowMessage,
        'Your deletion request has been received and is being processed.',
      );
    });

    test(
      'an HTTP 200 replay resolves the same operation, not a new one',
      () async {
        hub = await FakeHub.start([
          (
            status: HttpStatus.ok,
            body: successEnvelope(
              statusProjection(state: 'quiescing')
                ..['created'] = false
                ..['recoveryCredentialMatched'] = true,
            ),
          ),
        ]);

        final result = await CaleeHubClient(baseUri: hub.baseUri)
            .requestAccountDeletion(
              accessToken: 'hub-access-token',
              password: 'the-customers-password',
              recoveryCredential: testCredential,
            );

        expect(result.created, isFalse);
        expect(result.status.operationId, 'op_01HZY');
        expect(result.status.isProcessing, isTrue);
      },
    );

    test('reports unmatched recovery material from a replay', () async {
      hub = await FakeHub.start([
        (
          status: HttpStatus.ok,
          body: successEnvelope(
            statusProjection()
              ..['created'] = false
              ..['recoveryCredentialMatched'] = false,
          ),
        ),
      ]);

      final result = await CaleeHubClient(baseUri: hub.baseUri)
          .requestAccountDeletion(
            accessToken: 'hub-access-token',
            password: 'the-customers-password',
            recoveryCredential: testCredential,
          );

      expect(result.recoveryCredentialMatched, isFalse);
    });

    test(
      '401 DELETION_REAUTH_REQUIRED is surfaced without a token refresh',
      () async {
        // A wrong deletion password is not an expired session. Refreshing cannot
        // fix it, and a failed refresh would sign the customer out midway through
        // deleting their account.
        hub = await FakeHub.start([
          (
            status: HttpStatus.unauthorized,
            body: errorEnvelope(
              'DELETION_REAUTH_REQUIRED',
              'Confirm your password to continue with account deletion.',
            ),
          ),
        ]);

        var refreshed = 0;
        final client = CaleeHubClient(baseUri: hub.baseUri)
          ..onUnauthorized = () async {
            refreshed++;
            return 'a-new-token';
          };

        await expectLater(
          client.requestAccountDeletion(
            accessToken: 'hub-access-token',
            password: 'the-wrong-password',
            recoveryCredential: testCredential,
          ),
          throwsA(
            isA<CaleeHubException>()
                .having((e) => e.statusCode, 'statusCode', 401)
                .having((e) => e.code, 'code', 'DELETION_REAUTH_REQUIRED'),
          ),
        );

        expect(
          refreshed,
          0,
          reason: 'a password failure must not spend a refresh',
        );
        expect(
          hub.requests,
          hasLength(1),
          reason:
              'the destructive request must not be replayed on a bad password',
        );
      },
    );

    test('an ordinary 401 still refreshes and retries once', () async {
      hub = await FakeHub.start([
        (
          status: HttpStatus.unauthorized,
          body: errorEnvelope('UNAUTHORIZED', 'Account not found or inactive'),
        ),
        (
          status: HttpStatus.created,
          body: successEnvelope(
            statusProjection()
              ..['created'] = true
              ..['recoveryCredentialMatched'] = true,
          ),
        ),
      ]);

      var refreshed = 0;
      final client = CaleeHubClient(baseUri: hub.baseUri)
        ..onUnauthorized = () async {
          refreshed++;
          return 'a-new-token';
        };

      final result = await client.requestAccountDeletion(
        accessToken: 'stale-access-token',
        password: 'the-customers-password',
        recoveryCredential: testCredential,
      );

      expect(refreshed, 1);
      expect(result.created, isTrue);
      expect(hub.requests, hasLength(2));
      expect(hub.requests.first.authorization, 'Bearer stale-access-token');
      expect(hub.requests.last.authorization, 'Bearer a-new-token');
      // Safe to replay: the Hub's request path is idempotent by construction,
      // and the retry carries the SAME recovery material.
      expect(hub.requests.last.body['recoveryId'], testCredential.recoveryId);
    });

    test('a 409 managed-account refusal keeps its stable code', () async {
      hub = await FakeHub.start([
        (
          status: HttpStatus.conflict,
          body: errorEnvelope(
            'MANAGED_ACCOUNT_OFFBOARDING_REQUIRED',
            'This account is managed by an organisation.',
          ),
        ),
      ]);

      await expectLater(
        CaleeHubClient(baseUri: hub.baseUri).requestAccountDeletion(
          accessToken: 'hub-access-token',
          password: 'the-customers-password',
          recoveryCredential: testCredential,
        ),
        throwsA(
          isA<CaleeHubException>()
              .having((e) => e.statusCode, 'statusCode', 409)
              .having(
                (e) => e.code,
                'code',
                'MANAGED_ACCOUNT_OFFBOARDING_REQUIRED',
              ),
        ),
      );
    });

    test('a malformed 2xx body is an UNKNOWN outcome, not a success', () async {
      // The operation may well be committed. The caller must resolve this
      // through the status endpoint, never by minting fresh material.
      hub = await FakeHub.start([
        (
          status: HttpStatus.created,
          body: successEnvelope(
            statusProjection()..['created'] = true,
          ), // recoveryCredentialMatched missing
        ),
      ]);

      await expectLater(
        CaleeHubClient(baseUri: hub.baseUri).requestAccountDeletion(
          accessToken: 'hub-access-token',
          password: 'the-customers-password',
          recoveryCredential: testCredential,
        ),
        throwsA(
          isA<CaleeHubException>()
              .having((e) => e.statusCode, 'statusCode', 0)
              .having((e) => e.code, 'code', 'DELETION_RESPONSE_MALFORMED'),
        ),
      );
    });

    test(
      'malformed recovery material is refused before anything is sent',
      () async {
        hub = await FakeHub.start([
          (
            status: HttpStatus.created,
            body: successEnvelope(statusProjection()),
          ),
        ]);

        await expectLater(
          CaleeHubClient(baseUri: hub.baseUri).requestAccountDeletion(
            accessToken: 'hub-access-token',
            password: 'the-customers-password',
            recoveryCredential: const AccountDeletionRecoveryCredential(
              recoveryId: 'too-short',
              recoverySecret: 'also-too-short',
            ),
          ),
          throwsA(
            isA<CaleeHubException>().having(
              (e) => e.code,
              'code',
              'DELETION_RECOVERY_MATERIAL_INVALID',
            ),
          ),
        );

        expect(
          hub.requests,
          isEmpty,
          reason:
              'the password must not travel with material the Hub will reject',
        );
      },
    );
  });

  group('CaleeHubClient.accountDeletionStatus', () {
    test(
      'POSTs recovery material only to the deletion-only status route',
      () async {
        hub = await FakeHub.start([
          (
            status: HttpStatus.ok,
            body: successEnvelope(statusProjection(state: 'deleting')),
          ),
        ]);

        await CaleeHubClient(
          baseUri: hub.baseUri,
        ).accountDeletionStatus(recoveryCredential: testCredential);

        final request = hub.requests.single;
        expect(request.method, 'POST');
        expect(request.uri.path, '/client/v1/account-deletions/status');
        expect(request.body, {
          'recoveryId': testCredential.recoveryId,
          'recoverySecret': testCredential.recoverySecret,
        });
      },
    );

    test('sends NO bearer token', () async {
      // The point of the route: it must keep working once the identity that
      // would have authenticated the customer is quiesced or gone.
      hub = await FakeHub.start([
        (status: HttpStatus.ok, body: successEnvelope(statusProjection())),
      ]);

      await CaleeHubClient(
        baseUri: hub.baseUri,
      ).accountDeletionStatus(recoveryCredential: testCredential);

      expect(hub.requests.single.authorization, isNull);
    });

    test('never puts the credential in the URL or query string', () async {
      hub = await FakeHub.start([
        (status: HttpStatus.ok, body: successEnvelope(statusProjection())),
      ]);

      await CaleeHubClient(
        baseUri: hub.baseUri,
      ).accountDeletionStatus(recoveryCredential: testCredential);

      final uri = hub.requests.single.uri;
      expect(uri.query, isEmpty);
      expect(uri.toString(), isNot(contains(testCredential.recoverySecret)));
    });

    test('parses a completed operation', () async {
      hub = await FakeHub.start([
        (
          status: HttpStatus.ok,
          body: successEnvelope(
            statusProjection(
              state: 'completed',
              isTerminal: true,
              restorable: false,
            )..['completedAt'] = '2026-09-02T05:06:07.000000Z',
          ),
        ),
      ]);

      final status = await CaleeHubClient(
        baseUri: hub.baseUri,
      ).accountDeletionStatus(recoveryCredential: testCredential);

      expect(status.isCompleted, isTrue);
      expect(status.isRestored, isFalse);
      expect(status.completedAt, DateTime.utc(2026, 9, 2, 5, 6, 7));
    });

    test('parses a restored operation as NOT completed', () async {
      hub = await FakeHub.start([
        (
          status: HttpStatus.ok,
          body: successEnvelope(
            statusProjection(
              state: 'restored',
              isTerminal: true,
              restorable: false,
            )..['restoredAt'] = '2026-09-03T08:09:10.000000Z',
          ),
        ),
      ]);

      final status = await CaleeHubClient(
        baseUri: hub.baseUri,
      ).accountDeletionStatus(recoveryCredential: testCredential);

      expect(status.isRestored, isTrue);
      expect(status.isCompleted, isFalse);
    });

    test('404 keeps its stable code and never triggers a refresh', () async {
      hub = await FakeHub.start([
        (
          status: HttpStatus.notFound,
          body: errorEnvelope(
            'DELETION_OPERATION_NOT_FOUND',
            'No deletion request was found for that recovery code.',
          ),
        ),
      ]);

      var refreshed = 0;
      final client = CaleeHubClient(baseUri: hub.baseUri)
        ..onUnauthorized = () async {
          refreshed++;
          return 'a-new-token';
        };

      await expectLater(
        client.accountDeletionStatus(recoveryCredential: testCredential),
        throwsA(
          isA<CaleeHubException>()
              .having((e) => e.statusCode, 'statusCode', 404)
              .having((e) => e.code, 'code', 'DELETION_OPERATION_NOT_FOUND'),
        ),
      );

      expect(refreshed, 0);
      expect(hub.requests, hasLength(1));
    });

    test('a 401 on the status route is never refreshed or retried', () async {
      // Defensive: this route has no bearer token to refresh, so a 401 must
      // reach the caller instead of provoking a sign-out.
      hub = await FakeHub.start([
        (
          status: HttpStatus.unauthorized,
          body: errorEnvelope('UNAUTHORIZED', 'Account not found or inactive'),
        ),
      ]);

      var refreshed = 0;
      final client = CaleeHubClient(baseUri: hub.baseUri)
        ..onUnauthorized = () async {
          refreshed++;
          return 'a-new-token';
        };

      await expectLater(
        client.accountDeletionStatus(recoveryCredential: testCredential),
        throwsA(isA<CaleeHubException>()),
      );

      expect(refreshed, 0);
      expect(hub.requests, hasLength(1));
    });

    test('a malformed status body fails predictably', () async {
      hub = await FakeHub.start([
        (
          status: HttpStatus.ok,
          body: successEnvelope(statusProjection()..remove('state')),
        ),
      ]);

      await expectLater(
        CaleeHubClient(
          baseUri: hub.baseUri,
        ).accountDeletionStatus(recoveryCredential: testCredential),
        throwsA(
          isA<CaleeHubException>()
              .having((e) => e.statusCode, 'statusCode', 0)
              .having((e) => e.code, 'code', 'DELETION_STATUS_MALFORMED'),
        ),
      );
    });

    test('a thrown Hub error never quotes the recovery secret', () async {
      hub = await FakeHub.start([
        (
          status: HttpStatus.notFound,
          body: errorEnvelope(
            'DELETION_OPERATION_NOT_FOUND',
            'No deletion request was found for that recovery code.',
          ),
        ),
      ]);

      try {
        await CaleeHubClient(
          baseUri: hub.baseUri,
        ).accountDeletionStatus(recoveryCredential: testCredential);
        fail('expected a CaleeHubException');
      } on CaleeHubException catch (error) {
        expect(
          error.toString(),
          isNot(contains(testCredential.recoverySecret)),
        );
        expect(
          error.debugSummary,
          isNot(contains(testCredential.recoverySecret)),
        );
      }
    });
  });
}

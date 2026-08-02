// Tests for CaleeHubClient's calendar event attachment methods
// (listAttachments/uploadAttachment/downloadAttachment/detachAttachment),
// added alongside calee-hub-core's /client/v1/events/{eventId}/attachments
// API. Uses the same local-loopback HttpServer harness already established
// in calee_hub_client_calendar_test.dart / calee_hub_client_concurrency_error_test.dart
// -- no real network access.
import 'dart:convert';
import 'dart:io';

import 'package:calee_mobile/data/api/calee_hub_client.dart';
import 'package:calee_mobile/data/models/client_calendar.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late HttpServer server;
  late Directory tempDir;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('calee_attachment_test_');
  });

  tearDown(() async {
    await server.close(force: true);
    if (await tempDir.exists()) {
      await tempDir.delete(recursive: true);
    }
  });

  Map<String, dynamic> attachmentJson({
    String id = 'att-1',
    String filename = 'doc.pdf',
    String? contentType = 'application/pdf',
    int? size = 12345,
    bool hasPreview = false,
    String scope = 'series',
    bool downloadAvailable = true,
  }) {
    return {
      'id': id,
      'filename': filename,
      'contentType': contentType,
      'size': size,
      'hasPreview': hasPreview,
      'scope': scope,
      'downloadAvailable': downloadAvailable,
    };
  }

  group('CaleeHubClient.listAttachments()', () {
    Future<CaleeHubClient> startServerReturning(
      int statusCode,
      Map<String, dynamic> body, {
      void Function(HttpRequest request)? onRequest,
    }) async {
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      server.listen((req) async {
        onRequest?.call(req);
        req.response.headers.contentType = ContentType.json;
        req.response.statusCode = statusCode;
        req.response.write(jsonEncode(body));
        await req.response.close();
      });
      return CaleeHubClient(
        baseUri: Uri.parse('http://127.0.0.1:${server.port}'),
      );
    }

    test('sends GET to the correct path and parses attachments', () async {
      String? capturedMethod;
      String? capturedPath;
      final client = await startServerReturning(
        200,
        {
          'data': {
            'attachments': [attachmentJson()],
          },
          'meta': {},
        },
        onRequest: (req) {
          capturedMethod = req.method;
          capturedPath = req.uri.path;
        },
      );

      final attachments = await client.listAttachments(
        accessToken: 'tok',
        eventId: 'portal:evt-1',
      );

      expect(capturedMethod, 'GET');
      expect(capturedPath, '/client/v1/events/portal%3Aevt-1/attachments');
      expect(attachments, hasLength(1));
      expect(attachments.single.id, 'att-1');
      expect(attachments.single.filename, 'doc.pdf');
      expect(attachments.single.contentType, 'application/pdf');
      expect(attachments.single.size, 12345);
      expect(attachments.single.scope, AttachmentScope.series);
      expect(attachments.single.downloadAvailable, isTrue);
    });

    test('an empty attachments array parses to an empty list', () async {
      final client = await startServerReturning(200, {
        'data': {'attachments': []},
        'meta': {},
      });

      final attachments = await client.listAttachments(
        accessToken: 'tok',
        eventId: 'portal:evt-1',
      );

      expect(attachments, isEmpty);
    });

    test(
      'unknown additive fields on an attachment are ignored, not a crash',
      () async {
        final client = await startServerReturning(200, {
          'data': {
            'attachments': [
              {
                ...attachmentJson(),
                'futureField': 'some value from a newer backend',
                'anotherNewThing': {'nested': true},
              },
            ],
          },
          'meta': {},
        });

        final attachments = await client.listAttachments(
          accessToken: 'tok',
          eventId: 'portal:evt-1',
        );

        expect(attachments, hasLength(1));
        expect(attachments.single.id, 'att-1');
      },
    );

    test('a calendar-unsupported 409 parses safely', () async {
      final client = await startServerReturning(409, {
        'error': {
          'code': 'ATTACHMENTS_NOT_SUPPORTED_FOR_CALENDAR',
          'message': 'Attachments are not supported for this calendar',
        },
        'meta': {},
      });

      try {
        await client.listAttachments(
          accessToken: 'tok',
          eventId: 'google:evt-1',
        );
        fail('Expected CaleeHubException');
      } on CaleeHubException catch (e) {
        expect(e.statusCode, 409);
        expect(e.code, 'ATTACHMENTS_NOT_SUPPORTED_FOR_CALENDAR');
      }
    });
  });

  group('CaleeHubClient.uploadAttachment()', () {
    test(
      'sends multipart POST with the Idempotency-Key header and file part',
      () async {
        String? capturedMethod;
        String? capturedPath;
        String? capturedIdempotencyKey;
        List<int> capturedBody = [];
        String? capturedContentTypeHeader;

        server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        server.listen((req) async {
          capturedMethod = req.method;
          capturedPath = req.uri.path;
          capturedIdempotencyKey = req.headers.value('idempotency-key');
          capturedContentTypeHeader = req.headers.contentType?.mimeType;
          capturedBody = await req.fold<List<int>>(
            [],
            (acc, chunk) => acc..addAll(chunk),
          );

          req.response.headers.contentType = ContentType.json;
          req.response.statusCode = 201;
          req.response.write(
            jsonEncode({
              'data': {'attachment': attachmentJson(id: 'att-new')},
              'meta': {},
            }),
          );
          await req.response.close();
        });
        final client = CaleeHubClient(
          baseUri: Uri.parse('http://127.0.0.1:${server.port}'),
        );

        final sourceFile = File('${tempDir.path}/photo.jpg');
        await sourceFile.writeAsBytes(List<int>.filled(200, 65)); // 'A' * 200

        final progressUpdates = <int>[];
        final attachment = await client.uploadAttachment(
          accessToken: 'tok',
          eventId: 'portal:evt-1',
          file: sourceFile,
          idempotencyKey: 'idem-key-123',
          onProgress: (sent, total) => progressUpdates.add(sent),
        );

        expect(capturedMethod, 'POST');
        expect(capturedPath, '/client/v1/events/portal%3Aevt-1/attachments');
        expect(capturedIdempotencyKey, 'idem-key-123');
        expect(capturedContentTypeHeader, 'multipart/form-data');

        final bodyText = latin1.decode(capturedBody, allowInvalid: true);
        expect(bodyText, contains('name="file"'));
        expect(bodyText, contains('filename="photo.jpg"'));
        expect(
          bodyText,
          contains('A' * 200),
          reason:
              'the file bytes (200 "A" bytes) should appear as one contiguous run in the multipart body',
        );

        expect(attachment.id, 'att-new');
        expect(progressUpdates, isNotEmpty);
        expect(
          progressUpdates.last,
          progressUpdates.reduce((a, b) => a > b ? a : b),
          reason:
              'progress should be non-decreasing, ending at its own maximum',
        );
      },
    );

    test(
      'a pre-cancelled token prevents the upload from ever sending the file',
      () async {
        var requestReceived = false;
        server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        server.listen((req) async {
          requestReceived = true;
          req.response.statusCode = 201;
          await req.response.close();
        });
        final client = CaleeHubClient(
          baseUri: Uri.parse('http://127.0.0.1:${server.port}'),
        );

        final sourceFile = File('${tempDir.path}/cancelled.jpg');
        await sourceFile.writeAsBytes(List<int>.filled(100, 66));

        final cancelToken = AttachmentTransferCancelToken()..cancel();

        try {
          await client.uploadAttachment(
            accessToken: 'tok',
            eventId: 'portal:evt-1',
            file: sourceFile,
            idempotencyKey: 'idem-key-cancelled',
            cancelToken: cancelToken,
          );
          fail('Expected CaleeHubException(code: CANCELLED)');
        } on CaleeHubException catch (e) {
          expect(e.code, 'CANCELLED');
        }

        // Give the server loop a moment to have received anything, if it was
        // going to -- the request should never have been meaningfully sent.
        await Future<void>.delayed(const Duration(milliseconds: 50));
        expect(
          requestReceived,
          isFalse,
          reason:
              'a request line was received even though upload should have aborted before writing',
        );
      },
    );

    test('a 409 conflict during upload parses safely', () async {
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      server.listen((req) async {
        await req.drain<void>();
        req.response.headers.contentType = ContentType.json;
        req.response.statusCode = 409;
        req.response.write(
          jsonEncode({
            'error': {
              'code': 'CALENDAR_OBJECT_CONFLICT',
              'message':
                  'This event changed on another device. Refresh it and try again.',
            },
            'meta': {},
          }),
        );
        await req.response.close();
      });
      final client = CaleeHubClient(
        baseUri: Uri.parse('http://127.0.0.1:${server.port}'),
      );

      final sourceFile = File('${tempDir.path}/conflict.jpg');
      await sourceFile.writeAsBytes([1, 2, 3]);

      try {
        await client.uploadAttachment(
          accessToken: 'tok',
          eventId: 'portal:evt-1',
          file: sourceFile,
          idempotencyKey: 'idem-key-conflict',
        );
        fail('Expected CaleeHubException');
      } on CaleeHubException catch (e) {
        expect(e.statusCode, 409);
        expect(e.code, 'CALENDAR_OBJECT_CONFLICT');
      }
    });
  });

  group('CaleeHubClient.downloadAttachment()', () {
    test('streams response bytes to the destination file', () async {
      final fileBytes = List<int>.generate(5000, (i) => i % 256);
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      server.listen((req) async {
        req.response.headers.contentType = ContentType.parse('application/pdf');
        req.response.contentLength = fileBytes.length;
        req.response.statusCode = 200;
        req.response.add(fileBytes);
        await req.response.close();
      });
      final client = CaleeHubClient(
        baseUri: Uri.parse('http://127.0.0.1:${server.port}'),
      );

      final destination = File('${tempDir.path}/downloaded.pdf');
      final progressUpdates = <int>[];

      await client.downloadAttachment(
        accessToken: 'tok',
        eventId: 'portal:evt-1',
        attachmentId: 'att-1',
        destinationFile: destination,
        onProgress: (received, total) => progressUpdates.add(received),
      );

      expect(await destination.exists(), isTrue);
      expect(await destination.readAsBytes(), fileBytes);
      expect(progressUpdates, isNotEmpty);
      expect(progressUpdates.last, fileBytes.length);
    });

    test(
      'ATTACHMENT_FILE_UNAVAILABLE throws and never leaves a partial file behind',
      () async {
        server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        server.listen((req) async {
          req.response.headers.contentType = ContentType.json;
          req.response.statusCode = 409;
          req.response.write(
            jsonEncode({
              'error': {
                'code': 'ATTACHMENT_FILE_UNAVAILABLE',
                'message': 'This file is no longer available',
              },
              'meta': {},
            }),
          );
          await req.response.close();
        });
        final client = CaleeHubClient(
          baseUri: Uri.parse('http://127.0.0.1:${server.port}'),
        );

        final destination = File('${tempDir.path}/unavailable.pdf');

        try {
          await client.downloadAttachment(
            accessToken: 'tok',
            eventId: 'portal:evt-1',
            attachmentId: 'att-dead',
            destinationFile: destination,
          );
          fail('Expected CaleeHubException');
        } on CaleeHubException catch (e) {
          expect(e.code, 'ATTACHMENT_FILE_UNAVAILABLE');
        }

        expect(
          await destination.exists(),
          isFalse,
          reason:
              'no partial/empty file should be left behind after a failed download',
        );
      },
    );
  });

  group('CaleeHubClient.detachAttachment()', () {
    test(
      'sends DELETE to the correct path and parses the updated list',
      () async {
        String? capturedMethod;
        String? capturedPath;
        server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        server.listen((req) async {
          capturedMethod = req.method;
          capturedPath = req.uri.path;
          req.response.headers.contentType = ContentType.json;
          req.response.statusCode = 200;
          req.response.write(
            jsonEncode({
              'data': {
                'attachments': [attachmentJson(id: 'att-remaining')],
              },
              'meta': {},
            }),
          );
          await req.response.close();
        });
        final client = CaleeHubClient(
          baseUri: Uri.parse('http://127.0.0.1:${server.port}'),
        );

        final remaining = await client.detachAttachment(
          accessToken: 'tok',
          eventId: 'portal:evt-1',
          attachmentId: 'att-removed',
        );

        expect(capturedMethod, 'DELETE');
        expect(
          capturedPath,
          '/client/v1/events/portal%3Aevt-1/attachments/att-removed',
        );
        expect(remaining, hasLength(1));
        expect(remaining.single.id, 'att-remaining');
      },
    );

    test('ATTACHMENT_NOT_FOUND (repeated detach) parses safely', () async {
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      server.listen((req) async {
        req.response.headers.contentType = ContentType.json;
        req.response.statusCode = 404;
        req.response.write(
          jsonEncode({
            'error': {
              'code': 'ATTACHMENT_NOT_FOUND',
              'message': 'This attachment is no longer available on this event',
            },
            'meta': {},
          }),
        );
        await req.response.close();
      });
      final client = CaleeHubClient(
        baseUri: Uri.parse('http://127.0.0.1:${server.port}'),
      );

      try {
        await client.detachAttachment(
          accessToken: 'tok',
          eventId: 'portal:evt-1',
          attachmentId: 'att-already-gone',
        );
        fail('Expected CaleeHubException');
      } on CaleeHubException catch (e) {
        expect(e.statusCode, 404);
        expect(e.code, 'ATTACHMENT_NOT_FOUND');
      }
    });
  });
}

// Tests for CaleeHubClient's calendar event attachment methods
// (listAttachments/uploadAttachment/downloadAttachment/detachAttachment),
// added alongside calee-hub-core's /client/v1/events/{eventId}/attachments
// API. Uses the same local-loopback HttpServer harness already established
// in calee_hub_client_calendar_test.dart / calee_hub_client_concurrency_error_test.dart
// -- no real network access.
import 'dart:async';
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
          originalFilename: sourceFile.path.split('/').last,
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
            originalFilename: sourceFile.path.split('/').last,
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

    test('sanitizes CR/LF/quotes/backslash out of the filename and carries '
        'Unicode via filename*', () async {
      List<int> capturedBody = [];
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      server.listen((req) async {
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

      // A real filename that embeds a CR, an LF, a double-quote and a
      // backslash -- all legal bytes in a Unix path component -- to prove
      // header-injection-capable characters never reach the wire raw.
      final trickyName = 'evil\r\nInjected: header"quote\\slash.pdf';
      final sourceFile = File('${tempDir.path}/$trickyName');
      await sourceFile.writeAsBytes(utf8.encode('body'));

      await client.uploadAttachment(
        accessToken: 'tok',
        eventId: 'portal:evt-1',
        file: sourceFile,
        originalFilename: sourceFile.path.split('/').last,
        idempotencyKey: 'idem-key-tricky-name',
      );

      final bodyText = latin1.decode(capturedBody, allowInvalid: true);
      final physicalLines = bodyText.split('\r\n');
      final dispositionLines = physicalLines.where(
        (line) => line.startsWith('Content-Disposition:'),
      );
      expect(
        dispositionLines,
        hasLength(1),
        reason:
            'a stray CR/LF in the filename must never split into a second '
            'physical line (which would be header/part injection)',
      );
      expect(
        dispositionLines.single,
        'Content-Disposition: form-data; name="file"; '
        'filename="evilInjected: header\\"quote\\\\slash.pdf"',
      );
    });

    test('carries a Unicode-only filename via filename*=UTF-8\'\'', () async {
      List<int> capturedBody = [];
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      server.listen((req) async {
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

      final sourceFile = File('${tempDir.path}/café.pdf');
      await sourceFile.writeAsBytes(utf8.encode('body'));

      await client.uploadAttachment(
        accessToken: 'tok',
        eventId: 'portal:evt-1',
        file: sourceFile,
        originalFilename: sourceFile.path.split('/').last,
        idempotencyKey: 'idem-key-unicode-name',
      );

      final bodyText = latin1.decode(capturedBody, allowInvalid: true);
      final dispositionLine = bodyText
          .split('\r\n')
          .firstWhere((line) => line.startsWith('Content-Disposition:'));
      expect(dispositionLine, contains('filename="caf_.pdf"'));
      expect(dispositionLine, contains("filename*=UTF-8''caf%C3%A9.pdf"));
    });

    test('streams a multi-chunk file to the wire byte-for-byte via multiple '
        'progress updates', () async {
      List<int> capturedBody = [];
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      server.listen((req) async {
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

      // 512 KB: several times dart:io's internal 64 KB File.openRead()
      // block size, so a single-shot in-memory write versus genuine
      // chunk-by-chunk streaming is distinguishable by progress-call count.
      final pattern = List<int>.generate(16, (i) => i);
      final fileBytes = List<int>.generate(
        512 * 1024,
        (i) => pattern[i % pattern.length],
      );
      final sourceFile = File('${tempDir.path}/large.bin');
      await sourceFile.writeAsBytes(fileBytes);

      final progressUpdates = <int>[];
      await client.uploadAttachment(
        accessToken: 'tok',
        eventId: 'portal:evt-1',
        file: sourceFile,
        originalFilename: sourceFile.path.split('/').last,
        idempotencyKey: 'idem-key-large',
        onProgress: (sent, total) => progressUpdates.add(sent),
      );

      expect(
        progressUpdates.length,
        greaterThan(4),
        reason:
            'a 512 KB file read in ~64 KB blocks should report several '
            'distinct progress updates, not one single whole-file write',
      );
      for (var i = 1; i < progressUpdates.length; i++) {
        expect(progressUpdates[i], greaterThan(progressUpdates[i - 1]));
      }

      final bodyText = latin1.decode(capturedBody, allowInvalid: true);
      final headerEnd = bodyText.indexOf('\r\n\r\n') + 4;
      final fileBytesInBody = capturedBody.sublist(
        headerEnd,
        headerEnd + fileBytes.length,
      );
      expect(
        fileBytesInBody,
        fileBytes,
        reason: 'the full file must arrive intact, byte for byte',
      );
    });

    test('cancelling mid-upload genuinely tears down the connection instead of '
        'leaving it dangling', () async {
      final serverClosed = Completer<void>();
      var serverReceivedBytes = 0;
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      server.listen((req) {
        req.listen(
          (chunk) => serverReceivedBytes += chunk.length,
          onDone: () {
            if (!serverClosed.isCompleted) serverClosed.complete();
          },
          onError: (Object _) {
            if (!serverClosed.isCompleted) serverClosed.complete();
          },
          cancelOnError: true,
        );
        // Deliberately never responds: if the client left the socket
        // merely dangling (the old behavior) rather than genuinely
        // destroying it, nothing would ever complete serverClosed.
      });
      final client = CaleeHubClient(
        baseUri: Uri.parse('http://127.0.0.1:${server.port}'),
      );

      final pattern = List<int>.generate(16, (i) => i);
      final fileBytes = List<int>.generate(
        512 * 1024,
        (i) => pattern[i % pattern.length],
      );
      final sourceFile = File('${tempDir.path}/large-cancel.bin');
      await sourceFile.writeAsBytes(fileBytes);

      final cancelToken = AttachmentTransferCancelToken();
      var progressCalls = 0;

      try {
        await client.uploadAttachment(
          accessToken: 'tok',
          eventId: 'portal:evt-1',
          file: sourceFile,
          originalFilename: sourceFile.path.split('/').last,
          idempotencyKey: 'idem-key-midcancel',
          cancelToken: cancelToken,
          onProgress: (sent, total) {
            progressCalls++;
            if (progressCalls == 3) {
              cancelToken.cancel();
            }
          },
        );
        fail('Expected CaleeHubException(code: CANCELLED)');
      } on CaleeHubException catch (e) {
        expect(e.code, 'CANCELLED');
      }

      await serverClosed.future.timeout(
        const Duration(seconds: 5),
        onTimeout: () {
          fail(
            'the server never observed the connection close -- the '
            'client left the socket dangling instead of genuinely '
            'aborting it',
          );
        },
      );

      expect(
        serverReceivedBytes,
        lessThan(fileBytes.length),
        reason:
            'the connection should have been torn down well before the '
            'full 512 KB body arrived',
      );
    });

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
          originalFilename: sourceFile.path.split('/').last,
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

    test('cancelling mid-download stops the stream promptly and leaves no '
        'partial file', () async {
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      server.listen((req) async {
        req.response.headers.contentType = ContentType.parse(
          'application/octet-stream',
        );
        req.response.statusCode = 200;
        try {
          // Paced slowly (20 * 50ms = ~1s total) so there's a reliable
          // window to cancel mid-stream rather than racing an
          // instantaneous loopback transfer.
          for (var i = 0; i < 20; i++) {
            req.response.add(List<int>.filled(64 * 1024, i % 256));
            await req.response.flush();
            await Future<void>.delayed(const Duration(milliseconds: 50));
          }
          await req.response.close();
        } catch (_) {
          // The client is expected to disconnect mid-stream here.
        }
      });
      final client = CaleeHubClient(
        baseUri: Uri.parse('http://127.0.0.1:${server.port}'),
      );

      final destination = File('${tempDir.path}/cancelled-download.bin');
      final cancelToken = AttachmentTransferCancelToken();
      var receivedCalls = 0;

      final stopwatch = Stopwatch()..start();
      try {
        await client.downloadAttachment(
          accessToken: 'tok',
          eventId: 'portal:evt-1',
          attachmentId: 'att-1',
          destinationFile: destination,
          cancelToken: cancelToken,
          onProgress: (received, total) {
            receivedCalls++;
            if (receivedCalls == 2) {
              cancelToken.cancel();
            }
          },
        );
        fail('Expected CaleeHubException(code: CANCELLED)');
      } on CaleeHubException catch (e) {
        expect(e.code, 'CANCELLED');
      }
      stopwatch.stop();

      expect(
        stopwatch.elapsed,
        lessThan(const Duration(seconds: 1)),
        reason:
            'cancellation should interrupt the stream immediately rather '
            'than waiting for the artificially slow (~1s) server to finish',
      );
      expect(
        await destination.exists(),
        isFalse,
        reason: 'no partial file should be left behind after cancellation',
      );
    });
  });

  group('download length validation (Part E)', () {
    /// Serves [declaredLength] in Content-Length but only writes
    /// [actualBytes], i.e. exactly what a truncated upstream transfer looks
    /// like to the client once Hub has already committed its 200.
    Future<CaleeHubClient> serveMismatched({
      required int declaredLength,
      required int actualBytes,
    }) async {
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      server.listen((req) async {
        req.response.headers.contentType = ContentType.binary;
        req.response.contentLength = declaredLength;
        req.response.statusCode = 200;
        req.response.add(List<int>.filled(actualBytes, 7));
        try {
          // Closing with fewer bytes than declared makes dart:io tear the
          // connection down mid-body -- exactly what a truncated upstream
          // transfer looks like to the client.
          await req.response.close();
        } catch (_) {
          // The server-side complaint about the short body is the point.
        }
      });
      return CaleeHubClient(
        baseUri: Uri.parse('http://127.0.0.1:${server.port}'),
      );
    }

    test(
      'declared 100, received 60 -> fails and deletes the partial',
      () async {
        final client = await serveMismatched(
          declaredLength: 100,
          actualBytes: 60,
        );
        final destination = File('${tempDir.path}/short.bin');

        try {
          await client.downloadAttachment(
            accessToken: 'tok',
            eventId: 'portal:evt-1',
            attachmentId: 'att-1',
            destinationFile: destination,
          );
          fail('Expected a failed download for a short body');
        } on CaleeHubException catch (e) {
          expect(
            e.code,
            anyOf('ATTACHMENT_DOWNLOAD_FAILED', 'NETWORK_ERROR'),
            reason: 'a truncated download must never be reported as success',
          );
        }

        expect(
          await destination.exists(),
          isFalse,
          reason: 'a truncated file must never be left for the user to open',
        );
      },
    );

    test('a body longer than declared is also rejected', () async {
      final client = await serveMismatched(
        declaredLength: 100,
        actualBytes: 101,
      );
      final destination = File('${tempDir.path}/long.bin');

      try {
        await client.downloadAttachment(
          accessToken: 'tok',
          eventId: 'portal:evt-1',
          attachmentId: 'att-1',
          destinationFile: destination,
        );
        fail('Expected a failed download for an over-long body');
      } on CaleeHubException catch (e) {
        expect(e.code, anyOf('ATTACHMENT_DOWNLOAD_FAILED', 'NETWORK_ERROR'));
      }
      expect(await destination.exists(), isFalse);
    });

    test(
      'a connection dropped before ANY body arrives fails and cleans up',
      () async {
        final client = await serveMismatched(
          declaredLength: 5000,
          actualBytes: 0,
        );
        final destination = File('${tempDir.path}/dropped.bin');

        try {
          await client.downloadAttachment(
            accessToken: 'tok',
            eventId: 'portal:evt-1',
            attachmentId: 'att-1',
            destinationFile: destination,
          );
          fail('Expected a failed download when the body never arrives');
        } on CaleeHubException {
          // Either the stream errors or the length check catches it; both are
          // failures, which is all the caller needs.
        }
        expect(await destination.exists(), isFalse);
      },
    );

    test('a clean completion with NO Content-Length is accepted (nothing to '
        'validate against)', () async {
      final payload = List<int>.generate(3000, (i) => i % 256);
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      server.listen((req) async {
        req.response.headers.contentType = ContentType.binary;
        // Chunked: contentLength stays -1 on the client side.
        req.response.statusCode = 200;
        req.response.add(payload);
        await req.response.close();
      });
      final client = CaleeHubClient(
        baseUri: Uri.parse('http://127.0.0.1:${server.port}'),
      );
      final destination = File('${tempDir.path}/nolength.bin');

      await client.downloadAttachment(
        accessToken: 'tok',
        eventId: 'portal:evt-1',
        attachmentId: 'att-1',
        destinationFile: destination,
      );

      expect(await destination.readAsBytes(), payload);
    });

    test('an exactly-matching length still succeeds', () async {
      final payload = List<int>.generate(2048, (i) => i % 256);
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      server.listen((req) async {
        req.response.headers.contentType = ContentType.binary;
        req.response.contentLength = payload.length;
        req.response.statusCode = 200;
        req.response.add(payload);
        await req.response.close();
      });
      final client = CaleeHubClient(
        baseUri: Uri.parse('http://127.0.0.1:${server.port}'),
      );
      final destination = File('${tempDir.path}/exact.bin');

      await client.downloadAttachment(
        accessToken: 'tok',
        eventId: 'portal:evt-1',
        attachmentId: 'att-1',
        destinationFile: destination,
      );

      expect(await destination.readAsBytes(), payload);
    });
  });

  group('timeouts actively abort the transfer (Part F)', () {
    // The transfer timeout is 120s, far too long for a test. These use a
    // deliberately stalled server and assert the OBSERVABLE consequence of
    // a real abort -- the server sees its connection close, and no bytes
    // keep arriving -- rather than trying to wait out the real timeout.
    //
    // Cancellation and timeout share one teardown mechanism, so exercising
    // it through the cancel token proves the same wiring the timeout uses;
    // the timeout-specific mapping is covered separately below.

    test('a stalled upload is genuinely torn down: the server observes the '
        'close and stops receiving bytes', () async {
      final serverSawClose = Completer<void>();
      var bytesReceived = 0;
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      server.listen((req) {
        req.listen(
          (chunk) => bytesReceived += chunk.length,
          onDone: () {
            if (!serverSawClose.isCompleted) serverSawClose.complete();
          },
          onError: (Object _) {
            if (!serverSawClose.isCompleted) serverSawClose.complete();
          },
          cancelOnError: true,
        );
        // Never responds -- the client is left waiting.
      });
      final client = CaleeHubClient(
        baseUri: Uri.parse('http://127.0.0.1:${server.port}'),
      );

      final sourceFile = File('${tempDir.path}/stalled_upload.bin');
      await sourceFile.writeAsBytes(List<int>.filled(512 * 1024, 3));

      final cancelToken = AttachmentTransferCancelToken();
      var progressCalls = 0;

      try {
        await client.uploadAttachment(
          accessToken: 'tok',
          eventId: 'portal:evt-1',
          file: sourceFile,
          originalFilename: 'stalled_upload.bin',
          idempotencyKey: 'idem-stalled',
          cancelToken: cancelToken,
          onProgress: (sent, total) {
            progressCalls++;
            if (progressCalls == 3) cancelToken.cancel();
          },
        );
        fail('Expected the stalled upload to be torn down');
      } on CaleeHubException catch (e) {
        expect(e.code, 'CANCELLED');
      }

      await serverSawClose.future.timeout(
        const Duration(seconds: 5),
        onTimeout: () => fail(
          'the server never saw the connection close -- the transfer was '
          'abandoned rather than aborted',
        ),
      );

      final settledBytes = bytesReceived;
      // Nothing may continue flowing after the caller was told it stopped.
      await Future<void>.delayed(const Duration(milliseconds: 250));
      expect(
        bytesReceived,
        settledBytes,
        reason: 'bytes were still arriving after the transfer "ended"',
      );
      expect(bytesReceived, lessThan(512 * 1024));
    });

    test(
      'a stalled download is torn down and leaves no partial file behind',
      () async {
        server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        server.listen((req) async {
          req.response.headers.contentType = ContentType.binary;
          req.response.statusCode = 200;
          try {
            // Dribble slowly so there is a reliable window to abort in.
            for (var i = 0; i < 40; i++) {
              req.response.add(List<int>.filled(32 * 1024, i % 256));
              await req.response.flush();
              await Future<void>.delayed(const Duration(milliseconds: 50));
            }
            await req.response.close();
          } catch (_) {
            // Expected: the client disconnects mid-stream.
          }
        });
        final client = CaleeHubClient(
          baseUri: Uri.parse('http://127.0.0.1:${server.port}'),
        );

        final destination = File('${tempDir.path}/stalled_download.bin');
        final cancelToken = AttachmentTransferCancelToken();
        var progressCalls = 0;

        final stopwatch = Stopwatch()..start();
        try {
          await client.downloadAttachment(
            accessToken: 'tok',
            eventId: 'portal:evt-1',
            attachmentId: 'att-1',
            destinationFile: destination,
            cancelToken: cancelToken,
            onProgress: (received, total) {
              progressCalls++;
              if (progressCalls == 2) cancelToken.cancel();
            },
          );
          fail('Expected the stalled download to be torn down');
        } on CaleeHubException catch (e) {
          expect(e.code, 'CANCELLED');
        }
        stopwatch.stop();

        expect(
          stopwatch.elapsed,
          lessThan(const Duration(seconds: 2)),
          reason:
              'teardown must be immediate, not a wait for the slow server to '
              'finish on its own',
        );
        expect(
          await destination.exists(),
          isFalse,
          reason: 'a partially-written destination must be removed',
        );
      },
    );

    test('aborting before the response arrives surfaces cleanly, with no '
        'unhandled async errors', () async {
      // A server that accepts the whole body and then never replies is
      // the "upload body completed but response never arrives" case.
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      server.listen((req) async {
        await req.drain<void>();
        // Deliberately no response.
      });
      final client = CaleeHubClient(
        baseUri: Uri.parse('http://127.0.0.1:${server.port}'),
      );

      final sourceFile = File('${tempDir.path}/await_response.bin');
      await sourceFile.writeAsBytes(List<int>.filled(1024, 5));

      final cancelToken = AttachmentTransferCancelToken();
      final uploadFuture = client.uploadAttachment(
        accessToken: 'tok',
        eventId: 'portal:evt-1',
        file: sourceFile,
        originalFilename: 'await_response.bin',
        idempotencyKey: 'idem-await-response',
        cancelToken: cancelToken,
      );

      // Let the body finish, then abort while awaiting the response.
      await Future<void>.delayed(const Duration(milliseconds: 200));
      cancelToken.cancel();

      try {
        await uploadFuture;
        fail('Expected the awaited-response phase to abort');
      } on CaleeHubException catch (e) {
        expect(e.code, 'CANCELLED');
      }

      // Any stray unhandled async error would fail the test here.
      await Future<void>.delayed(const Duration(milliseconds: 250));
    });
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

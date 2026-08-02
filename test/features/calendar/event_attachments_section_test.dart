// Widget tests for EventAttachmentsSection (lib/features/calendar/widgets/
// event_attachments_section.dart). Exercises the section against a stub
// CaleeHubClient -- no real network access -- and, for the "add" flow,
// fakes ImagePickerPlatform.instance (the plugin's own supported testing
// seam) so the "Choose photo" path can be driven end to end without a real
// device picker.
import 'dart:async';
import 'dart:io';

import 'package:calee_mobile/data/api/calee_hub_client.dart';
import 'package:calee_mobile/data/models/client_calendar.dart';
import 'package:calee_mobile/features/calendar/widgets/event_attachments_section.dart';
import 'package:calee_mobile/ui/calee_theme.dart';
import 'package:calee_mobile/ui/calee_widgets.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image_picker_platform_interface/image_picker_platform_interface.dart';
import 'package:open_filex/open_filex.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';

// ── Stubs / fakes ────────────────────────────────────────────────────────────

class _StubHub extends CaleeHubClient {
  _StubHub({
    List<CalendarAttachment> initialAttachments = const [],
    Future<CalendarAttachment> Function(
      void Function(int sent, int total)? onProgress,
    )?
    onUpload,
    void Function(String attachmentId)? onDetach,
  }) : _attachments = List.of(initialAttachments),
       _onUpload = onUpload, // ignore: prefer_initializing_formals
       _onDetach = onDetach; // ignore: prefer_initializing_formals

  List<CalendarAttachment> _attachments;
  final Future<CalendarAttachment> Function(
    void Function(int sent, int total)? onProgress,
  )?
  _onUpload;
  final void Function(String attachmentId)? _onDetach;

  int listAttachmentsCallCount = 0;
  final List<String> downloadedPaths = [];

  @override
  Future<List<CalendarAttachment>> listAttachments({
    required String accessToken,
    required String eventId,
  }) async {
    listAttachmentsCallCount++;
    return List.of(_attachments);
  }

  @override
  Future<CalendarAttachment> uploadAttachment({
    required String accessToken,
    required String eventId,
    required File file,
    required String idempotencyKey,
    void Function(int sent, int total)? onProgress,
    AttachmentTransferCancelToken? cancelToken,
  }) async {
    final attachment = await _onUpload!(onProgress);
    _attachments = [..._attachments, attachment];
    return attachment;
  }

  @override
  Future<void> downloadAttachment({
    required String accessToken,
    required String eventId,
    required String attachmentId,
    required File destinationFile,
    void Function(int received, int? total)? onProgress,
    AttachmentTransferCancelToken? cancelToken,
  }) async {
    downloadedPaths.add(destinationFile.path);
    await destinationFile.writeAsBytes([1, 2, 3, 4]);
  }

  @override
  Future<List<CalendarAttachment>> detachAttachment({
    required String accessToken,
    required String eventId,
    required String attachmentId,
  }) async {
    _onDetach?.call(attachmentId);
    _attachments = _attachments.where((a) => a.id != attachmentId).toList();
    return List.of(_attachments);
  }
}

/// Fakes the image_picker plugin's own platform seam
/// (`ImagePickerPlatform.instance`) rather than driving a real platform
/// channel, matching the pattern the plugin itself recommends for tests.
class _FakeImagePickerPlatform extends ImagePickerPlatform
    with MockPlatformInterfaceMixin {
  _FakeImagePickerPlatform(this._file);

  final XFile? _file;

  @override
  Future<XFile?> getImageFromSource({
    required ImageSource source,
    ImagePickerOptions options = const ImagePickerOptions(),
  }) async => _file;
}

/// Fakes path_provider's own platform seam (`PathProviderPlatform.instance`)
/// so `getApplicationCacheDirectory()` -- used by the attachment
/// cache-lifecycle code -- resolves to a real, writable test directory
/// instead of throwing on the unregistered method channel.
class _FakePathProviderPlatform extends PathProviderPlatform
    with MockPlatformInterfaceMixin {
  _FakePathProviderPlatform(this._cachePath);

  final String _cachePath;

  @override
  Future<String?> getApplicationCachePath() async => _cachePath;
}

// ── Fixtures / helpers ───────────────────────────────────────────────────────

CalendarAttachment _attachment({
  String id = 'att-1',
  String filename = 'doc.pdf',
  String? contentType = 'application/pdf',
  int? size = 12345,
  bool hasPreview = false,
  AttachmentScope scope = AttachmentScope.series,
  bool downloadAvailable = true,
}) {
  return CalendarAttachment(
    id: id,
    filename: filename,
    contentType: contentType,
    size: size,
    hasPreview: hasPreview,
    scope: scope,
    downloadAvailable: downloadAvailable,
  );
}

/// Never actually invoked in production, but a real OpenFilex.open() call
/// falls back to spawning a real OS process (e.g. `xdg-open`) on any
/// non-mobile platform -- unsafe and environment-dependent to let run for
/// real in a test/CI environment. EventAttachmentsSection.openFile is
/// injected precisely so tests never take that path; this is the default
/// fake used unless a test overrides it.
Future<OpenResult> _fakeOpenFile(String path) async =>
    OpenResult(type: ResultType.done, message: 'ok');

Future<void> pumpSection(
  WidgetTester tester, {
  required CaleeHubClient hub,
  required bool canAdd,
  required bool canRemove,
  bool isSeriesScoped = false,
  TextScaler? textScaler,
  Future<OpenResult> Function(String path) openFile = _fakeOpenFile,
}) {
  return tester.pumpWidget(
    MaterialApp(
      theme: CaleeTheme.buildThemeData(),
      builder: textScaler == null
          ? null
          : (context, child) => MediaQuery(
              data: MediaQuery.of(context).copyWith(textScaler: textScaler),
              child: child!,
            ),
      home: Scaffold(
        body: SingleChildScrollView(
          child: EventAttachmentsSection(
            eventId: 'portal:evt-1',
            hubClient: hub,
            accessToken: 'tok',
            canAdd: canAdd,
            canRemove: canRemove,
            isSeriesScoped: isSeriesScoped,
            openFile: openFile,
          ),
        ),
      ),
    ),
  );
}

/// Taps [finder] (which triggers _ensureDownloaded()'s genuine file I/O via
/// pumpSection()'s stub hub, chained with the openFile fake) and waits for
/// that real work to actually run. tap()/pump() must stay in the normal
/// fake-async test zone -- only the real elapsed delay goes inside
/// runAsync() -- matching the constraint documented on the "upload
/// progress" test below (mixing tap/pump into runAsync() itself hangs).
/// pumpAndSettle() alone never drives real (non-Flutter-timer) async work
/// forward, only runAsync() does -- so this polls in short real-time
/// increments until the busy row's indeterminate CircularProgressIndicator
/// actually clears (bounded, rather than guessing a single fixed delay
/// that may not be enough under a loaded machine), then a final
/// pumpAndSettle() is safe now that pumpSection()'s default openFile fake
/// always resolves immediately.
Future<void> tapAndAwaitAsyncWork(WidgetTester tester, Finder finder) async {
  await tester.tap(finder);
  await tester.pump();
  for (var i = 0; i < 100; i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 50)),
    );
    await tester.pump();
    if (find.byType(CircularProgressIndicator).evaluate().isEmpty) {
      break;
    }
  }
  await tester.pumpAndSettle();
}

void main() {
  late Directory tempDir;
  late PathProviderPlatform originalPathProviderPlatform;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp(
      'calee_attachment_widget_test_',
    );
    originalPathProviderPlatform = PathProviderPlatform.instance;
    PathProviderPlatform.instance = _FakePathProviderPlatform(tempDir.path);
  });

  tearDown(() async {
    PathProviderPlatform.instance = originalPathProviderPlatform;
    if (await tempDir.exists()) {
      await tempDir.delete(recursive: true);
    }
  });

  testWidgets('shows only the add-attachment affordance when empty', (
    tester,
  ) async {
    final hub = _StubHub();
    await pumpSection(tester, hub: hub, canAdd: true, canRemove: true);
    await tester.pumpAndSettle();

    expect(find.byType(CaleeSection), findsOneWidget);
    expect(find.byKey(const Key('add_attachment_row')), findsOneWidget);
    expect(find.byType(CaleeListRow), findsOneWidget);
  });

  testWidgets('renders every attachment in the returned list', (tester) async {
    final hub = _StubHub(
      initialAttachments: [
        _attachment(id: 'a1', filename: 'One.pdf'),
        _attachment(id: 'a2', filename: 'Two.jpg'),
        _attachment(id: 'a3', filename: 'Three.docx'),
      ],
    );
    await pumpSection(tester, hub: hub, canAdd: true, canRemove: true);
    await tester.pumpAndSettle();

    expect(find.text('One.pdf'), findsOneWidget);
    expect(find.text('Two.jpg'), findsOneWidget);
    expect(find.text('Three.docx'), findsOneWidget);
    expect(find.byKey(const Key('add_attachment_row')), findsOneWidget);
  });

  testWidgets(
    'hides entirely when there is nothing to show and nothing addable '
    '(e.g. a calendar without attachment support)',
    (tester) async {
      final hub = _StubHub();
      await pumpSection(tester, hub: hub, canAdd: false, canRemove: false);
      await tester.pumpAndSettle();

      expect(find.byType(CaleeSection), findsNothing);
      expect(find.byType(EventAttachmentsSection), findsOneWidget);
    },
  );

  testWidgets(
    'a read-only calendar hides add/remove but keeps open and share',
    (tester) async {
      final hub = _StubHub(
        initialAttachments: [_attachment(filename: 'Notes.pdf')],
      );
      await pumpSection(tester, hub: hub, canAdd: false, canRemove: false);
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('add_attachment_row')), findsNothing);
      expect(find.byTooltip('Remove Notes.pdf from event'), findsNothing);
      expect(find.byTooltip('Share Notes.pdf'), findsOneWidget);
      expect(find.text('Notes.pdf'), findsOneWidget);
    },
  );

  testWidgets(
    'a series-scoped view shows the footer and disables add/remove even '
    'when the caller would otherwise allow them',
    (tester) async {
      final hub = _StubHub(
        initialAttachments: [_attachment(filename: 'Agenda.pdf')],
      );
      await pumpSection(
        tester,
        hub: hub,
        canAdd: true,
        canRemove: true,
        isSeriesScoped: true,
      );
      await tester.pumpAndSettle();

      expect(find.text('Applies to all events in this series'), findsOneWidget);
      expect(find.byKey(const Key('add_attachment_row')), findsNothing);
      expect(find.byTooltip('Remove Agenda.pdf from event'), findsNothing);
      expect(find.text('Agenda.pdf'), findsOneWidget);
    },
  );

  testWidgets(
    'a downloadAvailable:false attachment shows the unavailable state and '
    'offers no share action, but remove is unaffected',
    (tester) async {
      final hub = _StubHub(
        initialAttachments: [
          _attachment(
            filename: 'Missing.pdf',
            downloadAvailable: false,
            size: null,
            contentType: null,
          ),
        ],
      );
      await pumpSection(tester, hub: hub, canAdd: false, canRemove: true);
      await tester.pumpAndSettle();

      expect(find.text('File no longer available'), findsOneWidget);
      final row = tester.widget<CaleeListRow>(find.byType(CaleeListRow));
      expect(
        row.onTap,
        isNull,
        reason: 'a file that is no longer available should not be tappable',
      );
      expect(find.byTooltip('Share Missing.pdf'), findsNothing);
      expect(find.byTooltip('Remove Missing.pdf from event'), findsOneWidget);
    },
  );

  testWidgets('truncates a long filename to a single line with ellipsis', (
    tester,
  ) async {
    final longName = '${'a-very-long-attachment-file-name-' * 6}.pdf';
    final hub = _StubHub(initialAttachments: [_attachment(filename: longName)]);
    await pumpSection(tester, hub: hub, canAdd: false, canRemove: false);
    await tester.pumpAndSettle();

    expect(find.text(longName), findsOneWidget);
    final row = tester.widget<CaleeListRow>(find.byType(CaleeListRow));
    expect(row.titleMaxLines, 1);
  });

  testWidgets('renders a unicode filename correctly', (tester) async {
    const name = '文件 📎 résumé — dîner.pdf';
    final hub = _StubHub(initialAttachments: [_attachment(filename: name)]);
    await pumpSection(tester, hub: hub, canAdd: false, canRemove: false);
    await tester.pumpAndSettle();

    expect(find.text(name), findsOneWidget);
  });

  testWidgets('exposes accessibility labels describing availability', (
    tester,
  ) async {
    final handle = tester.ensureSemantics();

    final hub = _StubHub(
      initialAttachments: [
        _attachment(id: 'a1', filename: 'Available.pdf'),
        _attachment(id: 'a2', filename: 'Gone.pdf', downloadAvailable: false),
      ],
    );
    await pumpSection(tester, hub: hub, canAdd: false, canRemove: false);
    await tester.pumpAndSettle();

    // Semantics doesn't create an isolated node here -- the explicit label
    // merges with descendant text/icon semantics into one combined node, so
    // this asserts the phrase is present rather than an exact node label.
    expect(
      find.bySemanticsLabel(
        RegExp(RegExp.escape('Available.pdf. Available to download.')),
      ),
      findsOneWidget,
    );
    expect(
      find.bySemanticsLabel(
        RegExp(RegExp.escape('Gone.pdf. File no longer available.')),
      ),
      findsOneWidget,
    );

    // Flutter's own end-of-test check runs before package:test's
    // addTearDown queue, so a handle registered there is still reported as
    // "active at the end of the test" -- dispose it inline instead.
    handle.dispose();
  });

  testWidgets('renders without overflow at a large text scale', (tester) async {
    final hub = _StubHub(
      initialAttachments: [
        _attachment(
          filename: 'A reasonably long quarterly report filename.pdf',
        ),
      ],
    );
    await pumpSection(
      tester,
      hub: hub,
      canAdd: true,
      canRemove: true,
      textScaler: const TextScaler.linear(2.0),
    );
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
  });

  group('remove confirmation', () {
    testWidgets('cancelling the dialog leaves the attachment in place', (
      tester,
    ) async {
      var detachCalls = 0;
      final hub = _StubHub(
        initialAttachments: [_attachment(filename: 'Keep.pdf')],
        onDetach: (_) => detachCalls++,
      );
      await pumpSection(tester, hub: hub, canAdd: false, canRemove: true);
      await tester.pumpAndSettle();

      await tester.tap(find.byTooltip('Remove Keep.pdf from event'));
      await tester.pumpAndSettle();
      expect(find.text('Remove attachment?'), findsOneWidget);

      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();

      expect(detachCalls, 0);
      expect(find.text('Keep.pdf'), findsOneWidget);
    });

    testWidgets('confirming the dialog detaches and refreshes the list', (
      tester,
    ) async {
      var detachCalls = 0;
      final hub = _StubHub(
        initialAttachments: [_attachment(filename: 'Bye.pdf')],
        onDetach: (_) => detachCalls++,
      );
      await pumpSection(tester, hub: hub, canAdd: false, canRemove: true);
      await tester.pumpAndSettle();

      await tester.tap(find.byTooltip('Remove Bye.pdf from event'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Remove'));
      await tester.pumpAndSettle();

      expect(detachCalls, 1);
      expect(find.text('Bye.pdf'), findsNothing);
    });
  });

  group('add attachment (upload progress)', () {
    late ImagePickerPlatform originalImagePickerPlatform;

    setUp(() {
      originalImagePickerPlatform = ImagePickerPlatform.instance;
    });

    tearDown(() {
      ImagePickerPlatform.instance = originalImagePickerPlatform;
    });

    testWidgets('shows an in-flight progress indicator, then the newly-added '
        'attachment once the upload resolves', (tester) async {
      final sourceFile = File('${tempDir.path}/gallery_pick.jpg');
      // testWidgets runs the callback in a fake-async zone that only
      // advances via pump() -- real file I/O never completes unless it
      // runs under the real event loop that runAsync() provides.
      await tester.runAsync(
        () => sourceFile.writeAsBytes(List<int>.filled(2048, 1)),
      );
      ImagePickerPlatform.instance = _FakeImagePickerPlatform(
        XFile(sourceFile.path),
      );

      final uploadGate = Completer<void>();
      final hub = _StubHub(
        onUpload: (onProgress) async {
          onProgress?.call(50, 100);
          await uploadGate.future;
          return _attachment(
            id: 'new-1',
            filename: 'gallery_pick.jpg',
            size: 2048,
          );
        },
      );
      await pumpSection(tester, hub: hub, canAdd: true, canRemove: true);
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const Key('add_attachment_row')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Choose photo'));
      await tester.pump();
      // _addAttachment() awaits file.length() -- genuine file I/O -- before
      // it ever sets _isUploading. Like the write above, that only
      // completes if the real event loop gets to run; pumpAndSettle alone
      // won't drive it (nothing is scheduled yet for it to wait on), so it
      // needs a real elapsed delay under runAsync first.
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 100)),
      );
      await tester.pumpAndSettle();

      expect(find.text('Uploading…'), findsOneWidget);
      final progressIndicator = tester.widget<CircularProgressIndicator>(
        find.descendant(
          of: find.byKey(const Key('add_attachment_row')),
          matching: find.byType(CircularProgressIndicator),
        ),
      );
      expect(progressIndicator.value, closeTo(0.5, 0.0001));
      expect(find.widgetWithText(TextButton, 'Cancel'), findsOneWidget);

      uploadGate.complete();
      await tester.pumpAndSettle();

      expect(find.text('Uploading…'), findsNothing);
      expect(find.text('gallery_pick.jpg'), findsOneWidget);
    });
  });

  group('attachment cache lifecycle', () {
    testWidgets(
      'opening an attachment downloads to an unpredictable filename, never '
      'the attachment ID or original filename',
      (tester) async {
        final hub = _StubHub(
          initialAttachments: [
            _attachment(id: 'secret-id-123', filename: 'my-original-name.pdf'),
          ],
        );
        await pumpSection(tester, hub: hub, canAdd: false, canRemove: false);
        await tester.pumpAndSettle();

        await tapAndAwaitAsyncWork(tester, find.text('my-original-name.pdf'));

        expect(hub.downloadedPaths, hasLength(1));
        final path = hub.downloadedPaths.single;
        expect(path, isNot(contains('secret-id-123')));
        expect(path, isNot(contains('my-original-name')));
        expect(await File(path).exists(), isTrue);
      },
    );

    testWidgets(
      'opening the same attachment twice re-downloads and deletes the '
      'previous cached copy rather than trusting it as still valid',
      (tester) async {
        final hub = _StubHub(
          initialAttachments: [_attachment(id: 'a1', filename: 'Doc.pdf')],
        );
        await pumpSection(tester, hub: hub, canAdd: false, canRemove: false);
        await tester.pumpAndSettle();

        await tapAndAwaitAsyncWork(tester, find.text('Doc.pdf'));
        expect(hub.downloadedPaths, hasLength(1));
        final firstPath = hub.downloadedPaths.single;
        expect(await File(firstPath).exists(), isTrue);

        await tapAndAwaitAsyncWork(tester, find.text('Doc.pdf'));

        expect(hub.downloadedPaths, hasLength(2));
        final secondPath = hub.downloadedPaths.last;
        expect(
          secondPath,
          isNot(firstPath),
          reason: 'each download should land at a fresh unpredictable path',
        );
        expect(
          await File(firstPath).exists(),
          isFalse,
          reason: 'the stale first copy should be deleted, not left behind',
        );
        expect(await File(secondPath).exists(), isTrue);
      },
    );

    testWidgets('removing an attachment deletes its cached local copy', (
      tester,
    ) async {
      final hub = _StubHub(
        initialAttachments: [_attachment(id: 'a1', filename: 'Bye.pdf')],
      );
      await pumpSection(tester, hub: hub, canAdd: false, canRemove: true);
      await tester.pumpAndSettle();

      await tapAndAwaitAsyncWork(tester, find.text('Bye.pdf'));
      final cachedPath = hub.downloadedPaths.single;
      expect(await File(cachedPath).exists(), isTrue);

      await tester.tap(find.byTooltip('Remove Bye.pdf from event'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Remove'));
      await tester.pumpAndSettle();
      // The delete runs fire-and-forget (unawaited) after detach resolves.
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 50)),
      );

      expect(
        await File(cachedPath).exists(),
        isFalse,
        reason:
            'a cached copy of a detached attachment should not linger on disk',
      );
    });

    testWidgets('disposing the section deletes any cache files it downloaded', (
      tester,
    ) async {
      final hub = _StubHub(
        initialAttachments: [_attachment(id: 'a1', filename: 'Temp.pdf')],
      );
      await pumpSection(tester, hub: hub, canAdd: false, canRemove: false);
      await tester.pumpAndSettle();

      await tapAndAwaitAsyncWork(tester, find.text('Temp.pdf'));
      final cachedPath = hub.downloadedPaths.single;
      expect(await File(cachedPath).exists(), isTrue);

      // Replace the widget tree entirely so EventAttachmentsSection (and
      // its State) is disposed.
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 50)),
      );

      expect(
        await File(cachedPath).exists(),
        isFalse,
        reason:
            'cache files should not outlive the editor screen that made them',
      );
    });
  });

  group('upload timeout reconciliation', () {
    testWidgets(
      'a TIMEOUT during upload refreshes the attachment list instead of '
      'just reporting failure, since the upload may have actually succeeded',
      (tester) async {
        final hub = _StubHub(
          onUpload: (onProgress) async {
            throw const CaleeHubException(
              statusCode: 0,
              code: 'TIMEOUT',
              message: 'Check your connection and try again.',
            );
          },
        );
        final sourceFile = File('${tempDir.path}/timeout_pick.jpg');
        await tester.runAsync(
          () => sourceFile.writeAsBytes(List<int>.filled(2048, 1)),
        );
        final originalPlatform = ImagePickerPlatform.instance;
        ImagePickerPlatform.instance = _FakeImagePickerPlatform(
          XFile(sourceFile.path),
        );
        addTearDown(() => ImagePickerPlatform.instance = originalPlatform);

        await pumpSection(tester, hub: hub, canAdd: true, canRemove: true);
        await tester.pumpAndSettle();
        final loadCallsBeforeUpload = hub.listAttachmentsCallCount;

        await tester.tap(find.byKey(const Key('add_attachment_row')));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Choose photo'));
        await tester.pump();
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 100)),
        );
        await tester.pumpAndSettle();

        expect(
          find.text('Upload status unknown. Checking for the attachment…'),
          findsOneWidget,
        );
        expect(
          hub.listAttachmentsCallCount,
          greaterThan(loadCallsBeforeUpload),
          reason:
              'a timed-out upload should reconcile against the server list, '
              'not just assume failure',
        );
      },
    );
  });
}

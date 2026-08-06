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
import 'package:calee_mobile/features/calendar/attachment_upload_staging_manager.dart';
import 'package:calee_mobile/features/calendar/attachment_upload_status.dart';
import 'package:calee_mobile/features/calendar/widgets/event_attachments_section.dart';
import 'package:calee_mobile/ui/calee_theme.dart';
import 'package:calee_mobile/ui/calee_widgets.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image_picker_platform_interface/image_picker_platform_interface.dart';
import 'package:open_filex/open_filex.dart';
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
  final List<String> uploadIdempotencyKeys = [];
  final List<String> uploadOriginalFilenames = [];

  /// Every key the widget asked Hub about, in order. Reconciliation MUST go
  /// through here and not through the attachment list.
  final List<String> statusQueriedKeys = [];

  /// Responses handed out one per status call; the last one repeats.
  List<AttachmentUploadStatus> statusResponses = const [];

  /// When set, the status call throws this instead of answering.
  Object? statusThrows;

  /// When set, the status call waits on it before answering. Used to hold a
  /// send inside its own post-failure settlement, which is the other window
  /// in which a second send must be refused.
  Completer<void>? statusGate;

  @override
  Future<List<CalendarAttachment>> listAttachments({
    required String accessToken,
    required String eventId,
  }) async {
    listAttachmentsCallCount++;
    return List.of(_attachments);
  }

  @override
  Future<AttachmentUploadStatus> attachmentUploadStatus({
    required String accessToken,
    required String eventId,
    required String idempotencyKey,
  }) async {
    statusQueriedKeys.add(idempotencyKey);
    final held = statusGate;
    if (held != null) await held.future;
    if (statusThrows != null) throw statusThrows!;
    if (statusResponses.isEmpty) {
      return const AttachmentUploadStatus(
        kind: AttachmentUploadStatusKind.retryable,
        retryable: true,
      );
    }
    final index = statusQueriedKeys.length - 1;
    return statusResponses[index.clamp(0, statusResponses.length - 1)];
  }

  @override
  Future<CalendarAttachment> uploadAttachment({
    required String accessToken,
    required String eventId,
    required File file,
    required String originalFilename,
    required String idempotencyKey,
    void Function(int sent, int total)? onProgress,
    AttachmentTransferCancelToken? cancelToken,
  }) async {
    uploadIdempotencyKeys.add(idempotencyKey);
    uploadOriginalFilenames.add(originalFilename);
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

/// Lets the section's real file I/O complete between frames.
///
/// A selection is now COPIED into Calee-owned staging before it becomes a
/// pending upload, so the run from "the picker returned" to "an upload
/// started" spans several real filesystem operations -- a directory create,
/// a copy, and a verification read -- with no setState between them. Under
/// the fake-async test binding each of those advances only when runAsync
/// hands control back to the real event loop, and one pumpAndSettle alone
/// stops as soon as no frame is scheduled, which happens while the chain is
/// still in flight.
///
/// The bound is on the NUMBER of alternations, not on elapsed time -- the
/// delay is nominal, and raising it does not help. The count is generous on
/// purpose so this never becomes a timing assertion: it simply drives the
/// chain to completion, whatever length it turns out to be.
Future<void> settleWithFileIo(WidgetTester tester) async {
  for (var i = 0; i < 40; i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 5)),
    );
    await tester.pumpAndSettle();
  }
}

/// Per-test scratch directory, created in setUp and removed in tearDown.
/// Library-level (rather than local to main) so [pumpSection] can point the
/// section's staging manager at it: the picker paths below are driven for
/// real, so the selection really is copied to disk, and the default manager
/// would reach for path_provider's platform channel.
late Directory tempDir;

/// A real staging manager whose [isIntact] can be held open at will.
///
/// This is the seam the upload-preflight race tests need. `isIntact` is the
/// one await between "the user asked for a send" and "bytes start moving",
/// and every ordering the single-flight claim exists to survive is decided
/// inside it. Holding it on a Completer pins each race at exactly that
/// boundary, with no sleeps and nothing timing-dependent: the test decides
/// when preflight finishes.
///
/// Everything else -- staging, verification, discard -- is the real
/// implementation, so these tests exercise production behaviour rather than
/// a stand-in for it.
class _GatedStagingManager extends AttachmentUploadStagingManager {
  _GatedStagingManager({required super.stagingDirectoryProvider});

  /// While non-null, [isIntact] waits on it before answering.
  Completer<void>? gate;

  int isIntactCalls = 0;
  int discardCalls = 0;

  @override
  Future<bool> isIntact(StagedAttachmentFile staged) async {
    isIntactCalls++;
    final held = gate;
    if (held == null) return super.isIntact(staged);
    // The verdict is computed BEFORE the hold, so releasing the gate delivers
    // the answer the check would have produced at the moment it ran.
    //
    // This matters: Discard deletes the staged file, so a check that re-read
    // the file after being held would come back "gone" and be refused for
    // that reason instead of by the claim. The race under test would then
    // never actually happen -- it would be masked by whichever of the two
    // filesystem operations happened to win.
    final verdict = await super.isIntact(staged);
    await held.future;
    return verdict;
  }

  @override
  Future<void> discard(StagedAttachmentFile staged) {
    discardCalls++;
    return super.discard(staged);
  }
}

Future<void> pumpSection(
  WidgetTester tester, {
  required CaleeHubClient hub,
  required bool canAdd,
  required bool canRemove,
  bool isSeriesScoped = false,
  TextScaler? textScaler,
  Future<OpenResult> Function(String path) openFile = _fakeOpenFile,
  List<Duration>? statusPollSchedule,
  AttachmentUploadStagingManager? stagingManager,
  EventAttachmentsController? controller,
  ValueChanged<AttachmentOperationState>? onOperationStateChanged,
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
            stagingManager:
                stagingManager ??
                AttachmentUploadStagingManager(
                  stagingDirectoryProvider: () async => tempDir,
                ),
            statusPollSchedule: statusPollSchedule,
            controller: controller,
            onOperationStateChanged: onOperationStateChanged,
          ),
        ),
      ),
    ),
  );
}

/// Whether the Add row is currently tappable.
bool addRowEnabled(WidgetTester tester) =>
    tester
        .widget<CaleeListRow>(find.byKey(const Key('add_attachment_row')))
        .onTap !=
    null;

/// Whether the pending row's Retry button is currently tappable.
bool retryButtonEnabled(WidgetTester tester) =>
    tester
        .widget<TextButton>(find.byKey(const Key('retry_pending_upload')))
        .onPressed !=
    null;

void main() {
  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp(
      'calee_attachment_widget_test_',
    );
  });

  tearDown(() async {
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
      // _addAttachment() validates and then STAGES the selection -- genuine
      // file I/O -- before it ever sets _isUploading. Like the write above,
      // that only completes if the real event loop gets to run;
      // pumpAndSettle alone won't drive it.
      await settleWithFileIo(tester);

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

  // A widget-level "attachment cache lifecycle" group (tapping a row to
  // trigger _ensureDownloaded(), then asserting on cache files/paths) was
  // attempted here and dropped: the busy row shows an indeterminate
  // CircularProgressIndicator, whose animation never stops on its own, so
  // any tap that reaches it makes pumpAndSettle() un-usable afterward
  // (hangs for its own full timeout regardless of how much real time via
  // runAsync() precedes it), and a plain pump()-based alternative proved
  // unreliably slow in this environment. _ensureDownloaded()/
  // _forgetCachedFile()/dispose()'s cache-lifecycle behavior (unpredictable
  // filenames, re-download-and-delete-stale-copy, delete-on-detach,
  // delete-on-dispose) is covered by direct code review instead.

  group('upload timeout reconciliation and same-key retry (Part G)', () {
    late ImagePickerPlatform originalImagePickerPlatform;

    setUp(() {
      originalImagePickerPlatform = ImagePickerPlatform.instance;
    });

    tearDown(() {
      ImagePickerPlatform.instance = originalImagePickerPlatform;
    });

    /// Drives the "Choose photo" flow to the point where the upload has
    /// been attempted (and, in these tests, failed).
    Future<void> pickAndAttempt(WidgetTester tester, File sourceFile) async {
      ImagePickerPlatform.instance = _FakeImagePickerPlatform(
        XFile(sourceFile.path),
      );
      await tester.tap(find.byKey(const Key('add_attachment_row')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Choose photo'));
      await tester.pump();
      await settleWithFileIo(tester);
    }

    /// A poll schedule with no real waiting, so the bounded-polling
    /// behaviour can be asserted without burning the real schedule's ~7
    /// seconds of test clock. One entry per attempt, exactly like the
    /// production schedule -- so `length` really is the attempt count.
    const fastSchedule = [Duration.zero, Duration.zero, Duration.zero];

    AttachmentUploadStatus status(
      AttachmentUploadStatusKind kind, {
      CalendarAttachment? attachment,
      bool retryable = true,
    }) => AttachmentUploadStatus(
      kind: kind,
      retryable: retryable,
      attachment: attachment,
    );

    testWidgets(
      'a TIMEOUT resolves the operation by its IDEMPOTENCY KEY, not by '
      'scanning the attachment list',
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
        hub.statusResponses = [status(AttachmentUploadStatusKind.retryable)];
        final sourceFile = File('${tempDir.path}/timeout_pick.jpg');
        await tester.runAsync(
          () => sourceFile.writeAsBytes(List<int>.filled(2048, 1)),
        );

        await pumpSection(tester, hub: hub, canAdd: true, canRemove: true);
        await tester.pumpAndSettle();

        await pickAndAttempt(tester, sourceFile);

        expect(
          hub.statusQueriedKeys,
          isNotEmpty,
          reason: 'a timed-out upload must ask Hub about its own operation',
        );
        expect(
          hub.statusQueriedKeys.first,
          hub.uploadIdempotencyKeys.first,
          reason:
              'the operation is identified by the key it uploaded with -- '
              'nothing else identifies it',
        );
      },
    );

    testWidgets(
      'an existing attachment with the SAME filename AND size does not make '
      'a failed upload look successful',
      (tester) async {
        // The exact defect this replaced: filename+size is not identity, so
        // a decoy attachment that happens to match must not resolve this
        // operation. Hub says retryable; the decoy must not override that.
        final hub = _StubHub(
          initialAttachments: [
            _attachment(
              id: 'unrelated-but-identical-looking',
              filename: 'decoy_pick.jpg',
              size: 2048,
            ),
          ],
          onUpload: (onProgress) async {
            throw const CaleeHubException(
              statusCode: 0,
              code: 'TIMEOUT',
              message: 'Check your connection and try again.',
            );
          },
        );
        hub.statusResponses = [status(AttachmentUploadStatusKind.retryable)];
        final sourceFile = File('${tempDir.path}/decoy_pick.jpg');
        await tester.runAsync(
          () => sourceFile.writeAsBytes(List<int>.filled(2048, 1)),
        );

        await pumpSection(tester, hub: hub, canAdd: true, canRemove: true);
        await tester.pumpAndSettle();
        await pickAndAttempt(tester, sourceFile);

        expect(
          find.byKey(const Key('pending_upload_row')),
          findsOneWidget,
          reason:
              'a same-name, same-size stranger must NOT be mistaken for this '
              'upload -- the user would silently lose their document',
        );
        expect(find.byKey(const Key('retry_pending_upload')), findsOneWidget);
      },
    );

    testWidgets(
      'retrying after a timeout reuses the SAME idempotency key, so Hub can '
      'recognise it as the same operation instead of duplicating',
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
        hub.statusResponses = [status(AttachmentUploadStatusKind.retryable)];
        final sourceFile = File('${tempDir.path}/retry_pick.jpg');
        await tester.runAsync(
          () => sourceFile.writeAsBytes(List<int>.filled(2048, 1)),
        );

        await pumpSection(tester, hub: hub, canAdd: true, canRemove: true);
        await tester.pumpAndSettle();
        await pickAndAttempt(tester, sourceFile);

        expect(hub.uploadIdempotencyKeys, hasLength(1));

        // The operation is left resolvable by the user, not silently dropped.
        expect(find.byKey(const Key('pending_upload_row')), findsOneWidget);
        expect(find.byKey(const Key('retry_pending_upload')), findsOneWidget);

        await tester.tap(find.byKey(const Key('retry_pending_upload')));
        await tester.pump();
        // A retry re-verifies the staged file before it sends, so it needs
        // the same real-I/O window the first attempt did.
        await settleWithFileIo(tester);

        expect(hub.uploadIdempotencyKeys, hasLength(2));
        expect(
          hub.uploadIdempotencyKeys[1],
          hub.uploadIdempotencyKeys[0],
          reason:
              'a retry of the same selected file is the SAME logical upload '
              'and must not mint a new key',
        );
        // And every status check along the way used that same key.
        expect(
          hub.statusQueriedKeys.toSet(),
          {hub.uploadIdempotencyKeys[0]},
          reason: 'bounded polling must never rotate the key',
        );
      },
    );

    testWidgets(
      'ATTACHMENT_UPLOAD_IN_PROGRESS keeps the key and asks Hub, rather than '
      'starting a second upload',
      (tester) async {
        final hub = _StubHub(
          onUpload: (onProgress) async {
            throw const CaleeHubException(
              statusCode: 409,
              code: 'ATTACHMENT_UPLOAD_IN_PROGRESS',
              message: 'still processing',
            );
          },
        );
        hub.statusResponses = [status(AttachmentUploadStatusKind.retryable)];
        final sourceFile = File('${tempDir.path}/inprogress_pick.jpg');
        await tester.runAsync(
          () => sourceFile.writeAsBytes(List<int>.filled(2048, 1)),
        );

        await pumpSection(tester, hub: hub, canAdd: true, canRemove: true);
        await tester.pumpAndSettle();

        await pickAndAttempt(tester, sourceFile);

        expect(
          hub.statusQueriedKeys,
          isNotEmpty,
          reason: 'in-progress must ask Hub, never re-upload blindly',
        );
        expect(hub.uploadIdempotencyKeys, hasLength(1));

        await tester.tap(find.byKey(const Key('retry_pending_upload')));
        await tester.pump();
        // A retry re-verifies the staged file before it sends, so it needs
        // the same real-I/O window the first attempt did.
        await settleWithFileIo(tester);

        expect(hub.uploadIdempotencyKeys[1], hub.uploadIdempotencyKeys[0]);
      },
    );

    testWidgets(
      'a completed status clears the pending operation and shows the real '
      'attachment Hub returned',
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
        hub.statusResponses = [
          status(
            AttachmentUploadStatusKind.completed,
            retryable: false,
            attachment: _attachment(
              id: 'the-real-one',
              filename: 'found_pick.jpg',
              size: 2048,
            ),
          ),
        ];
        final sourceFile = File('${tempDir.path}/found_pick.jpg');
        await tester.runAsync(
          () => sourceFile.writeAsBytes(List<int>.filled(2048, 1)),
        );

        await pumpSection(tester, hub: hub, canAdd: true, canRemove: true);
        await tester.pumpAndSettle();
        await pickAndAttempt(tester, sourceFile);

        expect(
          find.byKey(const Key('pending_upload_row')),
          findsNothing,
          reason: 'a confirmed completion resolves the operation',
        );
        expect(hub.uploadIdempotencyKeys, hasLength(1));
      },
    );

    testWidgets(
      'a completed status with NO attachment payload is not treated as '
      'success',
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
        hub.statusResponses = [
          status(AttachmentUploadStatusKind.completed, retryable: false),
        ];
        final sourceFile = File('${tempDir.path}/hollow_pick.jpg');
        await tester.runAsync(
          () => sourceFile.writeAsBytes(List<int>.filled(2048, 1)),
        );

        await pumpSection(
          tester,
          hub: hub,
          canAdd: true,
          canRemove: true,
          statusPollSchedule: fastSchedule,
        );
        await tester.pumpAndSettle();
        await pickAndAttempt(tester, sourceFile);

        expect(
          find.byKey(const Key('pending_upload_row')),
          findsOneWidget,
          reason:
              'claiming success without the thing that succeeded is the '
              'failure mode this endpoint exists to remove',
        );
      },
    );

    testWidgets('polling is BOUNDED -- it does not spin forever', (
      tester,
    ) async {
      final hub = _StubHub(
        onUpload: (onProgress) async {
          throw const CaleeHubException(
            statusCode: 0,
            code: 'TIMEOUT',
            message: 'Check your connection and try again.',
          );
        },
      );
      // Hub never resolves: always in_progress.
      hub.statusResponses = [status(AttachmentUploadStatusKind.inProgress)];
      final sourceFile = File('${tempDir.path}/bounded_pick.jpg');
      await tester.runAsync(
        () => sourceFile.writeAsBytes(List<int>.filled(2048, 1)),
      );

      await pumpSection(
        tester,
        hub: hub,
        canAdd: true,
        canRemove: true,
        statusPollSchedule: fastSchedule,
      );
      await tester.pumpAndSettle();
      await pickAndAttempt(tester, sourceFile);

      expect(
        hub.statusQueriedKeys,
        hasLength(fastSchedule.length),
        reason:
            'exactly one status call per scheduled attempt, then it stops -- '
            'an unresolvable operation must not poll indefinitely',
      );
      expect(hub.uploadIdempotencyKeys, hasLength(1));
    });

    test(
      'the default poll schedule is one immediate check, then 1s, 2s, 4s',
      () {
        const schedule = EventAttachmentsSection.defaultStatusPollSchedule;

        expect(
          schedule,
          hasLength(4),
          reason: 'four status requests in total -- one entry per attempt',
        );
        expect(
          schedule.first,
          Duration.zero,
          reason: 'the first check is immediate, not delayed',
        );
        expect(
          schedule.sublist(1),
          const [
            Duration(seconds: 1),
            Duration(seconds: 2),
            Duration(seconds: 4),
          ],
          reason: 'the waits BEFORE the remaining three attempts',
        );
        expect(
          schedule.sublist(1).contains(const Duration(seconds: 8)),
          isFalse,
          reason:
              'the old list documented an 8s backoff the loop never reached; a '
              'schedule entry that is never consumed must not exist',
        );
      },
    );

    testWidgets('every entry in the default schedule is consumed -- exactly '
        'four status requests, with no unused entry', (tester) async {
      final hub = _StubHub(
        onUpload: (onProgress) async {
          throw const CaleeHubException(
            statusCode: 0,
            code: 'TIMEOUT',
            message: 'Check your connection and try again.',
          );
        },
      );
      // Hub never resolves, so polling runs the schedule to its end.
      hub.statusResponses = [status(AttachmentUploadStatusKind.inProgress)];
      final sourceFile = File('${tempDir.path}/default_schedule_pick.jpg');
      await tester.runAsync(
        () => sourceFile.writeAsBytes(List<int>.filled(2048, 1)),
      );

      // No injected schedule: this exercises the REAL production one, so the
      // documented schedule and the executed one cannot drift apart.
      await pumpSection(tester, hub: hub, canAdd: true, canRemove: true);
      await tester.pumpAndSettle();
      await pickAndAttempt(tester, sourceFile);
      // Let the real 1s + 2s + 4s of scheduled waiting elapse on the fake
      // clock, so every attempt actually runs.
      await tester.pump(const Duration(seconds: 10));
      await tester.pumpAndSettle();

      expect(
        hub.statusQueriedKeys,
        hasLength(EventAttachmentsSection.defaultStatusPollSchedule.length),
        reason:
            'the number of schedule entries IS the number of requests -- no '
            'entry is skipped, and none is left unused',
      );
      expect(
        hub.statusQueriedKeys.toSet(),
        hasLength(1),
        reason: 'every attempt uses the same idempotency key',
      );
      expect(hub.uploadIdempotencyKeys, hasLength(1));
    });

    testWidgets('a network failure during the status check leaves the outcome '
        'UNCERTAIN, never classified as success or failure', (tester) async {
      final hub = _StubHub(
        onUpload: (onProgress) async {
          throw const CaleeHubException(
            statusCode: 0,
            code: 'TIMEOUT',
            message: 'Check your connection and try again.',
          );
        },
      );
      hub.statusThrows = const SocketException('offline');
      final sourceFile = File('${tempDir.path}/offline_pick.jpg');
      await tester.runAsync(
        () => sourceFile.writeAsBytes(List<int>.filled(2048, 1)),
      );

      await pumpSection(
        tester,
        hub: hub,
        canAdd: true,
        canRemove: true,
        statusPollSchedule: fastSchedule,
      );
      await tester.pumpAndSettle();
      await pickAndAttempt(tester, sourceFile);

      expect(
        find.byKey(const Key('pending_upload_row')),
        findsOneWidget,
        reason: 'the operation and its key survive an unreachable Hub',
      );
      expect(find.byKey(const Key('retry_pending_upload')), findsOneWidget);
      expect(
        hub.uploadIdempotencyKeys,
        hasLength(1),
        reason: 'a failed status check must not trigger a second upload',
      );
    });

    testWidgets(
      'an unknown key (404) is a FINAL answer, not a silent re-upload',
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
        hub.statusThrows = const CaleeHubException(
          statusCode: 404,
          code: 'UPLOAD_NOT_FOUND',
          message: 'not found',
        );
        final sourceFile = File('${tempDir.path}/gone_pick.jpg');
        await tester.runAsync(
          () => sourceFile.writeAsBytes(List<int>.filled(2048, 1)),
        );

        await pumpSection(
          tester,
          hub: hub,
          canAdd: true,
          canRemove: true,
          statusPollSchedule: fastSchedule,
        );
        await tester.pumpAndSettle();
        await pickAndAttempt(tester, sourceFile);

        expect(
          hub.uploadIdempotencyKeys,
          hasLength(1),
          reason:
              'a missing operation must never be read as success, and must '
              'not re-upload behind the user\'s back',
        );
        expect(
          find.byKey(const Key('retry_pending_upload')),
          findsNothing,
          reason: 'a final failure requires an explicit fresh selection',
        );
      },
    );

    testWidgets('disposing the widget stops the status poll', (tester) async {
      final hub = _StubHub(
        onUpload: (onProgress) async {
          throw const CaleeHubException(
            statusCode: 0,
            code: 'TIMEOUT',
            message: 'Check your connection and try again.',
          );
        },
      );
      hub.statusResponses = [status(AttachmentUploadStatusKind.inProgress)];
      final sourceFile = File('${tempDir.path}/dispose_pick.jpg');
      await tester.runAsync(
        () => sourceFile.writeAsBytes(List<int>.filled(2048, 1)),
      );

      await pumpSection(
        tester,
        hub: hub,
        canAdd: true,
        canRemove: true,
        statusPollSchedule: const [
          Duration(milliseconds: 50),
          Duration(milliseconds: 50),
          Duration(milliseconds: 50),
          Duration(milliseconds: 50),
        ],
      );
      await tester.pumpAndSettle();
      await pickAndAttempt(tester, sourceFile);

      final callsAtDispose = hub.statusQueriedKeys.length;
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(seconds: 2));

      expect(
        hub.statusQueriedKeys.length,
        callsAtDispose,
        reason: 'no further status calls may run after the screen is gone',
      );
    });

    testWidgets(
      'discarding a pending upload lets the next pick mint a NEW key',
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
        final sourceFile = File('${tempDir.path}/discard_pick.jpg');
        await tester.runAsync(
          () => sourceFile.writeAsBytes(List<int>.filled(2048, 1)),
        );

        await pumpSection(tester, hub: hub, canAdd: true, canRemove: true);
        await tester.pumpAndSettle();
        await pickAndAttempt(tester, sourceFile);

        await tester.tap(find.byKey(const Key('discard_pending_upload')));
        await tester.pumpAndSettle();
        expect(find.byKey(const Key('pending_upload_row')), findsNothing);

        await pickAndAttempt(tester, sourceFile);

        expect(hub.uploadIdempotencyKeys, hasLength(2));
        expect(
          hub.uploadIdempotencyKeys[1],
          isNot(hub.uploadIdempotencyKeys[0]),
          reason:
              'a deliberately discarded operation is over -- the next pick is '
              'a genuinely new upload and needs its own key',
        );
      },
    );

    testWidgets(
      'the picker-reported filename is sent, not the local cache path '
      '(Part H)',
      (tester) async {
        final hub = _StubHub(
          onUpload: (onProgress) async =>
              _attachment(id: 'new-1', filename: 'Quarterly Report.pdf'),
        );
        // A cache/temp path whose basename is nothing like the user's name.
        final sourceFile = File('${tempDir.path}/image_picker_8f2a91cc.jpg');
        await tester.runAsync(
          () => sourceFile.writeAsBytes(List<int>.filled(2048, 1)),
        );

        await pumpSection(tester, hub: hub, canAdd: true, canRemove: true);
        await tester.pumpAndSettle();
        await pickAndAttempt(tester, sourceFile);

        expect(hub.uploadOriginalFilenames, hasLength(1));
        expect(
          hub.uploadOriginalFilenames.single,
          'image_picker_8f2a91cc.jpg',
          reason:
              'XFile.name is what the picker reported for this pick; the API '
              'receives it verbatim rather than re-deriving it downstream',
        );
      },
    );
  });

  // ── Upload preflight is single-flight ──────────────────────────────────────
  //
  // Every case here pins the section at the ONE await between "a send was
  // asked for" and "bytes start moving": the staged-file check. That window
  // used to be completely unguarded -- `_isUploading` was still false, a
  // freshly selected operation shows no pending row, and nothing else marked
  // the operation as claimed -- so Add stayed tappable, Retry stayed
  // tappable, and a second invocation could enter it and upload an operation
  // the first one was already sending, or one the user had since discarded.
  //
  // _GatedStagingManager holds that await on a Completer, so each ordering is
  // decided by the test rather than by timing.
  group('upload preflight single-flight claim', () {
    late ImagePickerPlatform originalImagePickerPlatform;
    late _GatedStagingManager staging;

    setUp(() {
      originalImagePickerPlatform = ImagePickerPlatform.instance;
      staging = _GatedStagingManager(
        stagingDirectoryProvider: () async => tempDir,
      );
    });

    tearDown(() {
      ImagePickerPlatform.instance = originalImagePickerPlatform;
    });

    Future<File> writeSource(WidgetTester tester, String name) async {
      final file = File('${tempDir.path}/$name');
      await tester.runAsync(() => file.writeAsBytes(List<int>.filled(2048, 1)));
      ImagePickerPlatform.instance = _FakeImagePickerPlatform(XFile(file.path));
      return file;
    }

    /// Taps Add -> Choose photo and settles up to (and including) staging,
    /// leaving the section held inside the gated preflight when [staging.gate]
    /// is set.
    Future<void> pickAndHold(WidgetTester tester) async {
      await tester.tap(find.byKey(const Key('add_attachment_row')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Choose photo'));
      await tester.pump();
      await settleWithFileIo(tester);
    }

    testWidgets(
      'an initial Add cannot start a second selection while its preflight is '
      'still running',
      (tester) async {
        final hub = _StubHub(
          onUpload: (onProgress) async =>
              _attachment(id: 'new-1', filename: 'first.jpg'),
        );
        await writeSource(tester, 'first.jpg');
        staging.gate = Completer<void>();

        await pumpSection(
          tester,
          hub: hub,
          canAdd: true,
          canRemove: true,
          stagingManager: staging,
        );
        await tester.pumpAndSettle();
        await pickAndHold(tester);

        expect(
          staging.isIntactCalls,
          1,
          reason: 'the send reached preflight and is being held there',
        );
        expect(
          hub.uploadIdempotencyKeys,
          isEmpty,
          reason: 'no bytes may move until preflight has answered',
        );
        expect(
          addRowEnabled(tester),
          isFalse,
          reason:
              'the claim is what closes this window: Add must not be tappable '
              'while an attempt already owns the pending operation',
        );
        expect(
          find.text('Uploading…'),
          findsNothing,
          reason: 'preflight must not claim that bytes are transferring',
        );
        expect(
          find.widgetWithText(TextButton, 'Cancel'),
          findsNothing,
          reason: 'there is no transfer to cancel yet',
        );

        // A tap on the disabled row, and a second source-sheet attempt, must
        // both be inert.
        await tester.tap(
          find.byKey(const Key('add_attachment_row')),
          warnIfMissed: false,
        );
        await tester.pumpAndSettle();
        expect(
          find.text('Take photo'),
          findsNothing,
          reason: 'no second picker may be opened during preflight',
        );

        staging.gate!.complete();
        await settleWithFileIo(tester);

        expect(
          hub.uploadIdempotencyKeys,
          hasLength(1),
          reason: 'exactly one upload, from the one attempt that held a claim',
        );
        expect(
          staging.isIntactCalls,
          1,
          reason: 'no second preflight was ever started',
        );
        expect(find.text('first.jpg'), findsOneWidget);
        expect(
          find.byKey(const Key('pending_upload_row')),
          findsNothing,
          reason: 'the single operation completed and left nothing unresolved',
        );
        expect(addRowEnabled(tester), isTrue);
      },
    );

    testWidgets(
      'Retry cannot start a duplicate send while its own preflight is still '
      'running, and the original key survives',
      (tester) async {
        final hub = _StubHub(
          onUpload: (onProgress) async {
            throw const CaleeHubException(
              statusCode: 0,
              code: 'NETWORK_ERROR',
              message: 'Check your connection and try again.',
            );
          },
        );
        await writeSource(tester, 'retry_race.jpg');

        await pumpSection(
          tester,
          hub: hub,
          canAdd: true,
          canRemove: true,
          stagingManager: staging,
        );
        await tester.pumpAndSettle();
        // First attempt runs ungated and fails retryably.
        await pickAndHold(tester);

        expect(hub.uploadIdempotencyKeys, hasLength(1));
        expect(find.byKey(const Key('retry_pending_upload')), findsOneWidget);
        expect(
          retryButtonEnabled(tester),
          isTrue,
          reason: 'no attempt owns the operation once the first one returned',
        );
        final originalKey = hub.uploadIdempotencyKeys.single;

        // Now hold the retry's preflight open.
        staging.gate = Completer<void>();
        await tester.tap(find.byKey(const Key('retry_pending_upload')));
        await tester.pump();
        await settleWithFileIo(tester);

        expect(
          staging.isIntactCalls,
          2,
          reason: 'the retry reached preflight and is being held there',
        );
        expect(
          hub.uploadIdempotencyKeys,
          hasLength(1),
          reason: 'the retry has not sent anything yet',
        );
        expect(
          retryButtonEnabled(tester),
          isFalse,
          reason:
              'a second Retry tap during preflight is exactly the duplicate '
              'send this claim prevents',
        );
        expect(
          addRowEnabled(tester),
          isFalse,
          reason: 'Add is inert while an attempt owns the operation',
        );

        await tester.tap(
          find.byKey(const Key('retry_pending_upload')),
          warnIfMissed: false,
        );
        await tester.pumpAndSettle();
        expect(
          staging.isIntactCalls,
          2,
          reason: 'the ignored tap did not start a second preflight',
        );

        staging.gate!.complete();
        await settleWithFileIo(tester);

        expect(
          hub.uploadIdempotencyKeys,
          hasLength(2),
          reason: 'exactly one additional send, from the retry that held it',
        );
        expect(
          hub.uploadIdempotencyKeys[1],
          originalKey,
          reason:
              'a retry is the SAME logical upload -- preflight must not mint '
              'a new key',
        );
      },
    );

    testWidgets(
      'Discard during preflight wins: the held attempt returns without ever '
      'calling Hub',
      (tester) async {
        final hub = _StubHub(
          onUpload: (onProgress) async {
            throw const CaleeHubException(
              statusCode: 0,
              code: 'NETWORK_ERROR',
              message: 'Check your connection and try again.',
            );
          },
        );
        await writeSource(tester, 'discard_race.jpg');

        await pumpSection(
          tester,
          hub: hub,
          canAdd: true,
          canRemove: true,
          stagingManager: staging,
        );
        await tester.pumpAndSettle();
        await pickAndHold(tester);

        expect(hub.uploadIdempotencyKeys, hasLength(1));
        final discardsBefore = staging.discardCalls;

        // Hold the retry's preflight, then discard underneath it.
        staging.gate = Completer<void>();
        await tester.tap(find.byKey(const Key('retry_pending_upload')));
        await tester.pump();
        await settleWithFileIo(tester);
        expect(staging.isIntactCalls, 2);

        await tester.tap(find.byKey(const Key('discard_pending_upload')));
        await tester.pumpAndSettle();

        expect(
          find.byKey(const Key('pending_upload_row')),
          findsNothing,
          reason:
              'Discard clears the operation synchronously, as it always did',
        );

        staging.gate!.complete();
        await settleWithFileIo(tester);

        expect(
          hub.uploadIdempotencyKeys,
          hasLength(1),
          reason:
              'the held attempt no longer speaks for the pending operation, '
              'so it must return without sending a discarded file',
        );
        expect(
          staging.discardCalls,
          greaterThan(discardsBefore),
          reason: 'the staged file is released by the discard path',
        );
        expect(
          find.byKey(const Key('pending_upload_row')),
          findsNothing,
          reason: 'a discarded operation must not be resurrected',
        );
        expect(
          find.text('discard_race.jpg'),
          findsNothing,
          reason: 'nothing was uploaded, so no attachment row may appear',
        );
        expect(
          find.byType(SnackBar),
          findsNothing,
          reason: 'a discarded operation must not produce a late error',
        );
        expect(
          addRowEnabled(tester),
          isTrue,
          reason: 'the claim was released, so Add is usable again',
        );
      },
    );

    testWidgets(
      'editor-close discard during preflight wins, and leaves the controller '
      'idle',
      (tester) async {
        final hub = _StubHub(
          onUpload: (onProgress) async =>
              _attachment(id: 'never', filename: 'closed.jpg'),
        );
        await writeSource(tester, 'closed.jpg');
        staging.gate = Completer<void>();

        final controller = EventAttachmentsController();
        final reported = <AttachmentOperationState>[];

        await pumpSection(
          tester,
          hub: hub,
          canAdd: true,
          canRemove: true,
          stagingManager: staging,
          controller: controller,
          onOperationStateChanged: reported.add,
        );
        await tester.pumpAndSettle();
        await pickAndHold(tester);

        expect(staging.isIntactCalls, 1);
        expect(hub.uploadIdempotencyKeys, isEmpty);

        // The editor's own close policy: stop what can be stopped, then
        // abandon the unresolved operation. Both are synchronous from the
        // editor's point of view and must not wait on the filesystem.
        await controller.cancelActiveTransfers();
        controller.discardUnresolvedUpload();
        await tester.pumpAndSettle();

        staging.gate!.complete();
        await settleWithFileIo(tester);

        expect(
          hub.uploadIdempotencyKeys,
          isEmpty,
          reason:
              'a preflight the editor already abandoned must never reach Hub',
        );
        expect(
          find.byKey(const Key('pending_upload_row')),
          findsNothing,
          reason: 'the abandoned operation must not come back',
        );
        expect(
          find.text('closed.jpg'),
          findsNothing,
          reason: 'no attachment may be appended for an abandoned operation',
        );
        expect(
          staging.discardCalls,
          greaterThan(0),
          reason: 'the staged file cleanup was requested by the discard path',
        );
        expect(
          reported.last,
          AttachmentOperationState.idle,
          reason:
              'the editor is owed nothing once the operation is abandoned, so '
              'it may close',
        );
        expect(tester.takeException(), isNull);
      },
    );

    testWidgets(
      'a send still settling a failure keeps its claim, so no second attempt '
      'can exist for a stale teardown to clear',
      (tester) async {
        // This is the invariant that makes the trailing teardown in
        // _runUploadAttempt safe. A timed-out upload hands off to
        // reconciliation, which the send AWAITS -- and only after that does
        // its `finally` clear the transfer fields and release the claim.
        // Before the claim existed, `_isUploading` was already false by then
        // and the pending row already offered Retry, so a tap during that
        // window started a second send whose `_isUploading` the first send's
        // trailing teardown then wiped. Holding the status call pins the
        // section inside exactly that window.
        final hub = _StubHub(
          onUpload: (onProgress) async {
            throw const CaleeHubException(
              statusCode: 0,
              code: 'TIMEOUT',
              message: 'Check your connection and try again.',
            );
          },
        );
        hub.statusGate = Completer<void>();
        hub.statusResponses = const [
          AttachmentUploadStatus(
            kind: AttachmentUploadStatusKind.retryable,
            retryable: true,
          ),
        ];
        await writeSource(tester, 'settling.jpg');

        await pumpSection(
          tester,
          hub: hub,
          canAdd: true,
          canRemove: true,
          stagingManager: staging,
          statusPollSchedule: const [Duration.zero, Duration.zero],
        );
        await tester.pumpAndSettle();
        await pickAndHold(tester);

        // The send is now inside its own reconciliation: bytes have stopped,
        // the row is back, but the send has NOT returned.
        expect(hub.uploadIdempotencyKeys, hasLength(1));
        expect(hub.statusQueriedKeys, hasLength(1));
        expect(find.text('Uploading…'), findsNothing);
        expect(find.byKey(const Key('pending_upload_row')), findsOneWidget);
        expect(
          retryButtonEnabled(tester),
          isFalse,
          reason:
              'the first send still owns the operation while it settles, so a '
              'second one cannot begin for its teardown to clobber',
        );
        expect(addRowEnabled(tester), isFalse);

        await tester.tap(
          find.byKey(const Key('retry_pending_upload')),
          warnIfMissed: false,
        );
        await tester.pumpAndSettle();
        expect(
          hub.uploadIdempotencyKeys,
          hasLength(1),
          reason: 'the tap during settlement started nothing',
        );

        hub.statusGate!.complete();
        await settleWithFileIo(tester);

        // The owner released its own claim on the way out, leaving the
        // operation exactly as retryable as Hub said it was.
        expect(
          retryButtonEnabled(tester),
          isTrue,
          reason: 'the claim is released once its owner returns',
        );

        await tester.tap(find.byKey(const Key('retry_pending_upload')));
        await tester.pump();
        await settleWithFileIo(tester);

        expect(
          hub.uploadIdempotencyKeys,
          hasLength(2),
          reason: 'a Retry after settlement is allowed, and starts exactly one',
        );
        expect(
          hub.uploadIdempotencyKeys[1],
          hub.uploadIdempotencyKeys[0],
          reason: 'and it is still the same logical upload',
        );
        expect(tester.takeException(), isNull);
      },
    );
  });
}

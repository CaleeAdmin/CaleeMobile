import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_timezone/flutter_timezone.dart';
import 'package:image_picker/image_picker.dart';

import '../../../data/api/calee_hub_client.dart';
import '../../../data/models/client_calendar.dart';
import '../../../data/models/client_event_draft.dart';
import '../../../shared/recurrence/calee_repeat_picker_sheet.dart';
import '../../../shared/recurrence/calee_repeat_rule.dart';
import '../../../ui/calee_design.dart';
import '../event_draft_image_preparer.dart';
import 'calendar_widget_helpers.dart';
import 'event_attachments_section.dart';

class CreateEventSheet extends StatefulWidget {
  const CreateEventSheet({
    required this.calendars,
    required this.onCreate,
    required this.hubClient,
    required this.accessToken,
    required this.use24h,
    this.initialDate,
    this.initialEvent,
    this.editScope,
    this.defaultCalendarId,
    this.onUpdate,
    this.showDragHandle = true,
    super.key,
  });

  final List<ClientCalendar> calendars;
  final bool use24h;

  /// Whether to draw the sheet's drag handle.
  ///
  /// Set by the caller to match how the sheet was actually presented. An
  /// editor that can hold attachment work is shown with `enableDrag: false`
  /// (the framework's drag-to-dismiss pops directly, bypassing this
  /// widget's close policy), and a handle on a sheet that cannot be dragged
  /// advertises an interaction that does not exist.
  final bool showDragHandle;
  final DateTime? initialDate;
  final ClientEvent? initialEvent;
  final String? editScope;
  final String? defaultCalendarId;
  final CaleeHubClient hubClient;
  final String accessToken;
  final Future<void> Function({
    required ClientCalendar calendar,
    required String title,
    required DateTime startsAt,
    required DateTime endsAt,
    required bool allDay,
    String? location,
    String? description,
    String? recurrence,
  })
  onCreate;
  final Future<void> Function({
    required ClientEvent event,
    required String title,
    required DateTime? startsAt,
    required DateTime? endsAt,
    required bool? allDay,
    String? location,
    String? description,
    String? recurrence,
    String? editScope,
  })?
  onUpdate;

  @override
  State<CreateEventSheet> createState() => _CreateEventSheetState();
}

class _CreateEventSheetState extends State<CreateEventSheet> {
  final _formKey = GlobalKey<FormState>();
  final _titleController = TextEditingController();
  final _locationController = TextEditingController();
  final _descriptionController = TextEditingController();

  late ClientCalendar _selectedCalendar;
  late DateTime _selectedDate;
  late DateTime _selectedEndDate;
  late TimeOfDay _startTime;
  late TimeOfDay _endTime;
  CaleeRepeatRule _selectedRepeatRule = CaleeRepeatRule.none;
  bool _allDay = false;
  bool _isSubmitting = false;
  bool _isScanningImage = false;

  /// What the attachments section is doing, as it last reported it. The
  /// editor cannot see inside that section, and used to close straight over
  /// the top of an upload it knew nothing about.
  AttachmentOperationState _attachmentOperations =
      AttachmentOperationState.idle;

  /// Lets [_requestClose] cancel in-flight transfers and drop an unresolved
  /// upload when the user chooses to close anyway.
  final EventAttachmentsController _attachmentsController =
      EventAttachmentsController();

  /// A close request is being decided: the confirmation is on screen, or
  /// its answer is still being acted on. Stops a Back press landing on top
  /// of the dialog it just opened and stacking a second one.
  bool _closeRequestInProgress = false;

  /// The editor is committed to closing. Distinct from
  /// [_closeRequestInProgress] because a request can end in "Keep editing",
  /// which must leave the editor fully usable again, whereas this one is
  /// one-way.
  bool _isClosing = false;

  bool get _isEditing => widget.initialEvent != null;
  bool get _isEditingSingleOccurrence =>
      _isEditing &&
      widget.initialEvent!.recurring &&
      widget.editScope == 'occurrence';

  bool get _isLocked => _isSubmitting || _isScanningImage;

  /// True while the attachments section has work that closing the editor
  /// would destroy: a transfer in flight, or an upload whose outcome is
  /// still unresolved.
  ///
  /// Saving is a close too -- `_submit` pops the sheet on success, which
  /// disposes the attachments section and cancels whatever it was doing.
  /// So submission is gated on exactly the same condition as closing, and
  /// the user resolves the attachment first rather than discovering
  /// afterwards that it never made it.
  bool get _hasBlockingAttachmentWork =>
      _attachmentOperations.blocksEditorClose;

  @override
  void initState() {
    super.initState();

    assert(
      widget.calendars.isNotEmpty,
      'CreateEventSheet requires at least one calendar',
    );
    _selectedCalendar = widget.calendars.first;
    if (widget.defaultCalendarId != null) {
      for (final cal in widget.calendars) {
        if (cal.id == widget.defaultCalendarId) {
          _selectedCalendar = cal;
          break;
        }
      }
    }

    final event = widget.initialEvent;
    if (event != null) {
      _titleController.text = event.title;
      _locationController.text = event.location ?? '';
      _descriptionController.text = event.description ?? '';
      _allDay = event.allDay;

      final start =
          DateTime.tryParse(event.startsAt)?.toLocal() ?? DateTime.now();
      final end =
          DateTime.tryParse(event.endsAt)?.toLocal() ??
          start.add(const Duration(hours: 1));

      _selectedDate = DateTime(start.year, start.month, start.day);
      _selectedEndDate = event.allDay
          ? DateTime(
              end.year,
              end.month,
              end.day,
            ).subtract(const Duration(days: 1))
          : _selectedDate;

      if (!_isEditingSingleOccurrence) {
        _applyInitialRecurrence(event.recurrence);
      }

      if (_selectedEndDate.isBefore(_selectedDate)) {
        _selectedEndDate = _selectedDate;
      }

      _startTime = TimeOfDay(hour: start.hour, minute: start.minute);
      _endTime = TimeOfDay(hour: end.hour, minute: end.minute);
      return;
    }

    // Use initialDate from calendar selection if provided, else today
    final initial = widget.initialDate;
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    _selectedDate = initial != null
        ? DateTime(initial.year, initial.month, initial.day)
        : today;
    _selectedEndDate = _selectedDate;

    // Default times: 9:00–10:00 for future dates, next hour for today
    if (isSameCalendarDay(_selectedDate, today)) {
      final nextHour = now.add(const Duration(hours: 1));
      // Clamp to 22 so end (start + 1) never wraps past midnight on the same day.
      final startHour = nextHour.hour.clamp(0, 22);
      _startTime = TimeOfDay(hour: startHour, minute: 0);
      _endTime = TimeOfDay(hour: startHour + 1, minute: 0);
    } else {
      _startTime = const TimeOfDay(hour: 9, minute: 0);
      _endTime = const TimeOfDay(hour: 10, minute: 0);
    }
  }

  @override
  void dispose() {
    _titleController.dispose();
    _locationController.dispose();
    _descriptionController.dispose();
    super.dispose();
  }

  // ── Closing ───────────────────────────────────────────────────────────────

  /// The ONE way this editor closes by user intent -- the top Close button,
  /// Android Back, an iOS back gesture, a tap on the modal barrier, and any
  /// programmatic pop all arrive here through [PopScope].
  ///
  /// Saving is deliberately not routed through it: `_submit` closes because
  /// the user asked to save, which is a different intent from abandoning the
  /// editor, and the attachments section cancels cleanly on disposal either
  /// way.
  Future<void> _requestClose() async {
    // Single-flight: one confirmation at a time, and a committed close can
    // never be started twice. Both flags are set BEFORE the first await, so
    // a second request arriving while the dialog is up is refused rather
    // than opening a competing one.
    if (_closeRequestInProgress || _isClosing) return;
    _closeRequestInProgress = true;
    try {
      // Note the absence of an _isLocked check: submitting or scanning has
      // never blocked Back or a barrier tap, and this method must not
      // quietly start. The attachment policy below is the only new gate.
      final operations = _attachmentOperations;
      if (!operations.blocksEditorClose) {
        _isClosing = true;
        _closeNow();
        return;
      }

      final isTransferring = operations.hasActiveTransfer;
      final confirmed = await CaleeDestructiveDialog.show(
        context: context,
        title: isTransferring
            ? 'Attachment still transferring'
            : 'Unfinished attachment upload',
        body: isTransferring
            ? 'An attachment is still being uploaded or downloaded. Closing '
                  'now cancels it.'
            : "One attachment upload hasn't finished. Closing now discards "
                  'it, and the file will not be attached.',
        confirmLabel: isTransferring
            ? 'Cancel attachment and close'
            : 'Discard upload and close',
        cancelLabel: 'Keep editing',
      );
      // "Keep editing" ends the request and leaves everything usable.
      if (!confirmed || !mounted) return;

      _isClosing = true;
      if (isTransferring) {
        // Stop the transfer and wait for it to actually unwind, so the
        // editor is never dismissed on top of a spinner still running.
        await _attachmentsController.cancelActiveTransfers();
      }
      // A cancelled upload can leave an operation whose server-side outcome
      // is unknown. The user has already said to close, so that operation is
      // dropped here rather than asking a second time.
      _attachmentsController.discardUnresolvedUpload();
      if (mounted) _closeNow();
    } finally {
      // Released only when the editor is staying: once committed to closing,
      // the flag stays set so nothing can re-enter on the way out.
      if (!_isClosing) _closeRequestInProgress = false;
    }
  }

  void _closeNow() {
    // Deliberately unconditional: this runs only after the close policy has
    // been satisfied, so it must not be re-intercepted by PopScope.
    Navigator.of(context).pop();
  }

  void _handleAttachmentOperationState(AttachmentOperationState state) {
    if (_attachmentOperations == state) return;
    _attachmentOperations = state;
    // The submit button's enabled state reads this, so the editor does have
    // to rebuild. Guarded on mounted because the section reports one final
    // idle state as it is disposed, which happens while this sheet is
    // already being torn down.
    if (mounted) setState(() {});
  }

  DateTime _dateTimeFor(TimeOfDay time) {
    return DateTime(
      _selectedDate.year,
      _selectedDate.month,
      _selectedDate.day,
      time.hour,
      time.minute,
    );
  }

  String _dateLabel(DateTime value) {
    return '${value.day}/${value.month}/${value.year}';
  }

  String _timeLabel(TimeOfDay value) {
    if (widget.use24h) {
      final hour = value.hour.toString().padLeft(2, '0');
      final minute = value.minute.toString().padLeft(2, '0');
      return '$hour:$minute';
    }
    final h12 = value.hour % 12 == 0 ? 12 : value.hour % 12;
    final period = value.hour < 12 ? 'AM' : 'PM';
    if (value.minute == 0) return '$h12 $period';
    return '$h12:${value.minute.toString().padLeft(2, '0')} $period';
  }

  void _applyInitialRecurrence(String? recurrence) {
    _selectedRepeatRule = CaleeRepeatRule.fromRrule(
      recurrence,
      anchorDate: _selectedDate,
    );
  }

  String? _recurrenceValue() =>
      _selectedRepeatRule.toRrule(anchorDate: _selectedDate);

  Future<void> _pickRepeat() async {
    await CaleeRepeatPickerSheet.show(
      context: context,
      current: _selectedRepeatRule,
      anchorDate: _selectedDate,
      onSelected: (rule) {
        setState(() => _selectedRepeatRule = rule);
      },
    );
  }

  Future<void> _pickDate() async {
    final picked = await showDatePicker(
      context: context,
      initialDate: _selectedDate,
      firstDate: DateTime(2020),
      lastDate: DateTime(2100),
    );

    if (picked != null && mounted) {
      setState(() {
        _selectedDate = DateTime(picked.year, picked.month, picked.day);
        if (_selectedEndDate.isBefore(_selectedDate)) {
          _selectedEndDate = _selectedDate;
        }
      });
    }
  }

  Future<void> _pickEndDate() async {
    final picked = await showDatePicker(
      context: context,
      initialDate: _selectedEndDate.isBefore(_selectedDate)
          ? _selectedDate
          : _selectedEndDate,
      firstDate: _selectedDate,
      lastDate: DateTime(2100),
    );

    if (picked != null && mounted) {
      setState(() {
        _selectedEndDate = DateTime(picked.year, picked.month, picked.day);
      });
    }
  }

  Future<void> _pickStartTime() async {
    final picked = await showTimePicker(
      context: context,
      initialTime: _startTime,
    );

    if (picked != null && mounted) {
      setState(() {
        _startTime = picked;
      });
    }
  }

  Future<void> _pickEndTime() async {
    final picked = await showTimePicker(
      context: context,
      initialTime: _endTime,
    );

    if (picked != null && mounted) {
      setState(() {
        _endTime = picked;
      });
    }
  }

  // ── Scan image ────────────────────────────────────────────────────────────

  Future<ImageSource?> _pickImageSource() async {
    final result = Completer<ImageSource?>();
    await CaleeActionSheet.show(
      context: context,
      actions: [
        CaleeAction(
          label: 'Take photo',
          icon: Icons.camera_alt_outlined,
          onTap: () => result.complete(ImageSource.camera),
        ),
        CaleeAction(
          label: 'Choose photo',
          icon: Icons.photo_library_outlined,
          onTap: () => result.complete(ImageSource.gallery),
        ),
      ],
    );
    if (!result.isCompleted) result.complete(null);
    return result.future;
  }

  void _applyDraft(ClientEventDraft draft) {
    setState(() {
      if (draft.title.isNotEmpty) _titleController.text = draft.title;
      if (draft.location != null) _locationController.text = draft.location!;
      if (draft.description != null) {
        _descriptionController.text = draft.description!;
      }
      _allDay = draft.allDay;

      final startsAt = draft.startsAt?.toLocal();
      if (startsAt != null) {
        _selectedDate = DateTime(startsAt.year, startsAt.month, startsAt.day);
        _startTime = TimeOfDay(hour: startsAt.hour, minute: startsAt.minute);
        if (_selectedEndDate.isBefore(_selectedDate)) {
          _selectedEndDate = _selectedDate;
        }
      }

      final endsAt = draft.endsAt?.toLocal();
      if (endsAt != null) {
        if (_allDay) {
          _selectedEndDate = DateTime(
            endsAt.year,
            endsAt.month,
            endsAt.day,
          ).subtract(const Duration(days: 1));
          if (_selectedEndDate.isBefore(_selectedDate)) {
            _selectedEndDate = _selectedDate;
          }
        } else {
          _endTime = TimeOfDay(hour: endsAt.hour, minute: endsAt.minute);
        }
      } else if (startsAt != null && !_allDay) {
        final inferredEnd = startsAt.add(const Duration(hours: 1));
        _endTime = TimeOfDay(
          hour: inferredEnd.hour % 24,
          minute: inferredEnd.minute,
        );
      }
    });
  }

  Future<ClientEventDraft?> _pickDraft(List<ClientEventDraft> drafts) {
    return showDialog<ClientEventDraft>(
      context: context,
      builder: (ctx) => SimpleDialog(
        title: const Text('Multiple events found'),
        children: [
          for (final draft in drafts)
            SimpleDialogOption(
              onPressed: () => Navigator.of(ctx).pop(draft),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    draft.title.isNotEmpty ? draft.title : 'Untitled event',
                    style: Theme.of(ctx).textTheme.bodyMedium,
                  ),
                  if (draft.startsAt != null)
                    Text(
                      _formatDraftDateTime(draft.startsAt!),
                      style: Theme.of(ctx).textTheme.bodySmall?.copyWith(
                        color: CaleeColors.textSecondary,
                      ),
                    ),
                ],
              ),
            ),
          SimpleDialogOption(
            onPressed: () => Navigator.of(ctx).pop(),
            child: Text('Cancel', style: TextStyle(color: CaleeColors.primary)),
          ),
        ],
      ),
    );
  }

  String _formatDraftDateTime(DateTime dt) {
    final local = dt.toLocal();
    final h = local.hour.toString().padLeft(2, '0');
    final m = local.minute.toString().padLeft(2, '0');
    return '${local.day}/${local.month}/${local.year} $h:$m';
  }

  Future<bool?> _confirmReplace() {
    return showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Replace event details?'),
        content: const Text(
          'Replace current event details with scanned details?',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Replace'),
          ),
        ],
      ),
    );
  }

  Future<void> _scanImage() async {
    final source = await _pickImageSource();
    if (source == null || !mounted) return;

    final xFile = await ImagePicker().pickImage(source: source);
    if (xFile == null || !mounted) return;

    final formHasContent =
        _titleController.text.trim().isNotEmpty ||
        _locationController.text.trim().isNotEmpty ||
        _descriptionController.text.trim().isNotEmpty;

    setState(() => _isScanningImage = true);

    File? compressedFile;
    try {
      compressedFile = await EventDraftImagePreparer().prepare(xFile);

      if (kDebugMode) {
        debugPrint('EventDraftsFromImage: picked ${xFile.path}');
        debugPrint('EventDraftsFromImage: compressed ${compressedFile.path}');
      }

      String? tz;
      try {
        tz = await FlutterTimezone.getLocalTimezone();
      } catch (_) {
        // Timezone unavailable; omit timezone hint from the request.
      }

      final now = DateTime.now();
      final referenceDate =
          '${now.year.toString().padLeft(4, '0')}-'
          '${now.month.toString().padLeft(2, '0')}-'
          '${now.day.toString().padLeft(2, '0')}';

      if (kDebugMode) {
        debugPrint('EventDraftsFromImage: uploading ${compressedFile.path}');
      }

      final response = await widget.hubClient.eventDraftsFromImage(
        accessToken: widget.accessToken,
        imageFile: compressedFile,
        timezone: tz,
        referenceDate: referenceDate,
        sourceHint: 'calendar image',
      );

      if (kDebugMode) {
        debugPrint(
          'EventDraftsFromImage: upload returned drafts=${response.drafts.length}',
        );
      }

      if (!mounted) return;
      setState(() => _isScanningImage = false);

      final drafts = response.drafts;
      if (kDebugMode) {
        debugPrint('EventDraftsFromImage: drafts=${drafts.length}');
      }
      if (drafts.isEmpty) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text("I couldn't find an event in this image."),
          ),
        );
        return;
      }

      ClientEventDraft selectedDraft;
      if (drafts.length == 1) {
        selectedDraft = drafts.first;
      } else {
        final picked = await _pickDraft(drafts);
        if (picked == null || !mounted) return;
        selectedDraft = picked;
      }

      if (formHasContent) {
        final replace = await _confirmReplace();
        if (!mounted || replace != true) return;
      }

      _applyDraft(selectedDraft);
    } catch (error) {
      if (kDebugMode) {
        debugPrint('EventDraftsFromImage: error=$error');
        if (error is CaleeHubException) {
          debugPrint('EventDraftsFromImage: ${error.debugSummary}');
        }
      }

      if (!mounted) return;
      setState(() => _isScanningImage = false);

      String message = 'Could not scan image. Please try again.';
      if (error is UnsupportedImageFormatException) {
        message = 'Please choose a JPEG, PNG, or WebP image.';
      } else if (error is ImageTooLargeException) {
        message = 'This image is too large. Please choose an image under 8 MB.';
      } else if (error is CaleeHubException) {
        if (error.code == 'AI_IMAGE_TIMEOUT') {
          message = 'Image scanning is taking too long. Please try again.';
        } else if (error.code == 'NETWORK_ERROR') {
          message = 'Check your connection and try again.';
        } else if (error.code == 'FILE_TOO_LARGE') {
          message = error.message;
        } else if (error.statusCode == 401) {
          assert(() {
            if (error.message.contains('Invalid device token')) {
              debugPrint(
                'Image scan endpoint is using device auth. Mobile must call the client-auth AI endpoint.',
              );
            }
            return true;
          }());
          message = 'Could not scan image. Please try again.';
        } else if (error.statusCode == 404) {
          message = 'Image scan is not available yet.';
        } else if (error.statusCode == 500 ||
            error.statusCode == 502 ||
            error.statusCode == 503) {
          message = 'Image scanning is temporarily unavailable.';
        }
      }

      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(message)));
    } finally {
      final fileToDelete = compressedFile;
      if (fileToDelete != null && fileToDelete.path != xFile.path) {
        try {
          await fileToDelete.delete();
        } catch (_) {
          // Ignore temporary-file cleanup failures.
        }
      }
    }
  }

  // ── Submit ────────────────────────────────────────────────────────────────

  Future<void> _submit() async {
    if (_isSubmitting) return;

    // Defensive, even though the button is disabled in this state: this can
    // be reached programmatically, or from a tap that raced the state change
    // that disabled it. Saving would pop the sheet and take the attachment
    // work down with it, so it is refused rather than reordered.
    if (_hasBlockingAttachmentWork) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'Finish or discard the attachment before updating this event.',
          ),
        ),
      );
      return;
    }

    if (!_formKey.currentState!.validate()) return;

    final startsAt = _dateTimeFor(_startTime);
    late final DateTime endsAt;

    if (_allDay) {
      if (_selectedEndDate.isBefore(_selectedDate)) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('End date must be on or after start date.'),
          ),
        );
        return;
      }
      endsAt = _selectedEndDate.add(const Duration(days: 1));
    } else {
      final end = _dateTimeFor(_endTime);
      if (!end.isAfter(startsAt)) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('End time must be after start time.')),
        );
        return;
      }
      endsAt = end;
    }

    setState(() {
      _isSubmitting = true;
    });

    try {
      final title = _titleController.text.trim();
      final location = _locationController.text.trim().isEmpty
          ? null
          : _locationController.text.trim();
      final description = _descriptionController.text.trim().isEmpty
          ? null
          : _descriptionController.text.trim();

      if (_isEditing) {
        await widget.onUpdate!(
          event: widget.initialEvent!,
          title: title,
          startsAt: startsAt,
          endsAt: endsAt,
          allDay: _allDay,
          location: location,
          description: description,
          recurrence: _isEditingSingleOccurrence ? null : _recurrenceValue(),
          editScope: widget.editScope,
        );
      } else {
        await widget.onCreate(
          calendar: _selectedCalendar,
          title: title,
          startsAt: startsAt,
          endsAt: endsAt,
          allDay: _allDay,
          location: location,
          description: description,
          recurrence: _recurrenceValue(),
        );
      }

      if (mounted) {
        Navigator.of(context).pop(true);
      }
    } catch (error) {
      if (mounted) {
        setState(() {
          _isSubmitting = false;
        });

        const friendly = 'Could not save this event. Please try again.';
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              kDebugMode && error is CaleeHubException
                  ? '$friendly\nDebug: ${error.debugSummary}'
                  : friendly,
            ),
          ),
        );
      }
    }
  }

  String get _submitLabel {
    if (!_isEditing) return 'Save Event';
    if (_isEditingSingleOccurrence) return 'Update Event';
    if (widget.initialEvent!.recurring) return 'Update Series';
    return 'Update Event';
  }

  @override
  Widget build(BuildContext context) {
    final bottomInset = MediaQuery.viewInsetsOf(context).bottom;

    final sheetTitle = _isEditing
        ? _isEditingSingleOccurrence
              ? 'Edit this event'
              : widget.initialEvent!.recurring
              ? 'Edit series'
              : 'Edit event'
        : 'Add event';

    return PopScope(
      // Never pops on its own. Every route to closing -- system Back, an
      // iOS back gesture, a tap on the modal barrier, a programmatic
      // maybePop -- lands in _requestClose(), which is the only place the
      // close policy is decided. (The sheet is also presented with
      // enableDrag: false, because the framework's drag-to-dismiss calls
      // Navigator.pop() directly and would bypass this.)
      canPop: false,
      onPopInvokedWithResult: (didPop, result) {
        if (didPop) return;
        unawaited(_requestClose());
      },
      child: SafeArea(
        child: ColoredBox(
          color: CaleeColors.scaffoldBackground,
          child: Form(
            key: _formKey,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                // Drag handle -- only when this sheet really can be dragged.
                if (widget.showDragHandle)
                  Center(
                    child: Container(
                      width: 36,
                      height: 4,
                      margin: const EdgeInsets.only(top: CaleeSpacing.sm),
                      decoration: BoxDecoration(
                        color: CaleeColors.separatorOpaque,
                        borderRadius: BorderRadius.circular(CaleeRadius.dot),
                      ),
                    ),
                  )
                else
                  // Keeps the title's spacing from the sheet's top edge the
                  // same whether or not the handle is drawn.
                  const SizedBox(height: CaleeSpacing.sm),
                Flexible(
                  child: SingleChildScrollView(
                    padding: EdgeInsets.fromLTRB(
                      CaleeSpacing.md,
                      CaleeSpacing.md,
                      CaleeSpacing.md,
                      CaleeSpacing.md + bottomInset,
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        // Sheet title
                        Row(
                          children: [
                            Expanded(
                              child: Text(
                                sheetTitle,
                                style: Theme.of(context).textTheme.titleLarge,
                              ),
                            ),
                            IconButton(
                              icon: const Icon(Icons.close),
                              tooltip: 'Close',
                              onPressed: _isLocked
                                  ? null
                                  : () => unawaited(_requestClose()),
                              padding: EdgeInsets.zero,
                              constraints: const BoxConstraints(
                                minWidth: 48,
                                minHeight: 48,
                              ),
                            ),
                          ],
                        ),

                        // Scan image button (create mode only)
                        if (!_isEditing) ...[
                          const SizedBox(height: CaleeSpacing.sm),
                          OutlinedButton.icon(
                            onPressed: _isLocked ? null : _scanImage,
                            icon: _isScanningImage
                                ? const SizedBox(
                                    width: 16,
                                    height: 16,
                                    child: CircularProgressIndicator(
                                      strokeWidth: 2,
                                    ),
                                  )
                                : const Icon(Icons.document_scanner_outlined),
                            label: Text(
                              _isScanningImage
                                  ? 'Scanning image…'
                                  : 'Scan image',
                            ),
                          ),
                        ],

                        const SizedBox(height: CaleeSpacing.md),

                        // ── Event ─────────────────────────────────────────────
                        CaleeSection(
                          children: [
                            // Title field
                            CaleeSectionTextFormField(
                              key: const Key('event_title_field'),
                              controller: _titleController,
                              enabled: !_isLocked,
                              autofocus: true,
                              hintText: 'Title',
                              textInputAction: TextInputAction.next,
                              validator: (value) {
                                if ((value ?? '').trim().isEmpty) {
                                  return 'Enter a title';
                                }
                                return null;
                              },
                            ),
                            // Calendar picker
                            CaleeSectionDropdownRow<ClientCalendar>(
                              label: 'Calendar',
                              value: _selectedCalendar,
                              items: [
                                for (final cal in widget.calendars)
                                  DropdownMenuItem(
                                    value: cal,
                                    child: Text(cal.name),
                                  ),
                              ],
                              onChanged: (cal) {
                                if (cal != null) {
                                  setState(() => _selectedCalendar = cal);
                                }
                              },
                              enabled: !_isLocked && !_isEditing,
                            ),
                          ],
                        ),

                        // ── Time ──────────────────────────────────────────────
                        const SizedBox(height: CaleeSpacing.sectionSpacing),
                        CaleeSection(
                          children: [
                            CaleeSectionSwitchRow(
                              label: 'All day',
                              value: _allDay,
                              enabled: !_isLocked,
                              switchKey: const Key('event_all_day_switch'),
                              onChanged: (v) => setState(() => _allDay = v),
                            ),
                            if (_allDay) ...[
                              CaleeSectionPickerRow(
                                label: 'Date',
                                value: _dateLabel(_selectedDate),
                                onTap: _isLocked ? null : _pickDate,
                                enabled: !_isLocked,
                              ),
                              CaleeSectionPickerRow(
                                label: 'End',
                                value: _dateLabel(_selectedEndDate),
                                onTap: _isLocked ? null : _pickEndDate,
                                enabled: !_isLocked,
                              ),
                            ] else ...[
                              CaleeSectionPickerRow(
                                label: 'Date',
                                value: _dateLabel(_selectedDate),
                                onTap: _isLocked ? null : _pickDate,
                                enabled: !_isLocked,
                              ),
                              CaleeSectionPickerRow(
                                label: 'Start',
                                value: _timeLabel(_startTime),
                                onTap: _isLocked ? null : _pickStartTime,
                                enabled: !_isLocked,
                              ),
                              CaleeSectionPickerRow(
                                label: 'End',
                                value: _timeLabel(_endTime),
                                onTap: _isLocked ? null : _pickEndTime,
                                enabled: !_isLocked,
                              ),
                            ],
                          ],
                        ),

                        // ── Repeat ────────────────────────────────────────────
                        if (!_isEditingSingleOccurrence) ...[
                          const SizedBox(height: CaleeSpacing.sectionSpacing),
                          CaleeSection(
                            children: [
                              CaleeSectionPickerRow(
                                label: 'Repeat',
                                value: _selectedRepeatRule.label(
                                  anchorDate: _selectedDate,
                                ),
                                onTap: _isLocked ? null : _pickRepeat,
                                enabled: !_isLocked,
                              ),
                            ],
                          ),
                        ],

                        // ── Details ───────────────────────────────────────────
                        const SizedBox(height: CaleeSpacing.sectionSpacing),
                        CaleeSection(
                          children: [
                            CaleeSectionTextFormField(
                              key: const Key('event_location_field'),
                              controller: _locationController,
                              enabled: !_isLocked,
                              hintText: 'Location',
                            ),
                            CaleeSectionTextFormField(
                              key: const Key('event_description_field'),
                              controller: _descriptionController,
                              enabled: !_isLocked,
                              hintText: 'Notes',
                              maxLines: 3,
                            ),
                          ],
                        ),

                        // ── Attachments ───────────────────────────────────────
                        // Only for an existing event (attaching a file
                        // requires an eventId, so this never shows while
                        // creating a new event) on a calendar the backend
                        // explicitly reports as attachment-capable -- never
                        // inferred from provider name.
                        if (_isEditing &&
                            _selectedCalendar
                                .capabilities
                                .canViewAttachments) ...[
                          const SizedBox(height: CaleeSpacing.sectionSpacing),
                          EventAttachmentsSection(
                            key: ValueKey(
                              'attachments-${widget.initialEvent!.id}',
                            ),
                            // Deliberately widget.initialEvent!.id, not
                            // writableEventId -- when editing a single
                            // occurrence, id keeps its RECURRENCE-ID suffix,
                            // so if this section's own add/remove gating
                            // (isSeriesScoped below) were ever wrong, Hub's
                            // own occurrence-context rejection is still a
                            // second, independent backstop. writableEventId
                            // would collapse to the series id and lose that.
                            eventId: widget.initialEvent!.id,
                            hubClient: widget.hubClient,
                            accessToken: widget.accessToken,
                            canAdd: _selectedCalendar
                                .capabilities
                                .canAddAttachments,
                            canRemove: _selectedCalendar
                                .capabilities
                                .canRemoveAttachments,
                            isSeriesScoped: _isEditingSingleOccurrence,
                            controller: _attachmentsController,
                            onOperationStateChanged:
                                _handleAttachmentOperationState,
                          ),
                        ],

                        // ── Submit ────────────────────────────────────────────
                        const SizedBox(height: CaleeSpacing.lg),
                        FilledButton(
                          key: const Key('event_submit_button'),
                          onPressed: (_isLocked || _hasBlockingAttachmentWork)
                              ? null
                              : _submit,
                          child: _isSubmitting
                              ? const SizedBox(
                                  width: 18,
                                  height: 18,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                  ),
                                )
                              : Text(_submitLabel),
                        ),
                        // Says why the button is unavailable. The attachment
                        // row directly above shows what is happening; this
                        // says what it means for saving.
                        if (_hasBlockingAttachmentWork) ...[
                          const SizedBox(height: CaleeSpacing.sm),
                          Text(
                            _attachmentOperations.hasActiveTransfer
                                ? 'Waiting for the attachment to finish.'
                                : 'Retry or discard the attachment to '
                                      'continue.',
                            textAlign: TextAlign.center,
                            style: Theme.of(context).textTheme.bodySmall
                                ?.copyWith(color: CaleeColors.textSecondary),
                          ),
                        ],
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

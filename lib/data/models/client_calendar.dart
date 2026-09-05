import 'calendar_service_error.dart';

class ClientCalendarList {
  const ClientCalendarList({
    required this.calendars,
    this.serviceErrors = const [],
  });

  factory ClientCalendarList.fromJson(Map<String, dynamic> json) {
    return ClientCalendarList(
      calendars: (json['calendars'] as List<dynamic>? ?? const [])
          .whereType<Map<String, dynamic>>()
          .map(ClientCalendar.fromJson)
          .toList(),
      serviceErrors: (json['serviceErrors'] as List<dynamic>? ?? const [])
          .whereType<Map<String, dynamic>>()
          .map(CalendarServiceError.fromJson)
          .toList(),
    );
  }

  final List<ClientCalendar> calendars;
  final List<CalendarServiceError> serviceErrors;
}

// Capabilities describing what a caller is allowed to do to a single
// calendar, as returned by the Hub alongside each ClientCalendar. These are
// server-computed (derived from the calendar's appearanceMode, ACL, and
// provider access role) — CaleeMobile only parses and consumes them, it
// never derives them itself.
class CalendarCapabilities {
  const CalendarCapabilities({
    required this.canEditAppearance,
    required this.canEditEvents,
    required this.canEditSourceMetadata,
    required this.canRemoveFromCalee,
    required this.canDeleteSource,
    this.canViewAttachments = false,
    this.canAddAttachments = false,
    this.canRemoveAttachments = false,
  });

  factory CalendarCapabilities.fromJson(Map<String, dynamic> json) {
    return CalendarCapabilities(
      canEditAppearance: json['canEditAppearance'] as bool? ?? false,
      canEditEvents: json['canEditEvents'] as bool? ?? false,
      canEditSourceMetadata: json['canEditSourceMetadata'] as bool? ?? false,
      canRemoveFromCalee: json['canRemoveFromCalee'] as bool? ?? false,
      canDeleteSource: json['canDeleteSource'] as bool? ?? false,
      // Additive fields: a backend that predates them simply omits the
      // keys, which the ?? false below already treats the same as
      // CalendarCapabilities.fallback() would -- no containsKey needed
      // here (unlike appearanceMode/sourceName elsewhere in this file),
      // since "not supported" is the correct reading either way.
      canViewAttachments: json['canViewAttachments'] as bool? ?? false,
      canAddAttachments: json['canAddAttachments'] as bool? ?? false,
      canRemoveAttachments: json['canRemoveAttachments'] as bool? ?? false,
    );
  }

  /// Safe fallback for a backend that predates the capabilities field.
  /// Only canEditAppearance is inferred (matching what editing already does
  /// today); every other capability fails closed to false rather than
  /// guessing, so e.g. subscriptions never become appearance-editable
  /// against an old backend. Attachment capabilities always fail closed to
  /// false here too -- never inferred from provider name or other fields.
  factory CalendarCapabilities.fallback({
    required bool readOnly,
    required bool isSubscription,
  }) {
    return CalendarCapabilities(
      canEditAppearance: !readOnly && !isSubscription,
      canEditEvents: false,
      canEditSourceMetadata: false,
      canRemoveFromCalee: false,
      canDeleteSource: false,
    );
  }

  final bool canEditAppearance;
  final bool canEditEvents;
  final bool canEditSourceMetadata;
  final bool canRemoveFromCalee;
  final bool canDeleteSource;

  /// Whether this calendar's events may show an Attachments section at
  /// all. Always backend-derived (see [CalendarCapabilities.fromJson]) --
  /// never inferred from [ClientCalendar.providerKey] or similar.
  final bool canViewAttachments;

  /// Whether CaleeMobile may upload a new attachment to an event on this
  /// calendar.
  final bool canAddAttachments;

  /// Whether CaleeMobile may remove an attachment from an event on this
  /// calendar.
  final bool canRemoveAttachments;
}

/// How far a subscription ("connected") calendar has got through its FIRST
/// authoritative synchronisation, as reported by Hub's additive
/// `subscriptionSyncState` field.
///
/// The distinction this exists to make: a subscription Calee has never
/// successfully fetched must NOT be drawn as an empty calendar. Calee knows
/// the feed validated and how many events it claimed to hold; it just does not
/// have them yet. Showing "No events" there is a lie, and it is the lie the
/// user hit after "Calendar added to Calee".
///
/// [ready] genuinely covers zero events too: a feed that was fetched
/// successfully and contains nothing is ready-and-empty, and gets the ordinary
/// empty-calendar UI, not a syncing state.
///
/// Null (the field absent) means either "not a subscription calendar" or "an
/// older Hub that predates the field". Both must behave exactly as CaleeMobile
/// did before this contract existed — never as [syncing], which would put a
/// permanent banner on every calendar against an old backend.
enum CalendarSyncState {
  /// An authoritative refresh has succeeded. What is shown is what the feed
  /// contains, including when that is nothing.
  ready,

  /// Registered, but its first authoritative refresh has not completed. Calee
  /// does not yet know what this calendar contains.
  syncing,

  /// The first authoritative refresh failed. Truthful, and deliberately
  /// carries no backend detail — Hub never sends one.
  error;

  /// Parses the wire value. An unrecognised string is treated as null rather
  /// than guessed at: a future state this build does not understand must not
  /// be silently rendered as one it does.
  static CalendarSyncState? fromJson(Object? value) {
    switch (value) {
      case 'ready':
        return CalendarSyncState.ready;
      case 'syncing':
        return CalendarSyncState.syncing;
      case 'error':
        return CalendarSyncState.error;
      default:
        return null;
    }
  }
}

/// v1 always returns 'series' -- see docs/attachment-investigation-findings.md
/// on calee-hub-core for why per-occurrence attachments are out of scope.
/// Modeled as an enum (rather than a bare String, unlike e.g.
/// [ClientCalendar.primaryKind]) so a future per-occurrence scope is a
/// compile-time-checked addition, not a silent new string value.
enum AttachmentScope {
  series;

  static AttachmentScope fromJson(String? value) {
    switch (value) {
      case 'series':
        return AttachmentScope.series;
      default:
        return AttachmentScope.series;
    }
  }
}

/// One file attached to a calendar event's series-master, as returned by
/// GET/POST /client/v1/events/{eventId}/attachments. Deliberately carries
/// no Nextcloud file ID, WebDAV path, or download URL -- [id] is an opaque
/// token only Hub can resolve (see calee-hub-core's
/// client_caldav_attachment_id()); downloading always goes through
/// CaleeHubClient.downloadAttachment(), never a URL CaleeMobile constructs
/// itself.
class CalendarAttachment {
  const CalendarAttachment({
    required this.id,
    required this.filename,
    required this.hasPreview,
    required this.scope,
    required this.downloadAvailable,
    this.contentType,
    this.size,
  });

  factory CalendarAttachment.fromJson(Map<String, dynamic> json) {
    return CalendarAttachment(
      id: json['id'] as String? ?? '',
      filename: json['filename'] as String? ?? '',
      contentType: json['contentType'] as String?,
      size: json['size'] as int?,
      hasPreview: json['hasPreview'] as bool? ?? false,
      scope: AttachmentScope.fromJson(json['scope'] as String?),
      downloadAvailable: json['downloadAvailable'] as bool? ?? false,
    );
  }

  final String id;
  final String filename;
  final String? contentType;

  /// Bytes, when currently known. Null when the backend could not
  /// currently resolve live metadata for this file (see
  /// [downloadAvailable]) -- never assume 0 means empty.
  final int? size;
  final bool hasPreview;
  final AttachmentScope scope;

  /// False means "File no longer available" -- the underlying Nextcloud
  /// file could not currently be resolved (deleted, or no longer
  /// accessible). Still shown in the list (per the task's product scope),
  /// just without a working download/open action.
  final bool downloadAvailable;

  /// Human-readable size, e.g. "1.2 MB". Null when [size] is unknown.
  String? get formattedSize {
    final bytes = size;
    if (bytes == null) return null;
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) {
      return '${(bytes / 1024).toStringAsFixed(1)} KB';
    }
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  }
}

// Calee calendar model
//
// Calee displays all calendars together, but only Calee calendars are edited
// in Calee.
//
// Calee calendars:
// - Are created and managed by Calee.
// - Are fully two-way editable.
// - Can be edited in CaleeMobile, Calee Portal, and optionally through CalDAV.
// - Are best for events users want to manage directly in Calee.
//
// Connected / non-Calee calendars:
// - Come from Google, Apple/iCloud, Outlook, school, sport, roster, booking,
//   or other calendar systems.
// - Are added using subscription URLs for now, such as ICS, webcal, private
//   iCal, published calendar, or shared calendar links.
// - Are read-only in Calee.
// - Must be edited in the original app or provider.
// - Are best for showing existing events on the Calee display.
//
// UX implications:
// - Calee calendar events may show create, edit, and delete controls.
// - Connected calendar events should show read-only messaging and should not
//   expose edit/delete controls in CaleeMobile.
// - User-facing wording should say "Add calendars you already use so their
//   events appear on your Calee display", not "manage everything in Calee".
class ClientCalendar {
  const ClientCalendar({
    required this.id,
    required this.serviceId,
    required this.serviceName,
    required this.name,
    required this.components,
    required this.primaryKind,
    required this.supportsEvents,
    required this.supportsTasks,
    required this.supportsChores,
    required this.readOnly,
    required this.isSubscription,
    required this.source,
    this.color,
    this.subscriptionUrl,
    this.providerKey,
    this.accessMode,
    this.sourceOfTruthPolicy,
    this.syncStatus,
    this.lastSyncedAt,
    this.sourceName,
    this.sourceColor,
    this.appearanceMode = 'source_metadata',
    this.hasServerAppearanceContract = true,
    this.subscriptionSyncState,
    this.capabilities = const CalendarCapabilities(
      canEditAppearance: true,
      canEditEvents: false,
      canEditSourceMetadata: false,
      canRemoveFromCalee: false,
      canDeleteSource: false,
    ),
  });

  factory ClientCalendar.fromJson(Map<String, dynamic> json) {
    final readOnly = json['readOnly'] as bool? ?? false;
    final isSubscription = json['isSubscription'] as bool? ?? false;
    final name = json['name'] as String? ?? '';
    final color = json['color'] as String?;

    // Old backends don't send capabilities at all — containsKey (rather than
    // a null check) is what distinguishes "old server, key absent" from "new
    // server, capabilities present". Without this distinction a new server's
    // explicit {} or malformed capabilities would be indistinguishable from
    // "not sent", which is fine (both fail closed via fromJson/fallback),
    // but an old server must never be mistaken for a new one either.
    final rawCapabilities = json['capabilities'];
    final capabilities =
        json.containsKey('capabilities') &&
            rawCapabilities is Map<String, dynamic>
        ? CalendarCapabilities.fromJson(rawCapabilities)
        : CalendarCapabilities.fallback(
            readOnly: readOnly,
            isSubscription: isSubscription,
          );

    final fallbackAppearanceMode = capabilities.canEditAppearance
        ? 'source_metadata'
        : 'unsupported';

    return ClientCalendar(
      id: json['id'] as String? ?? '',
      serviceId: json['serviceId'] as String? ?? '',
      serviceName: json['serviceName'] as String? ?? '',
      name: name,
      color: color,
      components: (json['components'] as List<dynamic>? ?? const [])
          .whereType<String>()
          .toList(),
      primaryKind: json['primaryKind'] as String? ?? 'calendar',
      supportsEvents: json['supportsEvents'] as bool? ?? true,
      supportsTasks: json['supportsTasks'] as bool? ?? false,
      supportsChores: json['supportsChores'] as bool? ?? false,
      readOnly: readOnly,
      isSubscription: isSubscription,
      subscriptionUrl: json['subscriptionUrl'] as String?,
      source: json['source'] as String? ?? '',
      providerKey: json['providerKey'] as String?,
      accessMode: json['accessMode'] as String?,
      sourceOfTruthPolicy: json['sourceOfTruthPolicy'] as String?,
      syncStatus: json['syncStatus'] as String?,
      lastSyncedAt: json['lastSyncedAt'] as String?,
      // sourceColor in particular is legitimately null on a new backend
      // (e.g. always null for external/Google calendars), so containsKey is
      // used here too rather than defaulting whenever the parsed value is
      // null.
      sourceName: json.containsKey('sourceName')
          ? json['sourceName'] as String?
          : name,
      sourceColor: json.containsKey('sourceColor')
          ? json['sourceColor'] as String?
          : color,
      appearanceMode: json.containsKey('appearanceMode')
          ? (json['appearanceMode'] as String? ?? fallbackAppearanceMode)
          : fallbackAppearanceMode,
      hasServerAppearanceContract:
          json.containsKey('capabilities') &&
          rawCapabilities is Map<String, dynamic>,
      capabilities: capabilities,
      // Additive. Absent on an older Hub and null for non-subscription
      // calendars; CalendarSyncState.fromJson returns null for both, which is
      // exactly the pre-contract behaviour.
      subscriptionSyncState: CalendarSyncState.fromJson(
        json['subscriptionSyncState'],
      ),
    );
  }

  final String id;
  final String serviceId;
  final String serviceName;
  final String name;
  final String? color;
  final List<String> components;
  final String primaryKind;
  final bool supportsEvents;
  final bool supportsTasks;
  final bool supportsChores;
  final bool readOnly;
  final bool isSubscription;
  final String? subscriptionUrl;
  final String source;
  final String? providerKey;
  final String? accessMode;
  final String? sourceOfTruthPolicy;
  final String? syncStatus;
  final String? lastSyncedAt;

  /// The provider/source's own name for this calendar, independent of any
  /// local Calee override. Defaults to [name] when the backend doesn't send
  /// it (old backend, or no override has ever been applied).
  final String? sourceName;

  /// The provider/source's own colour for this calendar. Unlike
  /// [sourceName], this is legitimately null even from a current backend
  /// (e.g. always null for external/Google calendars, which have no
  /// separately-tracked provider colour once a local override exists).
  final String? sourceColor;

  /// One of 'source_metadata', 'subscription_mapping', 'external_calendar',
  /// or 'unsupported'. Drives [capabilities] and the copy shown while
  /// editing appearance.
  final String appearanceMode;

  /// What the current caller may do to this calendar. Always populated —
  /// either parsed from the backend or, for an old backend that predates
  /// this field, computed via [CalendarCapabilities.fallback].
  final CalendarCapabilities capabilities;

  /// Whether [capabilities] genuinely came from the backend (the
  /// `capabilities` key was present in the payload) rather than from
  /// [CalendarCapabilities.fallback]. The `/appearance` endpoint only exists
  /// on backends that emit capabilities, so appearance editing must route
  /// through the legacy `updateCalendar()` source-metadata endpoint when
  /// this is false — a fallback-writable calendar has
  /// `canEditAppearance == true` but an old backend would 404 the new
  /// route. Defaults to true for direct construction (tests/fixtures model
  /// a current backend); [ClientCalendar.fromJson] always sets it from the
  /// payload.
  final bool hasServerAppearanceContract;

  /// How far this subscription calendar has got through its first
  /// authoritative sync, or null when that is not a meaningful question here
  /// (not a subscription, or an older Hub). See [CalendarSyncState].
  final CalendarSyncState? subscriptionSyncState;

  /// True only when Hub has positively said this calendar has not finished its
  /// first sync. Null — an old backend, or a non-subscription calendar — is
  /// deliberately NOT syncing: the truthful thing to do when Calee has not
  /// been told is to behave as it always did.
  bool get isInitialSyncPending =>
      subscriptionSyncState == CalendarSyncState.syncing;

  /// True when Hub has said this calendar's first authoritative refresh
  /// failed. Distinct from [isInitialSyncPending]: retrying will not help on
  /// its own, so the UI says so rather than showing an endless "Syncing…".
  bool get hasInitialSyncError =>
      subscriptionSyncState == CalendarSyncState.error;

  bool get isCalendarKind => primaryKind == 'calendar';
  bool get isTaskKind => primaryKind == 'tasks';
  bool get isChoreKind => primaryKind == 'chores';

  bool get isExternal =>
      source == 'external' ||
      serviceId == 'external' ||
      id.startsWith('external:');

  bool get isGoogleCalendar => providerKey == 'google_calendar';
}

class ClientEventList {
  const ClientEventList({
    required this.from,
    required this.to,
    required this.events,
  });

  factory ClientEventList.fromJson(Map<String, dynamic> json) {
    return ClientEventList(
      from: json['from'] as String? ?? '',
      to: json['to'] as String? ?? '',
      events: (json['events'] as List<dynamic>? ?? const [])
          .whereType<Map<String, dynamic>>()
          .map(ClientEvent.fromJson)
          .toList(),
    );
  }

  final String from;
  final String to;
  final List<ClientEvent> events;
}

class ClientEvent {
  const ClientEvent({
    required this.id,
    required this.calendarId,
    required this.serviceId,
    required this.serviceName,
    required this.title,
    required this.startsAt,
    required this.endsAt,
    required this.allDay,
    required this.source,
    required this.recurring,
    this.location,
    this.description,
    this.recurrence,
    this.seriesId,
    this.recurrenceId,
    this.occurrenceId,
    this.sourceUid,
    this.canonicalRecurrenceId,
    this.providerKey,
    this.readOnly = false,
    this.timeZone,
  });

  factory ClientEvent.fromJson(Map<String, dynamic> json) {
    return ClientEvent(
      id: json['id'] as String? ?? '',
      calendarId: json['calendarId'] as String? ?? '',
      serviceId: json['serviceId'] as String? ?? '',
      serviceName: json['serviceName'] as String? ?? '',
      title: json['title'] as String? ?? '',
      startsAt: json['startsAt'] as String? ?? '',
      endsAt: json['endsAt'] as String? ?? '',
      allDay: json['allDay'] as bool? ?? false,
      location: json['location'] as String?,
      description: json['description'] as String?,
      source: json['source'] as String? ?? '',
      recurring: json['recurring'] as bool? ?? false,
      recurrence: json['recurrence'] as String?,
      seriesId: json['seriesId'] as String?,
      recurrenceId: json['recurrenceId'] as String?,
      occurrenceId: json['occurrenceId'] as String?,
      // Verbatim, and deliberately NOT normalised. `UID` is opaque source
      // identity: `0` is a real UID, ` uid ` is a different event from `uid`,
      // and Hub already collapsed absent/whitespace-only to null (see
      // client_caldav_source_uid()). Trimming here would silently mint a link
      // naming another event.
      sourceUid: json['sourceUid'] as String?,
      canonicalRecurrenceId: json['canonicalRecurrenceId'] as String?,
      providerKey: json['providerKey'] as String?,
      readOnly: json['readOnly'] as bool? ?? false,
      timeZone: json['timeZone'] as String?,
    );
  }

  final String id;
  final String calendarId;
  final String serviceId;
  final String serviceName;
  final String title;
  final String startsAt;
  final String endsAt;
  final bool allDay;
  final String? location;
  final String? description;
  final String source;
  final bool recurring;
  final String? recurrence;
  final String? seriesId;
  final String? recurrenceId;
  final String? occurrenceId;

  /// The verbatim source `UID` of the component this event was read from, as
  /// computed by Hub Core under CaleeAdmin/calee-hub-core#424.
  ///
  /// This — never [id], [seriesId], [recurrenceId] or [occurrenceId] — is the
  /// Event Link source identity. Those four are Hub-local composite keys the
  /// `calee.event-occurrence-identity` contract declares NON-NORMATIVE, and
  /// they are known to be able to collide across distinct source UIDs, so a
  /// link minted from one can name a different source event entirely.
  ///
  /// Null on an older Hub that predates the field, and null when the source
  /// component carries no usable `UID` at all. Both mean "no canonical source
  /// identity" and must fail closed rather than fall back to a local id.
  final String? sourceUid;

  /// The canonical recurrence identity of this occurrence (`Ymd` for an
  /// all-day series, `YmdTHisZ` at its true UTC instant for a timed one), or
  /// null for a non-recurring event.
  ///
  /// Computed by Hub Core under CaleeAdmin/calee-hub-core#420/#421 and only
  /// consumed here — never rebuilt in Dart, and never derived from
  /// [startsAt]. For a DETACHED occurrence that was moved, this stays the
  /// ORIGINAL recurrence identity while [startsAt] shows the new time, which
  /// is exactly what keeps a link shared before the move resolving after it.
  final String? canonicalRecurrenceId;

  final String? providerKey;
  final bool readOnly;
  final String? timeZone;

  bool get isExternal =>
      source == 'external' ||
      serviceId == 'external' ||
      id.startsWith('external:');

  bool get isReadOnly => readOnly || isExternal;

  bool get isGoogleEvent => providerKey == 'google_calendar';

  String get writableEventId {
    if (isReadOnly) return id;

    if (recurring && (seriesId ?? '').trim().isNotEmpty) {
      return seriesId!.trim();
    }

    return id;
  }
}

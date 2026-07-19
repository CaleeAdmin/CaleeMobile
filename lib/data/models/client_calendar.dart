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
  });

  factory CalendarCapabilities.fromJson(Map<String, dynamic> json) {
    return CalendarCapabilities(
      canEditAppearance: json['canEditAppearance'] as bool? ?? false,
      canEditEvents: json['canEditEvents'] as bool? ?? false,
      canEditSourceMetadata: json['canEditSourceMetadata'] as bool? ?? false,
      canRemoveFromCalee: json['canRemoveFromCalee'] as bool? ?? false,
      canDeleteSource: json['canDeleteSource'] as bool? ?? false,
    );
  }

  /// Safe fallback for a backend that predates the capabilities field.
  /// Only canEditAppearance is inferred (matching what editing already does
  /// today); every other capability fails closed to false rather than
  /// guessing, so e.g. subscriptions never become appearance-editable
  /// against an old backend.
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

/// Where an event being edited may be moved to, and whether the Calendar
/// selector may be changed at all.
///
/// Both answers live here together deliberately. The selector is only enabled
/// when a move is genuinely possible, and it only ever lists destinations
/// calee-hub-core will actually accept — offering one it would reject turns a
/// server-side refusal into something the user only discovers after pressing
/// Save.
///
/// These rules mirror Hub's own validation of the optional destination
/// `calendarId` on `PATCH /client/v1/events/{eventId}`. Hub remains the
/// authority and re-checks every one of them; nothing here is a substitute for
/// that. This exists so the editor never proposes an impossible destination.
library;

import '../../data/models/client_calendar.dart';

/// The calendars [event] may be moved into, INCLUDING the one it is already
/// in — which is what the selector shows as its current value, and is itself a
/// valid "don't move it" choice.
///
/// Filtered to:
///
///  * event calendars only — a tasks or chores collection cannot hold an
///    event, and Hub answers `EVENT_MOVE_DESTINATION_UNSUPPORTED` for one;
///  * writable, non-subscription, non-external calendars — Hub answers
///    `READ_ONLY_CALENDAR` otherwise. This is the same expression the create
///    sheet already filters on, deliberately rather than
///    `capabilities.canEditEvents`, which fails closed on an older Hub that
///    predates it while legacy writable calendars still work (see
///    `CalendarCapabilities.fallback`);
///  * the event's OWN service — a Calee service is a distinct Nextcloud
///    account with its own credentials, so one server-side move cannot span
///    two of them and Hub answers `EVENT_MOVE_CROSS_SERVICE_UNSUPPORTED`.
///
/// Order is preserved from [calendars] so the selector lists destinations in
/// the same order as everywhere else in the app.
List<ClientCalendar> eventMoveDestinations({
  required ClientEvent event,
  required List<ClientCalendar> calendars,
}) {
  final eventServiceId = event.serviceId.trim();
  if (eventServiceId.isEmpty) return const [];

  return calendars
      .where(
        (calendar) =>
            calendar.serviceId.trim() == eventServiceId &&
            calendar.isCalendarKind &&
            !calendar.readOnly &&
            !calendar.isSubscription &&
            !calendar.isExternal,
      )
      .toList();
}

/// Whether the Calendar selector may be changed for this edit.
///
/// False for an occurrence-scoped edit: a series lives in ONE CalDAV
/// calendar-object resource, so a single occurrence cannot be relocated
/// without splitting the series across two collections, and Hub refuses it
/// with `EVENT_MOVE_OCCURRENCE_UNSUPPORTED`. Choosing "Edit This Event" must
/// therefore leave the calendar fixed rather than quietly moving the whole
/// series, which is not what was asked for. Editing an entire series has no
/// such problem and is movable.
///
/// False too when there is nowhere else to go, so the selector is never
/// interactive when opening it can only show the calendar already selected.
bool canChangeEventCalendar({
  required ClientEvent event,
  required String? editScope,
  required List<ClientCalendar> destinations,
}) {
  if (event.isReadOnly) return false;
  if (editScope?.trim().toLowerCase() == 'occurrence') return false;
  return destinations.length > 1;
}

/// The calendar in [destinations] that [event] currently lives in, or null
/// when it cannot be identified.
///
/// Matched the same service-aware way `CalendarController.calendarForEvent`
/// does, because an older Hub emitted a bare `calendarId` ("personal") on an
/// event while the calendar list already used the composite public id
/// ("portal:personal"), and both must resolve to the same calendar.
///
/// Returning null is a real answer and must NOT fall back to "the first
/// calendar in the list": selecting an unrelated calendar as the current value
/// would turn an ordinary edit into an unrequested move.
ClientCalendar? currentCalendarForEvent({
  required ClientEvent event,
  required List<ClientCalendar> destinations,
}) {
  for (final calendar in destinations) {
    if (calendar.id == event.calendarId ||
        calendar.id.endsWith(':${event.calendarId}') ||
        event.calendarId.endsWith(':${calendar.id}')) {
      return calendar;
    }
  }
  return null;
}

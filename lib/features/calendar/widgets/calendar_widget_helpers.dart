import 'package:flutter/material.dart';

import '../../../data/models/client_calendar.dart';
import '../calendar_utils.dart';

// Shared constants used across calendar widgets.

const kCalendarMonthAbbr = [
  'Jan',
  'Feb',
  'Mar',
  'Apr',
  'May',
  'Jun',
  'Jul',
  'Aug',
  'Sep',
  'Oct',
  'Nov',
  'Dec',
];

bool isSameCalendarDay(DateTime a, DateTime b) =>
    a.year == b.year && a.month == b.month && a.day == b.day;

Color? parseCalendarHexColor(String hex) {
  final clean = hex.startsWith('#') ? hex.substring(1) : hex;
  if (clean.length == 6) {
    final value = int.tryParse(clean, radix: 16);
    if (value != null) return Color(0xFF000000 | value);
  }
  if (clean.length == 8) {
    final value = int.tryParse(clean, radix: 16);
    if (value != null) return Color(value);
  }
  return null;
}

String? calendarSubscriptionHost(String? url) {
  if (url == null || url.isEmpty) return null;
  final host = Uri.tryParse(url)?.host;
  return (host == null || host.isEmpty) ? null : host;
}

String calendarEventTimeLabel(ClientEvent event, {bool use24h = true}) =>
    eventTimeLabel(event, use24h: use24h);

// Shared appearance-editing copy, used by both CalendarDetailSheet and
// CalendarCollectionsPage so the two surfaces stay textually consistent.

/// Explanatory copy shown while editing a calendar's name/colour, based on
/// its [ClientCalendar.appearanceMode]. Returns null for the `unsupported`
/// mode, which never reaches an edit view — see [calendarOwnerManagedMessage].
String? calendarAppearanceEditCopy(String appearanceMode) {
  switch (appearanceMode) {
    case 'source_metadata':
      return 'This updates the calendar name and colour.';
    case 'subscription_mapping':
    case 'external_calendar':
      return 'These changes only affect how this calendar appears in Calee.';
    default:
      return null;
  }
}

/// Shown in place of the edit action for a calendar whose appearance can't
/// be edited from Calee (a shared, read-only CalDAV calendar —
/// appearanceMode `unsupported`).
const String calendarOwnerManagedMessage =
    'This shared calendar is managed by its owner.';

/// The fields of a calendar-appearance edit that actually changed. A null
/// field means "unchanged — do not send", never "clear".
typedef CalendarAppearancePatch = ({String? name, String? color});

/// Canonical form of a hex colour for change comparison: trimmed,
/// '#'-prefixed, uppercased. Null/blank input stays null, so an empty colour
/// field compares equal to a calendar that never had a colour.
String? normalizeCalendarAppearanceColor(String? color) {
  final trimmed = color?.trim() ?? '';
  if (trimmed.isEmpty) return null;
  final prefixed = trimmed.startsWith('#') ? trimmed : '#$trimmed';
  return prefixed.toUpperCase();
}

/// Builds the changed-fields-only payload for the appearance endpoint,
/// shared by CalendarDetailSheet and CalendarCollectionsPage so both
/// screens produce identical requests. Returns null when nothing changed
/// (no request must be sent). Sending an unchanged field would create a
/// permanent local override on the backend, so each field is compared —
/// colours case-insensitively — and included only when it differs.
///
/// A cleared colour field is treated as "unchanged": the appearance
/// endpoint has no reset-to-source semantics, so blank never becomes a
/// request value.
CalendarAppearancePatch? buildCalendarAppearancePatch({
  required String originalName,
  required String? originalColor,
  required String nextName,
  required String? nextColor,
}) {
  final trimmedNextName = nextName.trim();
  final nameChanged = trimmedNextName != originalName.trim();

  final normalizedNextColor = normalizeCalendarAppearanceColor(nextColor);
  final colorChanged =
      normalizedNextColor != null &&
      normalizedNextColor != normalizeCalendarAppearanceColor(originalColor);

  if (!nameChanged && !colorChanged) return null;

  return (
    name: nameChanged ? trimmedNextName : null,
    color: colorChanged ? normalizedNextColor : null,
  );
}

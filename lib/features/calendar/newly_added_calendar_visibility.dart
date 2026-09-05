/// Calendars the user has just added, so the calendar screen shows them.
///
/// Calendar visibility lives in [CalendarController.hiddenCalendarIds], an
/// opt-out set: a calendar is visible unless its id is in it. That set is
/// keyed by calendar id and is only pruned when a calendar is missing from a
/// completed load, so an id can still be hidden from an earlier calendar that
/// carried the same id (hidden, then removed and added again without this
/// client ever completing a load in between). The user then saw
/// "Calendar added to Calee" while the new calendar sat unchecked in the
/// calendar selector and none of its events rendered.
///
/// A successful add records the new calendar's id here; the next calendar load
/// takes the recorded ids and drops exactly those from the hidden set. Nothing
/// else about the user's visibility choices is touched — no other calendar is
/// enabled, and hiding the new calendar afterwards works normally (the id has
/// already been consumed, so a later load leaves that choice alone).
class NewlyAddedCalendarVisibility {
  NewlyAddedCalendarVisibility();

  /// Shared instance used by the add flows and by the calendar screen. Tests
  /// construct their own instead.
  static final NewlyAddedCalendarVisibility instance =
      NewlyAddedCalendarVisibility();

  final Set<String> _calendarIds = {};

  /// Records a just-added calendar. Blank ids (an older backend that returns
  /// no id) are ignored: there is nothing to un-hide.
  void record(String calendarId) {
    final id = calendarId.trim();
    if (id.isEmpty) return;
    _calendarIds.add(id);
  }

  /// Returns the recorded ids and clears them, so each add is honoured once.
  Set<String> take() {
    if (_calendarIds.isEmpty) return const <String>{};
    final taken = Set<String>.from(_calendarIds);
    _calendarIds.clear();
    return taken;
  }
}

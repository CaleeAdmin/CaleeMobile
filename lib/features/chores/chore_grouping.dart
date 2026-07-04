import '../../data/models/client_chore.dart';

// ── Section key constants ────────────────────────────────────────────────────
// API section values: overdue | todoToday | doneToday | future | history
// 'future' is split into three UI-only display sections based on scheduled date.

/// Groups [chores] by UI section, splitting the 'future' API section into
/// 'tomorrow', 'laterThisWeek', and 'later' sub-sections.
///
/// [today] is injected so the function is deterministic and testable.
/// All other API section values pass through unchanged.
Map<String, List<ClientChore>> groupChoresBySection(
  List<ClientChore> chores,
  DateTime today,
) {
  final todayDate = DateTime(today.year, today.month, today.day);
  final tomorrowDate = todayDate.add(const Duration(days: 1));
  // End of week = this Sunday (Mon=1 … Sun=7). If today is Sunday: 0 days away.
  final daysUntilSunday = (7 - todayDate.weekday) % 7;
  final endOfWeekDate = daysUntilSunday == 0
      ? todayDate
      : todayDate.add(Duration(days: daysUntilSunday));

  // A recurring chore's persistent baseChore row and its completion-log row
  // for today share a choreUid/parentChoreUid. Collect the uids that already
  // have a completion recorded for today so the still-open baseChore row
  // doesn't also render as due/overdue alongside it.
  final doneTodayUids = <String>{};
  for (final chore in chores) {
    if (chore.completedToday || chore.normalizedSection == 'doneToday') {
      final uid = _choreIdentityUid(chore);
      if (uid != null) doneTodayUids.add(uid);
    }
  }

  final grouped = <String, List<ClientChore>>{};

  for (final chore in chores) {
    // completedToday overrides any stale section value. A UTC vs local timezone
    // mismatch can cause the server to assign the wrong section for a chore that
    // was completed today in local time but before UTC midnight.
    if (chore.completedToday) {
      grouped.putIfAbsent('doneToday', () => []).add(chore);
      continue;
    }
    final apiSection = chore.normalizedSection;
    final uiSection = apiSection == 'future'
        ? _futureSubsection(
            chore,
            todayDate: todayDate,
            tomorrowDate: tomorrowDate,
            endOfWeekDate: endOfWeekDate,
          )
        : apiSection;

    if ((uiSection == 'todoToday' || uiSection == 'overdue') &&
        chore.isBaseChore) {
      final uid = _choreIdentityUid(chore);
      if (uid != null && doneTodayUids.contains(uid)) {
        continue;
      }
    }

    grouped.putIfAbsent(uiSection, () => []).add(chore);
  }

  for (final group in grouped.values) {
    group.sort(compareChores);
  }

  return grouped;
}

/// The uid a chore's completion is tracked under: its own [ClientChore.choreUid]
/// for a baseChore row, or [ClientChore.parentChoreUid] for a completion-log
/// row pointing back at its recurring chore. Mirrors [ClientChore.completionActionId].
String? _choreIdentityUid(ClientChore chore) {
  final uid = chore.choreUid ?? chore.parentChoreUid;
  if (uid == null || uid.trim().isEmpty) return null;
  return uid;
}

String _futureSubsection(
  ClientChore chore, {
  required DateTime todayDate,
  required DateTime tomorrowDate,
  required DateTime endOfWeekDate,
}) {
  final dateStr = chore.scheduledDate ?? chore.scheduledAt;
  if (dateStr == null || dateStr.trim().isEmpty) {
    // A recurring chore with no explicit start date begins today.
    return chore.isRecurring ? 'todoToday' : 'later';
  }

  final parsed = DateTime.tryParse(dateStr)?.toLocal();
  if (parsed == null) return 'later';

  final d = DateTime(parsed.year, parsed.month, parsed.day);
  if (d.isBefore(todayDate)) return 'overdue';
  if (d.isAtSameMomentAs(todayDate)) return 'todoToday';
  if (d.isAtSameMomentAs(tomorrowDate)) return 'tomorrow';
  if (!d.isAfter(endOfWeekDate)) return 'laterThisWeek';
  return 'later';
}

/// Compares two chores for display order within a section:
/// 1. Assignee display name, ascending — unassigned last.
/// 2. Scheduled date, ascending.
/// 3. Title, ascending (case-insensitive).
int compareChores(ClientChore a, ClientChore b) {
  final aName = a.assigneeName?.trim() ?? '';
  final bName = b.assigneeName?.trim() ?? '';

  if (aName.isEmpty && bName.isNotEmpty) return 1;
  if (aName.isNotEmpty && bName.isEmpty) return -1;
  if (aName.isNotEmpty && bName.isNotEmpty) {
    final cmp = aName.toLowerCase().compareTo(bName.toLowerCase());
    if (cmp != 0) return cmp;
  }

  final aDate = a.scheduledDate ?? a.scheduledAt ?? '';
  final bDate = b.scheduledDate ?? b.scheduledAt ?? '';
  final dateCmp = aDate.compareTo(bDate);
  if (dateCmp != 0) return dateCmp;

  return a.title.toLowerCase().compareTo(b.title.toLowerCase());
}

/// Returns subtitle parts for a chore row.
///
/// History / completion-log rows: [scheduled/completed label, calendar name].
/// Active rows: [assignee or 'Unassigned', pts (if > 0), repeat label (if set), calendar name].
List<String> choreSubtitleParts({
  required ClientChore chore,
  required String calendarName,
  required String scheduledLabel,
}) {
  final isHistoryOrDone =
      chore.isCompletionLog ||
      chore.completedToday ||
      chore.normalizedSection == 'history' ||
      chore.normalizedSection == 'doneToday';

  if (isHistoryOrDone) {
    final assignee = chore.assigneeName?.trim();
    return [
      if (assignee != null && assignee.isNotEmpty) assignee,
      if (scheduledLabel.isNotEmpty) scheduledLabel,
      if (calendarName.isNotEmpty) calendarName,
    ];
  }

  final assignee = chore.assigneeName?.trim();
  final parts = <String>[
    assignee != null && assignee.isNotEmpty ? assignee : 'Unassigned',
  ];

  final rrule = _rruleLabel(chore.recurrence);
  if (rrule.isNotEmpty) parts.add(rrule);

  if (calendarName.isNotEmpty) parts.add(calendarName);

  return parts;
}

String _rruleLabel(String? recurrence) {
  final rrule = recurrence?.trim().toUpperCase();
  if (rrule == 'FREQ=DAILY') return 'Daily';
  if (rrule == 'FREQ=WEEKLY') return 'Weekly';
  if (rrule == 'FREQ=MONTHLY') return 'Monthly';
  return '';
}

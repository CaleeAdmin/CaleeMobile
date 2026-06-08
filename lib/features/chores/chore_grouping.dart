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

  final grouped = <String, List<ClientChore>>{};

  for (final chore in chores) {
    final apiSection = chore.normalizedSection;
    final uiSection = apiSection == 'future'
        ? _futureSubsection(
            chore,
            tomorrowDate: tomorrowDate,
            endOfWeekDate: endOfWeekDate,
          )
        : apiSection;
    grouped.putIfAbsent(uiSection, () => []).add(chore);
  }

  for (final group in grouped.values) {
    group.sort(compareChores);
  }

  return grouped;
}

String _futureSubsection(
  ClientChore chore, {
  required DateTime tomorrowDate,
  required DateTime endOfWeekDate,
}) {
  final dateStr = chore.scheduledDate ?? chore.scheduledAt;
  if (dateStr == null || dateStr.trim().isEmpty) return 'later';

  final parsed = DateTime.tryParse(dateStr)?.toLocal();
  if (parsed == null) return 'later';

  final d = DateTime(parsed.year, parsed.month, parsed.day);
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
  final isHistory =
      chore.isCompletionLog || chore.normalizedSection == 'history';

  if (isHistory) {
    return [
      if (scheduledLabel.isNotEmpty) scheduledLabel,
      if (calendarName.isNotEmpty) calendarName,
    ];
  }

  final assignee = chore.assigneeName?.trim();
  final parts = <String>[
    assignee != null && assignee.isNotEmpty ? assignee : 'Unassigned',
  ];

  if (chore.points > 0) parts.add('${chore.points} pts');

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

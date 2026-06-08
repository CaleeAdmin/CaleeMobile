import 'package:calee_mobile/data/models/client_chore.dart';
import 'package:calee_mobile/features/chores/chore_grouping.dart';
import 'package:flutter_test/flutter_test.dart';

// ── Helpers ──────────────────────────────────────────────────────────────────

ClientChore _chore({
  String id = 'c1',
  String section = 'future',
  String? scheduledDate,
  String? scheduledAt,
  String? assigneeName,
  String? assigneePersonId,
  int points = 1,
  String? recurrence,
  String calendarId = 'cal1',
  String title = 'Test chore',
  String kind = 'baseChore',
}) {
  return ClientChore(
    id: id,
    calendarId: calendarId,
    serviceId: 'portal',
    serviceName: 'Portal',
    title: title,
    scheduledAt: scheduledAt,
    scheduledDate: scheduledDate,
    description: null,
    source: '',
    kind: kind,
    choreUid: id,
    parentChoreUid: null,
    completionLogId: null,
    completedToday: false,
    section: section,
    recurrence: recurrence,
    points: points,
    metadataPoints: null,
    assigneePersonId: assigneePersonId,
    assigneeName: assigneeName,
    assigneeAvatarColor: null,
    approvalState: 'none',
  );
}

// Monday 2026-06-01 used as a stable test anchor
final _monday = DateTime(2026, 6, 1); // weekday = 1

void main() {
  group('ClientChore kind normalization', () {
    test('base chore aliases are treated as base chores', () {
      expect(_chore(kind: 'baseChore').isBaseChore, isTrue);
      expect(_chore(kind: 'chore').isBaseChore, isTrue);
      expect(_chore(kind: 'base_chore').isBaseChore, isTrue);
    });

    test('completion log aliases are treated as completion logs', () {
      expect(_chore(kind: 'completionLog').isCompletionLog, isTrue);
      expect(_chore(kind: 'completion_log').isCompletionLog, isTrue);
    });

    test('chore alias keeps completion actions actionable', () {
      final chore = _chore(id: 'chore-1', kind: 'chore', section: 'today');

      expect(chore.completionActionId, 'chore-1');
      expect(chore.canToggleCompletion, isTrue);
    });
  });

  // ── groupChoresBySection ─────────────────────────────────────────────────

  group('groupChoresBySection', () {
    test('passthrough sections are unchanged', () {
      final chores = [
        _chore(id: 'o', section: 'overdue'),
        _chore(id: 't', section: 'todoToday'),
        _chore(id: 'd', section: 'doneToday'),
        _chore(id: 'h', section: 'history'),
      ];
      final groups = groupChoresBySection(chores, _monday);
      expect(groups.containsKey('overdue'), isTrue);
      expect(groups.containsKey('todoToday'), isTrue);
      expect(groups.containsKey('doneToday'), isTrue);
      expect(groups.containsKey('history'), isTrue);
      expect(groups.containsKey('future'), isFalse);
    });

    test('future with no scheduled date → later', () {
      final chore = _chore(section: 'future');
      final groups = groupChoresBySection([chore], _monday);
      expect(groups['later'], isNotNull);
      expect(groups['later']!.first.id, 'c1');
    });

    test('future chore scheduled tomorrow → tomorrow', () {
      final tomorrow = _monday.add(const Duration(days: 1)); // 2026-06-02
      final chore = _chore(
        section: 'future',
        scheduledDate:
            '${tomorrow.year}-${tomorrow.month.toString().padLeft(2, '0')}-${tomorrow.day.toString().padLeft(2, '0')}',
      );
      final groups = groupChoresBySection([chore], _monday);
      expect(groups['tomorrow'], isNotNull);
    });

    test('future chore later this week (Wed) → laterThisWeek', () {
      // Monday week: Mon–Sun. Wednesday is within the same week.
      final wednesday = _monday.add(const Duration(days: 2)); // 2026-06-03
      final chore = _chore(
        section: 'future',
        scheduledDate:
            '${wednesday.year}-${wednesday.month.toString().padLeft(2, '0')}-${wednesday.day.toString().padLeft(2, '0')}',
      );
      final groups = groupChoresBySection([chore], _monday);
      expect(groups['laterThisWeek'], isNotNull);
    });

    test('future chore next week → later', () {
      final nextMonday = _monday.add(const Duration(days: 7)); // 2026-06-08
      final chore = _chore(
        section: 'future',
        scheduledDate:
            '${nextMonday.year}-${nextMonday.month.toString().padLeft(2, '0')}-${nextMonday.day.toString().padLeft(2, '0')}',
      );
      final groups = groupChoresBySection([chore], _monday);
      expect(groups['later'], isNotNull);
    });

    test('future chore on Sunday (end of week) → laterThisWeek', () {
      final sunday = _monday.add(const Duration(days: 6)); // 2026-06-07
      final chore = _chore(
        section: 'future',
        scheduledDate:
            '${sunday.year}-${sunday.month.toString().padLeft(2, '0')}-${sunday.day.toString().padLeft(2, '0')}',
      );
      final groups = groupChoresBySection([chore], _monday);
      expect(groups['laterThisWeek'], isNotNull);
    });

    test('section aliases are normalized into canonical groups', () {
      final chores = [
        _chore(id: 'today', section: 'today'),
        _chore(id: 'todo_today', section: 'todo_today'),
        _chore(id: 'done_today', section: 'done_today'),
        _chore(id: 'completedToday', section: 'completedToday'),
      ];

      final groups = groupChoresBySection(chores, _monday);

      expect(
        groups['todoToday']?.map((c) => c.id),
        containsAll(['today', 'todo_today']),
      );
      expect(
        groups['doneToday']?.map((c) => c.id),
        containsAll(['done_today', 'completedToday']),
      );
    });

    test('empty string section treated as todoToday', () {
      final chore = _chore(section: '');
      final groups = groupChoresBySection([chore], _monday);
      expect(groups['todoToday'], isNotNull);
    });
  });

  // ── compareChores ────────────────────────────────────────────────────────

  group('compareChores', () {
    test('assigned before unassigned', () {
      final assigned = _chore(id: 'a', assigneeName: 'Mia');
      final unassigned = _chore(id: 'b');
      expect(compareChores(assigned, unassigned), isNegative);
      expect(compareChores(unassigned, assigned), isPositive);
    });

    test('alphabetical by assignee name', () {
      final ana = _chore(id: 'a', assigneeName: 'Ana');
      final zoe = _chore(id: 'b', assigneeName: 'Zoe');
      expect(compareChores(ana, zoe), isNegative);
      expect(compareChores(zoe, ana), isPositive);
    });

    test('equal assignee → sort by date', () {
      final early = _chore(
        id: 'a',
        assigneeName: 'Mia',
        scheduledDate: '2026-06-01',
      );
      final late = _chore(
        id: 'b',
        assigneeName: 'Mia',
        scheduledDate: '2026-06-10',
      );
      expect(compareChores(early, late), isNegative);
    });

    test('equal assignee and date → sort by title', () {
      final apple = _chore(
        id: 'a',
        assigneeName: 'Mia',
        scheduledDate: '2026-06-01',
        title: 'Apple',
      );
      final banana = _chore(
        id: 'b',
        assigneeName: 'Mia',
        scheduledDate: '2026-06-01',
        title: 'Banana',
      );
      expect(compareChores(apple, banana), isNegative);
    });

    test('two unassigned sorted by date then title', () {
      final first = _chore(
        id: 'a',
        scheduledDate: '2026-06-01',
        title: 'Alpha',
      );
      final second = _chore(
        id: 'b',
        scheduledDate: '2026-06-01',
        title: 'Beta',
      );
      expect(compareChores(first, second), isNegative);
    });
  });

  // ── choreSubtitleParts ───────────────────────────────────────────────────

  group('choreSubtitleParts', () {
    test('active chore: assignee · pts · repeat · list', () {
      final chore = _chore(
        assigneeName: 'Mia',
        points: 2,
        recurrence: 'FREQ=DAILY',
      );
      final parts = choreSubtitleParts(
        chore: chore,
        calendarName: 'Kids chores',
        scheduledLabel: 'Scheduled 1/6/2026',
      );
      expect(parts, ['Mia', '2 pts', 'Daily', 'Kids chores']);
    });

    test('active chore with 0 points omits pts', () {
      final chore = _chore(assigneeName: 'Mia', points: 0);
      final parts = choreSubtitleParts(
        chore: chore,
        calendarName: 'Chores',
        scheduledLabel: '',
      );
      expect(parts, ['Mia', 'Chores']);
    });

    test('active unassigned chore shows "Unassigned"', () {
      final chore = _chore(points: 1);
      final parts = choreSubtitleParts(
        chore: chore,
        calendarName: 'Chores',
        scheduledLabel: '',
      );
      expect(parts.first, 'Unassigned');
    });

    test('active chore without recurrence omits repeat label', () {
      final chore = _chore(assigneeName: 'Tom', points: 1);
      final parts = choreSubtitleParts(
        chore: chore,
        calendarName: 'Chores',
        scheduledLabel: '',
      );
      expect(parts, ['Tom', '1 pts', 'Chores']);
    });

    test('history chore: date · list only', () {
      final chore = _chore(
        section: 'history',
        kind: 'completionLog',
        assigneeName: 'Mia',
        points: 5,
        recurrence: 'FREQ=WEEKLY',
      );
      final parts = choreSubtitleParts(
        chore: chore,
        calendarName: 'Kids chores',
        scheduledLabel: 'Completed 1/6/2026',
      );
      expect(parts, ['Completed 1/6/2026', 'Kids chores']);
    });

    test('history chore with empty scheduledLabel omits date', () {
      final chore = _chore(section: 'history', kind: 'completionLog');
      final parts = choreSubtitleParts(
        chore: chore,
        calendarName: 'Chores',
        scheduledLabel: '',
      );
      expect(parts, ['Chores']);
    });
  });
}

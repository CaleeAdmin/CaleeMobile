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
  bool completedToday = false,
  String? choreUid,
  String? parentChoreUid,
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
    choreUid: choreUid ?? id,
    parentChoreUid: parentChoreUid,
    completionLogId: null,
    completedToday: completedToday,
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

    test('completionLog done today can still be toggled (undone)', () {
      final chore = _chore(
        id: 'log-1',
        kind: 'completionLog',
        choreUid: 'uid-1',
        section: 'doneToday',
        completedToday: true,
      );

      expect(chore.canToggleCompletion, isTrue);
    });

    test('completionLog in history cannot be toggled', () {
      final chore = _chore(
        id: 'log-1',
        kind: 'completionLog',
        choreUid: 'uid-1',
        section: 'history',
      );

      expect(chore.canToggleCompletion, isFalse);
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

    test('recurring future with no scheduled date → todoToday', () {
      final chore = _chore(section: 'future', recurrence: 'FREQ=DAILY');
      final groups = groupChoresBySection([chore], _monday);
      expect(groups['todoToday'], isNotNull);
      expect(groups['todoToday']!.first.id, 'c1');
    });

    test('future chore scheduled today → todoToday', () {
      final chore = _chore(
        section: 'future',
        scheduledDate: '2026-06-01', // same as _monday
      );
      final groups = groupChoresBySection([chore], _monday);
      expect(groups['todoToday'], isNotNull);
      expect(groups['todoToday']!.first.id, 'c1');
    });

    test('future chore scheduled in the past → overdue', () {
      final yesterday = _monday.subtract(const Duration(days: 1));
      final chore = _chore(
        section: 'future',
        scheduledDate:
            '${yesterday.year}-${yesterday.month.toString().padLeft(2, '0')}-${yesterday.day.toString().padLeft(2, '0')}',
      );
      final groups = groupChoresBySection([chore], _monday);
      expect(groups['overdue'], isNotNull);
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

    // completedToday override ─────────────────────────────────────────────────

    test('completedToday=true overrides todoToday section → doneToday', () {
      final chore = _chore(section: 'todoToday', completedToday: true);
      final groups = groupChoresBySection([chore], _monday);

      expect(groups['doneToday'], contains(chore));
      expect(groups.containsKey('todoToday'), isFalse);
    });

    test('completedToday=true overrides overdue section → doneToday', () {
      final chore = _chore(
        section: 'overdue',
        completedToday: true,
        kind: 'completionLog',
      );
      final groups = groupChoresBySection([chore], _monday);

      expect(groups['doneToday'], contains(chore));
      expect(groups.containsKey('overdue'), isFalse);
    });

    test('completedToday=true with section=doneToday stays in doneToday', () {
      final chore = _chore(section: 'doneToday', completedToday: true);
      final groups = groupChoresBySection([chore], _monday);

      expect(groups['doneToday'], contains(chore));
    });

    test('completedToday=false with section=todoToday stays in todoToday', () {
      final chore = _chore(section: 'todoToday', completedToday: false);
      final groups = groupChoresBySection([chore], _monday);

      expect(groups['todoToday'], contains(chore));
      expect(groups.containsKey('doneToday'), isFalse);
    });

    // choreUid dedup between a baseChore row and its completionLog ─────────

    test('baseChore is suppressed from todoToday when a same-choreUid '
        'completionLog is done today', () {
      final base = _chore(
        id: 'base-1',
        choreUid: 'uid-1',
        section: 'future',
        recurrence: 'FREQ=DAILY',
      );
      final log = _chore(
        id: 'log-1',
        kind: 'completionLog',
        choreUid: 'uid-1',
        section: 'doneToday',
        completedToday: true,
      );

      final groups = groupChoresBySection([base, log], _monday);

      expect(groups['doneToday'], [log]);
      expect(groups.containsKey('todoToday'), isFalse);
    });

    test('baseChore is suppressed from overdue when a same-choreUid '
        'completionLog is done today', () {
      final yesterday = _monday.subtract(const Duration(days: 1));
      final overdueDate =
          '${yesterday.year}-${yesterday.month.toString().padLeft(2, '0')}-${yesterday.day.toString().padLeft(2, '0')}';
      final base = _chore(
        id: 'base-1',
        choreUid: 'uid-1',
        section: 'future',
        scheduledDate: overdueDate,
      );
      final log = _chore(
        id: 'log-1',
        kind: 'completionLog',
        choreUid: 'uid-1',
        section: 'doneToday',
        completedToday: true,
      );

      final groups = groupChoresBySection([base, log], _monday);

      expect(groups['doneToday'], [log]);
      expect(groups.containsKey('overdue'), isFalse);
    });

    test('completionLog matched via parentChoreUid also suppresses the '
        "matching baseChore's row", () {
      final base = _chore(
        id: 'base-1',
        choreUid: 'uid-1',
        section: 'future',
        recurrence: 'FREQ=DAILY',
      );
      final log = ClientChore(
        id: 'log-1',
        calendarId: 'cal1',
        serviceId: 'portal',
        serviceName: 'Portal',
        title: 'Test chore',
        scheduledAt: null,
        scheduledDate: null,
        description: null,
        source: '',
        kind: 'completionLog',
        choreUid: null,
        parentChoreUid: 'uid-1',
        completionLogId: 'log-1',
        completedToday: true,
        section: 'doneToday',
        recurrence: null,
        points: 1,
        metadataPoints: null,
        assigneePersonId: null,
        assigneeName: null,
        assigneeAvatarColor: null,
        approvalState: 'none',
      );

      final groups = groupChoresBySection([base, log], _monday);

      expect(groups['doneToday'], [log]);
      expect(groups.containsKey('todoToday'), isFalse);
    });

    test('baseChore with a distinct future scheduledDate is not suppressed by '
        "today's completionLog for the same choreUid", () {
      final nextWeek = _monday.add(const Duration(days: 7));
      final nextWeekDate =
          '${nextWeek.year}-${nextWeek.month.toString().padLeft(2, '0')}-${nextWeek.day.toString().padLeft(2, '0')}';
      final base = _chore(
        id: 'base-1',
        choreUid: 'uid-1',
        section: 'future',
        scheduledDate: nextWeekDate,
        recurrence: 'FREQ=WEEKLY',
      );
      final log = _chore(
        id: 'log-1',
        kind: 'completionLog',
        choreUid: 'uid-1',
        section: 'doneToday',
        completedToday: true,
      );

      final groups = groupChoresBySection([base, log], _monday);

      expect(groups['doneToday'], [log]);
      expect(groups['later'], [base]);
    });

    test('two different recurring chores due today do not cross-suppress '
        'each other', () {
      final baseA = _chore(
        id: 'a',
        choreUid: 'uid-a',
        section: 'future',
        recurrence: 'FREQ=DAILY',
      );
      final logB = _chore(
        id: 'b-log',
        kind: 'completionLog',
        choreUid: 'uid-b',
        section: 'doneToday',
        completedToday: true,
      );

      final groups = groupChoresBySection([baseA, logB], _monday);

      expect(groups['todoToday'], [baseA]);
      expect(groups['doneToday'], [logB]);
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
    test('active chore: assignee · repeat · list (no pts in subtitle)', () {
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
      expect(parts, ['Mia', 'Daily', 'Kids chores']);
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

    test('active chore without recurrence omits repeat label and pts', () {
      final chore = _chore(assigneeName: 'Tom', points: 1);
      final parts = choreSubtitleParts(
        chore: chore,
        calendarName: 'Chores',
        scheduledLabel: '',
      );
      expect(parts, ['Tom', 'Chores']);
    });

    test('history chore: assignee · date · list', () {
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
      expect(parts, ['Mia', 'Completed 1/6/2026', 'Kids chores']);
    });

    test('history chore without assignee: date · list only', () {
      final chore = _chore(
        section: 'history',
        kind: 'completionLog',
        points: 5,
      );
      final parts = choreSubtitleParts(
        chore: chore,
        calendarName: 'Kids chores',
        scheduledLabel: 'Completed 1/6/2026',
      );
      expect(parts, ['Completed 1/6/2026', 'Kids chores']);
    });

    test('doneToday chore shows assignee · date · list', () {
      final chore = _chore(
        section: 'doneToday',
        assigneeName: 'Noah',
        points: 1,
      );
      final parts = choreSubtitleParts(
        chore: chore,
        calendarName: 'Kids Chores',
        scheduledLabel: 'Completed 23/6/2026',
      );
      expect(parts, ['Noah', 'Completed 23/6/2026', 'Kids Chores']);
    });

    test('doneToday chore without assignee shows date · list', () {
      final chore = _chore(section: 'doneToday', points: 1);
      final parts = choreSubtitleParts(
        chore: chore,
        calendarName: 'Kids Chores',
        scheduledLabel: 'Completed 23/6/2026',
      );
      expect(parts, ['Completed 23/6/2026', 'Kids Chores']);
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

    test(
      'completedToday=true uses done format even when section=todoToday',
      () {
        final chore = _chore(
          section: 'todoToday',
          completedToday: true,
          assigneeName: 'Mia',
          recurrence: 'FREQ=DAILY',
        );
        final parts = choreSubtitleParts(
          chore: chore,
          calendarName: 'Kids chores',
          scheduledLabel: 'Completed 1/6/2026',
        );

        expect(parts, contains('Mia'));
        expect(parts, contains('Completed 1/6/2026'));
        expect(parts, contains('Kids chores'));
        // Repeat label must not appear for a completed chore row
        expect(parts, isNot(contains('Daily')));
        // 'Unassigned' must not appear when assignee is set
        expect(parts, isNot(contains('Unassigned')));
      },
    );
  });

  // ── points badge pluralisation ───────────────────────────────────────────

  String ptLabel(int points) => '$points ${points == 1 ? 'pt' : 'pts'}';

  group('points badge label pluralisation', () {
    test('1 point → "1 pt"', () => expect(ptLabel(1), '1 pt'));
    test('2 points → "2 pts"', () => expect(ptLabel(2), '2 pts'));
    test('100 points → "100 pts"', () => expect(ptLabel(100), '100 pts'));
  });
}

import 'package:calee_mobile/data/models/client_chore.dart';
import 'package:calee_mobile/data/models/client_person.dart';
import 'package:calee_mobile/features/chores/widgets/edit_chore_sheet.dart';
import 'package:calee_mobile/ui/calee_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

// ── Repeat helpers ────────────────────────────────────────────────────────────

Future<void> _openRepeatPicker(WidgetTester tester) async {
  final repeatRow = find.ancestor(
    of: find.text('Repeat'),
    matching: find.byType(InkWell),
  );
  await tester.tap(repeatRow.first);
  await tester.pumpAndSettle();
}

Future<void> _selectCustomRepeat(
  WidgetTester tester,
  List<String> pillLabels,
) async {
  await _openRepeatPicker(tester);
  await tester.tap(find.text('Custom days'));
  await tester.pumpAndSettle();
  for (final pill in pillLabels) {
    await tester.tap(find.text(pill));
    await tester.pumpAndSettle();
  }
  await tester.tap(find.text('Done'));
  await tester.pumpAndSettle();
}

// ── Helpers ───────────────────────────────────────────────────────────────────

ClientChore _chore() => ClientChore(
  id: 'c1',
  calendarId: 'cal-1',
  serviceId: 'portal',
  serviceName: 'Portal',
  title: 'Clean Kitchen',
  scheduledAt: null,
  scheduledDate: null,
  description: null,
  source: '',
  kind: 'baseChore',
  choreUid: 'uid-1',
  parentChoreUid: null,
  completionLogId: null,
  completedToday: false,
  section: 'todoToday',
  recurrence: null,
  points: 1,
  metadataPoints: null,
  assigneePersonId: null,
  assigneeName: null,
  assigneeAvatarColor: null,
  approvalState: 'none',
);

Widget _wrap({
  VoidCallback? onDeleteInvoked,
  void Function(String?)? onUpdateRecurrence,
}) => MaterialApp(
  theme: CaleeTheme.buildThemeData(),
  home: Scaffold(
    body: SingleChildScrollView(
      child: EditChoreSheet(
        chore: _chore(),
        people: const <ClientPerson>[],
        metadata: null,
        onUpdate: ({
          required chore,
          required title,
          scheduledAt,
          description,
          recurrence,
          required assigneePersonId,
          required points,
          required approvalState,
        }) async {
          onUpdateRecurrence?.call(recurrence);
        },
        onDelete: () async {
          onDeleteInvoked?.call();
        },
      ),
    ),
  ),
);

// ── Tests ─────────────────────────────────────────────────────────────────────

void main() {
  testWidgets('EditChoreSheet shows Save chore and Delete chore buttons', (
    tester,
  ) async {
    await tester.pumpWidget(_wrap());
    await tester.pumpAndSettle();

    expect(find.text('Save chore'), findsOneWidget);
    expect(find.text('Delete chore'), findsOneWidget);
  });

  testWidgets('EditChoreSheet delete button invokes onDelete', (tester) async {
    bool called = false;
    await tester.pumpWidget(_wrap(onDeleteInvoked: () => called = true));
    await tester.pumpAndSettle();

    await tester.ensureVisible(find.text('Delete chore'));
    await tester.tap(find.text('Delete chore'));
    await tester.pump();

    expect(called, isTrue);
  });

  testWidgets('EditChoreSheet shows Due date label not Date', (tester) async {
    await tester.pumpWidget(_wrap());
    await tester.pumpAndSettle();

    expect(find.text('Due date'), findsOneWidget);
    expect(find.text('Date'), findsNothing);
  });

  testWidgets('chore custom Mon/Wed/Fri sends FREQ=WEEKLY;BYDAY=MO,WE,FR', (
    tester,
  ) async {
    String? captured;
    await tester.pumpWidget(
      _wrap(onUpdateRecurrence: (r) => captured = r),
    );
    await tester.pumpAndSettle();

    await _selectCustomRepeat(tester, ['Mon', 'Wed', 'Fri']);

    await tester.ensureVisible(find.text('Save chore'));
    await tester.tap(find.text('Save chore'));
    await tester.pumpAndSettle();

    expect(captured, 'FREQ=WEEKLY;BYDAY=MO,WE,FR');
  });
}

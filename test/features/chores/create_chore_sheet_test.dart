import 'package:calee_mobile/data/models/client_calendar.dart';
import 'package:calee_mobile/data/models/client_person.dart';
import 'package:calee_mobile/features/chores/widgets/create_chore_sheet.dart';
import 'package:calee_mobile/ui/calee_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

// ── Fixtures ──────────────────────────────────────────────────────────────────

const _calendar = ClientCalendar(
  id: 'cal-1',
  serviceId: 'svc-1',
  serviceName: 'Family',
  name: 'Chores',
  components: ['VTODO'],
  primaryKind: 'chores',
  supportsEvents: false,
  supportsTasks: false,
  supportsChores: true,
  readOnly: false,
  isSubscription: false,
  source: 'test',
);

// ── Helpers ───────────────────────────────────────────────────────────────────

Widget _buildSheet({void Function(String?)? onRecurrence}) {
  return MaterialApp(
    theme: CaleeTheme.buildThemeData(),
    home: Scaffold(
      body: SingleChildScrollView(
        child: CreateChoreSheet(
          calendars: const [_calendar],
          people: const <ClientPerson>[],
          onCreate:
              ({
                required calendar,
                required title,
                scheduledAt,
                description,
                recurrence,
                required assigneePersonIds,
                required points,
              }) async {
                onRecurrence?.call(recurrence);
              },
        ),
      ),
    ),
  );
}

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
    await tester.ensureVisible(find.text(pill));
    await tester.pumpAndSettle();
    await tester.tap(find.text(pill));
    await tester.pumpAndSettle();
  }
  await tester.ensureVisible(find.text('Done'));
  await tester.pumpAndSettle();
  await tester.tap(find.text('Done'));
  await tester.pumpAndSettle();
}

// ── Tests ─────────────────────────────────────────────────────────────────────

void main() {
  group('CreateChoreSheet', () {
    testWidgets('shows Create chore button', (tester) async {
      await tester.pumpWidget(_buildSheet());
      await tester.pumpAndSettle();

      expect(find.text('Create chore'), findsOneWidget);
    });

    testWidgets('custom Mon/Wed/Fri sends FREQ=WEEKLY;BYDAY=MO,WE,FR', (
      tester,
    ) async {
      String? captured;
      await tester.pumpWidget(_buildSheet(onRecurrence: (r) => captured = r));
      await tester.pumpAndSettle();

      await tester.enterText(find.byType(TextFormField).first, 'Test chore');
      await tester.pumpAndSettle();

      await _selectCustomRepeat(tester, ['Mon', 'Wed', 'Fri']);

      await tester.ensureVisible(find.text('Create chore'));
      await tester.tap(find.text('Create chore'));
      await tester.pumpAndSettle();

      expect(captured, 'FREQ=WEEKLY;BYDAY=MO,WE,FR');
    });
  });
}

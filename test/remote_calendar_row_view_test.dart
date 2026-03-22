import 'package:caleesync/models/calendar_display_item.dart';
import 'package:caleesync/home/widgets/remote_calendar_row_view.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  CalendarDisplayItem buildItem({
    bool isEnabled = false,
    bool hasRelinkSuggestion = false,
    String name = 'Remote Work Calendar',
  }) {
    return CalendarDisplayItem(
      localId: 'local-1',
      remotePath: '/remote/work/',
      name: name,
      color: '#336699',
      eventCount: 12,
      isReadOnly: false,
      isSubscription: false,
      isLocalReadOnly: false,
      accountName: 'demo@example.com',
      isEnabled: isEnabled,
      origin: 0,
      bindingId: 1,
      bindingRole: 1,
      remoteCollectionId: 42,
      hasRelinkSuggestion: hasRelinkSuggestion,
      allowMassDeletionDangerous: false,
    );
  }

  Future<void> pumpRow(
    WidgetTester tester, {
    required CalendarDisplayItem item,
    bool isToggling = false,
    VoidCallback? onEnablePressed,
    VoidCallback? onDisablePressed,
    VoidCallback? onReviewRelinkPressed,
    VoidCallback? onEnableAnywayPressed,
    VoidCallback? onMorePressed,
    String? syncGateMessage,
  }) {
    return tester.pumpWidget(
      MaterialApp(
        home: Material(
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 700),
              child: RemoteCalendarRowView(
                item: item,
                isToggling: isToggling,
                color: Colors.blue,
                onEnablePressed: onEnablePressed,
                onDisablePressed: onDisablePressed,
                onReviewRelinkPressed: onReviewRelinkPressed,
                onEnableAnywayPressed: onEnableAnywayPressed,
                onMorePressed: onMorePressed,
                syncGateMessage: syncGateMessage,
              ),
            ),
          ),
        ),
      ),
    );
  }

  group('RemoteCalendarRowView state matrix', () {
    testWidgets('enabled row shows connected badge and disable action', (tester) async {
      await pumpRow(
        tester,
        item: buildItem(isEnabled: true),
        onDisablePressed: () {},
        onMorePressed: () {},
      );

      expect(find.text('Connected'), findsOneWidget);
      expect(find.text('Disable'), findsOneWidget);
      expect(find.text('Enable'), findsNothing);
      expect(find.text('Review Re-link'), findsNothing);
      expect(find.text('Enable anyway'), findsNothing);
    });

    testWidgets('disabled row without relink shows enable action only', (tester) async {
      await pumpRow(
        tester,
        item: buildItem(isEnabled: false, hasRelinkSuggestion: false),
        onEnablePressed: () {},
        onMorePressed: () {},
      );

      expect(find.text('Enable'), findsOneWidget);
      expect(find.text('Connected'), findsNothing);
      expect(find.text('Disable'), findsNothing);
      expect(find.text('Review Re-link'), findsNothing);
      expect(find.text('Enable anyway'), findsNothing);
    });

    testWidgets('disabled row with relink suggestion shows relink actions', (tester) async {
      await pumpRow(
        tester,
        item: buildItem(isEnabled: false, hasRelinkSuggestion: true),
        onReviewRelinkPressed: () {},
        onEnableAnywayPressed: () {},
        onMorePressed: () {},
      );

      expect(find.text('Review Re-link'), findsOneWidget);
      expect(find.text('Enable anyway'), findsOneWidget);
      expect(find.text('Possible reconnection on this device'), findsOneWidget);
      expect(find.text('Enable'), findsNothing);
      expect(find.text('Connected'), findsNothing);
    });

    testWidgets('toggling enabled row shows updating state and disables actions', (tester) async {
      await pumpRow(
        tester,
        item: buildItem(isEnabled: true),
        isToggling: true,
      );

      expect(find.text('Updating...'), findsOneWidget);
      expect(find.byType(CircularProgressIndicator), findsOneWidget);

      final TextButton disableButton = tester.widget<TextButton>(find.byType(TextButton).first);
      expect(disableButton.onPressed, isNull);

      final IconButton moreButton = tester.widget<IconButton>(find.byIcon(Icons.more_vert));
      expect(moreButton.onPressed, isNull);
    });

    testWidgets('toggling disabled non-relink row disables enable action with spinner', (tester) async {
      await pumpRow(
        tester,
        item: buildItem(isEnabled: false, hasRelinkSuggestion: false),
        isToggling: true,
      );

      expect(find.text('Updating...'), findsOneWidget);
      expect(find.byType(CircularProgressIndicator), findsOneWidget);

      final FilledButton enableButton = tester.widget<FilledButton>(find.byType(FilledButton));
      expect(enableButton.onPressed, isNull);
    });

    testWidgets('toggling disabled relink row disables actions without review spinner', (tester) async {
      await pumpRow(
        tester,
        item: buildItem(isEnabled: false, hasRelinkSuggestion: true),
        isToggling: true,
      );

      expect(find.text('Updating...'), findsOneWidget);
      expect(find.byType(CircularProgressIndicator), findsNothing);

      final FilledButton reviewButton = tester.widget<FilledButton>(
        find.widgetWithText(FilledButton, 'Review Re-link'),
      );
      expect(reviewButton.onPressed, isNull);

      final TextButton enableAnywayButton = tester.widget<TextButton>(
        find.widgetWithText(TextButton, 'Enable anyway'),
      );
      expect(enableAnywayButton.onPressed, isNull);
    });
  });

  group('RemoteCalendarRowView callbacks', () {
    testWidgets('tapping Enable triggers onEnablePressed', (tester) async {
      var tapped = false;
      await pumpRow(
        tester,
        item: buildItem(isEnabled: false, hasRelinkSuggestion: false),
        onEnablePressed: () => tapped = true,
        onMorePressed: () {},
      );

      await tester.tap(find.text('Enable'));
      await tester.pump();

      expect(tapped, isTrue);
    });

    testWidgets('tapping Disable triggers onDisablePressed', (tester) async {
      var tapped = false;
      await pumpRow(
        tester,
        item: buildItem(isEnabled: true),
        onDisablePressed: () => tapped = true,
        onMorePressed: () {},
      );

      await tester.tap(find.text('Disable'));
      await tester.pump();

      expect(tapped, isTrue);
    });

    testWidgets('tapping Review Re-link triggers onReviewRelinkPressed', (tester) async {
      var tapped = false;
      await pumpRow(
        tester,
        item: buildItem(isEnabled: false, hasRelinkSuggestion: true),
        onReviewRelinkPressed: () => tapped = true,
        onEnableAnywayPressed: () {},
        onMorePressed: () {},
      );

      await tester.tap(find.text('Review Re-link'));
      await tester.pump();

      expect(tapped, isTrue);
    });

    testWidgets('tapping Enable anyway triggers onEnableAnywayPressed', (tester) async {
      var tapped = false;
      await pumpRow(
        tester,
        item: buildItem(isEnabled: false, hasRelinkSuggestion: true),
        onReviewRelinkPressed: () {},
        onEnableAnywayPressed: () => tapped = true,
        onMorePressed: () {},
      );

      await tester.tap(find.text('Enable anyway'));
      await tester.pump();

      expect(tapped, isTrue);
    });
  });
}

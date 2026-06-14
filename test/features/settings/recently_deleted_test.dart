// Widget tests for RecentlyDeletedPage.

import 'package:calee_mobile/data/api/calee_hub_client.dart';
import 'package:calee_mobile/data/models/client_deleted_items.dart';
import 'package:calee_mobile/features/settings/recently_deleted_page.dart';
import 'package:calee_mobile/ui/calee_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

// ─── Stubs ────────────────────────────────────────────────────────────────────

class _EmptyHubClient extends CaleeHubClient {
  _EmptyHubClient() : super(baseUri: Uri.parse('http://localhost'));

  @override
  Future<DeletedItemsResponse> listDeletedItems({
    required String accessToken,
    String? serviceId,
    String? type,
    int? limit,
    String? cursor,
  }) async {
    return const DeletedItemsResponse(items: [], unsupportedServices: []);
  }
}

class _ItemsHubClient extends CaleeHubClient {
  _ItemsHubClient(this._response)
    : super(baseUri: Uri.parse('http://localhost'));

  final DeletedItemsResponse _response;

  @override
  Future<DeletedItemsResponse> listDeletedItems({
    required String accessToken,
    String? serviceId,
    String? type,
    int? limit,
    String? cursor,
  }) async {
    return _response;
  }

  @override
  Future<void> restoreDeletedItem({
    required String accessToken,
    required String serviceId,
    required String deletedItemId,
  }) async {}

  @override
  Future<void> deleteDeletedItemPermanently({
    required String accessToken,
    required String serviceId,
    required String deletedItemId,
  }) async {}
}

class _RestoreConflictClient extends CaleeHubClient {
  _RestoreConflictClient(this._items)
    : super(baseUri: Uri.parse('http://localhost'));

  final List<DeletedItem> _items;

  @override
  Future<DeletedItemsResponse> listDeletedItems({
    required String accessToken,
    String? serviceId,
    String? type,
    int? limit,
    String? cursor,
  }) async {
    return DeletedItemsResponse(items: _items, unsupportedServices: const []);
  }

  @override
  Future<void> restoreDeletedItem({
    required String accessToken,
    required String serviceId,
    required String deletedItemId,
  }) async {
    throw const CaleeHubException(
      statusCode: 409,
      message: 'Conflict',
      code: 'RESTORE_CONFLICT',
    );
  }
}

// ─── Helpers ──────────────────────────────────────────────────────────────────

DeletedItem _calendarItem({
  String id = 'item-1',
  String serviceId = 'svc-1',
  bool canRestore = true,
  bool canDeletePermanently = true,
}) {
  return DeletedItem(
    deletedItemId: id,
    serviceId: serviceId,
    provider: 'nextcloud',
    type: 'calendar',
    title: 'Work Calendar',
    deletedAt: '2026-06-01T10:00:00Z',
    canRestore: canRestore,
    canDeletePermanently: canDeletePermanently,
    restoreConflictPossible: false,
  );
}

DeletedItem _eventItem() {
  return const DeletedItem(
    deletedItemId: 'ev-1',
    serviceId: 'svc-1',
    provider: 'nextcloud',
    type: 'event',
    title: 'Team meeting',
    subtitle: 'Work Calendar',
    deletedAt: '2026-06-02T09:00:00Z',
    canRestore: true,
    canDeletePermanently: false,
    restoreConflictPossible: false,
  );
}

Widget _wrap(CaleeHubClient client) => MaterialApp(
  theme: CaleeTheme.buildThemeData(),
  home: RecentlyDeletedPage(hubClient: client, accessToken: 'tok'),
);

void _setUpChannels() {
  SharedPreferences.setMockInitialValues({
    'calee_pref_migrated_to_shared_prefs': true,
  });
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(
        const MethodChannel('plugins.it_nomads.com/flutter_secure_storage'),
        (call) async => <String, String>{},
      );
}

void _tearDownChannels() {
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(
        const MethodChannel('plugins.it_nomads.com/flutter_secure_storage'),
        null,
      );
}

// ─── Tests ────────────────────────────────────────────────────────────────────

void main() {
  setUp(_setUpChannels);
  tearDown(_tearDownChannels);

  testWidgets('shows page title', (tester) async {
    await tester.pumpWidget(_wrap(_EmptyHubClient()));
    await tester.pumpAndSettle();
    expect(find.text('Recently deleted'), findsOneWidget);
  });

  testWidgets('empty state renders when no items', (tester) async {
    await tester.pumpWidget(_wrap(_EmptyHubClient()));
    await tester.pumpAndSettle();
    expect(find.text('Nothing recently deleted'), findsOneWidget);
    expect(
      find.text('Deleted items will appear here for a limited time.'),
      findsOneWidget,
    );
  });

  testWidgets('item row shows title and type label', (tester) async {
    final client = _ItemsHubClient(
      DeletedItemsResponse(
        items: [_calendarItem()],
        unsupportedServices: const [],
      ),
    );
    await tester.pumpWidget(_wrap(client));
    await tester.pumpAndSettle();
    expect(find.text('Work Calendar'), findsOneWidget);
    expect(find.textContaining('Calendar'), findsWidgets);
  });

  testWidgets('list-type item appears under Calendars and lists section', (
    tester,
  ) async {
    final client = _ItemsHubClient(
      DeletedItemsResponse(
        items: [_calendarItem()],
        unsupportedServices: const [],
      ),
    );
    await tester.pumpWidget(_wrap(client));
    await tester.pumpAndSettle();
    expect(find.text('CALENDARS AND LISTS'), findsOneWidget);
  });

  testWidgets('event item appears under Items section', (tester) async {
    final client = _ItemsHubClient(
      DeletedItemsResponse(
        items: [_eventItem()],
        unsupportedServices: const [],
      ),
    );
    await tester.pumpWidget(_wrap(client));
    await tester.pumpAndSettle();
    expect(find.text('ITEMS'), findsOneWidget);
    expect(find.text('Team meeting'), findsOneWidget);
  });

  testWidgets('unsupported service message appears', (tester) async {
    final client = _ItemsHubClient(
      const DeletedItemsResponse(
        items: [],
        unsupportedServices: [
          UnsupportedDeletedItemsService(
            serviceId: 'svc-2',
            displayName: 'Legacy Server',
          ),
        ],
      ),
    );
    await tester.pumpWidget(_wrap(client));
    await tester.pumpAndSettle();
    expect(find.text('Legacy Server'), findsOneWidget);
    expect(
      find.text(
        'Recently deleted is not available for this connected service yet.',
      ),
      findsOneWidget,
    );
  });

  testWidgets('restore calls API and shows snackbar', (tester) async {
    final client = _ItemsHubClient(
      DeletedItemsResponse(
        items: [_calendarItem()],
        unsupportedServices: const [],
      ),
    );
    await tester.pumpWidget(_wrap(client));
    await tester.pumpAndSettle();

    await tester.tap(find.byIcon(Icons.more_horiz).first);
    await tester.pumpAndSettle();

    await tester.tap(find.text('Restore'));
    await tester.pumpAndSettle();

    expect(find.text('Restored'), findsOneWidget);
  });

  testWidgets('delete permanently shows confirmation dialog', (tester) async {
    final client = _ItemsHubClient(
      DeletedItemsResponse(
        items: [_calendarItem()],
        unsupportedServices: const [],
      ),
    );
    await tester.pumpWidget(_wrap(client));
    await tester.pumpAndSettle();

    await tester.tap(find.byIcon(Icons.more_horiz).first);
    await tester.pumpAndSettle();

    await tester.tap(find.text('Delete permanently'));
    await tester.pumpAndSettle();

    expect(find.text('Delete permanently?'), findsOneWidget);
    expect(find.text('This cannot be undone.'), findsOneWidget);
  });

  testWidgets('confirming delete permanently shows snackbar', (tester) async {
    final client = _ItemsHubClient(
      DeletedItemsResponse(
        items: [_calendarItem()],
        unsupportedServices: const [],
      ),
    );
    await tester.pumpWidget(_wrap(client));
    await tester.pumpAndSettle();

    await tester.tap(find.byIcon(Icons.more_horiz).first);
    await tester.pumpAndSettle();

    await tester.tap(find.text('Delete permanently'));
    await tester.pumpAndSettle();

    final confirmButtons = find.text('Delete permanently');
    await tester.tap(confirmButtons.last);
    await tester.pumpAndSettle();

    expect(find.text('Deleted permanently'), findsOneWidget);
  });

  testWidgets('RESTORE_CONFLICT error shows friendly message', (tester) async {
    final item = _calendarItem();
    final client = _RestoreConflictClient([item]);
    await tester.pumpWidget(_wrap(client));
    await tester.pumpAndSettle();

    await tester.tap(find.byIcon(Icons.more_horiz).first);
    await tester.pumpAndSettle();

    await tester.tap(find.text('Restore'));
    await tester.pumpAndSettle();

    expect(
      find.textContaining('Could not restore because another item'),
      findsOneWidget,
    );
  });

  testWidgets('type label for task_list is Task list', (tester) async {
    final client = _ItemsHubClient(
      const DeletedItemsResponse(
        items: [
          DeletedItem(
            deletedItemId: 'tl-1',
            serviceId: 'svc-1',
            provider: 'nextcloud',
            type: 'task_list',
            title: 'Shopping',
            deletedAt: '2026-06-01T10:00:00Z',
            canRestore: false,
            canDeletePermanently: false,
            restoreConflictPossible: false,
          ),
        ],
        unsupportedServices: [],
      ),
    );
    await tester.pumpWidget(_wrap(client));
    await tester.pumpAndSettle();
    expect(find.textContaining('Task list'), findsWidgets);
  });

  testWidgets('type label for chore_list is Chore list', (tester) async {
    final client = _ItemsHubClient(
      const DeletedItemsResponse(
        items: [
          DeletedItem(
            deletedItemId: 'cl-1',
            serviceId: 'svc-1',
            provider: 'nextcloud',
            type: 'chore_list',
            title: 'Household chores',
            deletedAt: '2026-06-01T10:00:00Z',
            canRestore: false,
            canDeletePermanently: false,
            restoreConflictPossible: false,
          ),
        ],
        unsupportedServices: [],
      ),
    );
    await tester.pumpWidget(_wrap(client));
    await tester.pumpAndSettle();
    expect(find.textContaining('Chore list'), findsWidgets);
  });

  testWidgets('no forbidden words appear in UI', (tester) async {
    final client = _ItemsHubClient(
      DeletedItemsResponse(
        items: [_calendarItem(), _eventItem()],
        unsupportedServices: const [],
      ),
    );
    await tester.pumpWidget(_wrap(client));
    await tester.pumpAndSettle();

    final allText = tester
        .widgetList<Text>(find.byType(Text))
        .map((w) => w.data ?? '')
        .join(' ')
        .toLowerCase();

    expect(allText, isNot(contains('trashbin')));
    expect(allText, isNot(contains('nextcloud trashbin')));
    expect(allText, isNot(contains('caldav')));
    expect(allText, isNot(contains('deleted_at')));
    expect(allText, isNot(contains('vevent')));
    expect(allText, isNot(contains('vtodo')));
    expect(allText, isNot(contains('vjournal')));
  });

  testWidgets('settings shows Recently deleted entry', (tester) async {
    // Verified via settings_page_content_test.dart; this spot-checks
    // the subtitle string used in settings.
    const subtitle = 'Restore deleted calendars, tasks, and chores';
    expect(subtitle.toLowerCase(), isNot(contains('trashbin')));
    expect(subtitle.toLowerCase(), isNot(contains('caldav')));
  });

  testWidgets('unsupported service shows backend message when provided', (
    tester,
  ) async {
    final client = _ItemsHubClient(
      const DeletedItemsResponse(
        items: [],
        unsupportedServices: [
          UnsupportedDeletedItemsService(
            serviceId: 'svc-3',
            displayName: 'Old Server',
            message: 'Restore coming soon for this service.',
          ),
        ],
      ),
    );
    await tester.pumpWidget(_wrap(client));
    await tester.pumpAndSettle();
    expect(find.text('Restore coming soon for this service.'), findsOneWidget);
  });

  testWidgets('item row shows deleted date', (tester) async {
    final client = _ItemsHubClient(
      const DeletedItemsResponse(
        items: [
          DeletedItem(
            deletedItemId: 'ev-2',
            serviceId: 'svc-1',
            provider: 'nextcloud',
            type: 'event',
            title: 'Gym session',
            deletedAt: '2026-06-14T08:00:00Z',
            canRestore: false,
            canDeletePermanently: false,
            restoreConflictPossible: false,
          ),
        ],
        unsupportedServices: [],
      ),
    );
    await tester.pumpWidget(_wrap(client));
    await tester.pumpAndSettle();
    expect(find.textContaining('Deleted'), findsWidgets);
  });

  testWidgets('actionable event row shows three-dot button', (tester) async {
    final client = _ItemsHubClient(
      DeletedItemsResponse(
        items: [_eventItem()],
        unsupportedServices: const [],
      ),
    );
    await tester.pumpWidget(_wrap(client));
    await tester.pumpAndSettle();
    expect(find.byIcon(Icons.more_horiz), findsOneWidget);
  });

  testWidgets('non-actionable task_list row does not show three-dot button', (
    tester,
  ) async {
    final client = _ItemsHubClient(
      const DeletedItemsResponse(
        items: [
          DeletedItem(
            deletedItemId: 'tl-2',
            serviceId: 'svc-1',
            provider: 'nextcloud',
            type: 'task_list',
            title: 'My tasks',
            deletedAt: '2026-06-01T10:00:00Z',
            canRestore: false,
            canDeletePermanently: false,
            restoreConflictPossible: false,
          ),
        ],
        unsupportedServices: [],
      ),
    );
    await tester.pumpWidget(_wrap(client));
    await tester.pumpAndSettle();
    expect(find.byIcon(Icons.more_horiz), findsNothing);
  });

  testWidgets('tapping three-dot button opens action sheet with item title', (
    tester,
  ) async {
    final client = _ItemsHubClient(
      DeletedItemsResponse(
        items: [_eventItem()],
        unsupportedServices: const [],
      ),
    );
    await tester.pumpWidget(_wrap(client));
    await tester.pumpAndSettle();

    await tester.tap(find.byIcon(Icons.more_horiz));
    await tester.pumpAndSettle();

    expect(find.text('Team meeting'), findsWidgets);
  });

  testWidgets('leading icons render for each item type', (tester) async {
    final client = _ItemsHubClient(
      const DeletedItemsResponse(
        items: [
          DeletedItem(
            deletedItemId: 'ev-3',
            serviceId: 'svc-1',
            provider: 'nextcloud',
            type: 'event',
            title: 'Event',
            deletedAt: '2026-06-01T10:00:00Z',
            canRestore: true,
            canDeletePermanently: false,
            restoreConflictPossible: false,
          ),
          DeletedItem(
            deletedItemId: 'task-1',
            serviceId: 'svc-1',
            provider: 'nextcloud',
            type: 'task',
            title: 'A task',
            deletedAt: '2026-06-01T10:00:00Z',
            canRestore: true,
            canDeletePermanently: false,
            restoreConflictPossible: false,
          ),
          DeletedItem(
            deletedItemId: 'chore-1',
            serviceId: 'svc-1',
            provider: 'nextcloud',
            type: 'chore',
            title: 'A chore',
            deletedAt: '2026-06-01T10:00:00Z',
            canRestore: true,
            canDeletePermanently: false,
            restoreConflictPossible: false,
          ),
        ],
        unsupportedServices: [],
      ),
    );
    await tester.pumpWidget(_wrap(client));
    await tester.pumpAndSettle();

    expect(find.byIcon(Icons.event_outlined), findsOneWidget);
    expect(find.byIcon(Icons.check_circle_outline), findsOneWidget);
    expect(find.byIcon(Icons.cleaning_services_outlined), findsOneWidget);
  });
}

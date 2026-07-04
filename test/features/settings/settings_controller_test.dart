// Tests verify SettingsController state transitions without a widget tree.
// FlutterSecureStorage uses platform channels that hang in the Linux CI
// environment, so CaleePreferences is stubbed out.

import 'package:calee_mobile/data/api/calee_hub_client.dart';
import 'package:calee_mobile/data/auth/calee_preferences.dart';
import 'package:calee_mobile/data/models/client_bootstrap.dart';
import 'package:calee_mobile/data/models/client_calendar.dart';
import 'package:calee_mobile/features/settings/settings_controller.dart';
import 'package:calee_mobile/features/settings/settings_repository.dart';
import 'package:flutter_test/flutter_test.dart';

// ── Stubs ─────────────────────────────────────────────────────────────────────

class _StubPreferences extends CaleePreferences {
  StoredPreferences _stored = const StoredPreferences();
  bool _remindersEnabled = false;

  void seed(StoredPreferences value) => _stored = value;

  @override
  Future<StoredPreferences> load() async => _stored;

  @override
  Future<void> saveFirstDayOfWeek(FirstDayOfWeek value) async {
    _stored = StoredPreferences(
      firstDayOfWeek: value,
      timeFormat: _stored.timeFormat,
      defaultCalendarId: _stored.defaultCalendarId,
      defaultTaskListId: _stored.defaultTaskListId,
    );
  }

  @override
  Future<void> saveTimeFormat(TimeFormatPref value) async {
    _stored = StoredPreferences(
      firstDayOfWeek: _stored.firstDayOfWeek,
      timeFormat: value,
      defaultCalendarId: _stored.defaultCalendarId,
      defaultTaskListId: _stored.defaultTaskListId,
    );
  }

  @override
  Future<void> saveDefaultCalendarId(String? calendarId) async {
    _stored = StoredPreferences(
      firstDayOfWeek: _stored.firstDayOfWeek,
      timeFormat: _stored.timeFormat,
      defaultCalendarId: calendarId,
      defaultTaskListId: _stored.defaultTaskListId,
    );
  }

  @override
  Future<void> saveDefaultTaskListId(String? calendarId) async {
    _stored = StoredPreferences(
      firstDayOfWeek: _stored.firstDayOfWeek,
      timeFormat: _stored.timeFormat,
      defaultCalendarId: _stored.defaultCalendarId,
      defaultTaskListId: calendarId,
    );
  }

  @override
  Future<bool> loadCalendarRemindersEnabled() async => _remindersEnabled;

  @override
  Future<void> saveCalendarRemindersEnabled(bool enabled) async {
    _remindersEnabled = enabled;
  }
}

class _StubHubClient extends CaleeHubClient {
  _StubHubClient({
    List<ClientCalendar>? calendars,
    ClientBootstrap? bootstrap,
    this._failEnsure = false,
  }) : _calendars = calendars ?? [],
       _bootstrap = bootstrap ?? _emptyBootstrap();

  final List<ClientCalendar> _calendars;
  final ClientBootstrap _bootstrap;
  final bool _failEnsure;

  @override
  Future<ClientCalendarList> calendars({required String accessToken}) async =>
      ClientCalendarList(calendars: _calendars);

  @override
  Future<ClientBootstrap> bootstrap({required String accessToken}) async =>
      _bootstrap;

  @override
  Future<ClientContext> ensureDefaultFamily({
    required String accessToken,
  }) async {
    if (_failEnsure) {
      throw const CaleeHubException(statusCode: 500, message: 'Server error');
    }
    return const ClientContext(
      id: 'h1',
      type: 'household',
      name: 'My Family',
      role: 'admin',
      status: 'active',
    );
  }
}

// ── Fixtures ─────────────────────────────────────────────────────────────────

ClientBootstrap _emptyBootstrap() => ClientBootstrap(
  account: const ClientAccount(
    id: 'acc1',
    displayName: 'Test User',
    primaryEmail: 'test@example.com',
    timeZone: null,
    status: 'active',
  ),
  services: const [],
  contexts: const ClientContexts(households: [], organisations: []),
  availableContexts: const [],
  capabilities: const {},
);

ClientBootstrap _bootstrapWithHousehold() => ClientBootstrap(
  account: const ClientAccount(
    id: 'acc1',
    displayName: 'Test User',
    primaryEmail: 'test@example.com',
    timeZone: null,
    status: 'active',
  ),
  services: const [],
  contexts: ClientContexts(
    households: [
      const ClientContext(
        id: 'h1',
        type: 'household',
        name: 'My Family',
        role: 'admin',
        status: 'active',
      ),
    ],
    organisations: const [],
  ),
  availableContexts: const [],
  capabilities: const {},
);

ClientCalendar _calendar({
  required String id,
  String kind = 'calendar',
  bool readOnly = false,
}) => ClientCalendar(
  id: id,
  serviceId: 'svc1',
  serviceName: 'Service',
  name: id,
  color: '#ff0000',
  components: const [],
  primaryKind: kind,
  supportsEvents: kind == 'calendar',
  supportsTasks: kind == 'tasks',
  supportsChores: false,
  readOnly: readOnly,
  isSubscription: false,
  source: '',
);

// ── Helpers ───────────────────────────────────────────────────────────────────

SettingsController _makeController({
  List<ClientCalendar> calendars = const [],
  ClientBootstrap? bootstrap,
  bool failEnsure = false,
  _StubPreferences? prefs,
}) {
  final stubPrefs = prefs ?? _StubPreferences();
  final repository = SettingsRepository(
    hubClient: _StubHubClient(
      calendars: calendars,
      bootstrap: bootstrap ?? _emptyBootstrap(),
      failEnsure: failEnsure,
    ),
    accessToken: 'token',
    preferences: stubPrefs,
  );
  return SettingsController(
    repository: repository,
    initialBootstrap: _emptyBootstrap(),
  );
}

// ── Tests ─────────────────────────────────────────────────────────────────────

void main() {
  group('SettingsController.load', () {
    test('sets isLoadingPreferences true then false on success', () async {
      final controller = _makeController();
      final states = <bool>[];
      controller.addListener(() => states.add(controller.isLoadingPreferences));

      await controller.load();

      expect(states, [true, false]);
      expect(controller.error, isNull);
    });

    test('sets isLoadingPreferences true then false on error', () async {
      final failRepo = _FailingRepository(
        hubClient: _StubHubClient(),
        accessToken: 'token',
      );
      final ctrl = SettingsController(
        repository: failRepo,
        initialBootstrap: _emptyBootstrap(),
      );
      final states = <bool>[];
      ctrl.addListener(() => states.add(ctrl.isLoadingPreferences));

      await ctrl.load();

      expect(states, [true, false]);
      expect(ctrl.error, isNotNull);
    });

    test(
      'clears stale default calendar if missing from writable calendars',
      () async {
        final prefs = _StubPreferences();
        prefs.seed(const StoredPreferences(defaultCalendarId: 'gone-cal'));

        final controller = _makeController(
          calendars: [_calendar(id: 'other-cal')],
          prefs: prefs,
        );
        await controller.load();

        expect(controller.preferences.defaultCalendarId, isNull);
      },
    );

    test('retains default calendar if it exists and is writable', () async {
      final prefs = _StubPreferences();
      prefs.seed(const StoredPreferences(defaultCalendarId: 'cal1'));

      final controller = _makeController(
        calendars: [_calendar(id: 'cal1')],
        prefs: prefs,
      );
      await controller.load();

      expect(controller.preferences.defaultCalendarId, 'cal1');
    });

    test(
      'clears stale default task list if missing from task calendars',
      () async {
        final prefs = _StubPreferences();
        prefs.seed(const StoredPreferences(defaultTaskListId: 'gone-task'));

        final controller = _makeController(
          calendars: [_calendar(id: 'other-task', kind: 'tasks')],
          prefs: prefs,
        );
        await controller.load();

        expect(controller.preferences.defaultTaskListId, isNull);
      },
    );

    test('retains default task list if it exists in task calendars', () async {
      final prefs = _StubPreferences();
      prefs.seed(const StoredPreferences(defaultTaskListId: 'task1'));

      final controller = _makeController(
        calendars: [_calendar(id: 'task1', kind: 'tasks')],
        prefs: prefs,
      );
      await controller.load();

      expect(controller.preferences.defaultTaskListId, 'task1');
    });
  });

  group('SettingsController preference mutations', () {
    test('setFirstDayOfWeek updates controller preferences', () async {
      final controller = _makeController();
      await controller.load();

      await controller.setFirstDayOfWeek(FirstDayOfWeek.monday);

      expect(controller.preferences.firstDayOfWeek, FirstDayOfWeek.monday);
    });

    test('setTimeFormat updates controller preferences', () async {
      final controller = _makeController();
      await controller.load();

      await controller.setTimeFormat(TimeFormatPref.h24);

      expect(controller.preferences.timeFormat, TimeFormatPref.h24);
    });

    test('setDefaultCalendar updates controller preferences', () async {
      final cal = _calendar(id: 'cal1');
      final controller = _makeController(calendars: [cal]);
      await controller.load();

      await controller.setDefaultCalendar(cal);

      expect(controller.preferences.defaultCalendarId, 'cal1');
    });

    test('setDefaultTaskList updates controller preferences', () async {
      final task = _calendar(id: 'task1', kind: 'tasks');
      final controller = _makeController(calendars: [task]);
      await controller.load();

      await controller.setDefaultTaskList(task);

      expect(controller.preferences.defaultTaskListId, 'task1');
    });
  });

  group('SettingsController.ensureDefaultFamilyAndRefreshBootstrap', () {
    test(
      'sets isOpeningFamily true then false and updates bootstrap',
      () async {
        final controller = _makeController(
          bootstrap: _bootstrapWithHousehold(),
        );

        final states = <bool>[];
        controller.addListener(() => states.add(controller.isOpeningFamily));

        final fresh = await controller.ensureDefaultFamilyAndRefreshBootstrap();

        expect(states, [true, false]);
        expect(fresh.contexts.households, hasLength(1));
        expect(controller.bootstrap.contexts.households, hasLength(1));
        expect(controller.error, isNull);
      },
    );

    test(
      'propagates error so SettingsPage can show debug/fallback behavior',
      () async {
        final controller = _makeController(failEnsure: true);

        final states = <bool>[];
        controller.addListener(() => states.add(controller.isOpeningFamily));

        await expectLater(
          controller.ensureDefaultFamilyAndRefreshBootstrap(),
          throwsA(isA<CaleeHubException>()),
        );

        expect(states, [true, false]);
        expect(controller.isOpeningFamily, isFalse);
        expect(controller.error, isA<CaleeHubException>());
      },
    );
  });
}

// ── Failing repository stub ───────────────────────────────────────────────────

class _FailingRepository extends SettingsRepository {
  _FailingRepository({required super.hubClient, required super.accessToken});

  @override
  Future<SettingsOverview> loadOverview() => Future.error(Exception('fail'));
}

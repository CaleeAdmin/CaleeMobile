import 'dart:io';

import 'package:calee_mobile/data/models/client_bootstrap.dart';
import 'package:calee_mobile/data/models/client_calendar.dart';
import 'package:calee_mobile/data/models/client_caldav_account.dart';
import 'package:calee_mobile/data/models/client_deleted_items.dart';
import 'package:calee_mobile/data/models/client_task.dart';
import 'package:flutter_test/flutter_test.dart';

ClientEvent _event({
  required String id,
  bool recurring = false,
  String? seriesId,
}) => ClientEvent(
  id: id,
  calendarId: '',
  serviceId: '',
  serviceName: '',
  title: '',
  startsAt: '',
  endsAt: '',
  allDay: false,
  source: '',
  recurring: recurring,
  seriesId: seriesId,
);

ClientTask _task(String status) => ClientTask(
  id: '',
  calendarId: '',
  serviceId: '',
  serviceName: '',
  title: '',
  status: status,
  dueAt: null,
  completedAt: null,
  description: null,
  source: '',
);

void main() {
  _capabilityTests();
  _bootstrapMealsCapabilityTests();
  _deletedItemsModelTests();
  _clientCalDavAccountTests();

  group('ClientEvent.writableEventId', () {
    test('returns seriesId for recurring event with seriesId', () {
      final event = _event(id: 'evt1', recurring: true, seriesId: 'series1');
      expect(event.writableEventId, 'series1');
    });

    test('returns id for non-recurring event', () {
      final event = _event(id: 'evt2', recurring: false, seriesId: 'series1');
      expect(event.writableEventId, 'evt2');
    });

    test('returns id for recurring event with null seriesId', () {
      final event = _event(id: 'evt3', recurring: true, seriesId: null);
      expect(event.writableEventId, 'evt3');
    });

    test('returns id for recurring event with blank seriesId', () {
      final event = _event(id: 'evt4', recurring: true, seriesId: '   ');
      expect(event.writableEventId, 'evt4');
    });
  });

  group('ClientTask.isCompleted', () {
    test('returns true for completed status', () {
      expect(_task('completed').isCompleted, isTrue);
    });

    test('returns false for needsaction status', () {
      expect(_task('needsaction').isCompleted, isFalse);
    });

    test('returns false for cancelled status', () {
      expect(_task('cancelled').isCompleted, isFalse);
    });

    test('returns false for inprocess status', () {
      expect(_task('inprocess').isCompleted, isFalse);
    });
  });

  group('ClientTask.statusLabel', () {
    test('needsaction maps to To do', () {
      expect(_task('needsaction').statusLabel, 'To do');
    });

    test('completed maps to Completed', () {
      expect(_task('completed').statusLabel, 'Completed');
    });

    test('cancelled maps to Cancelled', () {
      expect(_task('cancelled').statusLabel, 'Cancelled');
    });

    test('inprocess maps to In progress', () {
      expect(_task('inprocess').statusLabel, 'In progress');
    });

    test('unknown status returns the raw status value', () {
      expect(_task('someother').statusLabel, 'someother');
    });

    test('empty status returns Task', () {
      expect(_task('').statusLabel, 'Task');
    });
  });
}

ClientBootstrap _bootstrap(Map<String, dynamic> caps) => ClientBootstrap(
  account: const ClientAccount(
    id: '',
    displayName: null,
    primaryEmail: null,
    timeZone: null,
    status: null,
  ),
  services: const [],
  contexts: const ClientContexts(households: [], organisations: []),
  availableContexts: const [],
  capabilities: caps,
);

ClientService _svc(Map<String, dynamic> caps) => ClientService(
  id: 'svc',
  displayName: 'Service',
  baseUrl: '',
  launchUrl: '',
  serviceType: '',
  accessStatus: 'active',
  calendarCredentialStatus: 'unsupported',
  source: '',
  capabilities: caps,
);

void _capabilityTests() {
  group('ClientService.supportsRecentlyDeleted', () {
    test('returns true for deletedItems capability', () {
      expect(_svc({'deletedItems': true}).supportsRecentlyDeleted, isTrue);
    });

    test('returns true for legacy recentlyDeleted capability', () {
      expect(_svc({'recentlyDeleted': true}).supportsRecentlyDeleted, isTrue);
    });

    test('returns false when neither capability set', () {
      expect(_svc({}).supportsRecentlyDeleted, isFalse);
    });

    test('returns false when deletedItems is false', () {
      expect(_svc({'deletedItems': false}).supportsRecentlyDeleted, isFalse);
    });
  });

  group('ClientService.supportsDeletedItemsRestore', () {
    test('returns true when deletedItemsRestore set', () {
      expect(
        _svc({'deletedItemsRestore': true}).supportsDeletedItemsRestore,
        isTrue,
      );
    });

    test('falls back to supportsRecentlyDeleted', () {
      expect(_svc({'deletedItems': true}).supportsDeletedItemsRestore, isTrue);
    });
  });

  group('ClientService.supportsDeletedItemsPermanentDelete', () {
    test('returns true when deletedItemsPermanentDelete set', () {
      expect(
        _svc({
          'deletedItemsPermanentDelete': true,
        }).supportsDeletedItemsPermanentDelete,
        isTrue,
      );
    });

    test('falls back to supportsRecentlyDeleted', () {
      expect(
        _svc({'deletedItems': true}).supportsDeletedItemsPermanentDelete,
        isTrue,
      );
    });
  });

  group('ClientService.supportsMeals', () {
    test('returns true when meals capability is true', () {
      expect(_svc({'meals': true}).supportsMeals, isTrue);
    });

    test('returns false when meals capability is absent', () {
      expect(_svc({}).supportsMeals, isFalse);
    });

    test('returns false when meals capability is false', () {
      expect(_svc({'meals': false}).supportsMeals, isFalse);
    });
  });
}

void _bootstrapMealsCapabilityTests() {
  group('ClientBootstrap.supportsMeals', () {
    test('returns true when meals capability is true', () {
      expect(_bootstrap({'meals': true}).supportsMeals, isTrue);
    });

    test('returns false when meals capability is false', () {
      expect(_bootstrap({'meals': false}).supportsMeals, isFalse);
    });

    test('returns false when meals capability is absent', () {
      expect(_bootstrap({}).supportsMeals, isFalse);
    });
  });

  group('ClientBootstrap.supportsMealTemplates', () {
    test('returns true when mealTemplates capability is true', () {
      expect(_bootstrap({'mealTemplates': true}).supportsMealTemplates, isTrue);
    });

    test('returns true when only meals is true (fallback)', () {
      expect(_bootstrap({'meals': true}).supportsMealTemplates, isTrue);
    });

    test('returns false when neither capability is set', () {
      expect(_bootstrap({}).supportsMealTemplates, isFalse);
    });
  });
}

void _deletedItemsModelTests() {
  group('DeletedItemsResponse.fromJson', () {
    test('parses nextCursor', () {
      final r = DeletedItemsResponse.fromJson({
        'items': <dynamic>[],
        'unsupportedServices': <dynamic>[],
        'nextCursor': 'page2',
      });
      expect(r.nextCursor, 'page2');
    });

    test('falls back to legacy cursor key', () {
      final r = DeletedItemsResponse.fromJson({
        'items': <dynamic>[],
        'unsupportedServices': <dynamic>[],
        'cursor': 'legacy',
      });
      expect(r.nextCursor, 'legacy');
    });

    test('nextCursor null when absent', () {
      final r = DeletedItemsResponse.fromJson({
        'items': <dynamic>[],
        'unsupportedServices': <dynamic>[],
      });
      expect(r.nextCursor, isNull);
    });
  });

  group('UnsupportedDeletedItemsService.fromJson', () {
    test('parses all fields', () {
      final s = UnsupportedDeletedItemsService.fromJson({
        'serviceId': 's1',
        'displayName': 'My Server',
        'provider': 'dav',
        'supportsDeletedItems': false,
        'message': 'Coming soon.',
      });
      expect(s.serviceId, 's1');
      expect(s.displayName, 'My Server');
      expect(s.provider, 'dav');
      expect(s.supportsDeletedItems, false);
      expect(s.message, 'Coming soon.');
    });

    test('displayName falls back to serviceId', () {
      final s = UnsupportedDeletedItemsService.fromJson({
        'serviceId': 'fallback-id',
      });
      expect(s.displayName, 'fallback-id');
    });

    test('displayName falls back to Connected service', () {
      final s = UnsupportedDeletedItemsService.fromJson({});
      expect(s.displayName, 'Connected service');
    });
  });
}

void _clientCalDavAccountTests() {
  group('ClientCalDavAccount.fromJson', () {
    test('maps backend password to appPassword', () {
      final account = ClientCalDavAccount.fromJson({
        'serviceId': 'svc1',
        'serviceName': 'Nextcloud',
        'server': 'https://nextcloud.example.com',
        'username': 'family-calendar',
        'password': 'nextcloud-app-password',
        'description': 'Use these credentials in an external calendar app.',
      });

      expect(account.serviceId, 'svc1');
      expect(account.serviceName, 'Nextcloud');
      expect(account.server, 'https://nextcloud.example.com');
      expect(account.username, 'family-calendar');
      expect(account.appPassword, 'nextcloud-app-password');
      expect(
        account.description,
        'Use these credentials in an external calendar app.',
      );
    });

    test('does not expose a generic password field in the model source', () {
      final source = File(
        'lib/data/models/client_caldav_account.dart',
      ).readAsStringSync();

      expect(source, contains('final String appPassword;'));
      expect(source, isNot(contains('final String password;')));
      expect(source, isNot(contains('required this.password')));
      expect(source, isNot(contains('password:')));
    });
  });
}

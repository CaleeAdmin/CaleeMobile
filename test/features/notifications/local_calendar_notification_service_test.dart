// Tests for LocalCalendarNotificationService.rescheduleUpcomingEvents.
//
// Uses forTest() subclassing to control permission results and track calls
// without hitting flutter_local_notifications platform channels.

import 'package:calee_mobile/data/models/client_calendar.dart';
import 'package:calee_mobile/features/notifications/local_calendar_notification_service.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

// ── Test subclass ─────────────────────────────────────────────────────────────

class _ControlledService extends LocalCalendarNotificationService {
  _ControlledService({required this.permissionGranted}) : super.forTest();

  final bool permissionGranted;
  int cancelCount = 0;

  @override
  Future<bool> requestPermissionIfNeeded() async => permissionGranted;

  @override
  Future<void> cancelAllCalendarEventNotifications() async {
    cancelCount++;
  }
}

// ── Helpers ───────────────────────────────────────────────────────────────────

ClientEvent _event(String id, {String startsAt = '2026-07-05T09:00:00'}) =>
    ClientEvent(
      id: id,
      calendarId: 'cal1',
      serviceId: 'svc',
      serviceName: 'Test',
      title: 'Event $id',
      startsAt: startsAt,
      endsAt: '2026-07-05T10:00:00',
      allDay: false,
      recurring: false,
      source: 'test',
    );

// ── Tests ─────────────────────────────────────────────────────────────────────

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({
      'calee_pref_migrated_to_shared_prefs': true,
      'calee_pref_calendar_reminders_enabled': true,
    });

    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.it_nomads.com/flutter_secure_storage'),
          (call) async => <String, String>{},
        );
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.it_nomads.com/flutter_secure_storage'),
          null,
        );
  });

  group('rescheduleUpcomingEvents — permission denied', () {
    test('does not cancel or schedule when permission is denied', () async {
      final service = _ControlledService(permissionGranted: false);

      await service.rescheduleUpcomingEvents([_event('e1')]);

      expect(service.cancelCount, 0);
    });

    test(
      'returns without scheduling even when there are eligible events',
      () async {
        final events = List.generate(5, (i) => _event('e$i'));
        final service = _ControlledService(permissionGranted: false);

        await service.rescheduleUpcomingEvents(events);

        // cancelAllCalendarEventNotifications is not reached when denied.
        expect(service.cancelCount, 0);
      },
    );
  });

  group('rescheduleUpcomingEvents — permission granted', () {
    test('cancels existing notifications before scheduling', () async {
      final service = _ControlledService(permissionGranted: true);

      await service.rescheduleUpcomingEvents([_event('e1')]);

      expect(service.cancelCount, 1);
    });
  });

  group('rescheduleUpcomingEvents — reminders disabled', () {
    test(
      'cancels existing notifications and returns early when disabled',
      () async {
        SharedPreferences.setMockInitialValues({
          'calee_pref_migrated_to_shared_prefs': true,
          'calee_pref_calendar_reminders_enabled': false,
        });

        final service = _ControlledService(permissionGranted: true);

        await service.rescheduleUpcomingEvents([_event('e1')]);

        // Cancels old notifications but does not request permission.
        expect(service.cancelCount, 1);
      },
    );
  });
}

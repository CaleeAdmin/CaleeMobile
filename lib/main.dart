import 'package:flutter/material.dart';
import 'package:flutter_timezone/flutter_timezone.dart';
import 'package:timezone/data/latest.dart' as tz;
import 'package:timezone/timezone.dart' as tz_local;

import 'app/calee_app.dart';
import 'config/calee_environment.dart';
import 'features/notifications/local_calendar_notification_service.dart';

Future<void> _configureLocalTimezone() async {
  tz.initializeTimeZones();
  try {
    final timeZoneName = await FlutterTimezone.getLocalTimezone();
    tz_local.setLocalLocation(tz_local.getLocation(timeZoneName));
  } catch (_) {
    tz_local.setLocalLocation(tz_local.UTC);
  }
}

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // In debug/regression builds this prints the resolved backend on a single
  // stable line the regression framework reads back; a no-op in a production
  // release. See CaleeEnvironment.
  CaleeEnvironment.logDiagnostics();
  await _configureLocalTimezone();
  // Best-effort: a notification-plugin init failure must not crash startup.
  // The service stays uninitialized and retries on the next reconcile.
  try {
    await LocalCalendarNotificationService.instance.initialize();
  } catch (_) {}
  runApp(const CaleeApp());
}

import 'package:flutter/material.dart';
import 'package:flutter_timezone/flutter_timezone.dart';
import 'package:timezone/data/latest.dart' as tz;
import 'package:timezone/timezone.dart' as tz_local;

import 'app/calee_app.dart';
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
  await _configureLocalTimezone();
  await LocalCalendarNotificationService.instance.initialize();
  runApp(const CaleeApp());
}

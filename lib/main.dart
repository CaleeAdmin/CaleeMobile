import 'package:flutter/material.dart';
import 'package:timezone/data/latest.dart' as tz;

import 'app/calee_app.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  tz.initializeTimeZones();
  runApp(const CaleeApp());
}

import 'dart:ui';

import 'package:flutter/foundation.dart';
import 'package:flutter_timezone/flutter_timezone.dart';

import '../models/device_profile_defaults.dart';

class DeviceProfileDefaultsProvider {
  Future<DeviceProfileDefaults> load() async {
    String? timeZone;
    String? locale;
    String? countryCode;

    try {
      final tz = await FlutterTimezone.getLocalTimezone();
      if (tz.isNotEmpty) timeZone = tz;
    } catch (e) {
      debugPrint('[DeviceProfileDefaultsProvider] timezone lookup failed: $e');
    }

    try {
      final locales = PlatformDispatcher.instance.locales;
      if (locales.isNotEmpty) {
        final primary = locales.first;
        final cc = primary.countryCode;
        locale = cc != null && cc.isNotEmpty
            ? '${primary.languageCode}-$cc'
            : primary.languageCode;
        if (cc != null && cc.isNotEmpty) countryCode = cc;
      }
    } catch (e) {
      debugPrint('[DeviceProfileDefaultsProvider] locale lookup failed: $e');
    }

    return DeviceProfileDefaults(
      timeZone: timeZone,
      locale: locale,
      countryCode: countryCode,
    );
  }
}

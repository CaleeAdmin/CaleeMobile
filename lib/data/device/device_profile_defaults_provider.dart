import 'dart:ui';

import 'package:flutter/foundation.dart';
import 'package:flutter_timezone/flutter_timezone.dart';

import '../models/device_profile_defaults.dart';

const _kAustralianPostcodes = {
  'Australia/Perth': '6000',
  'Australia/Sydney': '2000',
  'Australia/Melbourne': '3000',
  'Australia/Brisbane': '4000',
  'Australia/Adelaide': '5000',
  'Australia/Darwin': '0800',
  'Australia/Hobart': '7000',
};

class DeviceProfileDefaultsProvider {
  Future<DeviceProfileDefaults> load() async {
    String? timeZone;
    String? locale;
    String? countryCode;

    try {
      final tz = await FlutterTimezone.getLocalTimezone();
      if (tz.isNotEmpty) timeZone = tz;
    } catch (e) {
      if (kDebugMode) {
        debugPrint(
          '[DeviceProfileDefaultsProvider] timezone lookup failed: $e',
        );
      }
    }

    try {
      final locales = PlatformDispatcher.instance.locales;
      if (locales.isNotEmpty) {
        final primary = locales.first;
        final cc = primary.countryCode;
        locale = cc != null && cc.isNotEmpty
            ? '${primary.languageCode}-${cc.toUpperCase()}'
            : primary.languageCode;
        if (cc != null && cc.isNotEmpty) countryCode = cc.toUpperCase();
      }
    } catch (e) {
      if (kDebugMode) {
        debugPrint('[DeviceProfileDefaultsProvider] locale lookup failed: $e');
      }
    }

    String? postalCode;
    if (countryCode == 'AU') {
      postalCode = _kAustralianPostcodes[timeZone];
    }

    return DeviceProfileDefaults(
      timeZone: timeZone,
      locale: locale,
      countryCode: countryCode,
      postalCode: postalCode,
    );
  }

  @visibleForTesting
  static DeviceProfileDefaults buildFromLocales(
    List<Locale> locales, {
    String? timeZone,
  }) {
    String? locale;
    String? countryCode;
    if (locales.isNotEmpty) {
      final primary = locales.first;
      final cc = primary.countryCode;
      locale = cc != null && cc.isNotEmpty
          ? '${primary.languageCode}-${cc.toUpperCase()}'
          : primary.languageCode;
      if (cc != null && cc.isNotEmpty) countryCode = cc.toUpperCase();
    }

    String? postalCode;
    if (countryCode == 'AU') {
      postalCode = _kAustralianPostcodes[timeZone];
    }

    return DeviceProfileDefaults(
      timeZone: timeZone,
      locale: locale,
      countryCode: countryCode,
      postalCode: postalCode,
    );
  }
}

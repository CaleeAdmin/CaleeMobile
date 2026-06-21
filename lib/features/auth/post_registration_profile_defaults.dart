import 'package:flutter/foundation.dart';

import '../../data/api/calee_hub_client.dart';
import '../../data/device/device_profile_defaults_provider.dart';

Future<void> applyPostRegistrationProfileDefaults({
  required CaleeHubClient hubClient,
  required String accessToken,
  required DeviceProfileDefaultsProvider provider,
}) async {
  try {
    final defaults = await provider.load();
    if (!defaults.hasAnyValue) return;
    await hubClient.updateProfile(
      accessToken: accessToken,
      timeZone: defaults.timeZone,
      locale: defaults.locale,
      countryCode: defaults.countryCode,
    );
  } catch (e) {
    if (kDebugMode) {
      debugPrint(
        '[applyPostRegistrationProfileDefaults] failed (non-fatal): $e',
      );
    }
  }
}

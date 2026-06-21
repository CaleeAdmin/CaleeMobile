import '../../data/api/calee_hub_client.dart';
import '../../data/models/client_profile.dart';

class ProfileRepository {
  const ProfileRepository({
    required this.hubClient,
    required this.accessToken,
  });

  final CaleeHubClient hubClient;
  final String accessToken;

  Future<ClientProfile> loadProfile() {
    return hubClient.profile(accessToken: accessToken);
  }

  Future<ClientProfile> saveProfile({
    required String firstName,
    required String lastName,
    String? displayName,
    String? timeZone,
    String? postalCode,
    String? countryCode,
    String? locale,
  }) {
    return hubClient.updateProfile(
      accessToken: accessToken,
      firstName: firstName,
      lastName: lastName,
      displayName: displayName,
      timeZone: timeZone,
      postalCode: postalCode,
      countryCode: countryCode,
      locale: locale,
    );
  }

  Future<ClientProfile> saveProfileDefaults({
    String? timeZone,
    String? countryCode,
    String? locale,
  }) {
    return hubClient.updateProfile(
      accessToken: accessToken,
      timeZone: timeZone,
      countryCode: countryCode,
      locale: locale,
    );
  }
}

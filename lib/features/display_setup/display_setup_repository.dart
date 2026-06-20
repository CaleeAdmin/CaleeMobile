import '../../data/api/calee_hub_client.dart';

class DisplaySetupRepository {
  const DisplaySetupRepository({required this.hubClient});

  final CaleeHubClient hubClient;

  Future<void> approveDisplayLogin({
    required String accessToken,
    required String token,
  }) => hubClient.approveDisplayLogin(accessToken: accessToken, token: token);
}

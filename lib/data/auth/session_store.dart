import 'package:flutter_secure_storage/flutter_secure_storage.dart';

class SessionStore {
  SessionStore();

  static const _accessTokenKey = 'calee_hub_access_token';

  final FlutterSecureStorage _secureStorage = const FlutterSecureStorage();

  Future<String?> loadAccessToken() {
    return _secureStorage.read(key: _accessTokenKey);
  }

  Future<void> saveAccessToken(String accessToken) {
    return _secureStorage.write(
      key: _accessTokenKey,
      value: accessToken,
    );
  }

  Future<void> clear() {
    return _secureStorage.delete(key: _accessTokenKey);
  }
}

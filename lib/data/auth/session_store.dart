import 'package:flutter_secure_storage/flutter_secure_storage.dart';

class SessionStore {
  SessionStore();

  static const _accessTokenKey = 'calee_hub_access_token';
  static const _refreshTokenKey = 'calee_hub_refresh_token';

  final FlutterSecureStorage _secureStorage = const FlutterSecureStorage();

  Future<StoredSession?> loadSession() async {
    final accessToken = await _secureStorage.read(key: _accessTokenKey);
    final refreshToken = await _secureStorage.read(key: _refreshTokenKey);

    if (accessToken == null ||
        accessToken.trim().isEmpty ||
        refreshToken == null ||
        refreshToken.trim().isEmpty) {
      return null;
    }

    return StoredSession(accessToken: accessToken, refreshToken: refreshToken);
  }

  Future<void> saveSession({
    required String accessToken,
    required String refreshToken,
  }) async {
    await _secureStorage.write(key: _accessTokenKey, value: accessToken);
    await _secureStorage.write(key: _refreshTokenKey, value: refreshToken);
  }

  Future<void> saveAccessToken(String accessToken) {
    return _secureStorage.write(key: _accessTokenKey, value: accessToken);
  }

  Future<void> clear() async {
    await _secureStorage.delete(key: _accessTokenKey);
    await _secureStorage.delete(key: _refreshTokenKey);
  }
}

class StoredSession {
  const StoredSession({required this.accessToken, required this.refreshToken});

  final String accessToken;
  final String refreshToken;
}

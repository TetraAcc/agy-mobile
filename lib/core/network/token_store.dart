import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

abstract class TokenStore {
  String? get accessToken;
  Future<String?> readRefreshToken();
  Future<void> saveTokens({required String accessToken, required String refreshToken});
  Future<void> clear();
}

class PlatformTokenStore implements TokenStore {
  static const String _refreshKey = 'agy_v2_refresh_token';

  final FlutterSecureStorage _secureStorage;
  String? _accessToken;

  PlatformTokenStore({FlutterSecureStorage? secureStorage})
      : _secureStorage = secureStorage ?? const FlutterSecureStorage();

  @override
  String? get accessToken => kIsWeb ? null : _accessToken;

  @override
  Future<String?> readRefreshToken() async {
    if (kIsWeb) return null;
    try {
      return await _secureStorage.read(key: _refreshKey);
    } catch (_) {
      return null;
    }
  }

  @override
  Future<void> saveTokens({required String accessToken, required String refreshToken}) async {
    if (kIsWeb) {
      // Web relies solely on HttpOnly cookies managed by the Gateway.
      _accessToken = null;
      return;
    }
    _accessToken = accessToken;
    if (refreshToken.isNotEmpty) {
      try {
        await _secureStorage.write(key: _refreshKey, value: refreshToken);
      } catch (_) {}
    }
  }

  @override
  Future<void> clear() async {
    _accessToken = null;
    if (kIsWeb) return;
    try {
      await _secureStorage.delete(key: _refreshKey);
    } catch (_) {}
  }
}

class MemoryTokenStore implements TokenStore {
  String? _access;
  String? _refresh;

  MemoryTokenStore({String? initialAccess, String? initialRefresh})
      : _access = initialAccess,
        _refresh = initialRefresh;

  @override
  String? get accessToken => _access;

  @override
  Future<String?> readRefreshToken() async => _refresh;

  @override
  Future<void> saveTokens({required String accessToken, required String refreshToken}) async {
    _access = accessToken;
    if (refreshToken.isNotEmpty) {
      _refresh = refreshToken;
    }
  }

  @override
  Future<void> clear() async {
    _access = null;
    _refresh = null;
  }
}

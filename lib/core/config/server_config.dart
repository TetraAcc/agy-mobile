import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

class ServerConfig {
  static const String _prefKey = 'v2_server_base_url';
  static const String defaultNativeUrl = 'http://127.0.0.1:8768';

  final String baseUrl;

  const ServerConfig(this.baseUrl);

  String get wsBaseUrl {
    if (baseUrl.startsWith('https://')) {
      return 'wss://${baseUrl.substring(8)}';
    }
    if (baseUrl.startsWith('http://')) {
      return 'ws://${baseUrl.substring(7)}';
    }
    return 'ws://$baseUrl';
  }

  static String defaultBaseUrl() {
    if (kIsWeb) {
      final origin = Uri.base.origin;
      if (origin.startsWith('http://') || origin.startsWith('https://')) {
        return normalizeBaseUrl(origin);
      }
    }
    return defaultNativeUrl;
  }

  static String normalizeBaseUrl(String raw) {
    var cleaned = raw.trim();
    if (cleaned.isEmpty) {
      return defaultBaseUrl();
    }
    while (cleaned.endsWith('/')) {
      cleaned = cleaned.substring(0, cleaned.length - 1);
    }
    if (!cleaned.startsWith('http://') && !cleaned.startsWith('https://')) {
      final isLocalOrIp = cleaned.startsWith('localhost') ||
          cleaned.startsWith('127.') ||
          cleaned.startsWith('192.168.') ||
          cleaned.startsWith('10.') ||
          cleaned.startsWith('100.') ||
          cleaned.contains(':8768') ||
          cleaned.contains(':8765');
      cleaned = '${isLocalOrIp ? 'http' : 'https'}://$cleaned';
    }
    return cleaned;
  }

  static Future<ServerConfig> load() async {
    final prefs = await SharedPreferences.getInstance();
    final saved = prefs.getString(_prefKey);
    if (saved != null && saved.trim().isNotEmpty) {
      return ServerConfig(normalizeBaseUrl(saved));
    }
    return ServerConfig(defaultBaseUrl());
  }

  static Future<ServerConfig> save(String rawUrl) async {
    final normalized = normalizeBaseUrl(rawUrl);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_prefKey, normalized);
    return ServerConfig(normalized);
  }
}

import 'package:dio/dio.dart';
import 'package:flutter/services.dart';

import 'app_fonts.dart';

class FontLoaderService {
  static final Set<String> _loadedFamilies = <String>{};
  static final Map<String, Future<bool>> _inFlight = <String, Future<bool>>{};

  static bool isLoaded(AppFontOption option) {
    final fam = option.fontFamily;
    if (fam == null || option.remoteFile == null) return true;
    return _loadedFamilies.contains(fam);
  }

  static Future<bool> ensureLoaded(
    AppFontOption option, {
    required String baseUrl,
    Dio? dio,
  }) async {
    final fam = option.fontFamily;
    final file = option.remoteFile;
    if (fam == null || file == null) return true;
    if (_loadedFamilies.contains(fam)) return true;

    final existing = _inFlight[fam];
    if (existing != null) return existing;

    final future = _downloadAndRegister(fam, file, baseUrl: baseUrl, dio: dio);
    _inFlight[fam] = future;
    try {
      return await future;
    } finally {
      _inFlight.remove(fam);
    }
  }

  static Future<bool> _downloadAndRegister(
    String family,
    String filename, {
    required String baseUrl,
    Dio? dio,
  }) async {
    final cleanBase = baseUrl.trim().replaceAll(RegExp(r'/+$'), '');
    if (cleanBase.isEmpty) return false;

    final client = dio ??
        Dio(
          BaseOptions(
            connectTimeout: const Duration(seconds: 15),
            receiveTimeout: const Duration(seconds: 60),
          ),
        );
    try {
      final resp = await client.get<List<int>>(
        '$cleanBase/static-fonts/$filename',
        options: Options(responseType: ResponseType.bytes),
      );
      final raw = resp.data;
      if (resp.statusCode != 200 || raw == null || raw.length < 1024) {
        return false;
      }
      // Reject accidental HTML error responses
      if (raw[0] == 0x3C) {
        return false;
      }
      final bytes = raw is Uint8List ? raw : Uint8List.fromList(raw);
      final loader = FontLoader(family);
      loader.addFont(Future.value(ByteData.sublistView(bytes)));
      await loader.load();
      _loadedFamilies.add(family);
      return true;
    } catch (_) {
      return false;
    }
  }
}

import 'package:shared_preferences/shared_preferences.dart';

import '../platform/android_native_bridge.dart';
import '../platform/platform_bridge.dart';

const String kFallbackAppVersion = '2.3.2';
const String kAppVersionDefine = String.fromEnvironment('APP_VERSION', defaultValue: '');

class AppReleaseInfo {
  final String latestVersion;
  final String tagName;
  final String releaseName;
  final String releaseNotes;
  final String apkUrl;
  final String apkName;
  final int apkSize;
  final String htmlUrl;
  final String publishedAt;
  final String source;
  final String error;

  const AppReleaseInfo({
    this.latestVersion = '',
    this.tagName = '',
    this.releaseName = '',
    this.releaseNotes = '',
    this.apkUrl = '',
    this.apkName = '',
    this.apkSize = 0,
    this.htmlUrl = '',
    this.publishedAt = '',
    this.source = 'github',
    this.error = '',
  });

  factory AppReleaseInfo.fromJson(Map<String, dynamic> json) {
    return AppReleaseInfo(
      latestVersion: json['latest_version']?.toString() ?? '',
      tagName: json['tag_name']?.toString() ?? '',
      releaseName: json['release_name']?.toString() ?? '',
      releaseNotes: json['release_notes']?.toString() ?? '',
      apkUrl: json['apk_url']?.toString() ?? '',
      apkName: json['apk_name']?.toString() ?? '',
      apkSize: (json['apk_size'] as num?)?.toInt() ?? 0,
      htmlUrl: json['html_url']?.toString() ?? '',
      publishedAt: json['published_at']?.toString() ?? '',
      source: json['source']?.toString() ?? 'github',
      error: json['error']?.toString() ?? '',
    );
  }
}

String normalizeSemver(String raw) {
  var cleaned = raw.trim();
  if (cleaned.startsWith('v') || cleaned.startsWith('V')) {
    cleaned = cleaned.substring(1).trim();
  }
  final plusIdx = cleaned.indexOf('+');
  if (plusIdx >= 0) {
    cleaned = cleaned.substring(0, plusIdx);
  }
  final dashIdx = cleaned.indexOf('-');
  if (dashIdx >= 0) {
    cleaned = cleaned.substring(0, dashIdx);
  }
  return cleaned.trim();
}

int compareSemver(String a, String b) {
  final partsA = normalizeSemver(a).split('.');
  final partsB = normalizeSemver(b).split('.');
  final maxLen = partsA.length > partsB.length ? partsA.length : partsB.length;
  for (var i = 0; i < maxLen; i++) {
    final segA = i < partsA.length ? (int.tryParse(partsA[i]) ?? 0) : 0;
    final segB = i < partsB.length ? (int.tryParse(partsB[i]) ?? 0) : 0;
    if (segA != segB) {
      return segA.compareTo(segB);
    }
  }
  return 0;
}

bool isAppUpdateAvailable(String currentVersion, String latestVersion) {
  final normLatest = normalizeSemver(latestVersion);
  if (normLatest.isEmpty) return false;
  return compareSemver(normLatest, currentVersion) > 0;
}

class AppUpdateService {
  static const String _ignoredVersionKey = 'agy_ignored_app_update_version';

  static Future<String> resolveCurrentVersion() async {
    if (AndroidNativeBridge.isAndroidNative) {
      final info = await AndroidNativeBridge.getAppVersion();
      final v = normalizeSemver(info?.versionName ?? '');
      if (v.isNotEmpty) return v;
    }
    final defined = normalizeSemver(kAppVersionDefine);
    if (defined.isNotEmpty) return defined;
    return kFallbackAppVersion;
  }

  static Future<String> getIgnoredVersion() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      return normalizeSemver(prefs.getString(_ignoredVersionKey) ?? '');
    } catch (_) {
      return '';
    }
  }

  static Future<void> setIgnoredVersion(String version) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final norm = normalizeSemver(version);
      if (norm.isEmpty) {
        await prefs.remove(_ignoredVersionKey);
      } else {
        await prefs.setString(_ignoredVersionKey, norm);
      }
    } catch (_) {}
  }

  static Future<void> clearIgnoredVersion() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(_ignoredVersionKey);
    } catch (_) {}
  }

  static Future<({String? path, String? error, bool cancelled})> downloadApkToCache({
    required String apkUrl,
    required String filename,
    void Function(int received, int total)? onProgress,
    Object? cancelToken,
  }) async {
    if (!AndroidNativeBridge.isAndroidNative) {
      return (path: null, error: '仅支持 Android 原生客户端内下载更新', cancelled: false);
    }
    if (apkUrl.trim().isEmpty) {
      return (path: null, error: '未提供有效 APK 下载链接', cancelled: false);
    }
    final dir = await AndroidNativeBridge.getDownloadsDir();
    if (dir == null || dir.isEmpty) {
      return (path: null, error: '无法访问应用下载缓存目录', cancelled: false);
    }
    final rawName = filename.trim().isEmpty ? 'agy-remote-update.apk' : filename.trim();
    final safeName = rawName.replaceAll(RegExp(r'[/\\:*?"<>|]+'), '_');
    final sep = dir.endsWith('/') ? '' : '/';
    final savePath = '$dir$sep$safeName';
    final dl = await PlatformBridge.downloadUrlToLocalFile(
      url: apkUrl,
      savePath: savePath,
      onProgress: onProgress,
      cancelToken: cancelToken,
    );
    if (dl.cancelled) {
      return (path: null, error: null, cancelled: true);
    }
    if (!dl.ok) {
      return (path: null, error: dl.error ?? '下载安装包失败', cancelled: false);
    }
    return (path: savePath, error: null, cancelled: false);
  }
}

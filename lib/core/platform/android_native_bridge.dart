import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

class SharedIncomingFile {
  final String path;
  final String name;
  final String mimeType;

  const SharedIncomingFile({
    required this.path,
    required this.name,
    required this.mimeType,
  });

  bool get isImage {
    final m = mimeType.toLowerCase();
    if (m.startsWith('image/')) return true;
    final lower = name.toLowerCase();
    return lower.endsWith('.png') ||
        lower.endsWith('.jpg') ||
        lower.endsWith('.jpeg') ||
        lower.endsWith('.webp') ||
        lower.endsWith('.gif') ||
        lower.endsWith('.bmp');
  }
}

class SharedIncomingPayload {
  final String? text;
  final List<SharedIncomingFile> files;

  const SharedIncomingPayload({
    this.text,
    this.files = const [],
  });

  bool get isEmpty => (text == null || text!.trim().isEmpty) && files.isEmpty;

  factory SharedIncomingPayload.fromMap(Map<dynamic, dynamic> raw) {
    final text = raw['text']?.toString();
    final rawFiles = raw['files'] as List<dynamic>? ?? const [];
    final files = <SharedIncomingFile>[];
    for (final item in rawFiles) {
      if (item is Map) {
        final path = item['path']?.toString() ?? '';
        final name = item['name']?.toString() ?? '';
        final mime = item['mimeType']?.toString() ?? '*/*';
        if (path.isNotEmpty) {
          files.add(SharedIncomingFile(
            path: path,
            name: name.isNotEmpty ? name : path.split('/').last,
            mimeType: mime,
          ));
        }
      }
    }
    return SharedIncomingPayload(text: text, files: files);
  }
}

class CapturedPhotoResult {
  final String path;
  final String name;

  const CapturedPhotoResult({
    required this.path,
    required this.name,
  });
}

class DownloadedLocalFile {
  final String path;
  final String filename;
  final int sizeBytes;
  final String mimeType;

  const DownloadedLocalFile({
    required this.path,
    required this.filename,
    required this.sizeBytes,
    required this.mimeType,
  });
}

class AndroidNativeBridge {
  static const MethodChannel _channel = MethodChannel('com.tetra.agyremote/android_native');
  static final StreamController<SharedIncomingPayload> _shareController =
      StreamController<SharedIncomingPayload>.broadcast();
  static bool _initialized = false;

  static bool get isAndroidNative =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

  static Stream<SharedIncomingPayload> get incomingShares => _shareController.stream;

  static void ensureInitialized() {
    if (!isAndroidNative || _initialized) return;
    _initialized = true;
    _channel.setMethodCallHandler((call) async {
      if (call.method == 'onShareReceived' && call.arguments is Map) {
        final payload = SharedIncomingPayload.fromMap(call.arguments as Map);
        if (!payload.isEmpty && !_shareController.isClosed) {
          _shareController.add(payload);
        }
      }
    });
  }

  static Future<List<SharedIncomingPayload>> consumePendingShares() async {
    if (!isAndroidNative) return const [];
    ensureInitialized();
    try {
      final raw = await _channel.invokeMethod<List<dynamic>>('getPendingShares');
      if (raw == null) return const [];
      final out = <SharedIncomingPayload>[];
      for (final item in raw) {
        if (item is Map) {
          final parsed = SharedIncomingPayload.fromMap(item);
          if (!parsed.isEmpty) out.add(parsed);
        }
      }
      return out;
    } catch (_) {
      return const [];
    }
  }

  static Future<CapturedPhotoResult?> capturePhoto() async {
    if (!isAndroidNative) return null;
    try {
      final raw = await _channel.invokeMethod<Map<dynamic, dynamic>>('capturePhoto');
      if (raw == null) return null;
      final path = raw['path']?.toString() ?? '';
      final name = raw['name']?.toString() ?? 'photo.jpg';
      if (path.isEmpty) return null;
      return CapturedPhotoResult(path: path, name: name);
    } catch (_) {
      return null;
    }
  }

  static Future<String?> getDownloadsDir() async {
    if (!isAndroidNative) return null;
    try {
      return await _channel.invokeMethod<String>('getDownloadsDir');
    } catch (_) {
      return null;
    }
  }

  static Future<bool> openLocalFile(String path, {String mimeType = '*/*'}) async {
    if (!isAndroidNative || path.isEmpty) return false;
    try {
      final ok = await _channel.invokeMethod<bool>('openLocalFile', {
        'path': path,
        'mimeType': mimeType,
      });
      return ok == true;
    } catch (_) {
      return false;
    }
  }

  static Future<bool> shareLocalFile(
    String path, {
    String mimeType = '*/*',
    String? title,
  }) async {
    if (!isAndroidNative || path.isEmpty) return false;
    try {
      final ok = await _channel.invokeMethod<bool>('shareLocalFile', {
        'path': path,
        'mimeType': mimeType,
        'title': title ?? '分享文件',
      });
      return ok == true;
    } catch (_) {
      return false;
    }
  }

  static Future<bool> requestNotificationPermission() async {
    if (!isAndroidNative) return false;
    try {
      final ok = await _channel.invokeMethod<bool>('requestNotificationPermission');
      return ok == true;
    } catch (_) {
      return false;
    }
  }

  static Future<void> updateRunningNotification({
    required String title,
    required String body,
  }) async {
    if (!isAndroidNative) return;
    try {
      await _channel.invokeMethod<void>('updateRunningNotification', {
        'title': title,
        'body': body,
      });
    } catch (_) {}
  }

  static Future<void> stopRunningNotification() async {
    if (!isAndroidNative) return;
    try {
      await _channel.invokeMethod<void>('stopRunningNotification');
    } catch (_) {}
  }

  static Future<void> showAlertNotification({
    required String title,
    required String body,
    int id = 2001,
  }) async {
    if (!isAndroidNative) return;
    try {
      await _channel.invokeMethod<void>('showAlertNotification', {
        'title': title,
        'body': body,
        'id': id,
      });
    } catch (_) {}
  }

  static String inferMimeType(String filename) {
    final dot = filename.lastIndexOf('.');
    if (dot < 0 || dot == filename.length - 1) return '*/*';
    final ext = filename.substring(dot + 1).toLowerCase();
    return switch (ext) {
      'pdf' => 'application/pdf',
      'png' => 'image/png',
      'jpg' || 'jpeg' => 'image/jpeg',
      'webp' => 'image/webp',
      'gif' => 'image/gif',
      'bmp' => 'image/bmp',
      'svg' => 'image/svg+xml',
      'md' || 'markdown' => 'text/markdown',
      'txt' || 'log' || 'yaml' || 'yml' || 'py' || 'dart' || 'ts' || 'js' => 'text/plain',
      'json' => 'application/json',
      'csv' => 'text/csv',
      'zip' => 'application/zip',
      _ => '*/*',
    };
  }
}

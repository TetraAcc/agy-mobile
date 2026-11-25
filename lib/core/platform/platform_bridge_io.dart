import 'dart:io';

import 'package:dio/dio.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:url_launcher/url_launcher.dart';

import 'platform_bridge.dart';

const _imageExts = {'png', 'jpg', 'jpeg', 'gif', 'webp', 'bmp'};

Future<PickedLocalFile?> implPickFile({required bool imagesOnly}) async {
  final file = await FilePicker.pickFile(
    type: imagesOnly ? FileType.image : FileType.any,
  );
  if (file == null) return null;
  final bytes = await file.readAsBytes();
  if (bytes.isEmpty) return null;
  final ext = file.extension?.toLowerCase() ?? '';
  final isImg = imagesOnly || _imageExts.contains(ext);
  return PickedLocalFile(filename: file.name, bytes: bytes, isImage: isImg);
}

Future<void> implOpenExternalUrl(String url) async {
  final uri = Uri.tryParse(url);
  if (uri == null) return;
  await launchUrl(uri, mode: LaunchMode.externalApplication);
}

Future<void> implTriggerDownload(String url, String filename) async {
  await implOpenExternalUrl(url);
}

VoidCallback implRegisterWebDropAndPaste(void Function(PickedLocalFile file) onFile) {
  return () {};
}

Future<Uint8List?> implReadLocalFileBytes(String path) async {
  if (path.trim().isEmpty) return null;
  try {
    final file = File(path);
    if (!await file.exists()) return null;
    return await file.readAsBytes();
  } catch (_) {
    return null;
  }
}

Future<void> implDeleteLocalFile(String path) async {
  if (path.trim().isEmpty) return;
  try {
    final file = File(path);
    if (await file.exists()) {
      await file.delete();
    }
  } catch (_) {}
}

Future<({bool ok, bool cancelled, String? error})> implDownloadUrlToLocalFile({
  required String url,
  required String savePath,
  void Function(int received, int total)? onProgress,
  Object? cancelToken,
}) async {
  if (url.trim().isEmpty || savePath.trim().isEmpty) {
    return (ok: false, cancelled: false, error: '下载地址或保存路径无效');
  }
  final tmpPath = '$savePath.part';
  try {
    final file = File(savePath);
    await file.parent.create(recursive: true);
    final tmpFile = File(tmpPath);
    if (await tmpFile.exists()) {
      await tmpFile.delete();
    }
    final dio = Dio(
      BaseOptions(
        connectTimeout: const Duration(seconds: 15),
        receiveTimeout: const Duration(seconds: 180),
        followRedirects: true,
        maxRedirects: 8,
        headers: const {'User-Agent': 'agy-remote-android-updater'},
      ),
    );
    await dio.download(
      url,
      tmpPath,
      cancelToken: cancelToken is CancelToken ? cancelToken : null,
      deleteOnError: true,
      onReceiveProgress: onProgress,
    );
    if (await file.exists()) {
      await file.delete();
    }
    await tmpFile.rename(savePath);
    return (ok: true, cancelled: false, error: null);
  } on DioException catch (e) {
    await implDeleteLocalFile(tmpPath);
    if (CancelToken.isCancel(e)) {
      return (ok: false, cancelled: true, error: null);
    }
    return (ok: false, cancelled: false, error: e.message ?? '安装包下载失败');
  } catch (e) {
    await implDeleteLocalFile(tmpPath);
    return (ok: false, cancelled: false, error: '安装包下载失败: $e');
  }
}

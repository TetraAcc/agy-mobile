import 'dart:io';

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

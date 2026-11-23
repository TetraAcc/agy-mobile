import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:url_launcher/url_launcher.dart';

import 'platform_bridge.dart';

const _imageExts = {'png', 'jpg', 'jpeg', 'gif', 'webp', 'bmp'};

Future<PickedLocalFile?> implPickFile({required bool imagesOnly}) async {
  final res = await FilePicker.platform.pickFiles(
    type: imagesOnly ? FileType.image : FileType.any,
    withData: true,
  );
  if (res == null || res.files.isEmpty) return null;
  final file = res.files.first;
  Uint8List? bytes = file.bytes;
  if (bytes == null && file.path != null) {
    bytes = await File(file.path!).readAsBytes();
  }
  if (bytes == null) return null;
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

import 'package:flutter/foundation.dart';

import 'platform_bridge_io.dart' if (dart.library.js_interop) 'platform_bridge_web.dart' as impl;

class PickedLocalFile {
  final String filename;
  final Uint8List bytes;
  final bool isImage;

  const PickedLocalFile({
    required this.filename,
    required this.bytes,
    required this.isImage,
  });
}

class PlatformBridge {
  static Future<PickedLocalFile?> pickFile({required bool imagesOnly}) =>
      impl.implPickFile(imagesOnly: imagesOnly);

  static Future<void> openExternalUrl(String url) => impl.implOpenExternalUrl(url);

  static Future<void> triggerDownload(String url, String filename) =>
      impl.implTriggerDownload(url, filename);

  static VoidCallback registerWebDropAndPaste(void Function(PickedLocalFile file) onFile) =>
      impl.implRegisterWebDropAndPaste(onFile);
}

import 'dart:js_interop';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:web/web.dart' as web;

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
  final anchor = web.document.createElement('a') as web.HTMLAnchorElement;
  anchor.href = url;
  anchor.target = '_blank';
  anchor.rel = 'noopener noreferrer';
  anchor.style.display = 'none';
  web.document.body?.append(anchor);
  anchor.click();
  anchor.remove();
}

Future<void> implTriggerDownload(String url, String filename) async {
  final anchor = web.document.createElement('a') as web.HTMLAnchorElement;
  anchor.href = url;
  if (filename.isNotEmpty) {
    anchor.download = filename;
  }
  anchor.style.display = 'none';
  web.document.body?.append(anchor);
  anchor.click();
  anchor.remove();
}

void _readWebFile(web.File file, bool isImage, void Function(PickedLocalFile file) onFile) {
  final reader = web.FileReader();
  reader.onload = ((web.Event _) {
    final result = reader.result;
    if (result != null && result.isA<JSArrayBuffer>()) {
      final buffer = (result as JSArrayBuffer).toDart;
      final bytes = Uint8List.view(buffer);
      final name = file.name.isNotEmpty ? file.name : (isImage ? 'clipboard_image.png' : 'upload.bin');
      onFile(PickedLocalFile(filename: name, bytes: bytes, isImage: isImage));
    }
  }).toJS;
  reader.readAsArrayBuffer(file);
}

VoidCallback implRegisterWebDropAndPaste(void Function(PickedLocalFile file) onFile) {
  final pasteHandler = ((web.Event evt) {
    final clipEvt = evt as web.ClipboardEvent;
    final items = clipEvt.clipboardData?.items;
    if (items == null) return;
    for (var i = 0; i < items.length; i++) {
      final item = items[i];
      if (item.type.contains('image')) {
        final file = item.getAsFile();
        if (file != null) {
          evt.preventDefault();
          _readWebFile(file, true, onFile);
          break;
        }
      }
    }
  }).toJS;

  final dragOverHandler = ((web.Event evt) {
    evt.preventDefault();
  }).toJS;

  final dropHandler = ((web.Event evt) {
    evt.preventDefault();
    final dragEvt = evt as web.DragEvent;
    final files = dragEvt.dataTransfer?.files;
    if (files != null && files.length > 0) {
      final file = files.item(0);
      if (file != null) {
        final isImg = file.type.contains('image');
        _readWebFile(file, isImg, onFile);
      }
    }
  }).toJS;

  web.window.addEventListener('paste', pasteHandler);
  web.window.addEventListener('dragover', dragOverHandler);
  web.window.addEventListener('drop', dropHandler);

  return () {
    web.window.removeEventListener('paste', pasteHandler);
    web.window.removeEventListener('dragover', dragOverHandler);
    web.window.removeEventListener('drop', dropHandler);
  };
}

Future<Uint8List?> implReadLocalFileBytes(String path) async => null;

Future<void> implDeleteLocalFile(String path) async {}

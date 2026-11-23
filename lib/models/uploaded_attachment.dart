import 'dart:typed_data';

class UploadedAttachment {
  final String filename;
  final bool isImage;
  String? serverPath;
  String? absPath;
  String? rootId;
  bool isUploading;
  bool hasError;
  int size;
  Uint8List? imageBytes;

  UploadedAttachment({
    required this.filename,
    required this.isImage,
    this.serverPath,
    this.absPath,
    this.rootId,
    this.isUploading = true,
    this.hasError = false,
    this.size = 0,
    this.imageBytes,
  });
}

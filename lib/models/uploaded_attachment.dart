import 'dart:typed_data';

class UploadedAttachment {
  final String filename;
  final String dataUrl;
  final bool isImage;
  String? serverPath;
  bool isUploading;
  int size;
  Uint8List? imageBytes;

  UploadedAttachment({
    required this.filename,
    required this.dataUrl,
    required this.isImage,
    this.serverPath,
    this.isUploading = true,
    this.size = 0,
    this.imageBytes,
  });
}

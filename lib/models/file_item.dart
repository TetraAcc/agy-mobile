class FileItem {
  final String name;
  final bool isDir;
  final String path;
  final int size;

  FileItem({
    required this.name,
    required this.isDir,
    required this.path,
    required this.size,
  });

  factory FileItem.fromJson(Map<String, dynamic> json) {
    return FileItem(
      name: json['name'] ?? '',
      isDir: json['is_dir'] ?? false,
      path: json['path'] ?? '',
      size: json['size'] ?? 0,
    );
  }
}

class FileRootItem {
  final String id;
  final String name;
  final String path;
  final bool readonly;

  const FileRootItem({
    required this.id,
    required this.name,
    required this.path,
    this.readonly = false,
  });

  factory FileRootItem.fromJson(Map<String, dynamic> json) {
    return FileRootItem(
      id: json['id']?.toString() ?? '',
      name: json['name']?.toString() ?? '',
      path: json['path']?.toString() ?? '',
      readonly: json['readonly'] == true,
    );
  }
}

class FileItem {
  final String name;
  final bool isDir;
  final String path;
  final int size;

  const FileItem({
    required this.name,
    required this.isDir,
    required this.path,
    required this.size,
  });

  factory FileItem.fromJson(Map<String, dynamic> json) {
    return FileItem(
      name: json['name']?.toString() ?? '',
      isDir: json['is_dir'] == true,
      path: json['path']?.toString() ?? '',
      size: (json['size'] as num?)?.toInt() ?? 0,
    );
  }
}

class FileTreeData {
  final String rootId;
  final String rootName;
  final String currentPath;
  final List<FileItem> items;

  const FileTreeData({
    required this.rootId,
    required this.rootName,
    required this.currentPath,
    required this.items,
  });

  factory FileTreeData.fromJson(Map<String, dynamic> json) {
    final rawItems = json['items'] as List<dynamic>? ?? const [];
    return FileTreeData(
      rootId: json['root_id']?.toString() ?? '',
      rootName: json['root_name']?.toString() ?? '',
      currentPath: json['current_path']?.toString() ?? '',
      items: rawItems
          .whereType<Map>()
          .map((e) => FileItem.fromJson(Map<String, dynamic>.from(e)))
          .toList(),
    );
  }
}

class FileContentData {
  final String rootId;
  final String path;
  final String name;
  final String content;
  final int totalLines;
  final bool truncated;
  final int size;
  final double mtime;

  const FileContentData({
    required this.rootId,
    required this.path,
    required this.name,
    required this.content,
    required this.totalLines,
    required this.truncated,
    required this.size,
    this.mtime = 0.0,
  });

  factory FileContentData.fromJson(Map<String, dynamic> json) {
    return FileContentData(
      rootId: json['root_id']?.toString() ?? '',
      path: json['path']?.toString() ?? '',
      name: json['name']?.toString() ?? '',
      content: json['content']?.toString() ?? '',
      totalLines: (json['total_lines'] as num?)?.toInt() ?? 0,
      truncated: json['truncated'] == true,
      size: (json['size'] as num?)?.toInt() ?? 0,
      mtime: (json['mtime'] as num?)?.toDouble() ?? 0.0,
    );
  }
}

class GitDiffData {
  final String rootId;
  final String workspace;
  final String status;
  final String diff;

  const GitDiffData({
    required this.rootId,
    required this.workspace,
    required this.status,
    required this.diff,
  });

  factory GitDiffData.fromJson(Map<String, dynamic> json) {
    return GitDiffData(
      rootId: json['root_id']?.toString() ?? '',
      workspace: json['workspace']?.toString() ?? '',
      status: json['status']?.toString() ?? '',
      diff: json['diff']?.toString() ?? '',
    );
  }
}

class UploadResult {
  final String filename;
  final String rootId;
  final String path;
  final String absPath;
  final bool isImage;
  final int size;

  const UploadResult({
    required this.filename,
    required this.rootId,
    required this.path,
    required this.absPath,
    required this.isImage,
    required this.size,
  });

  factory UploadResult.fromJson(Map<String, dynamic> json) {
    return UploadResult(
      filename: json['filename']?.toString() ?? '',
      rootId: json['root_id']?.toString() ?? 'brain',
      path: json['path']?.toString() ?? '',
      absPath: json['abs_path']?.toString() ?? '',
      isImage: json['is_image'] == true,
      size: (json['size'] as num?)?.toInt() ?? 0,
    );
  }
}

class DownloadTicket {
  final String ticket;
  final int expiresIn;
  final String filename;

  const DownloadTicket({
    required this.ticket,
    required this.expiresIn,
    required this.filename,
  });

  factory DownloadTicket.fromJson(Map<String, dynamic> json) {
    return DownloadTicket(
      ticket: json['ticket']?.toString() ?? '',
      expiresIn: (json['expires_in'] as num?)?.toInt() ?? 60,
      filename: json['filename']?.toString() ?? 'download',
    );
  }
}

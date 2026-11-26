import 'dart:convert';
import 'package:flutter/material.dart';

class FileUtils {
  static ({String cleanPath, int? startLine, int? endLine}) parseFileLinkTarget(String rawPath) {
    final trimmed = rawPath.trim();
    if (trimmed.isEmpty) {
      return (cleanPath: '', startLine: null, endLine: null);
    }
    var pathPart = trimmed;
    int? startLine;
    int? endLine;
    final hashIdx = trimmed.indexOf('#');
    if (hashIdx >= 0) {
      pathPart = trimmed.substring(0, hashIdx);
      final frag = trimmed.substring(hashIdx + 1).trim();
      final m = RegExp(r'^L(\d+)(?:-L?(\d+))?$', caseSensitive: false).firstMatch(frag);
      if (m != null) {
        startLine = int.tryParse(m.group(1) ?? '');
        endLine = int.tryParse(m.group(2) ?? '') ?? startLine;
        if (startLine != null && endLine != null && startLine > endLine) {
          final tmp = startLine;
          startLine = endLine;
          endLine = tmp;
        }
      }
    }
    final qIdx = pathPart.indexOf('?');
    if (qIdx >= 0) {
      pathPart = pathPart.substring(0, qIdx);
    }
    return (cleanPath: pathPart.trim(), startLine: startLine, endLine: endLine);
  }

  static String extractFilename(String rawPath) {
    final clean = parseFileLinkTarget(rawPath).cleanPath;
    if (clean.isEmpty) return 'file';
    final parts = clean.split(RegExp(r'[\\/]')).where((s) => s.isNotEmpty).toList();
    return parts.isEmpty ? clean : parts.last;
  }

  static String _extensionOf(String path) {
    final clean = parseFileLinkTarget(path).cleanPath.toLowerCase();
    final base = clean.split(RegExp(r'[\\/]')).last;
    return base.contains('.') ? base.split('.').last : '';
  }

  static bool isMarkdownFile(String path) {
    final ext = _extensionOf(path);
    return ext == 'md' || ext == 'markdown' || ext == 'mdx';
  }

  static bool isImageFile(String path) {
    const imageExts = {'png', 'jpg', 'jpeg', 'gif', 'webp', 'bmp', 'svg'};
    return imageExts.contains(_extensionOf(path));
  }

  static bool isPdfFile(String path) => _extensionOf(path) == 'pdf';

  static bool isVideoFile(String path) {
    const videoExts = {'mp4', 'mkv', 'avi', 'mov', 'webm', 'm4v', '3gp', 'flv'};
    return videoExts.contains(_extensionOf(path));
  }

  static bool isAudioFile(String path) {
    const audioExts = {'mp3', 'wav', 'ogg', 'm4a', 'flac', 'aac', 'opus'};
    return audioExts.contains(_extensionOf(path));
  }

  static bool isMediaStreamFile(String path) => isVideoFile(path) || isAudioFile(path);

  static bool isBinaryFile(String path) {
    final ext = _extensionOf(path);
    const binaryExts = {
      'zip', 'rar', '7z', 'tar', 'gz', 'bz2', 'xz', 'tgz',
      'exe', 'dll', 'so', 'dylib', 'bin', 'iso', 'apk', 'msi',
      'pdf', 'docx', 'xlsx', 'pptx', 'doc', 'xls', 'ppt',
      'png', 'jpg', 'jpeg', 'gif', 'webp', 'ico', 'bmp', 'svg',
      'mp3', 'wav', 'ogg', 'm4a', 'flac', 'aac', 'opus',
      'mp4', 'mkv', 'avi', 'mov', 'webm', 'm4v', '3gp', 'flv',
      'wasm', 'pyc', 'class', 'o', 'a', 'lib', 'db', 'sqlite'
    };
    return binaryExts.contains(ext);
  }

  static IconData getFileIconData(String name, bool isDir) {
    if (isDir) return Icons.folder_rounded;
    final lower = name.toLowerCase();
    final ext = lower.contains('.') ? lower.split('.').last : '';
    if (const {'zip', 'rar', '7z', 'tar', 'gz', 'bz2', 'xz', 'tgz'}.contains(ext)) {
      return Icons.folder_zip_rounded;
    }
    if (const {'png', 'jpg', 'jpeg', 'gif', 'webp', 'ico', 'bmp', 'svg'}.contains(ext)) {
      return Icons.image_rounded;
    }
    if (const {'mp4', 'mkv', 'avi', 'mov', 'webm', 'm4v', '3gp', 'flv'}.contains(ext)) {
      return Icons.movie_outlined;
    }
    if (const {'mp3', 'wav', 'ogg', 'm4a', 'flac', 'aac', 'opus'}.contains(ext)) {
      return Icons.audiotrack_rounded;
    }
    if (const {'pdf', 'docx', 'xlsx', 'pptx', 'doc', 'xls', 'ppt'}.contains(ext)) {
      return Icons.description_rounded;
    }
    if (const {'exe', 'msi', 'apk', 'bin', 'iso'}.contains(ext)) {
      return Icons.extension_rounded;
    }
    if (const {
      'dart', 'py', 'js', 'ts', 'html', 'css', 'json', 'yaml', 'yml',
      'sh', 'bat', 'c', 'cpp', 'h', 'java', 'go', 'rs', 'sql'
    }.contains(ext)) {
      return Icons.code_rounded;
    }
    return Icons.insert_drive_file_outlined;
  }

  static Color getFileIconColor(String name, bool isDir, BuildContext context) {
    if (isDir) return const Color(0xFFFBBF24);
    final lower = name.toLowerCase();
    final ext = lower.contains('.') ? lower.split('.').last : '';
    if (const {'zip', 'rar', '7z', 'tar', 'gz', 'bz2', 'xz', 'tgz'}.contains(ext)) {
      return const Color(0xFFF97316);
    }
    if (const {'png', 'jpg', 'jpeg', 'gif', 'webp', 'ico', 'bmp', 'svg'}.contains(ext)) {
      return const Color(0xFF10B981);
    }
    if (const {'mp4', 'mkv', 'avi', 'mov', 'webm', 'm4v', '3gp', 'flv'}.contains(ext)) {
      return const Color(0xFF6366F1);
    }
    if (const {'mp3', 'wav', 'ogg', 'm4a', 'flac', 'aac', 'opus'}.contains(ext)) {
      return const Color(0xFF06B6D4);
    }
    if (const {'pdf', 'docx', 'xlsx', 'pptx', 'doc', 'xls', 'ppt'}.contains(ext)) {
      return const Color(0xFFEF4444);
    }
    if (const {'exe', 'msi', 'apk', 'bin', 'iso'}.contains(ext)) {
      return const Color(0xFF8B5CF6);
    }
    return Theme.of(context).colorScheme.primary;
  }

  static List<String> extractImagePaths(String text) {
    final List<String> paths = [];
    final reg = RegExp(r'\[用户上传图片:\s*(.*?)\]');
    for (final m in reg.allMatches(text)) {
      final p = m.group(1)?.trim();
      if (p != null && p.isNotEmpty && !paths.contains(p)) paths.add(p);
    }
    final reg2 = RegExp(
      r'([A-Za-z]:[\\/][^\s\n\r"\[\]]+\.(?:png|jpg|jpeg|webp)|/(?:home|tmp)[^\s\n\r"\[\]]+\.(?:png|jpg|jpeg|webp))',
    );
    for (final m in reg2.allMatches(text)) {
      final p = m.group(1)?.trim();
      if (p != null && p.isNotEmpty && !paths.contains(p)) paths.add(p);
    }
    return paths;
  }

  static List<String> extractDownloadableFiles(String text) {
    final List<String> files = [];
    final reg = RegExp(
      r'(?:file:///)?([A-Za-z]:[\\/][^\s\n\r"\[\]<>]+\.(?:zip|tar\.gz|tgz|rar|7z|pdf|txt|py|json|bat|sh|csv|docx|xlsx|pptx)|/(?:home|tmp|root)[^\s\n\r"\[\]<>]+\.(?:zip|tar\.gz|tgz|rar|7z|pdf|txt|py|json|bat|sh|csv|docx|xlsx|pptx))',
      caseSensitive: false,
    );
    for (final m in reg.allMatches(text)) {
      final p = m.group(1)?.trim();
      if (p != null && p.isNotEmpty && !files.contains(p)) {
        files.add(p);
      }
    }
    return files;
  }

  static String cleanPath(dynamic p) {
    if (p == null) return '';
    return p.toString().replaceAll('"', '').trim();
  }

  static String cleanCodeString(dynamic val) {
    if (val == null) return '';
    var s = val.toString();
    if (s.startsWith('"') && s.endsWith('"') && s.length >= 2) {
      s = s.substring(1, s.length - 1);
    }
    return s.replaceAll(r'\n', '\n').replaceAll(r'\"', '"').replaceAll(r'\\', '\\');
  }

  static Map<String, dynamic> parseToolArgs(dynamic rawArgs) {
    if (rawArgs == null) return {};
    if (rawArgs is Map<String, dynamic>) return rawArgs;
    if (rawArgs is Map) return Map<String, dynamic>.from(rawArgs);
    if (rawArgs is String) {
      try {
        final decoded = jsonDecode(rawArgs);
        if (decoded is Map) return Map<String, dynamic>.from(decoded);
      } catch (_) {}
    }
    return {};
  }
}

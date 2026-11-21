import 'dart:convert';
import 'package:flutter/material.dart';

/// 文件与工具辅助工具类
class FileUtils {
  /// 判断是否为二进制或非纯文本文件
  static bool isBinaryFile(String path) {
    final lower = path.toLowerCase();
    final ext = lower.contains('.') ? lower.split('.').last : '';
    const binaryExts = {
      'zip', 'rar', '7z', 'tar', 'gz', 'bz2', 'xz', 'tgz',
      'exe', 'dll', 'so', 'dylib', 'bin', 'iso', 'apk', 'msi',
      'pdf', 'docx', 'xlsx', 'pptx', 'doc', 'xls', 'ppt',
      'png', 'jpg', 'jpeg', 'gif', 'webp', 'ico', 'bmp', 'svg',
      'mp3', 'wav', 'ogg', 'm4a', 'flac',
      'mp4', 'mkv', 'avi', 'mov', 'webm',
      'wasm', 'pyc', 'class', 'o', 'a', 'lib', 'db', 'sqlite'
    };
    return binaryExts.contains(ext);
  }

  /// 获取文件或目录对应的 Material 图标
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

  /// 获取文件图标展示颜色
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
    if (const {'pdf', 'docx', 'xlsx', 'pptx', 'doc', 'xls', 'ppt'}.contains(ext)) {
      return const Color(0xFFEF4444);
    }
    if (const {'exe', 'msi', 'apk', 'bin', 'iso'}.contains(ext)) {
      return const Color(0xFF8B5CF6);
    }
    return Theme.of(context).colorScheme.primary;
  }

  /// 从文本中提取用户上传的图片路径
  static List<String> extractImagePaths(String text) {
    final List<String> paths = [];
    final reg = RegExp(r'\[用户上传图片:\s*(.*?)\]');
    for (final m in reg.allMatches(text)) {
      final p = m.group(1)?.trim();
      if (p != null && p.isNotEmpty && !paths.contains(p)) paths.add(p);
    }
    final reg2 = RegExp(
      r'([A-Za-z]:[\\/][^\s\n\r"\[\]]+\.(?:png|jpg|jpeg|webp)|/(?:home|tmp)[^\s\n\r"\[\]]+\.(?:png|jpg|jpeg|webp))'
    );
    for (final m in reg2.allMatches(text)) {
      final p = m.group(1)?.trim();
      if (p != null && p.isNotEmpty && !paths.contains(p)) paths.add(p);
    }
    return paths;
  }

  /// 从 Agent 回复正文中正则匹配生成的可下载文件
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

  /// 清洗文件路径字符串
  static String cleanPath(dynamic p) {
    if (p == null) return "";
    return p.toString().replaceAll('"', '').trim();
  }

  /// 清洗转义代码字符串
  static String cleanCodeString(dynamic val) {
    if (val == null) return "";
    String s = val.toString();
    if (s.startsWith('"') && s.endsWith('"') && s.length >= 2) {
      s = s.substring(1, s.length - 1);
    }
    return s.replaceAll(r'\n', '\n').replaceAll(r'\"', '"').replaceAll(r'\\', '\\');
  }

  /// 安全解析工具参数
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

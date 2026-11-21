import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../utils/file_utils.dart';

/// 纯文本文件全文查看器（带行号、复制全文、二进制安全阻断）
class FileViewerSheet extends StatelessWidget {
  final String name;
  final String path;
  final String content;
  final int totalLines;
  final bool truncated;
  final int size;

  const FileViewerSheet({
    super.key,
    required this.name,
    required this.path,
    required this.content,
    required this.totalLines,
    required this.truncated,
    required this.size,
  });

  /// 弹出展示文件全文查看器
  static void show(
    BuildContext context, {
    required String name,
    required String path,
    required String content,
    required int totalLines,
    required bool truncated,
    required int size,
    required void Function(String path) onDownloadFallback,
  }) {
    final isDark = Theme.of(context).brightness == Brightness.dark;

    // 🛡️ 防御：如果检测到 NUL 字节或二进制后缀，坚决拒绝纯文本排版，防止 CanvasKit 死锁
    if (content.contains('\x00') || FileUtils.isBinaryFile(name)) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text("📦 文件 [$name] 为二进制文件，已自动转为下载通道"),
          behavior: SnackBarBehavior.floating,
          duration: const Duration(seconds: 3),
          action: SnackBarAction(
            label: "立即下载",
            textColor: Colors.cyanAccent,
            onPressed: () => onDownloadFallback(path),
          ),
        ),
      );
      onDownloadFallback(path);
      return;
    }

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: isDark ? const Color(0xFF0F172A) : Colors.white,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (ctx) => FileViewerSheet(
        name: name,
        path: path,
        content: content,
        totalLines: totalLines,
        truncated: truncated,
        size: size,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final lines = content.split('\n');

    return Container(
      height: MediaQuery.of(context).size.height * 0.88,
      padding: const EdgeInsets.all(14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Icon(
                          Icons.description_outlined,
                          color: Theme.of(context).colorScheme.primary,
                          size: 20,
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            name,
                            style: TextStyle(
                              fontSize: 16,
                              fontWeight: FontWeight.bold,
                              color: isDark ? Colors.white : Colors.black87,
                            ),
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 2),
                    Text(
                      path,
                      style: TextStyle(
                        fontSize: 10,
                        color: isDark ? Colors.white38 : Colors.black38,
                        fontFamily: 'monospace',
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                ),
              ),
              Row(
                children: [
                  IconButton(
                    icon: const Icon(Icons.copy_rounded, size: 18),
                    tooltip: "复制全文",
                    onPressed: () {
                      Clipboard.setData(ClipboardData(text: content));
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(content: Text("已复制到剪贴板")),
                      );
                    },
                  ),
                  IconButton(
                    icon: const Icon(Icons.close_rounded, size: 20),
                    onPressed: () => Navigator.pop(context),
                  ),
                ],
              ),
            ],
          ),
          Container(
            margin: const EdgeInsets.symmetric(vertical: 8),
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
            decoration: BoxDecoration(
              color: isDark ? Colors.white.withOpacity(0.05) : Colors.black.withOpacity(0.04),
              borderRadius: BorderRadius.circular(6),
            ),
            child: Row(
              children: [
                Text(
                  truncated ? "共 $totalLines 行 (已显示前 2000 行)" : "共 $totalLines 行",
                  style: TextStyle(fontSize: 11, color: isDark ? Colors.white60 : Colors.black54),
                ),
                const Spacer(),
                Text(
                  "${(size / 1024).toStringAsFixed(1)} KB",
                  style: TextStyle(fontSize: 11, color: isDark ? Colors.white38 : Colors.black38),
                ),
              ],
            ),
          ),
          Expanded(
            child: Container(
              decoration: BoxDecoration(
                color: isDark ? const Color(0xFF090D16) : const Color(0xFFF8FAFC),
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: isDark ? const Color(0xFF23324A) : const Color(0xFFE2E8F0)),
              ),
              child: SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: SingleChildScrollView(
                  child: Padding(
                    padding: const EdgeInsets.all(10),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Column(
                          crossAxisAlignment: CrossAxisAlignment.end,
                          children: [
                            for (int i = 1; i <= lines.length; i++)
                              Text(
                                "$i  ",
                                style: TextStyle(
                                  fontFamily: 'monospace',
                                  fontSize: 12,
                                  color: isDark ? Colors.white24 : Colors.black26,
                                  height: 1.45,
                                ),
                              ),
                          ],
                        ),
                        SelectableText(
                          content,
                          style: TextStyle(
                            fontFamily: 'monospace',
                            fontSize: 12,
                            color: isDark ? const Color(0xFFE2E8F0) : const Color(0xFF1E293B),
                            height: 1.45,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

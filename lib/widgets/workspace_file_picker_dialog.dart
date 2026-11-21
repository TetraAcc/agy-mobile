import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../models/models.dart';
import '../utils/file_utils.dart';

/// 工作区文件浏览与拾取弹窗
class WorkspaceFilePickerDialog extends StatelessWidget {
  final String baseDirName;
  final String currentSubPath;
  final List<FileItem> files;
  final bool isDark;
  final ValueChanged<String> onNavigate;
  final ValueChanged<String> onDownload;
  final ValueChanged<String> onReadFile;
  final ValueChanged<String> onInsertRef;

  const WorkspaceFilePickerDialog({
    super.key,
    required this.baseDirName,
    required this.currentSubPath,
    required this.files,
    required this.isDark,
    required this.onNavigate,
    required this.onDownload,
    required this.onReadFile,
    required this.onInsertRef,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      height: MediaQuery.of(context).size.height * 0.75,
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Row(
                children: [
                  Icon(
                    Icons.folder_special_rounded,
                    color: Theme.of(context).colorScheme.primary,
                    size: 20,
                  ),
                  const SizedBox(width: 8),
                  Text(
                    currentSubPath.isEmpty ? "工作区: $baseDirName" : ".../$currentSubPath",
                    style: TextStyle(
                      fontWeight: FontWeight.bold,
                      fontSize: 14,
                      color: isDark ? Colors.white : Colors.black87,
                    ),
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
              ),
              IconButton(
                icon: Icon(Icons.close, color: isDark ? Colors.white54 : Colors.black54, size: 20),
                onPressed: () => Navigator.pop(context),
              ),
            ],
          ),
          Divider(color: isDark ? Colors.white12 : Colors.black12),

          if (currentSubPath.isNotEmpty)
            InkWell(
              onTap: () {
                final parts = currentSubPath.split('/');
                parts.removeLast();
                final parentPath = parts.join('/');
                onNavigate(parentPath);
              },
              child: Container(
                padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 10),
                margin: const EdgeInsets.only(bottom: 6),
                decoration: BoxDecoration(
                  color: isDark ? Colors.white.withOpacity(0.04) : Colors.black.withOpacity(0.04),
                  borderRadius: BorderRadius.circular(6),
                ),
                child: Row(
                  children: [
                    Icon(
                      Icons.arrow_upward_rounded,
                      size: 16,
                      color: Theme.of(context).colorScheme.primary,
                    ),
                    const SizedBox(width: 8),
                    Text(
                      "返回上一层目录 (..)",
                      style: TextStyle(color: Theme.of(context).colorScheme.primary, fontSize: 12),
                    ),
                  ],
                ),
              ),
            ),

          Expanded(
            child: files.isEmpty
                ? const Center(child: CircularProgressIndicator())
                : ListView.builder(
                    itemCount: files.length,
                    itemBuilder: (c, idx) {
                      final item = files[idx];
                      final isBin = FileUtils.isBinaryFile(item.path);

                      return ListTile(
                        dense: true,
                        visualDensity: const VisualDensity(vertical: -2),
                        leading: Icon(
                          FileUtils.getFileIconData(item.name, item.isDir),
                          color: FileUtils.getFileIconColor(item.name, item.isDir, context),
                          size: 18,
                        ),
                        title: Text(
                          item.name,
                          style: TextStyle(
                            color: isDark
                                ? (item.isDir ? Colors.white : const Color(0xFFE2E8F0))
                                : (item.isDir ? Colors.black87 : Colors.black54),
                            fontSize: 13,
                            fontWeight: item.isDir ? FontWeight.bold : FontWeight.normal,
                          ),
                        ),
                        trailing: item.isDir
                            ? Icon(Icons.chevron_right, size: 16, color: isDark ? Colors.white24 : Colors.black26)
                            : Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  IconButton(
                                    icon: const Icon(Icons.download_rounded, size: 18),
                                    tooltip: "下载到本地",
                                    color: Colors.greenAccent.shade400,
                                    onPressed: () => onDownload(item.path),
                                  ),
                                  if (!isBin)
                                    IconButton(
                                      icon: const Icon(Icons.visibility_outlined, size: 18),
                                      tooltip: "查看内容",
                                      color: Theme.of(context).colorScheme.primary,
                                      onPressed: () => onReadFile(item.path),
                                    ),
                                  IconButton(
                                    icon: const Icon(Icons.add_comment_outlined, size: 18),
                                    tooltip: "引用到输入框",
                                    color: isDark ? Colors.white54 : Colors.black45,
                                    onPressed: () {
                                      Navigator.pop(context);
                                      onInsertRef("@file:${item.path} ");
                                      HapticFeedback.lightImpact();
                                    },
                                  ),
                                ],
                              ),
                        onTap: () {
                          if (item.isDir) {
                            onNavigate(item.path);
                          } else if (isBin) {
                            onDownload(item.path);
                            ScaffoldMessenger.of(context).showSnackBar(
                              SnackBar(
                                content: Text("📦 检测到文档/二进制文件 [${item.name}]，已为您触发直接下载"),
                                behavior: SnackBarBehavior.floating,
                                duration: const Duration(seconds: 2),
                              ),
                            );
                          } else {
                            onReadFile(item.path);
                          }
                        },
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }
}

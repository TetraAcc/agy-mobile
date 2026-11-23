import 'package:flutter/material.dart';

class ContextMenuSheet extends StatelessWidget {
  final bool isDark;
  final bool canWrite;
  final VoidCallback onPickFile;
  final VoidCallback onPickImage;
  final VoidCallback onRequestGitDiff;
  final VoidCallback onOpenWorkspaceFiles;
  final VoidCallback? onOpenSessionArtifacts;

  const ContextMenuSheet({
    super.key,
    required this.isDark,
    this.canWrite = true,
    required this.onPickFile,
    required this.onPickImage,
    required this.onRequestGitDiff,
    required this.onOpenWorkspaceFiles,
    this.onOpenSessionArtifacts,
  });

  static void show(
    BuildContext context, {
    required bool isDark,
    bool canWrite = true,
    required VoidCallback onPickFile,
    required VoidCallback onPickImage,
    required VoidCallback onRequestGitDiff,
    required VoidCallback onOpenWorkspaceFiles,
    VoidCallback? onOpenSessionArtifacts,
  }) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: isDark ? const Color(0xFF161F30) : Colors.white,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (ctx) => ContextMenuSheet(
        isDark: isDark,
        canWrite: canWrite,
        onPickFile: onPickFile,
        onPickImage: onPickImage,
        onRequestGitDiff: onRequestGitDiff,
        onOpenWorkspaceFiles: onOpenWorkspaceFiles,
        onOpenSessionArtifacts: onOpenSessionArtifacts,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: ConstrainedBox(
        constraints: BoxConstraints(maxHeight: MediaQuery.of(context).size.height * 0.85),
        child: SingleChildScrollView(
          padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 8),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
                child: Text(
                  '工具与上下文',
                  style: TextStyle(
                    color: isDark ? Colors.white54 : Colors.black45,
                    fontSize: 12,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
              Divider(color: isDark ? Colors.white12 : Colors.black12, height: 1),
              if (canWrite) ...[
                _buildMenuItem(
                  context,
                  icon: Icons.upload_file_rounded,
                  title: '添加本地文件',
                  subtitle: '从电脑/手机选择并上传本地代码、文档或配置',
                  onTap: () {
                    Navigator.pop(context);
                    onPickFile();
                  },
                ),
                _buildMenuItem(
                  context,
                  icon: Icons.image_outlined,
                  title: '上传图片',
                  subtitle: '选择本地图片上传 (Web 端支持 Ctrl+V / 拖拽)',
                  onTap: () {
                    Navigator.pop(context);
                    onPickImage();
                  },
                ),
              ],
              _buildMenuItem(
                context,
                icon: Icons.folder_open_rounded,
                title: '工作区文件',
                subtitle: '浏览受控工程文件、在线预览 PDF/图片与下载',
                onTap: () {
                  Navigator.pop(context);
                  onOpenWorkspaceFiles();
                },
              ),
              _buildMenuItem(
                context,
                icon: Icons.difference_rounded,
                title: '变更评审 (Diff)',
                subtitle: '查看本会话文件修改与工程 Git 变更，支持逐处批注',
                onTap: () {
                  Navigator.pop(context);
                  onRequestGitDiff();
                },
              ),
              if (onOpenSessionArtifacts != null)
                _buildMenuItem(
                  context,
                  icon: Icons.auto_awesome_mosaic_outlined,
                  title: '会话文档 (Artifacts)',
                  subtitle: '查看并审阅本会话产出的方案、脚本与图片文件',
                  onTap: () {
                    Navigator.pop(context);
                    onOpenSessionArtifacts!();
                  },
                ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildMenuItem(
    BuildContext context, {
    required IconData icon,
    required String title,
    required String subtitle,
    required VoidCallback onTap,
  }) {
    return ListTile(
      dense: true,
      leading: Icon(icon, color: Theme.of(context).colorScheme.primary, size: 22),
      title: Text(
        title,
        style: TextStyle(
          color: isDark ? Colors.white : Colors.black87,
          fontSize: 13,
          fontWeight: FontWeight.bold,
        ),
      ),
      subtitle: Text(
        subtitle,
        style: TextStyle(
          color: isDark ? Colors.white38 : Colors.black38,
          fontSize: 11,
        ),
      ),
      onTap: onTap,
    );
  }
}

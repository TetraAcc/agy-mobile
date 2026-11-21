import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import '../bridge/js_bridge.dart';

/// 添加上下文与快捷动作菜单底栏
class ContextMenuSheet extends StatelessWidget {
  final bool isDark;
  final VoidCallback onRequestGitDiff;
  final VoidCallback onOpenWorkspaceFiles;
  final ValueChanged<String> onInsertText;
  final void Function(String title, String hint, ValueChanged<String> onConfirm) onShowPromptDialog;

  const ContextMenuSheet({
    super.key,
    required this.isDark,
    required this.onRequestGitDiff,
    required this.onOpenWorkspaceFiles,
    required this.onInsertText,
    required this.onShowPromptDialog,
  });

  static void show(
    BuildContext context, {
    required bool isDark,
    required VoidCallback onRequestGitDiff,
    required VoidCallback onOpenWorkspaceFiles,
    required ValueChanged<String> onInsertText,
    required void Function(String title, String hint, ValueChanged<String> onConfirm) onShowPromptDialog,
  }) {
    showModalBottomSheet(
      context: context,
      backgroundColor: isDark ? const Color(0xFF161F30) : Colors.white,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (ctx) => ContextMenuSheet(
        isDark: isDark,
        onRequestGitDiff: onRequestGitDiff,
        onOpenWorkspaceFiles: onOpenWorkspaceFiles,
        onInsertText: onInsertText,
        onShowPromptDialog: onShowPromptDialog,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 8),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
              child: Text(
                "添加上下文",
                style: TextStyle(
                  color: isDark ? Colors.white54 : Colors.black45,
                  fontSize: 12,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ),
            Divider(color: isDark ? Colors.white12 : Colors.black12, height: 1),
            _buildMenuItem(
              context,
              icon: Icons.upload_file_rounded,
              title: "添加本地文件",
              subtitle: "从电脑/手机选择并上传本地代码、文档或配置",
              onTap: () {
                Navigator.pop(context);
                if (kIsWeb) {
                  try {
                    JsBridge.pickFile('*/*', false);
                  } catch (e) {
                    debugPrint("pickFile error: $e");
                  }
                }
              },
            ),
            _buildMenuItem(
              context,
              icon: Icons.image_outlined,
              title: "上传图片",
              subtitle: "选择本地图片上传 (也可直接按 Ctrl+V 粘贴)",
              onTap: () {
                Navigator.pop(context);
                if (kIsWeb) {
                  try {
                    JsBridge.pickFile('image/*', true);
                  } catch (e) {
                    debugPrint("pickFile error: $e");
                  }
                }
              },
            ),
            _buildMenuItem(
              context,
              icon: Icons.difference_rounded,
              title: "Git 变更 Diff",
              subtitle: "查看当前项目所有未提交修改对比",
              onTap: () {
                Navigator.pop(context);
                onRequestGitDiff();
              },
            ),
            _buildMenuItem(
              context,
              icon: Icons.folder_open_rounded,
              title: "工作区文件",
              subtitle: "点选浏览工程文件并可直接查看代码",
              onTap: () {
                Navigator.pop(context);
                onOpenWorkspaceFiles();
              },
            ),
            _buildMenuItem(
              context,
              icon: Icons.alternate_email,
              title: "提及",
              subtitle: "快捷引用规则与技能",
              onTap: () {
                Navigator.pop(context);
                _showMentionOptionsSheet(context);
              },
            ),
            _buildMenuItem(
              context,
              icon: Icons.check_box_outlined,
              title: "快捷操作",
              subtitle: "一键执行测试或 Git 状态",
              onTap: () {
                Navigator.pop(context);
                _showQuickActionsSheet(context);
              },
            ),
            _buildMenuItem(
              context,
              icon: Icons.language,
              title: "浏览器",
              subtitle: "调度浏览器子代理交互",
              onTap: () {
                Navigator.pop(context);
                onShowPromptDialog("浏览器操作", "输入要测试或访问的网址:", (val) {
                  onInsertText("请使用 browser 代理打开 $val 进行测试");
                });
              },
            ),
          ],
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

  void _showQuickActionsSheet(BuildContext context) {
    showModalBottomSheet(
      context: context,
      backgroundColor: isDark ? const Color(0xFF1E293B) : Colors.white,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (ctx) {
        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  "常用快捷操作",
                  style: TextStyle(
                    fontWeight: FontWeight.bold,
                    fontSize: 14,
                    color: isDark ? Colors.white : Colors.black87,
                  ),
                ),
                const SizedBox(height: 12),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    _buildActionChip(ctx, "🚀 运行测试", "/test"),
                    _buildActionChip(ctx, "📊 Git 状态", "运行 git status 查看当前工作区修改"),
                    _buildActionChip(ctx, "🧹 紧凑上下文", "/compact"),
                    _buildActionChip(ctx, "🔍 检查报错", "分析刚才命令执行中的所有报错并给出修复方案"),
                    _buildActionChip(ctx, "📖 查看帮助", "/help"),
                  ],
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  void _showMentionOptionsSheet(BuildContext context) {
    showModalBottomSheet(
      context: context,
      backgroundColor: isDark ? const Color(0xFF1E293B) : Colors.white,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (ctx) {
        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  "快速提及",
                  style: TextStyle(
                    fontWeight: FontWeight.bold,
                    fontSize: 14,
                    color: isDark ? Colors.white : Colors.black87,
                  ),
                ),
                const SizedBox(height: 12),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    _buildActionChip(ctx, "📜 全局协作约定", "@rules "),
                    _buildActionChip(ctx, "💻 终端会话", "@terminal "),
                    _buildActionChip(ctx, "🧩 故障排查技能", "@engineering-debugging "),
                    _buildActionChip(ctx, "🐍 Python辅导", "@python-coaching "),
                  ],
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _buildActionChip(BuildContext ctx, String label, String command) {
    return ActionChip(
      backgroundColor: isDark ? const Color(0xFF0F172A) : const Color(0xFFF1F5F9),
      side: BorderSide(color: isDark ? const Color(0xFF334155) : const Color(0xFFCBD5E1)),
      label: Text(
        label,
        style: TextStyle(color: isDark ? Colors.white : Colors.black87, fontSize: 12),
      ),
      onPressed: () {
        Navigator.pop(ctx);
        onInsertText(command);
      },
    );
  }
}

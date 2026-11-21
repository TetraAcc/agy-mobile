import 'package:flutter/material.dart';
import '../models/models.dart';
import 'slash_command_menu.dart';
import 'attachment_preview_bar.dart';

/// 底部输入栏组件（支持附件预览、斜杠补全弹窗、任务发送/停止切换）
class BottomInputBar extends StatelessWidget {
  final TextEditingController inputController;
  final bool isConnected;
  final bool isThinking;
  final bool isDark;
  final bool showSlashMenu;
  final List<SlashCommandOption> filteredSlashCommands;
  final ValueChanged<String> onSelectSlashCommand;
  final List<UploadedAttachment> pendingAttachments;
  final ValueChanged<int> onRemoveAttachment;
  final VoidCallback onShowAddContext;
  final VoidCallback onSendMessage;
  final VoidCallback onStopTask;

  const BottomInputBar({
    super.key,
    required this.inputController,
    required this.isConnected,
    required this.isThinking,
    required this.isDark,
    required this.showSlashMenu,
    required this.filteredSlashCommands,
    required this.onSelectSlashCommand,
    required this.pendingAttachments,
    required this.onRemoveAttachment,
    required this.onShowAddContext,
    required this.onSendMessage,
    required this.onStopTask,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      color: isDark ? const Color(0xFF161F30) : Colors.white,
      child: SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // 斜杠指令悬浮补全卡片
            if (showSlashMenu)
              SlashCommandMenu(
                commands: filteredSlashCommands,
                onSelect: onSelectSlashCommand,
                isDark: isDark,
              ),

            // 待上传附件栏
            if (pendingAttachments.isNotEmpty)
              AttachmentPreviewBar(
                attachments: pendingAttachments,
                onRemove: onRemoveAttachment,
                isDark: isDark,
              ),

            // 输入框主行
            Row(
              children: [
                InkWell(
                  borderRadius: BorderRadius.circular(20),
                  onTap: onShowAddContext,
                  child: Container(
                    width: 36,
                    height: 36,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: isDark ? Colors.white.withOpacity(0.08) : Colors.black.withOpacity(0.05),
                    ),
                    child: Icon(
                      Icons.add_rounded,
                      color: isDark ? Colors.white70 : Colors.black54,
                      size: 22,
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: TextField(
                    controller: inputController,
                    style: TextStyle(color: isDark ? Colors.white : Colors.black87),
                    decoration: InputDecoration(
                      hintText: isConnected ? "向 Agent 发送指令或 /斜杠命令..." : "请先连接电脑...",
                      hintStyle: TextStyle(
                        color: isDark ? Colors.white24 : Colors.black26,
                        fontSize: 13,
                      ),
                      filled: true,
                      fillColor: isDark ? const Color(0xFF0B0F19) : const Color(0xFFF1F5F9),
                      contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(24),
                        borderSide: BorderSide.none,
                      ),
                    ),
                    onSubmitted: (_) {
                      if (isConnected && !isThinking) {
                        onSendMessage();
                      }
                    },
                  ),
                ),
                const SizedBox(width: 8),
                IconButton(
                  icon: isThinking
                      ? Container(
                          width: 32,
                          height: 32,
                          decoration: BoxDecoration(
                            color: Colors.redAccent.withOpacity(0.15),
                            shape: BoxShape.circle,
                            border: Border.all(color: Colors.redAccent, width: 1.5),
                          ),
                          child: const Center(
                            child: Icon(Icons.stop_rounded, color: Colors.redAccent, size: 20),
                          ),
                        )
                      : Icon(Icons.arrow_upward_rounded, color: Theme.of(context).colorScheme.primary),
                  tooltip: isThinking ? "停止当前任务 (Stop)" : "发送",
                  onPressed: isConnected
                      ? (isThinking ? onStopTask : onSendMessage)
                      : null,
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

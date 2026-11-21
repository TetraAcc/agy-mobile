import 'package:flutter/material.dart';
import 'package:flutter_markdown/flutter_markdown.dart';
import '../models/models.dart';
import '../utils/file_utils.dart';

/// 聊天消息渲染卡片（支持用户气泡、多模态图片、极简工具栏、思考折叠、Markdown排版、下载卡片）
class MessageCard extends StatelessWidget {
  final AgentMessage msg;
  final bool isDark;
  final String authToken;
  final void Function(String path, {String? filename}) onDownloadFile;
  final void Function(String path) onReadFile;
  final void Function(String url) onOpenUrl;

  const MessageCard({
    super.key,
    required this.msg,
    required this.isDark,
    required this.authToken,
    required this.onDownloadFile,
    required this.onReadFile,
    required this.onOpenUrl,
  });

  @override
  Widget build(BuildContext context) {
    // 1. 用户消息气泡
    if (msg.isUser) {
      final imgPaths = FileUtils.extractImagePaths(msg.content);
      var displayContent = msg.content.replaceAll(RegExp(r'\[用户上传图片:\s*.*?\]\n?'), '').trim();
      displayContent = displayContent.replaceAll(RegExp(r'\[用户上传文件:\s*.*?\]\n?'), '').trim();

      return Align(
        alignment: Alignment.centerRight,
        child: Container(
          margin: const EdgeInsets.only(bottom: 12, left: 40),
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
          decoration: BoxDecoration(
            color: const Color(0xFF0284C7),
            borderRadius: BorderRadius.circular(16).copyWith(bottomRight: const Radius.circular(2)),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.end,
            mainAxisSize: MainAxisSize.min,
            children: [
              if (displayContent.isNotEmpty)
                SelectableText(
                  displayContent,
                  style: const TextStyle(color: Colors.white, fontSize: 14, height: 1.4),
                ),
              for (var imgPath in imgPaths)
                _buildImagePreviewWidget(imgPath),
            ],
          ),
        ),
      );
    }

    // 2. 纯工具执行或空内容步骤：彻底隐藏，不占任何空间！
    if (msg.content.trim().isEmpty && msg.status != 'WAITING_APPROVAL' && msg.status != 'WAITING_INPUT') {
      return const SizedBox.shrink();
    }

    // 3. Agent 回复内容卡片（极简现代化卡片）
    return Container(
      margin: const EdgeInsets.only(bottom: 14),
      decoration: BoxDecoration(
        color: isDark ? const Color(0xFF161F30) : Colors.white,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: isDark ? const Color(0xFF23324A) : const Color(0xFFE2E8F0)),
        boxShadow: isDark
            ? null
            : [
                BoxShadow(
                  color: Colors.black.withOpacity(0.04),
                  blurRadius: 4,
                  offset: const Offset(0, 2),
                )
              ],
      ),
      padding: const EdgeInsets.all(14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // 极简微型工具标签栏（单行 18px 标签）
          if (msg.toolCalls.isNotEmpty)
            _buildCompactToolCallsBar(msg.toolCalls),

          // 思考过程折叠栏
          if (msg.thinking.isNotEmpty) ...[
            _buildThinkingFold(context, msg.thinking),
            const SizedBox(height: 10),
          ],

          // Markdown 回复正文（无任何多余边框）
          if (msg.content.isNotEmpty)
            MarkdownBody(
              data: msg.content,
              selectable: true,
              onTapLink: (text, href, title) {
                if (href != null && href.isNotEmpty) {
                  if (href.startsWith("http://") || href.startsWith("https://")) {
                    onOpenUrl(href);
                  } else {
                    onDownloadFile(href);
                  }
                }
              },
              styleSheet: MarkdownStyleSheet.fromTheme(Theme.of(context)).copyWith(
                p: TextStyle(
                  color: isDark ? const Color(0xFFE2E8F0) : const Color(0xFF1E293B),
                  fontSize: 14,
                  height: 1.6,
                ),
                h1: TextStyle(
                  color: isDark ? Colors.white : Colors.black87,
                  fontSize: 18,
                  fontWeight: FontWeight.bold,
                ),
                h2: TextStyle(
                  color: isDark ? Colors.white : Colors.black87,
                  fontSize: 16,
                  fontWeight: FontWeight.bold,
                ),
                h3: TextStyle(
                  color: Theme.of(context).colorScheme.primary,
                  fontSize: 15,
                  fontWeight: FontWeight.bold,
                ),
                strong: TextStyle(
                  color: isDark ? Colors.white : Colors.black87,
                  fontWeight: FontWeight.bold,
                ),
                em: TextStyle(
                  color: isDark ? const Color(0xFF94A3B8) : const Color(0xFF64748B),
                  fontStyle: FontStyle.italic,
                ),
                a: TextStyle(
                  color: isDark ? const Color(0xFF38BDF8) : const Color(0xFF0284C7),
                  decoration: TextDecoration.underline,
                ),
                listBullet: TextStyle(
                  color: Theme.of(context).colorScheme.primary,
                  fontSize: 14,
                ),
                blockquote: TextStyle(
                  color: isDark ? const Color(0xFFCBD5E1) : const Color(0xFF334155),
                  fontSize: 13.5,
                  height: 1.6,
                ),
                blockquotePadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                blockquoteDecoration: BoxDecoration(
                  color: isDark ? const Color(0xFF161F30) : const Color(0xFFF1F5F9),
                  borderRadius: BorderRadius.circular(8),
                  border: Border(
                    left: BorderSide(
                      color: isDark ? const Color(0xFF38BDF8) : const Color(0xFF0284C7),
                      width: 3.5,
                    ),
                  ),
                ),
                code: TextStyle(
                  backgroundColor: isDark ? const Color(0xFF0B0F19) : const Color(0xFFF1F5F9),
                  color: Theme.of(context).colorScheme.primary,
                  fontFamily: 'monospace',
                  fontSize: 12,
                ),
                codeblockPadding: const EdgeInsets.all(10),
                codeblockDecoration: BoxDecoration(
                  color: isDark ? const Color(0xFF0B0F19) : const Color(0xFFF8FAFC),
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: isDark ? const Color(0xFF23324A) : const Color(0xFFE2E8F0)),
                ),
                tableHead: TextStyle(
                  color: isDark ? Colors.white : Colors.black87,
                  fontWeight: FontWeight.bold,
                ),
                tableBody: TextStyle(
                  color: isDark ? const Color(0xFFE2E8F0) : const Color(0xFF1E293B),
                ),
                tableBorder: TableBorder.all(
                  color: isDark ? const Color(0xFF23324A) : const Color(0xFFE2E8F0),
                  width: 1,
                ),
                tableCellsDecoration: BoxDecoration(
                  color: isDark ? const Color(0xFF0F172A) : const Color(0xFFF8FAFC),
                ),
                horizontalRuleDecoration: BoxDecoration(
                  border: Border(
                    top: BorderSide(
                      color: isDark ? const Color(0xFF23324A) : const Color(0xFFE2E8F0),
                      width: 1,
                    ),
                  ),
                ),
              ),
            ),

          // 自动检测正文中提及的可下载文件，生成直观显眼的【下载卡片】
          for (final fPath in FileUtils.extractDownloadableFiles(msg.content))
            _buildDownloadCard(context, fPath),
        ],
      ),
    );
  }

  Widget _buildImagePreviewWidget(String path) {
    final url = "/api/media?path=${Uri.encodeComponent(path)}&token=$authToken";
    return Container(
      margin: const EdgeInsets.only(top: 8),
      constraints: const BoxConstraints(maxHeight: 240, maxWidth: 320),
      decoration: BoxDecoration(
        color: Colors.black26,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: isDark ? Colors.white24 : Colors.black12),
      ),
      clipBehavior: Clip.antiAlias,
      child: Image.network(
        url,
        fit: BoxFit.contain,
        errorBuilder: (ctx, err, stack) => Padding(
          padding: const EdgeInsets.all(8.0),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.image_outlined, size: 16, color: Colors.white70),
              const SizedBox(width: 6),
              Flexible(
                child: Text(
                  "图片已上传: ${path.split(RegExp(r'[\\/]')).last}",
                  style: const TextStyle(fontSize: 10, color: Colors.white70),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildCompactToolCallsBar(List<dynamic> toolCalls) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Wrap(
        spacing: 6,
        runSpacing: 4,
        children: toolCalls.map((rawTool) {
          final tool = rawTool is Map ? rawTool : {};
          final name = (tool['name'] ?? 'tool').toString();
          final args = FileUtils.parseToolArgs(tool['args']);
          String label = name;
          IconData icon = Icons.settings_suggest_rounded;

          if (name == 'edit_file') {
            final p = FileUtils.cleanPath(args['Path'] ?? args['path']);
            final f = p.isEmpty ? '文件' : p.split(RegExp(r'[\\/]')).last;
            label = "edit: $f";
            icon = Icons.edit_note_rounded;
          } else if (name == 'write_file') {
            final p = FileUtils.cleanPath(args['Path'] ?? args['path']);
            final f = p.isEmpty ? '文件' : p.split(RegExp(r'[\\/]')).last;
            label = "write: $f";
            icon = Icons.post_add_rounded;
          } else if (name == 'read_file') {
            final p = FileUtils.cleanPath(args['Path'] ?? args['path']);
            final f = p.isEmpty ? '文件' : p.split(RegExp(r'[\\/]')).last;
            label = "read: $f";
            icon = Icons.menu_book_rounded;
          } else if (name == 'run_command') {
            final s = (args['toolSummary'] ?? '').toString();
            label = s.isNotEmpty ? s : "run_command";
            icon = Icons.terminal_rounded;
          }

          return Container(
            padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2.5),
            decoration: BoxDecoration(
              color: isDark ? Colors.white.withOpacity(0.04) : Colors.black.withOpacity(0.04),
              borderRadius: BorderRadius.circular(4),
              border: Border.all(color: isDark ? Colors.white10 : Colors.black12),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(icon, size: 11, color: isDark ? Colors.white38 : Colors.black38),
                const SizedBox(width: 4),
                ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 220),
                  child: Text(
                    label,
                    style: TextStyle(
                      fontSize: 10.5,
                      fontFamily: 'monospace',
                      color: isDark ? Colors.white60 : Colors.black54,
                    ),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
            ),
          );
        }).toList(),
      ),
    );
  }

  Widget _buildThinkingFold(BuildContext context, String thinkingText) {
    final preview = thinkingText.trim().split('\n').first;
    final cleanPreview = preview.length > 30 ? "${preview.substring(0, 30)}..." : preview;

    return Container(
      decoration: BoxDecoration(
        color: isDark ? const Color(0xFF090D16) : const Color(0xFFF3E8FF).withOpacity(0.4),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: isDark ? const Color(0xFF2E1065) : const Color(0xFFD8B4FE)),
      ),
      child: Theme(
        data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
        child: ExpansionTile(
          initiallyExpanded: false,
          tilePadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 0),
          childrenPadding: const EdgeInsets.only(left: 10, right: 10, bottom: 10),
          leading: const Icon(Icons.psychology_outlined, color: Color(0xFFA855F7), size: 18),
          title: Text(
            "思考过程: $cleanPreview",
            style: const TextStyle(color: Color(0xFFA855F7), fontSize: 12, fontWeight: FontWeight.w500),
            overflow: TextOverflow.ellipsis,
          ),
          children: [
            SelectableText(
              thinkingText,
              style: TextStyle(
                color: isDark ? const Color(0xFFD8B4FE) : const Color(0xFF6B21A8),
                fontSize: 12,
                height: 1.45,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildDownloadCard(BuildContext context, String filePath) {
    final cleanPath = filePath.replaceAll('file:///', '').replaceAll('file://', '').trim();
    final fileName = cleanPath.split(RegExp(r'[\\/]')).last;

    return Container(
      margin: const EdgeInsets.only(top: 8),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: isDark ? const Color(0xFF1E293B) : const Color(0xFFF1F5F9),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: isDark ? const Color(0xFF334155) : const Color(0xFFCBD5E1)),
      ),
      child: Row(
        children: [
          Icon(
            Icons.inventory_2_outlined,
            size: 20,
            color: Theme.of(context).colorScheme.primary,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  fileName,
                  style: TextStyle(
                    fontSize: 12.5,
                    fontWeight: FontWeight.bold,
                    color: isDark ? Colors.white : Colors.black87,
                  ),
                  overflow: TextOverflow.ellipsis,
                ),
                Text(
                  cleanPath,
                  style: TextStyle(
                    fontSize: 10,
                    color: isDark ? Colors.white38 : Colors.black38,
                  ),
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          ElevatedButton.icon(
            onPressed: () => onDownloadFile(cleanPath, filename: fileName),
            style: ElevatedButton.styleFrom(
              backgroundColor: Theme.of(context).colorScheme.primary,
              foregroundColor: Colors.white,
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
              minimumSize: const Size(0, 32),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(6)),
              elevation: 0,
            ),
            icon: const Icon(Icons.download_rounded, size: 14),
            label: const Text("下载", style: TextStyle(fontSize: 12)),
          ),
        ],
      ),
    );
  }
}

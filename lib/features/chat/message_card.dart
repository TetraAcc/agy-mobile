import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/utils/file_utils.dart';
import '../../models/models.dart';
import '../workspace/session_changes_bar.dart';
import 'markdown_message_body.dart';

class MessageCard extends StatelessWidget {
  final AgentMessage msg;
  final bool isDark;
  final String Function(String rawPath) resolveMediaUrl;
  final Map<String, String>? mediaHeaders;
  final void Function(String path, {String? filename}) onDownloadFile;
  final void Function(String url) onOpenUrl;
  final void Function(String rawPath)? onOpenMediaExternal;
  final void Function(String filePath, int stepIndex)? onOpenEditDiff;
  final void Function(int stepIndex, ToolCallItem tool)? onOpenToolDetail;
  final Future<String?> Function(String replyText)? onSubmitQuickReply;
  final SessionTurnChange? turnChanges;
  final VoidCallback? onOpenTurnReview;
  final ValueChanged<SessionFileChange>? onOpenTurnFile;

  const MessageCard({
    super.key,
    required this.msg,
    required this.isDark,
    required this.resolveMediaUrl,
    this.mediaHeaders,
    required this.onDownloadFile,
    required this.onOpenUrl,
    this.onOpenMediaExternal,
    this.onOpenEditDiff,
    this.onOpenToolDetail,
    this.onSubmitQuickReply,
    this.turnChanges,
    this.onOpenTurnReview,
    this.onOpenTurnFile,
  });

  List<AskQuestionItem> get _askQuestions {
    final items = <AskQuestionItem>[];
    for (final tool in msg.toolCalls) {
      if (tool.name == 'ask_question') {
        items.addAll(AskQuestionItem.parseFromTool(tool));
      }
    }
    return items;
  }

  void _copyMessage(BuildContext context, String text) {
    if (text.trim().isEmpty) return;
    Clipboard.setData(ClipboardData(text: text));
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('已复制原文到剪贴板'), duration: Duration(seconds: 1)),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (msg.isUser) {
      final imgPaths = FileUtils.extractImagePaths(msg.content);
      var displayContent = msg.content.replaceAll(RegExp(r'\[用户上传图片:\s*.*?\]\n?'), '').trim();
      displayContent = displayContent.replaceAll(RegExp(r'\[用户上传文件:\s*.*?\]\n?'), '').trim();

      return Align(
        alignment: Alignment.centerRight,
        child: Container(
          margin: const EdgeInsets.only(bottom: 18, left: 48),
          padding: const EdgeInsets.symmetric(horizontal: 15, vertical: 11),
          decoration: BoxDecoration(
            color: isDark ? const Color(0xFF26262A) : const Color(0xFFF2F2F4),
            borderRadius: BorderRadius.circular(18),
            border: Border.all(
              color: isDark ? const Color(0xFF34343B) : const Color(0xFFE4E4E7),
              width: 0.8,
            ),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.end,
            mainAxisSize: MainAxisSize.min,
            children: [
              if (displayContent.isNotEmpty)
                SelectableText(
                  displayContent,
                  style: TextStyle(
                    color: isDark ? const Color(0xFFF4F4F5) : const Color(0xFF18181B),
                    fontSize: 14.5,
                    height: 1.5,
                  ),
                ),
              for (final imgPath in imgPaths) _buildUserImagePreview(context, imgPath),
            ],
          ),
        ),
      );
    }

    final askQuestions = _askQuestions;
    final hasTurnChanges = turnChanges != null && turnChanges!.totalFiles > 0 && turnChanges!.files.isNotEmpty;
    if (msg.content.trim().isEmpty &&
        askQuestions.isEmpty &&
        !hasTurnChanges &&
        msg.status != 'WAITING_APPROVAL' &&
        msg.status != 'WAITING_INPUT') {
      return const SizedBox.shrink();
    }

    return Padding(
      padding: const EdgeInsets.only(bottom: 22),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (msg.toolCalls.isNotEmpty) _buildCompactToolCallsBar(context, msg.stepIndex, msg.toolCalls),
          if (msg.thinking.isNotEmpty) ...[
            _buildThinkingFold(context, msg.thinking),
            const SizedBox(height: 10),
          ],
          if (msg.content.isNotEmpty)
            MarkdownMessageBody(
              text: msg.content,
              isDark: isDark,
              resolveMediaUrl: resolveMediaUrl,
              mediaHeaders: mediaHeaders,
              onOpenUrl: onOpenUrl,
              onDownloadPath: (p) => onDownloadFile(p),
              onOpenMediaExternal: onOpenMediaExternal,
            ),
          for (final fPath in FileUtils.extractDownloadableFiles(msg.content))
            _buildDownloadCard(context, fPath),
          if (askQuestions.isNotEmpty)
            _AskQuestionCard(
              questions: askQuestions,
              isDark: isDark,
              onSubmit: onSubmitQuickReply,
            ),
          if (hasTurnChanges)
            Padding(
              padding: const EdgeInsets.only(top: 10),
              child: SessionChangesBar(
                changes: turnChanges!.toChangesData(),
                isDark: isDark,
                badgeText: '本轮修改',
                onOpenReview: () => onOpenTurnReview?.call(),
                onOpenFile: (f) => onOpenTurnFile?.call(f),
              ),
            ),
          if (msg.content.trim().isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  _miniActionButton(
                    icon: Icons.copy_rounded,
                    label: '复制 Markdown',
                    color: isDark ? Colors.white38 : Colors.black45,
                    onTap: () => _copyMessage(context, msg.content),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }

  Widget _miniActionButton({
    required IconData icon,
    required String label,
    required Color color,
    required VoidCallback onTap,
  }) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(4),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 12, color: color),
            const SizedBox(width: 3),
            Text(label, style: TextStyle(fontSize: 10.5, color: color)),
          ],
        ),
      ),
    );
  }

  Widget _buildUserImagePreview(BuildContext context, String rawPath) {
    final url = resolveMediaUrl(rawPath);
    final filename = rawPath.split(RegExp(r'[\\/]')).last;
    return InkWell(
      onTap: () => _openUserImageDialog(context, url, rawPath, filename),
      borderRadius: BorderRadius.circular(8),
      child: Container(
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
          headers: mediaHeaders,
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
                    '图片已上传: $filename',
                    style: const TextStyle(fontSize: 10, color: Colors.white70),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  void _openUserImageDialog(BuildContext context, String imageUrl, String rawPath, String filename) {
    showDialog(
      context: context,
      builder: (ctx) {
        return Dialog(
          backgroundColor: Colors.transparent,
          insetPadding: const EdgeInsets.all(12),
          child: Container(
            constraints: BoxConstraints(
              maxWidth: MediaQuery.of(ctx).size.width * 0.95,
              maxHeight: MediaQuery.of(ctx).size.height * 0.85,
            ),
            decoration: BoxDecoration(
              color: isDark ? const Color(0xFF18181B) : Colors.white,
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: isDark ? const Color(0xFF2C2C32) : const Color(0xFFE4E4E7)),
              boxShadow: const [BoxShadow(color: Colors.black54, blurRadius: 24, spreadRadius: 4)],
            ),
            clipBehavior: Clip.antiAlias,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                  color: isDark ? const Color(0xFF222226) : const Color(0xFFF8F8F9),
                  child: Row(
                    children: [
                      Icon(Icons.image_outlined, size: 16, color: Theme.of(context).colorScheme.primary),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          filename,
                          style: TextStyle(
                            fontSize: 13,
                            fontWeight: FontWeight.bold,
                            color: isDark ? Colors.white : Colors.black87,
                          ),
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      IconButton(
                        tooltip: '在新标签页打开原图',
                        icon: const Icon(Icons.open_in_new_rounded, size: 18),
                        onPressed: () {
                          if (onOpenMediaExternal != null) {
                            onOpenMediaExternal!(rawPath);
                          } else {
                            onDownloadFile(rawPath, filename: filename);
                          }
                        },
                      ),
                      IconButton(
                        tooltip: '关闭',
                        icon: const Icon(Icons.close_rounded, size: 20),
                        onPressed: () => Navigator.of(ctx).pop(),
                      ),
                    ],
                  ),
                ),
                Flexible(
                  child: InteractiveViewer(
                    panEnabled: true,
                    scaleEnabled: true,
                    minScale: 0.8,
                    maxScale: 4.0,
                    child: Center(
                      child: Image.network(imageUrl, headers: mediaHeaders, fit: BoxFit.contain),
                    ),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _buildCompactToolCallsBar(BuildContext context, int stepIndex, List<ToolCallItem> toolCalls) {
    final primary = Theme.of(context).colorScheme.primary;
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Wrap(
        spacing: 6,
        runSpacing: 4,
        children: toolCalls.map((tool) {
          final name = tool.name;
          final args = tool.args;
          var label = name;
          var icon = Icons.settings_suggest_rounded;
          String? editTargetPath;

          if (name == 'edit_file' || name == 'replace_file_content' || name == 'multi_replace_file_content') {
            final p = FileUtils.cleanPath(args['Path'] ?? args['path'] ?? args['TargetFile'] ?? args['target_file']);
            final f = p.isEmpty ? '文件' : p.split(RegExp(r'[\\/]')).last;
            label = 'edit: $f';
            icon = Icons.edit_note_rounded;
            if (p.isNotEmpty) editTargetPath = p;
          } else if (name == 'write_file') {
            final p = FileUtils.cleanPath(args['Path'] ?? args['path']);
            final f = p.isEmpty ? '文件' : p.split(RegExp(r'[\\/]')).last;
            label = 'write: $f';
            icon = Icons.post_add_rounded;
            if (p.isNotEmpty) editTargetPath = p;
          } else if (name == 'read_file') {
            final p = FileUtils.cleanPath(args['Path'] ?? args['path']);
            final f = p.isEmpty ? '文件' : p.split(RegExp(r'[\\/]')).last;
            label = 'read: $f';
            icon = Icons.menu_book_rounded;
          } else if (name == 'run_command') {
            final s = (args['toolSummary'] ?? '').toString();
            label = s.isNotEmpty ? s : 'run_command';
            icon = Icons.terminal_rounded;
          }

          final canOpenDiff = editTargetPath != null && onOpenEditDiff != null;
          final canOpenDetail = !canOpenDiff && onOpenToolDetail != null;
          final isInteractive = canOpenDiff || canOpenDetail;
          final chip = Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3.5),
            decoration: BoxDecoration(
              color: canOpenDiff
                  ? primary.withValues(alpha: isDark ? 0.10 : 0.08)
                  : (isDark ? const Color(0xFF18181B) : const Color(0xFFF4F4F5)),
              borderRadius: BorderRadius.circular(6),
              border: Border.all(
                color: canOpenDiff
                    ? primary.withValues(alpha: 0.35)
                    : (isDark ? const Color(0xFF2C2C32) : const Color(0xFFE4E4E7)),
              ),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  icon,
                  size: 11,
                  color: canOpenDiff
                      ? primary
                      : (canOpenDetail ? (isDark ? Colors.white60 : Colors.black54) : (isDark ? Colors.white38 : Colors.black38)),
                ),
                const SizedBox(width: 4),
                ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 220),
                  child: Text(
                    label,
                    style: TextStyle(
                      fontSize: 10.5,
                      fontFamily: 'monospace',
                      color: isInteractive
                          ? (isDark ? Colors.white : Colors.black87)
                          : (isDark ? Colors.white60 : Colors.black54),
                    ),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                if (canOpenDiff) ...[
                  const SizedBox(width: 4),
                  Icon(Icons.difference_outlined, size: 11, color: primary),
                ] else if (canOpenDetail) ...[
                  const SizedBox(width: 4),
                  Icon(Icons.open_in_new_rounded, size: 10, color: isDark ? Colors.white38 : Colors.black38),
                ],
              ],
            ),
          );

          if (!isInteractive) return chip;
          return InkWell(
            onTap: () {
              if (canOpenDiff) {
                onOpenEditDiff!(editTargetPath!, stepIndex);
              } else if (canOpenDetail) {
                onOpenToolDetail!(stepIndex, tool);
              }
            },
            borderRadius: BorderRadius.circular(4),
            child: chip,
          );
        }).toList(),
      ),
    );
  }

  Widget _buildThinkingFold(BuildContext context, String thinkingText) {
    final preview = thinkingText.trim().split('\n').first;
    final cleanPreview = preview.length > 36 ? '${preview.substring(0, 36)}...' : preview;
    final muted = isDark ? const Color(0xFFA1A1AA) : const Color(0xFF71717A);

    return Container(
      decoration: BoxDecoration(
        color: isDark ? const Color(0xFF18181B) : const Color(0xFFF8F8F9),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(
          color: isDark ? const Color(0xFF2C2C32) : const Color(0xFFE4E4E7),
        ),
      ),
      child: Theme(
        data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
        child: ExpansionTile(
          initiallyExpanded: false,
          tilePadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 0),
          childrenPadding: const EdgeInsets.only(left: 10, right: 10, bottom: 10),
          leading: Icon(Icons.auto_awesome_outlined, color: muted, size: 16),
          title: Text(
            '思考过程 · $cleanPreview',
            style: TextStyle(color: muted, fontSize: 12, fontWeight: FontWeight.w500),
            overflow: TextOverflow.ellipsis,
          ),
          children: [
            SelectableText(
              thinkingText,
              style: TextStyle(
                color: isDark ? const Color(0xFFD4D4D8) : const Color(0xFF3F3F46),
                fontSize: 12.5,
                height: 1.5,
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
      margin: const EdgeInsets.only(top: 10),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: isDark ? const Color(0xFF18181B) : const Color(0xFFF8F8F9),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: isDark ? const Color(0xFF2C2C32) : const Color(0xFFE4E4E7)),
      ),
      child: Row(
        children: [
          Icon(Icons.inventory_2_outlined, size: 20, color: Theme.of(context).colorScheme.primary),
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
            label: const Text('下载', style: TextStyle(fontSize: 12)),
          ),
        ],
      ),
    );
  }
}

class _AskQuestionCard extends StatefulWidget {
  final List<AskQuestionItem> questions;
  final bool isDark;
  final Future<String?> Function(String replyText)? onSubmit;

  const _AskQuestionCard({
    required this.questions,
    required this.isDark,
    this.onSubmit,
  });

  @override
  State<_AskQuestionCard> createState() => _AskQuestionCardState();
}

class _AskQuestionCardState extends State<_AskQuestionCard> {
  final Map<int, Set<String>> _selected = {};
  final TextEditingController _noteCtrl = TextEditingController();
  bool _submitting = false;
  bool _submitted = false;

  @override
  void dispose() {
    _noteCtrl.dispose();
    super.dispose();
  }

  void _toggleOption(int qIdx, String opt, bool multiSelect) {
    if (_submitted) return;
    setState(() {
      final current = Set<String>.from(_selected[qIdx] ?? const <String>{});
      if (multiSelect) {
        if (!current.add(opt)) current.remove(opt);
      } else {
        current
          ..clear()
          ..add(opt);
      }
      _selected[qIdx] = current;
    });
  }

  Future<void> _handleSubmit() async {
    if (widget.onSubmit == null || _submitting) return;
    final buf = StringBuffer('[选择回复]\n');
    for (var i = 0; i < widget.questions.length; i++) {
      final q = widget.questions[i];
      final chosen = _selected[i]?.toList() ?? const [];
      buf.writeln('${i + 1}. ${q.question}');
      buf.writeln('   选择: ${chosen.isEmpty ? "（未选）" : chosen.join("、")}');
    }
    final extra = _noteCtrl.text.trim();
    if (extra.isNotEmpty) {
      buf.writeln('补充说明: $extra');
    }

    setState(() => _submitting = true);
    final err = await widget.onSubmit!(buf.toString().trim());
    if (!mounted) return;
    setState(() {
      _submitting = false;
      if (err == null) {
        _submitted = true;
      }
    });
    if (err != null) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(err), backgroundColor: Colors.redAccent.shade700),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final isDark = widget.isDark;
    final primary = Theme.of(context).colorScheme.primary;
    final hasAnySelection = _selected.values.any((s) => s.isNotEmpty) || _noteCtrl.text.trim().isNotEmpty;

    return Container(
      margin: const EdgeInsets.only(top: 10),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: isDark ? const Color(0xFF0F172A) : const Color(0xFFF8FAFC),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: primary.withValues(alpha: 0.4)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.quiz_outlined, size: 16, color: primary),
              const SizedBox(width: 6),
              Text(
                '请确认选项',
                style: TextStyle(
                  fontSize: 12.5,
                  fontWeight: FontWeight.bold,
                  color: isDark ? Colors.white : Colors.black87,
                ),
              ),
              const Spacer(),
              if (_submitted)
                Text(
                  '已发送',
                  style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold, color: Colors.greenAccent.shade400),
                ),
            ],
          ),
          const SizedBox(height: 8),
          for (var i = 0; i < widget.questions.length; i++) ...[
            Text(
              '${i + 1}. ${widget.questions[i].question}',
              style: TextStyle(
                fontSize: 12.5,
                fontWeight: FontWeight.w600,
                color: isDark ? Colors.white : Colors.black87,
              ),
            ),
            const SizedBox(height: 6),
            for (final opt in widget.questions[i].options)
              Padding(
                padding: const EdgeInsets.only(bottom: 5),
                child: InkWell(
                  onTap: _submitted ? null : () => _toggleOption(i, opt, widget.questions[i].isMultiSelect),
                  borderRadius: BorderRadius.circular(8),
                  child: Container(
                    width: double.infinity,
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
                    decoration: BoxDecoration(
                      color: (_selected[i]?.contains(opt) ?? false)
                          ? primary.withValues(alpha: 0.16)
                          : (isDark ? const Color(0xFF161F30) : Colors.white),
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(
                        color: (_selected[i]?.contains(opt) ?? false)
                            ? primary
                            : (isDark ? Colors.white12 : Colors.black12),
                      ),
                    ),
                    child: Row(
                      children: [
                        Icon(
                          widget.questions[i].isMultiSelect
                              ? ((_selected[i]?.contains(opt) ?? false)
                                  ? Icons.check_box_rounded
                                  : Icons.check_box_outline_blank_rounded)
                              : ((_selected[i]?.contains(opt) ?? false)
                                  ? Icons.radio_button_checked_rounded
                                  : Icons.radio_button_off_rounded),
                          size: 16,
                          color: (_selected[i]?.contains(opt) ?? false)
                              ? primary
                              : (isDark ? Colors.white38 : Colors.black38),
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            opt,
                            style: TextStyle(
                              fontSize: 12,
                              color: isDark ? Colors.white70 : Colors.black87,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            const SizedBox(height: 6),
          ],
          if (!_submitted && widget.onSubmit != null) ...[
            TextField(
              controller: _noteCtrl,
              onChanged: (_) => setState(() {}),
              style: TextStyle(fontSize: 12, color: isDark ? Colors.white : Colors.black87),
              decoration: InputDecoration(
                isDense: true,
                hintText: '可选补充说明或自定义方案...',
                hintStyle: TextStyle(fontSize: 11.5, color: isDark ? Colors.white30 : Colors.black26),
                filled: true,
                fillColor: isDark ? const Color(0xFF161F30) : Colors.white,
                border: OutlineInputBorder(borderRadius: BorderRadius.circular(8), borderSide: BorderSide.none),
              ),
            ),
            const SizedBox(height: 8),
            Align(
              alignment: Alignment.centerRight,
              child: ElevatedButton.icon(
                onPressed: (_submitting || !hasAnySelection) ? null : _handleSubmit,
                icon: _submitting
                    ? const SizedBox(
                        width: 13,
                        height: 13,
                        child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                      )
                    : const Icon(Icons.send_rounded, size: 14),
                label: Text(_submitting ? '提交中' : '提交选择', style: const TextStyle(fontSize: 12)),
                style: ElevatedButton.styleFrom(
                  backgroundColor: primary,
                  foregroundColor: Colors.white,
                  elevation: 0,
                  visualDensity: VisualDensity.compact,
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

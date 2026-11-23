import 'package:flutter/material.dart';

import '../../models/models.dart';

class SessionArtifactsSheet extends StatefulWidget {
  final String sessionTitle;
  final bool isDark;
  final bool canWrite;
  final Future<List<SessionArtifactItem>> Function() onLoadArtifacts;
  final Future<void> Function(SessionArtifactItem item) onPreviewText;
  final void Function(SessionArtifactItem item) onPreviewImage;
  final Future<void> Function(SessionArtifactItem item) onDownload;
  final Future<String?> Function(String prompt) onSendPrompt;

  const SessionArtifactsSheet({
    super.key,
    required this.sessionTitle,
    required this.isDark,
    this.canWrite = true,
    required this.onLoadArtifacts,
    required this.onPreviewText,
    required this.onPreviewImage,
    required this.onDownload,
    required this.onSendPrompt,
  });

  static Future<void> show(
    BuildContext context, {
    required String sessionTitle,
    required bool isDark,
    bool canWrite = true,
    required Future<List<SessionArtifactItem>> Function() onLoadArtifacts,
    required Future<void> Function(SessionArtifactItem item) onPreviewText,
    required void Function(SessionArtifactItem item) onPreviewImage,
    required Future<void> Function(SessionArtifactItem item) onDownload,
    required Future<String?> Function(String prompt) onSendPrompt,
  }) {
    return showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: isDark ? const Color(0xFF0F172A) : Colors.white,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (_) => SessionArtifactsSheet(
        sessionTitle: sessionTitle,
        isDark: isDark,
        canWrite: canWrite,
        onLoadArtifacts: onLoadArtifacts,
        onPreviewText: onPreviewText,
        onPreviewImage: onPreviewImage,
        onDownload: onDownload,
        onSendPrompt: onSendPrompt,
      ),
    );
  }

  @override
  State<SessionArtifactsSheet> createState() => _SessionArtifactsSheetState();
}

class _SessionArtifactsSheetState extends State<SessionArtifactsSheet> {
  List<SessionArtifactItem> _items = const [];
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final list = await widget.onLoadArtifacts();
      if (!mounted) return;
      setState(() {
        _items = list;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = '$e';
        _loading = false;
      });
    }
  }

  Future<void> _sendArtifactReview(SessionArtifactItem item) async {
    final feedback = await showDialog<String>(
      context: context,
      builder: (_) => _ArtifactFeedbackDialog(
        artifactName: item.name,
        isDark: widget.isDark,
      ),
    );
    if (feedback == null || feedback.trim().isEmpty || !mounted) return;
    final err = await widget.onSendPrompt(
      '针对产物 `${item.name}`（`${item.relPath}`）提出修改意见：\n${feedback.trim()}',
    );
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(err ?? '已发送文档修改意见')),
    );
    if (err == null) Navigator.pop(context);
  }

  Future<void> _approvePlan(SessionArtifactItem item) async {
    final err = await widget.onSendPrompt('请按照文档 `${item.name}` 的方案继续执行。');
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(err ?? '已发送批准执行指令')),
    );
    if (err == null) Navigator.pop(context);
  }

  String _formatSize(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  }

  @override
  Widget build(BuildContext context) {
    final isDark = widget.isDark;
    final primary = Theme.of(context).colorScheme.primary;

    return SafeArea(
      child: SizedBox(
        height: MediaQuery.of(context).size.height * 0.8,
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(Icons.auto_awesome_mosaic_outlined, size: 20, color: primary),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          '会话文档与产物 (Artifacts)',
                          style: TextStyle(
                            fontSize: 15,
                            fontWeight: FontWeight.bold,
                            color: isDark ? Colors.white : Colors.black87,
                          ),
                        ),
                        Text(
                          widget.sessionTitle,
                          style: TextStyle(fontSize: 11, color: isDark ? Colors.white54 : Colors.black45),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ],
                    ),
                  ),
                  IconButton(
                    icon: const Icon(Icons.refresh_rounded, size: 18),
                    tooltip: '刷新',
                    onPressed: _load,
                  ),
                  IconButton(
                    icon: const Icon(Icons.close_rounded, size: 20),
                    onPressed: () => Navigator.pop(context),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Divider(color: isDark ? Colors.white12 : Colors.black12, height: 1),
              Expanded(
                child: _loading
                    ? const Center(child: CircularProgressIndicator())
                    : _error != null
                        ? Center(
                            child: Text(
                              '加载失败: $_error',
                              style: TextStyle(color: Colors.redAccent.shade200, fontSize: 12),
                            ),
                          )
                        : _items.isEmpty
                            ? Center(
                                child: Text(
                                  '当前会话暂无生成的方案、脚本或图片产物',
                                  style: TextStyle(
                                    color: isDark ? Colors.white38 : Colors.black38,
                                    fontSize: 12.5,
                                  ),
                                ),
                              )
                            : ListView.separated(
                                padding: const EdgeInsets.symmetric(vertical: 10),
                                itemCount: _items.length,
                                separatorBuilder: (_, __) => const SizedBox(height: 8),
                                itemBuilder: (_, idx) {
                                  final item = _items[idx];
                                  return _buildArtifactCard(item, isDark, primary);
                                },
                              ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildArtifactCard(SessionArtifactItem item, bool isDark, Color primary) {
    final IconData icon = item.isImage
        ? Icons.image_outlined
        : (item.isMarkdown ? Icons.article_outlined : Icons.description_outlined);

    return Container(
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: isDark ? const Color(0xFF161F30) : const Color(0xFFF8FAFC),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: isDark ? const Color(0xFF23324A) : const Color(0xFFE2E8F0)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          InkWell(
            onTap: () {
              if (item.isImage) {
                widget.onPreviewImage(item);
              } else {
                widget.onPreviewText(item);
              }
            },
            child: Row(
              children: [
                Icon(icon, size: 20, color: primary),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        item.name,
                        style: TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                          color: isDark ? Colors.white : Colors.black87,
                        ),
                        overflow: TextOverflow.ellipsis,
                      ),
                      Text(
                        '${_formatSize(item.size)} · ${item.relPath}',
                        style: TextStyle(fontSize: 10.5, color: isDark ? Colors.white38 : Colors.black45),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ],
                  ),
                ),
                IconButton(
                  icon: const Icon(Icons.download_rounded, size: 18),
                  tooltip: '下载',
                  onPressed: () => widget.onDownload(item),
                ),
              ],
            ),
          ),
          if (item.isMarkdown && widget.canWrite) ...[
            const SizedBox(height: 6),
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                TextButton.icon(
                  onPressed: () => _sendArtifactReview(item),
                  icon: const Icon(Icons.rate_review_outlined, size: 14),
                  label: const Text('修改意见', style: TextStyle(fontSize: 11.5)),
                  style: TextButton.styleFrom(visualDensity: VisualDensity.compact),
                ),
                const SizedBox(width: 6),
                ElevatedButton.icon(
                  onPressed: () => _approvePlan(item),
                  icon: const Icon(Icons.play_arrow_rounded, size: 15),
                  label: const Text('批准执行', style: TextStyle(fontSize: 11.5)),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: primary,
                    foregroundColor: Colors.white,
                    elevation: 0,
                    visualDensity: VisualDensity.compact,
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                  ),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }
}

class _ArtifactFeedbackDialog extends StatefulWidget {
  final String artifactName;
  final bool isDark;

  const _ArtifactFeedbackDialog({
    required this.artifactName,
    required this.isDark,
  });

  @override
  State<_ArtifactFeedbackDialog> createState() => _ArtifactFeedbackDialogState();
}

class _ArtifactFeedbackDialogState extends State<_ArtifactFeedbackDialog> {
  final TextEditingController _ctrl = TextEditingController();

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      backgroundColor: widget.isDark ? const Color(0xFF161F30) : Colors.white,
      title: Text(
        '批注 ${widget.artifactName}',
        style: TextStyle(
          fontSize: 15,
          fontWeight: FontWeight.bold,
          color: widget.isDark ? Colors.white : Colors.black87,
        ),
      ),
      content: TextField(
        controller: _ctrl,
        maxLines: 4,
        autofocus: true,
        style: TextStyle(fontSize: 13, color: widget.isDark ? Colors.white : Colors.black87),
        decoration: InputDecoration(
          hintText: '输入希望 Agent 调整的地方...',
          hintStyle: TextStyle(color: widget.isDark ? Colors.white30 : Colors.black26),
          filled: true,
          fillColor: widget.isDark ? const Color(0xFF0F172A) : const Color(0xFFF1F5F9),
          border: OutlineInputBorder(borderRadius: BorderRadius.circular(10), borderSide: BorderSide.none),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('取消'),
        ),
        ElevatedButton(
          onPressed: () => Navigator.pop(context, _ctrl.text),
          child: const Text('发送'),
        ),
      ],
    );
  }
}

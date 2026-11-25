import 'package:flutter/material.dart';

import '../../core/config/offline_outbox_store.dart';

class OfflineOutboxBar extends StatefulWidget {
  final List<OfflineOutboxItem> items;
  final bool isDark;
  final bool isFlushing;
  final VoidCallback onRetryAll;
  final ValueChanged<String> onRetryItem;
  final void Function(String itemId, String newContent) onEditItem;
  final ValueChanged<String> onDeleteItem;
  final VoidCallback onClearAll;

  const OfflineOutboxBar({
    super.key,
    required this.items,
    required this.isDark,
    this.isFlushing = false,
    required this.onRetryAll,
    required this.onRetryItem,
    required this.onEditItem,
    required this.onDeleteItem,
    required this.onClearAll,
  });

  @override
  State<OfflineOutboxBar> createState() => _OfflineOutboxBarState();
}

class _OfflineOutboxBarState extends State<OfflineOutboxBar> {
  bool _expanded = false;

  Future<void> _showEditDialog(OfflineOutboxItem item) async {
    final updated = await showDialog<String>(
      context: context,
      builder: (_) => _OfflineOutboxEditDialog(
        initialContent: item.content,
        isDark: widget.isDark,
      ),
    );
    if (updated != null && updated.isNotEmpty) {
      widget.onEditItem(item.id, updated);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (widget.items.isEmpty) return const SizedBox.shrink();

    final isDark = widget.isDark;
    final accent = isDark ? const Color(0xFFFBBF24) : const Color(0xFFD97706);
    final bgColor = isDark ? const Color(0xFF231D12) : const Color(0xFFFFFBEB);
    final borderColor = accent.withValues(alpha: isDark ? 0.35 : 0.45);
    final first = widget.items.first;
    final preview = first.content.replaceAll('\n', ' ').trim();

    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      decoration: BoxDecoration(
        color: bgColor,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: borderColor, width: 1),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          InkWell(
            borderRadius: BorderRadius.circular(14),
            onTap: () => setState(() => _expanded = !_expanded),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              child: Row(
                children: [
                  Icon(Icons.cloud_off_rounded, size: 15, color: accent),
                  const SizedBox(width: 7),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1.5),
                    decoration: BoxDecoration(
                      color: accent.withValues(alpha: 0.16),
                      borderRadius: BorderRadius.circular(6),
                    ),
                    child: Text(
                      '等待重连 (${widget.items.length})',
                      style: TextStyle(fontSize: 11, fontWeight: FontWeight.w700, color: accent),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      preview,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 12,
                        color: isDark ? Colors.white70 : Colors.black87,
                      ),
                    ),
                  ),
                  const SizedBox(width: 6),
                  TextButton(
                    onPressed: widget.isFlushing ? null : widget.onRetryAll,
                    style: TextButton.styleFrom(
                      visualDensity: VisualDensity.compact,
                      padding: const EdgeInsets.symmetric(horizontal: 8),
                    ),
                    child: Text(
                      widget.isFlushing ? '发送中' : '重试',
                      style: TextStyle(fontSize: 11.5, fontWeight: FontWeight.w600, color: accent),
                    ),
                  ),
                  Icon(
                    _expanded ? Icons.expand_more_rounded : Icons.expand_less_rounded,
                    size: 18,
                    color: isDark ? Colors.white54 : Colors.black45,
                  ),
                ],
              ),
            ),
          ),
          if (_expanded) ...[
            Divider(height: 1, color: borderColor),
            ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 160),
              child: ListView.separated(
                shrinkWrap: true,
                padding: const EdgeInsets.fromLTRB(10, 6, 10, 6),
                itemCount: widget.items.length,
                separatorBuilder: (_, __) => const SizedBox(height: 4),
                itemBuilder: (ctx, idx) {
                  final item = widget.items[idx];
                  return Row(
                    children: [
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              item.content.replaceAll('\n', ' ').trim(),
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                fontSize: 12,
                                color: isDark ? Colors.white : Colors.black87,
                              ),
                            ),
                            if (item.lastError.isNotEmpty)
                              Text(
                                item.lastError,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(fontSize: 10.5, color: Colors.redAccent),
                              ),
                          ],
                        ),
                      ),
                      IconButton(
                        tooltip: '立即重试',
                        visualDensity: VisualDensity.compact,
                        icon: Icon(Icons.send_rounded, size: 15, color: accent),
                        onPressed: widget.isFlushing ? null : () => widget.onRetryItem(item.id),
                      ),
                      IconButton(
                        tooltip: '编辑内容',
                        visualDensity: VisualDensity.compact,
                        icon: Icon(Icons.edit_outlined, size: 15, color: isDark ? Colors.white60 : Colors.black54),
                        onPressed: () => _showEditDialog(item),
                      ),
                      IconButton(
                        tooltip: '撤回删除',
                        visualDensity: VisualDensity.compact,
                        icon: Icon(Icons.close_rounded, size: 15, color: isDark ? Colors.white54 : Colors.black45),
                        onPressed: () => widget.onDeleteItem(item.id),
                      ),
                    ],
                  );
                },
              ),
            ),
            Padding(
              padding: const EdgeInsets.only(right: 10, bottom: 6),
              child: Align(
                alignment: Alignment.centerRight,
                child: TextButton(
                  onPressed: widget.onClearAll,
                  style: TextButton.styleFrom(visualDensity: VisualDensity.compact),
                  child: Text(
                    '清空暂存',
                    style: TextStyle(fontSize: 11, color: isDark ? Colors.white54 : Colors.black54),
                  ),
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _OfflineOutboxEditDialog extends StatefulWidget {
  final String initialContent;
  final bool isDark;

  const _OfflineOutboxEditDialog({
    required this.initialContent,
    required this.isDark,
  });

  @override
  State<_OfflineOutboxEditDialog> createState() => _OfflineOutboxEditDialogState();
}

class _OfflineOutboxEditDialogState extends State<_OfflineOutboxEditDialog> {
  late final TextEditingController _ctrl;

  @override
  void initState() {
    super.initState();
    _ctrl = TextEditingController(text: widget.initialContent);
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      backgroundColor: widget.isDark ? const Color(0xFF222226) : Colors.white,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      title: const Text('编辑离线暂存指令', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
      content: SizedBox(
        width: 360,
        child: TextField(
          controller: _ctrl,
          minLines: 2,
          maxLines: 6,
          autofocus: true,
          style: TextStyle(
            fontSize: 13.5,
            color: widget.isDark ? Colors.white : Colors.black87,
          ),
          decoration: InputDecoration(
            filled: true,
            fillColor: widget.isDark ? const Color(0xFF141418) : const Color(0xFFF5F5F7),
            border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
          ),
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('取消')),
        ElevatedButton(
          onPressed: () {
            final text = _ctrl.text.trim();
            if (text.isEmpty) return;
            Navigator.pop(context, text);
          },
          child: const Text('保存'),
        ),
      ],
    );
  }
}

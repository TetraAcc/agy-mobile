import 'package:flutter/material.dart';

import '../../core/theme/app_colors.dart';
import '../../models/models.dart';

class SessionQueueBar extends StatefulWidget {
  final SessionQueueData queue;
  final bool isDark;
  final bool canWrite;
  final Future<void> Function(bool paused) onTogglePause;
  final Future<void> Function(String itemId, String newContent) onEditItem;
  final Future<void> Function(String itemId) onDeleteItem;
  final Future<void> Function(String itemId) onSendNow;
  final Future<void> Function() onClearAll;

  const SessionQueueBar({
    super.key,
    required this.queue,
    required this.isDark,
    this.canWrite = true,
    required this.onTogglePause,
    required this.onEditItem,
    required this.onDeleteItem,
    required this.onSendNow,
    required this.onClearAll,
  });

  @override
  State<SessionQueueBar> createState() => _SessionQueueBarState();
}

class _SessionQueueBarState extends State<SessionQueueBar> {
  bool _expanded = false;

  Future<void> _openEditDialog(QueuedMessageItem item) async {
    final updated = await showDialog<String>(
      context: context,
      builder: (_) => _EditQueuedMessageDialog(
        initialContent: item.content,
        isDark: widget.isDark,
      ),
    );
    if (updated != null && updated.trim().isNotEmpty) {
      await widget.onEditItem(item.id, updated.trim());
    }
  }

  @override
  Widget build(BuildContext context) {
    final items = widget.queue.items;
    if (items.isEmpty) return const SizedBox.shrink();

    final isDark = widget.isDark;
    final primary = Theme.of(context).colorScheme.primary;
    final paused = widget.queue.paused;
    final hasError = widget.queue.lastError.trim().isNotEmpty;
    final badgeColor = paused
        ? AppColors.statusAmber(isDark)
        : (hasError ? AppColors.statusRed(isDark) : primary);

    return Container(
      margin: const EdgeInsets.only(bottom: 6),
      decoration: BoxDecoration(
        color: isDark ? const Color(0xFF0F172A) : const Color(0xFFF8FAFC),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(
          color: badgeColor.withValues(alpha: 0.45),
        ),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          InkWell(
            onTap: () => setState(() => _expanded = !_expanded),
            borderRadius: BorderRadius.circular(10),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
              child: Row(
                children: [
                  Icon(
                    paused ? Icons.pause_circle_outline_rounded : Icons.queue_rounded,
                    size: 15,
                    color: badgeColor,
                  ),
                  const SizedBox(width: 6),
                  Text(
                    '待发队列 (${items.length})',
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                      color: isDark ? Colors.white : Colors.black87,
                    ),
                  ),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      hasError
                          ? '已暂停：${widget.queue.lastError}'
                          : (paused ? '已暂停自动发送' : '当前回合结束后自动发送'),
                      style: TextStyle(
                        fontSize: 11,
                        color: hasError
                            ? AppColors.statusRed(isDark)
                            : (paused ? AppColors.statusAmber(isDark) : (isDark ? Colors.white54 : Colors.black54)),
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  if (widget.canWrite) ...[
                    TextButton(
                      onPressed: () => widget.onTogglePause(!paused),
                      style: TextButton.styleFrom(
                        visualDensity: VisualDensity.compact,
                        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                        minimumSize: const Size(0, 26),
                      ),
                      child: Text(paused ? '继续' : '暂停', style: const TextStyle(fontSize: 11.5)),
                    ),
                    TextButton(
                      onPressed: widget.onClearAll,
                      style: TextButton.styleFrom(
                        visualDensity: VisualDensity.compact,
                        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                        minimumSize: const Size(0, 26),
                      ),
                      child: Text(
                        '清空',
                        style: TextStyle(fontSize: 11.5, color: AppColors.statusRed(isDark)),
                      ),
                    ),
                  ],
                  Icon(
                    _expanded ? Icons.expand_less_rounded : Icons.expand_more_rounded,
                    size: 18,
                    color: isDark ? Colors.white54 : Colors.black45,
                  ),
                ],
              ),
            ),
          ),
          if (_expanded)
            ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 190),
              child: ListView.separated(
                shrinkWrap: true,
                padding: const EdgeInsets.fromLTRB(10, 2, 10, 8),
                itemCount: items.length,
                separatorBuilder: (_, __) => const SizedBox(height: 6),
                itemBuilder: (_, idx) {
                  final item = items[idx];
                  return Container(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
                    decoration: BoxDecoration(
                      color: isDark ? const Color(0xFF161F30) : Colors.white,
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(color: isDark ? Colors.white12 : Colors.black12),
                    ),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.center,
                      children: [
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1.5),
                          decoration: BoxDecoration(
                            color: primary.withValues(alpha: 0.14),
                            borderRadius: BorderRadius.circular(4),
                          ),
                          child: Text(
                            '#${idx + 1}',
                            style: TextStyle(
                              fontSize: 10.5,
                              fontWeight: FontWeight.bold,
                              color: primary,
                            ),
                          ),
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            item.content,
                            style: TextStyle(
                              fontSize: 12,
                              color: isDark ? Colors.white : Colors.black87,
                            ),
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        if (widget.canWrite) ...[
                          IconButton(
                            tooltip: '立即发送',
                            icon: Icon(Icons.send_rounded, size: 15, color: primary),
                            visualDensity: VisualDensity.compact,
                            padding: EdgeInsets.zero,
                            constraints: const BoxConstraints(minWidth: 28, minHeight: 28),
                            onPressed: () => widget.onSendNow(item.id),
                          ),
                          IconButton(
                            tooltip: '编辑',
                            icon: Icon(Icons.edit_outlined, size: 15, color: isDark ? Colors.white60 : Colors.black54),
                            visualDensity: VisualDensity.compact,
                            padding: EdgeInsets.zero,
                            constraints: const BoxConstraints(minWidth: 28, minHeight: 28),
                            onPressed: () => _openEditDialog(item),
                          ),
                          IconButton(
                            tooltip: '删除',
                            icon: Icon(Icons.delete_outline_rounded, size: 15, color: AppColors.statusRed(isDark)),
                            visualDensity: VisualDensity.compact,
                            padding: EdgeInsets.zero,
                            constraints: const BoxConstraints(minWidth: 28, minHeight: 28),
                            onPressed: () => widget.onDeleteItem(item.id),
                          ),
                        ],
                      ],
                    ),
                  );
                },
              ),
            ),
        ],
      ),
    );
  }
}

class _EditQueuedMessageDialog extends StatefulWidget {
  final String initialContent;
  final bool isDark;

  const _EditQueuedMessageDialog({
    required this.initialContent,
    required this.isDark,
  });

  @override
  State<_EditQueuedMessageDialog> createState() => _EditQueuedMessageDialogState();
}

class _EditQueuedMessageDialogState extends State<_EditQueuedMessageDialog> {
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
      backgroundColor: widget.isDark ? const Color(0xFF161F30) : Colors.white,
      title: Text(
        '编辑队列消息',
        style: TextStyle(
          fontSize: 15,
          fontWeight: FontWeight.bold,
          color: widget.isDark ? Colors.white : Colors.black87,
        ),
      ),
      content: TextField(
        controller: _ctrl,
        maxLines: 5,
        autofocus: true,
        style: TextStyle(fontSize: 13, color: widget.isDark ? Colors.white : Colors.black87),
        decoration: InputDecoration(
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
          child: const Text('保存'),
        ),
      ],
    );
  }
}

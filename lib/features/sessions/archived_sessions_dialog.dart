import 'package:flutter/material.dart';

import '../../core/theme/app_colors.dart';
import '../../models/models.dart';

class ArchivedSessionsDialog extends StatefulWidget {
  final bool isDark;
  final bool canWrite;
  final Future<List<ArchivedSessionItem>> Function() onLoad;
  final Future<String?> Function(ArchivedSessionItem item) onRestore;
  final ValueChanged<ArchivedSessionItem> onOpenSession;

  const ArchivedSessionsDialog({
    super.key,
    required this.isDark,
    required this.canWrite,
    required this.onLoad,
    required this.onRestore,
    required this.onOpenSession,
  });

  @override
  State<ArchivedSessionsDialog> createState() => _ArchivedSessionsDialogState();
}

class _ArchivedSessionsDialogState extends State<ArchivedSessionsDialog> {
  final TextEditingController _searchCtrl = TextEditingController();
  bool _loading = true;
  String? _error;
  List<ArchivedSessionItem> _items = const [];
  String _query = '';
  final Set<String> _restoringIds = {};

  bool get isDark => widget.isDark;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _searchCtrl.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final list = await widget.onLoad();
      if (!mounted) return;
      setState(() {
        _items = list;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = e.toString().replaceFirst('Exception: ', '');
      });
    }
  }

  Future<void> _handleRestore(ArchivedSessionItem item) async {
    if (_restoringIds.contains(item.id)) return;
    setState(() => _restoringIds.add(item.id));
    final err = await widget.onRestore(item);
    if (!mounted) return;
    setState(() => _restoringIds.remove(item.id));

    if (err != null) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(err), backgroundColor: Colors.redAccent.shade700),
      );
      return;
    }

    setState(() {
      _items = _items.where((e) => e.id != item.id).toList();
    });
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('已召回「${item.title}」')),
    );
  }

  @override
  Widget build(BuildContext context) {
    final primary = Theme.of(context).colorScheme.primary;
    final muted = isDark ? AppColors.darkTextSecondary : AppColors.lightTextSecondary;
    final borderColor = isDark ? AppColors.darkBorder : AppColors.lightBorder;
    final q = _query.trim().toLowerCase();
    final filtered = q.isEmpty
        ? _items
        : _items
            .where(
              (item) =>
                  item.title.toLowerCase().contains(q) ||
                  item.projectName.toLowerCase().contains(q),
            )
            .toList();

    return AlertDialog(
      backgroundColor: isDark ? const Color(0xFF1E1E22) : Colors.white,
      insetPadding: const EdgeInsets.symmetric(horizontal: 18, vertical: 20),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      titlePadding: const EdgeInsets.fromLTRB(16, 14, 10, 8),
      contentPadding: const EdgeInsets.fromLTRB(16, 0, 16, 14),
      title: Row(
        children: [
          Icon(Icons.archive_outlined, size: 18, color: primary),
          const SizedBox(width: 8),
          const Expanded(
            child: Text(
              '已归档会话',
              style: TextStyle(fontSize: 15.5, fontWeight: FontWeight.bold),
            ),
          ),
          IconButton(
            tooltip: '刷新已归档列表',
            icon: const Icon(Icons.refresh_rounded, size: 18),
            visualDensity: VisualDensity.compact,
            onPressed: _loading ? null : _load,
          ),
          IconButton(
            tooltip: '关闭',
            icon: const Icon(Icons.close_rounded, size: 18),
            visualDensity: VisualDensity.compact,
            onPressed: () => Navigator.pop(context),
          ),
        ],
      ),
      content: SizedBox(
        width: 480,
        height: 400,
        child: Column(
          children: [
            Container(
              height: 36,
              decoration: BoxDecoration(
                color: isDark ? const Color(0xFF141417) : const Color(0xFFF6F7F9),
                borderRadius: BorderRadius.circular(9),
                border: Border.all(color: borderColor, width: 0.8),
              ),
              child: TextField(
                controller: _searchCtrl,
                onChanged: (val) => setState(() => _query = val),
                style: TextStyle(fontSize: 12.5, color: isDark ? Colors.white : Colors.black87),
                decoration: InputDecoration(
                  hintText: '搜索已归档会话标题或项目...',
                  hintStyle: TextStyle(fontSize: 12, color: muted),
                  prefixIcon: Icon(Icons.search_rounded, size: 16, color: muted),
                  suffixIcon: _query.isNotEmpty
                      ? InkWell(
                          onTap: () {
                            _searchCtrl.clear();
                            setState(() => _query = '');
                          },
                          child: Icon(Icons.clear_rounded, size: 15, color: muted),
                        )
                      : null,
                  border: InputBorder.none,
                  isDense: true,
                  contentPadding: const EdgeInsets.symmetric(vertical: 9),
                ),
              ),
            ),
            const SizedBox(height: 10),
            Expanded(
              child: _loading
                  ? const Center(child: CircularProgressIndicator(strokeWidth: 2))
                  : _error != null
                      ? Center(
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Text(_error!, style: TextStyle(fontSize: 12.5, color: muted), textAlign: TextAlign.center),
                              const SizedBox(height: 10),
                              OutlinedButton(onPressed: _load, child: const Text('重试')),
                            ],
                          ),
                        )
                      : filtered.isEmpty
                          ? Center(
                              child: Text(
                                _items.isEmpty ? '暂无已归档会话' : '未找到匹配的已归档会话',
                                style: TextStyle(fontSize: 12.5, color: muted),
                              ),
                            )
                          : ListView.separated(
                              itemCount: filtered.length,
                              separatorBuilder: (_, __) => const SizedBox(height: 6),
                              itemBuilder: (ctx, idx) {
                                final item = filtered[idx];
                                final busy = _restoringIds.contains(item.id);
                                return Material(
                                  color: isDark ? const Color(0xFF151519) : const Color(0xFFF8F8FA),
                                  borderRadius: BorderRadius.circular(10),
                                  clipBehavior: Clip.antiAlias,
                                  child: InkWell(
                                    onTap: () {
                                      Navigator.pop(context);
                                      widget.onOpenSession(item);
                                    },
                                    child: Container(
                                      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                                      decoration: BoxDecoration(
                                        borderRadius: BorderRadius.circular(10),
                                        border: Border.all(color: borderColor, width: 0.7),
                                      ),
                                      child: Row(
                                        children: [
                                          Expanded(
                                            child: Column(
                                              crossAxisAlignment: CrossAxisAlignment.start,
                                              children: [
                                                Text(
                                                  item.title,
                                                  maxLines: 1,
                                                  overflow: TextOverflow.ellipsis,
                                                  style: TextStyle(
                                                    fontSize: 13,
                                                    fontWeight: FontWeight.w600,
                                                    color: isDark ? Colors.white : Colors.black87,
                                                  ),
                                                ),
                                                if (item.projectName.isNotEmpty || item.updatedAt.isNotEmpty) ...[
                                                  const SizedBox(height: 3),
                                                  Row(
                                                    children: [
                                                      if (item.projectName.isNotEmpty) ...[
                                                        Icon(Icons.folder_outlined, size: 11.5, color: muted),
                                                        const SizedBox(width: 3),
                                                        Flexible(
                                                          child: Text(
                                                            item.projectName,
                                                            maxLines: 1,
                                                            overflow: TextOverflow.ellipsis,
                                                            style: TextStyle(fontSize: 11.5, color: muted),
                                                          ),
                                                        ),
                                                      ],
                                                      if (item.projectName.isNotEmpty && item.updatedAt.isNotEmpty)
                                                        Padding(
                                                          padding: const EdgeInsets.symmetric(horizontal: 4),
                                                          child: Text('·', style: TextStyle(fontSize: 11.5, color: muted)),
                                                        ),
                                                      if (item.updatedAt.isNotEmpty)
                                                        Text(
                                                          item.updatedAt,
                                                          style: TextStyle(fontSize: 11.5, color: muted),
                                                        ),
                                                    ],
                                                  ),
                                                ],
                                              ],
                                            ),
                                          ),
                                          if (widget.canWrite) ...[
                                            const SizedBox(width: 8),
                                            OutlinedButton(
                                              key: ValueKey('restore_archived_${item.id}'),
                                              onPressed: busy ? null : () => _handleRestore(item),
                                              style: OutlinedButton.styleFrom(
                                                foregroundColor: primary,
                                                side: BorderSide(color: primary.withValues(alpha: 0.45)),
                                                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                                                minimumSize: Size.zero,
                                                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                                                textStyle: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
                                                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(7)),
                                              ),
                                              child: Text(busy ? '处理中' : '召回'),
                                            ),
                                          ],
                                        ],
                                      ),
                                    ),
                                  ),
                                );
                              },
                            ),
            ),
          ],
        ),
      ),
    );
  }
}

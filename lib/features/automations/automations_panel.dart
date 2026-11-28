import 'package:flutter/material.dart';

import '../../core/theme/app_colors.dart';
import '../../models/models.dart';

class AutomationFormData {
  final String id;
  final String displayName;
  final String description;
  final String cronExpr;
  final String timezone;
  final String prompt;
  final String workspacePath;

  const AutomationFormData({
    required this.id,
    required this.displayName,
    this.description = '',
    required this.cronExpr,
    this.timezone = 'Asia/Tokyo',
    required this.prompt,
    this.workspacePath = '',
  });
}

class AutomationsPanel extends StatefulWidget {
  final String nodeId;
  final String nodeName;
  final bool isDark;
  final bool canWrite;
  final bool canDelete;
  final Future<AutomationListResponse> Function(String nodeId) onLoad;
  final Future<AutomationItem> Function(String nodeId, String id, bool enabled) onToggle;
  final Future<(bool ok, String sessionId, String message)> Function(String nodeId, String id) onRunNow;
  final Future<AutomationItem> Function(String nodeId, AutomationFormData form) onCreate;
  final Future<AutomationItem> Function(String nodeId, String id, AutomationFormData form) onUpdate;
  final Future<void> Function(String nodeId, String id) onDelete;
  final Future<AutomationLogsResponse> Function(String nodeId, String id) onLoadLogs;
  final void Function(String sessionId, String title) onOpenSession;
  final VoidCallback? onClose;
  final ValueChanged<int>? onCountChanged;

  const AutomationsPanel({
    super.key,
    required this.nodeId,
    required this.nodeName,
    required this.isDark,
    required this.canWrite,
    required this.canDelete,
    required this.onLoad,
    required this.onToggle,
    required this.onRunNow,
    required this.onCreate,
    required this.onUpdate,
    required this.onDelete,
    required this.onLoadLogs,
    required this.onOpenSession,
    this.onClose,
    this.onCountChanged,
  });

  @override
  State<AutomationsPanel> createState() => _AutomationsPanelState();
}

class _AutomationsPanelState extends State<AutomationsPanel> {
  bool _loading = true;
  String? _error;
  List<AutomationItem> _items = const [];
  final Set<String> _expandedHistoryIds = {};
  final Set<String> _expandedLogIds = {};
  final Map<String, List<String>> _logsById = {};
  final Set<String> _loadingLogIds = {};
  final Set<String> _busyIds = {};

  bool get isDark => widget.isDark;

  @override
  void initState() {
    super.initState();
    _loadData();
  }

  @override
  void didUpdateWidget(covariant AutomationsPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.nodeId != widget.nodeId) {
      _expandedHistoryIds.clear();
      _expandedLogIds.clear();
      _logsById.clear();
      _loadData();
    }
  }

  void _notifyCount(List<AutomationItem> items) {
    final enabledCount = items.where((e) => e.enabled).length;
    widget.onCountChanged?.call(enabledCount);
  }

  Future<void> _loadData() async {
    if (widget.nodeId.isEmpty) {
      setState(() {
        _loading = false;
        _items = const [];
        _error = '尚未选择控制节点';
      });
      return;
    }
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final resp = await widget.onLoad(widget.nodeId);
      if (!mounted) return;
      setState(() {
        _items = resp.items;
        _loading = false;
      });
      _notifyCount(resp.items);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = e.toString().replaceFirst('Exception: ', '');
      });
    }
  }

  void _showSnack(String msg, {bool isError = false, SnackBarAction? action}) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(msg),
        backgroundColor: isError ? Colors.redAccent.shade700 : null,
        action: action,
      ),
    );
  }

  Future<void> _handleToggle(AutomationItem item, bool nextVal) async {
    if (_busyIds.contains(item.id)) return;
    setState(() => _busyIds.add(item.id));
    try {
      final updated = await widget.onToggle(widget.nodeId, item.id, nextVal);
      if (!mounted) return;
      setState(() {
        _items = _items.map((e) => e.id == updated.id ? updated : e).toList();
      });
      _notifyCount(_items);
      _showSnack(
        '已将「${updated.displayName}」${updated.enabled ? '启用' : '停用'}（同步写入桌面端 config.json）',
      );
    } catch (e) {
      _showSnack('切换状态失败: $e', isError: true);
    } finally {
      if (mounted) setState(() => _busyIds.remove(item.id));
    }
  }

  Future<void> _handleRunNow(AutomationItem item) async {
    if (_busyIds.contains(item.id)) return;
    setState(() => _busyIds.add(item.id));
    try {
      final (ok, sid, msg) = await widget.onRunNow(widget.nodeId, item.id);
      if (!mounted) return;
      if (!ok || sid.isEmpty) {
        _showSnack(msg.isNotEmpty ? msg : '触发单次运行失败', isError: true);
        return;
      }
      _showSnack(
        '已在 ${widget.nodeName} 发起单次运行',
        action: SnackBarAction(
          label: '打开会话',
          onPressed: () => widget.onOpenSession(sid, item.displayName),
        ),
      );
    } catch (e) {
      _showSnack('触发运行失败: $e', isError: true);
    } finally {
      if (mounted) setState(() => _busyIds.remove(item.id));
    }
  }

  Future<void> _toggleLogs(AutomationItem item) async {
    if (_expandedLogIds.contains(item.id)) {
      setState(() => _expandedLogIds.remove(item.id));
      return;
    }
    setState(() {
      _expandedLogIds.add(item.id);
      _loadingLogIds.add(item.id);
    });
    try {
      final res = await widget.onLoadLogs(widget.nodeId, item.id);
      if (!mounted) return;
      setState(() {
        _logsById[item.id] = res.lines;
      });
    } catch (e) {
      _showSnack('加载调度日志失败: $e', isError: true);
    } finally {
      if (mounted) setState(() => _loadingLogIds.remove(item.id));
    }
  }

  Future<void> _confirmDelete(AutomationItem item) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: isDark ? const Color(0xFF1E1E22) : Colors.white,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
        title: const Text('删除自动化任务？', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
        content: Text(
          '确定要删除「${item.displayName}」(${item.id}) 吗？\n将移除 sidecar.json 并在 config.json 中清理其配置（历史对话仍保留）。',
          style: TextStyle(fontSize: 13, color: isDark ? Colors.white70 : Colors.black87),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: ElevatedButton.styleFrom(
              backgroundColor: Colors.redAccent.shade700,
              foregroundColor: Colors.white,
            ),
            child: const Text('确认删除'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;

    setState(() => _busyIds.add(item.id));
    try {
      await widget.onDelete(widget.nodeId, item.id);
      if (!mounted) return;
      setState(() {
        _items = _items.where((e) => e.id != item.id).toList();
      });
      _notifyCount(_items);
      _showSnack('已删除「${item.displayName}」');
    } catch (e) {
      _showSnack('删除失败: $e', isError: true);
    } finally {
      if (mounted) setState(() => _busyIds.remove(item.id));
    }
  }

  Future<void> _openFormDialog({AutomationItem? existing}) async {
    final saved = await showDialog<AutomationFormData>(
      context: context,
      builder: (ctx) => _AutomationEditDialog(
        isDark: isDark,
        existing: existing,
      ),
    );
    if (saved == null) return;

    try {
      if (existing == null) {
        final created = await widget.onCreate(widget.nodeId, saved);
        if (!mounted) return;
        setState(() => _items = [created, ..._items]);
        _notifyCount(_items);
        _showSnack('已创建自动化「${created.displayName}」');
      } else {
        final updated = await widget.onUpdate(widget.nodeId, existing.id, saved);
        if (!mounted) return;
        setState(() {
          _items = _items.map((e) => e.id == updated.id ? updated : e).toList();
        });
        _notifyCount(_items);
        _showSnack('已更新「${updated.displayName}」（保留既有权限授权）');
      }
    } catch (e) {
      _showSnack('${existing == null ? '创建' : '更新'}失败: $e', isError: true);
    }
  }

  String _formatEventTime(int ms) {
    if (ms <= 0) return '未知时间';
    final dt = DateTime.fromMillisecondsSinceEpoch(ms, isUtc: true).toLocal();
    String two(int n) => n.toString().padLeft(2, '0');
    return '${dt.year}-${two(dt.month)}-${two(dt.day)} ${two(dt.hour)}:${two(dt.minute)}:${two(dt.second)}';
  }

  String _formatShortRunTime(int ms) {
    if (ms <= 0) return '';
    final dt = DateTime.fromMillisecondsSinceEpoch(ms, isUtc: true).toLocal();
    String two(int n) => n.toString().padLeft(2, '0');
    return '${two(dt.month)}-${two(dt.day)} ${two(dt.hour)}:${two(dt.minute)}';
  }

  @override
  Widget build(BuildContext context) {
    final primary = Theme.of(context).colorScheme.primary;
    final cardBg = isDark ? const Color(0xFF18181B) : Colors.white;
    final borderColor = isDark ? AppColors.darkBorder : AppColors.lightBorder;
    final muted = isDark ? AppColors.darkTextSecondary : AppColors.lightTextSecondary;

    return Column(
      children: [
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
          decoration: BoxDecoration(
            color: cardBg,
            border: Border(bottom: BorderSide(color: borderColor, width: 0.6)),
          ),
          child: Row(
            children: [
              if (widget.onClose != null) ...[
                IconButton(
                  tooltip: '返回会话',
                  icon: const Icon(Icons.arrow_back_rounded, size: 19),
                  visualDensity: VisualDensity.compact,
                  onPressed: widget.onClose,
                ),
                const SizedBox(width: 4),
              ],
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Text(
                          'Automations 自动化',
                          style: TextStyle(
                            fontSize: 15,
                            fontWeight: FontWeight.bold,
                            color: isDark ? Colors.white : Colors.black87,
                          ),
                        ),
                        const SizedBox(width: 8),
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
                          decoration: BoxDecoration(
                            color: primary.withValues(alpha: 0.14),
                            borderRadius: BorderRadius.circular(10),
                            border: Border.all(color: primary.withValues(alpha: 0.35), width: 0.8),
                          ),
                          child: Text(
                            widget.nodeName,
                            style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: primary),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 2),
                    Text(
                      '同步自 ~/.gemini/config/sidecars（仅显示定时任务）',
                      style: TextStyle(fontSize: 11.5, color: muted),
                    ),
                  ],
                ),
              ),
              IconButton(
                tooltip: '刷新自动化列表',
                icon: const Icon(Icons.refresh_rounded, size: 19),
                onPressed: _loading ? null : _loadData,
              ),
              if (widget.canWrite) ...[
                const SizedBox(width: 4),
                ElevatedButton.icon(
                  key: const ValueKey('automation_create_btn'),
                  onPressed: () => _openFormDialog(),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: primary,
                    foregroundColor: isDark ? const Color(0xFF0E1117) : Colors.white,
                    elevation: 0,
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                    textStyle: const TextStyle(fontSize: 12, fontWeight: FontWeight.bold),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                  ),
                  icon: const Icon(Icons.add_rounded, size: 16),
                  label: const Text('新建自动化'),
                ),
              ],
            ],
          ),
        ),
        Expanded(
          child: _loading
              ? const Center(child: CircularProgressIndicator())
              : _error != null
                  ? Center(
                      child: Padding(
                        padding: const EdgeInsets.all(24),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(Icons.error_outline_rounded, size: 34, color: AppColors.statusRed(isDark)),
                            const SizedBox(height: 10),
                            Text(
                              _error!,
                              textAlign: TextAlign.center,
                              style: TextStyle(fontSize: 12.5, color: muted),
                            ),
                            const SizedBox(height: 12),
                            OutlinedButton.icon(
                              onPressed: _loadData,
                              icon: const Icon(Icons.refresh_rounded, size: 16),
                              label: const Text('重试'),
                            ),
                          ],
                        ),
                      ),
                    )
                  : _items.isEmpty
                      ? Center(
                          child: Padding(
                            padding: const EdgeInsets.all(24),
                            child: Column(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Icon(Icons.schedule_rounded, size: 36, color: muted.withValues(alpha: 0.5)),
                                const SizedBox(height: 10),
                                Text(
                                  '当前节点暂无原生定时自动化任务',
                                  style: TextStyle(fontSize: 13, color: muted),
                                ),
                                if (widget.canWrite) ...[
                                  const SizedBox(height: 12),
                                  ElevatedButton.icon(
                                    onPressed: () => _openFormDialog(),
                                    icon: const Icon(Icons.add_rounded, size: 16),
                                    label: const Text('创建第一个自动化'),
                                  ),
                                ],
                              ],
                            ),
                          ),
                        )
                      : ListView.separated(
                          padding: const EdgeInsets.all(14),
                          itemCount: _items.length,
                          separatorBuilder: (_, __) => const SizedBox(height: 12),
                          itemBuilder: (ctx, idx) => _buildCard(_items[idx]),
                        ),
        ),
      ],
    );
  }

  Widget _buildCard(AutomationItem item) {
    final primary = Theme.of(context).colorScheme.primary;
    final green = AppColors.statusGreen(isDark);
    final red = AppColors.statusRed(isDark);
    final muted = isDark ? AppColors.darkTextSecondary : AppColors.lightTextSecondary;
    final borderColor = isDark ? AppColors.darkBorder : AppColors.lightBorder;
    final cardBg = isDark ? const Color(0xFF18181B) : Colors.white;
    final isBusy = _busyIds.contains(item.id);
    final histExpanded = _expandedHistoryIds.contains(item.id);
    final logExpanded = _expandedLogIds.contains(item.id);

    return Container(
      key: ValueKey('automation_card_${item.id}'),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: cardBg,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: borderColor, width: 0.8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Wrap(
                      crossAxisAlignment: WrapCrossAlignment.center,
                      spacing: 8,
                      runSpacing: 4,
                      children: [
                        Text(
                          item.displayName,
                          style: TextStyle(
                            fontSize: 14,
                            fontWeight: FontWeight.bold,
                            color: isDark ? Colors.white : Colors.black87,
                          ),
                        ),
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
                          decoration: BoxDecoration(
                            color: (item.enabled ? green : muted).withValues(alpha: 0.14),
                            borderRadius: BorderRadius.circular(10),
                            border: Border.all(
                              color: (item.enabled ? green : muted).withValues(alpha: 0.38),
                              width: 0.8,
                            ),
                          ),
                          child: Text(
                            item.enabled ? '已启用' : '未启用',
                            style: TextStyle(
                              fontSize: 11,
                              fontWeight: FontWeight.w600,
                              color: item.enabled ? green : muted,
                            ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 3),
                    Text(
                      item.id,
                      style: TextStyle(fontSize: 11.5, fontFamily: 'monospace', color: muted),
                    ),
                  ],
                ),
              ),
              if (widget.canWrite)
                Switch(
                  key: ValueKey('automation_toggle_${item.id}'),
                  value: item.enabled,
                  activeThumbColor: primary,
                  onChanged: isBusy ? null : (val) => _handleToggle(item, val),
                ),
            ],
          ),
          if (item.description.isNotEmpty) ...[
            const SizedBox(height: 6),
            Text(
              item.description,
              style: TextStyle(fontSize: 12.5, color: muted, height: 1.4),
            ),
          ],
          const SizedBox(height: 10),
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: [
              _buildChip(
                text: '${item.cadenceLabel}${item.timezone.isNotEmpty ? ' (${item.timezone})' : ''}',
                icon: Icons.schedule_rounded,
                color: primary,
              ),
              if (item.nextRunText.isNotEmpty)
                _buildChip(
                  text: '下次: ${item.nextRunText}',
                  color: isDark ? Colors.white70 : Colors.black87,
                ),
              if (item.lastRunOk != null)
                _buildChip(
                  text:
                      '最近: ${_formatShortRunTime(item.lastRunAtMs)} · ${item.lastRunOk! ? '成功' : '失败'}',
                  color: item.lastRunOk! ? green : red,
                ),
              if (item.workspacePath.isNotEmpty)
                _buildChip(
                  text: '工作区: ${item.workspacePath.split(RegExp(r'[\\/]')).last}',
                  color: muted,
                ),
              if (item.accessGrants.isNotEmpty)
                _buildChip(
                  text: '权限 ×${item.accessGrants.length}',
                  color: muted,
                ),
            ],
          ),
          const SizedBox(height: 10),
          Divider(color: borderColor, height: 1),
          const SizedBox(height: 10),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              if (widget.canWrite)
                ElevatedButton.icon(
                  key: ValueKey('automation_run_${item.id}'),
                  onPressed: isBusy ? null : () => _handleRunNow(item),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: primary,
                    foregroundColor: isDark ? const Color(0xFF0E1117) : Colors.white,
                    elevation: 0,
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
                    textStyle: const TextStyle(fontSize: 12, fontWeight: FontWeight.bold),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                  ),
                  icon: const Icon(Icons.play_arrow_rounded, size: 15),
                  label: const Text('立即运行'),
                ),
              OutlinedButton(
                key: ValueKey('automation_history_btn_${item.id}'),
                onPressed: () {
                  setState(() {
                    if (histExpanded) {
                      _expandedHistoryIds.remove(item.id);
                    } else {
                      _expandedHistoryIds.add(item.id);
                    }
                  });
                },
                style: OutlinedButton.styleFrom(
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
                  textStyle: const TextStyle(fontSize: 12),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                ),
                child: Text('运行历史 (${item.eventCount})'),
              ),
              OutlinedButton(
                key: ValueKey('automation_logs_btn_${item.id}'),
                onPressed: () => _toggleLogs(item),
                style: OutlinedButton.styleFrom(
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
                  textStyle: const TextStyle(fontSize: 12),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                ),
                child: const Text('调度日志'),
              ),
              if (widget.canWrite)
                OutlinedButton(
                  key: ValueKey('automation_edit_btn_${item.id}'),
                  onPressed: isBusy ? null : () => _openFormDialog(existing: item),
                  style: OutlinedButton.styleFrom(
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
                    textStyle: const TextStyle(fontSize: 12),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                  ),
                  child: const Text('编辑'),
                ),
              if (widget.canDelete)
                OutlinedButton(
                  key: ValueKey('automation_delete_btn_${item.id}'),
                  onPressed: isBusy ? null : () => _confirmDelete(item),
                  style: OutlinedButton.styleFrom(
                    foregroundColor: red,
                    side: BorderSide(color: red.withValues(alpha: 0.45)),
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
                    textStyle: const TextStyle(fontSize: 12),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                  ),
                  child: const Text('删除'),
                ),
            ],
          ),
          if (histExpanded) ...[
            const SizedBox(height: 10),
            if (item.recentEvents.isEmpty)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 4),
                child: Text('尚无历史执行记录', style: TextStyle(fontSize: 12, color: muted)),
              )
            else
              Column(
                children: item.recentEvents.map((ev) {
                  return Container(
                    margin: const EdgeInsets.only(top: 6),
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
                    decoration: BoxDecoration(
                      color: isDark ? const Color(0xFF111113) : const Color(0xFFF8F8F9),
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(color: borderColor, width: 0.7),
                    ),
                    child: Row(
                      children: [
                        Container(
                          width: 7,
                          height: 7,
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            color: ev.ok ? green : red,
                          ),
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                _formatEventTime(ev.timestampMs),
                                style: TextStyle(
                                  fontSize: 12,
                                  fontFamily: 'monospace',
                                  color: isDark ? Colors.white70 : Colors.black87,
                                ),
                              ),
                              if (ev.error.isNotEmpty)
                                Text(
                                  ev.error,
                                  maxLines: 2,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(fontSize: 11.5, color: red),
                                ),
                            ],
                          ),
                        ),
                        if (ev.conversationId.isNotEmpty)
                          TextButton(
                            key: ValueKey('automation_open_session_${ev.conversationId}'),
                            onPressed: () => widget.onOpenSession(ev.conversationId, item.displayName),
                            style: TextButton.styleFrom(
                              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                              minimumSize: Size.zero,
                              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                            ),
                            child: Text(
                              '打开会话 →',
                              style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: primary),
                            ),
                          ),
                      ],
                    ),
                  );
                }).toList(),
              ),
          ],
          if (logExpanded) ...[
            const SizedBox(height: 10),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: isDark ? const Color(0xFF111113) : const Color(0xFFF8F8F9),
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: borderColor, width: 0.7),
              ),
              child: _loadingLogIds.contains(item.id)
                  ? const Center(child: Padding(padding: EdgeInsets.all(8), child: CircularProgressIndicator(strokeWidth: 2)))
                  : SelectableText(
                      (_logsById[item.id] ?? const []).isEmpty
                          ? '暂无调度日志'
                          : _logsById[item.id]!.join('\n'),
                      style: TextStyle(fontSize: 11.5, fontFamily: 'monospace', color: muted, height: 1.4),
                    ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildChip({required String text, IconData? icon, required Color color}) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: color.withValues(alpha: 0.28), width: 0.7),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (icon != null) ...[
            Icon(icon, size: 12, color: color),
            const SizedBox(width: 4),
          ],
          Text(
            text,
            style: TextStyle(fontSize: 11.5, fontWeight: FontWeight.w500, color: color),
          ),
        ],
      ),
    );
  }
}

class _AutomationEditDialog extends StatefulWidget {
  final bool isDark;
  final AutomationItem? existing;

  const _AutomationEditDialog({required this.isDark, this.existing});

  @override
  State<_AutomationEditDialog> createState() => _AutomationEditDialogState();
}

enum _CadenceMode { hourly, daily, weekly, custom }

class _AutomationEditDialogState extends State<_AutomationEditDialog> {
  late final TextEditingController _nameCtrl;
  late final TextEditingController _idCtrl;
  late final TextEditingController _descCtrl;
  late final TextEditingController _promptCtrl;
  late final TextEditingController _workspaceCtrl;
  late final TextEditingController _tzCtrl;
  late final TextEditingController _minuteCtrl;
  late final TextEditingController _hourCtrl;
  late final TextEditingController _customCronCtrl;

  _CadenceMode _cadence = _CadenceMode.daily;
  String _weekday = '1';
  bool _idManuallyEdited = false;
  String? _validationError;

  @override
  void initState() {
    super.initState();
    final ex = widget.existing;
    _nameCtrl = TextEditingController(text: ex?.displayName ?? '');
    _idCtrl = TextEditingController(text: ex?.id ?? '');
    _descCtrl = TextEditingController(text: ex?.description ?? '');
    _promptCtrl = TextEditingController(text: ex?.prompt ?? '');
    _workspaceCtrl = TextEditingController(text: ex?.workspacePath ?? '');
    _tzCtrl = TextEditingController(text: (ex?.timezone.isNotEmpty == true) ? ex!.timezone : 'Asia/Tokyo');
    _minuteCtrl = TextEditingController(text: '0');
    _hourCtrl = TextEditingController(text: '9');
    _customCronCtrl = TextEditingController(text: (ex?.cronExpr.isNotEmpty == true) ? ex!.cronExpr : '0 9 * * *');

    if (ex != null && ex.cronExpr.isNotEmpty) {
      _cadence = _CadenceMode.custom;
    }
  }

  @override
  void dispose() {
    _nameCtrl.dispose();
    _idCtrl.dispose();
    _descCtrl.dispose();
    _promptCtrl.dispose();
    _workspaceCtrl.dispose();
    _tzCtrl.dispose();
    _minuteCtrl.dispose();
    _hourCtrl.dispose();
    _customCronCtrl.dispose();
    super.dispose();
  }

  String _computedCron() {
    switch (_cadence) {
      case _CadenceMode.hourly:
        final m = int.tryParse(_minuteCtrl.text.trim()) ?? 0;
        return '${m.clamp(0, 59)} * * * *';
      case _CadenceMode.daily:
        final hrs = _hourCtrl.text.trim().replaceAll(RegExp(r'\s+'), '');
        return '0 ${hrs.isEmpty ? '9' : hrs} * * *';
      case _CadenceMode.weekly:
        final firstHour = _hourCtrl.text.split(',').first.trim();
        return '0 ${firstHour.isEmpty ? '9' : firstHour} * * $_weekday';
      case _CadenceMode.custom:
        return _customCronCtrl.text.trim().split(RegExp(r'\s+')).join(' ');
    }
  }

  void _onNameChanged(String val) {
    if (widget.existing != null || _idManuallyEdited) return;
    final slug = val
        .trim()
        .toLowerCase()
        .replaceAll(RegExp(r'[^a-z0-9_-]+'), '-')
        .replaceAll(RegExp(r'^-+|-+$'), '');
    _idCtrl.text = slug.isEmpty ? 'custom-automation' : slug;
  }

  void _submit() {
    final name = _nameCtrl.text.trim();
    final id = _idCtrl.text.trim();
    final prompt = _promptCtrl.text.trim();
    final cron = _computedCron();
    final tz = _tzCtrl.text.trim().isEmpty ? 'Asia/Tokyo' : _tzCtrl.text.trim();

    if (name.isEmpty || id.isEmpty || prompt.isEmpty) {
      setState(() => _validationError = '请填写任务名称、任务 ID 与执行指令 Prompt');
      return;
    }
    if (cron.split(RegExp(r'\s+')).length != 5) {
      setState(() => _validationError = 'Cron 表达式必须包含 5 个字段（分 时 日 月 周）');
      return;
    }
    Navigator.pop(
      context,
      AutomationFormData(
        id: id,
        displayName: name,
        description: _descCtrl.text.trim(),
        cronExpr: cron,
        timezone: tz,
        prompt: prompt,
        workspacePath: _workspaceCtrl.text.trim(),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final isDark = widget.isDark;
    final primary = Theme.of(context).colorScheme.primary;
    final isEdit = widget.existing != null;
    final cronPreview = 'CRON_TZ=${_tzCtrl.text.trim().isEmpty ? 'Asia/Tokyo' : _tzCtrl.text.trim()} ${_computedCron()}';

    return AlertDialog(
      backgroundColor: isDark ? const Color(0xFF1E1E22) : Colors.white,
      insetPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 20),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      title: Text(
        isEdit ? '编辑自动化：${widget.existing!.displayName}' : '新建自动化任务',
        style: const TextStyle(fontSize: 15.5, fontWeight: FontWeight.bold),
      ),
      content: SizedBox(
        width: 520,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              TextField(
                key: const ValueKey('automation_form_name'),
                controller: _nameCtrl,
                onChanged: _onNameChanged,
                decoration: const InputDecoration(labelText: '任务名称 *', isDense: true),
              ),
              const SizedBox(height: 10),
              TextField(
                key: const ValueKey('automation_form_id'),
                controller: _idCtrl,
                readOnly: isEdit,
                onChanged: (_) => _idManuallyEdited = true,
                decoration: InputDecoration(
                  labelText: '任务 ID (kebab-case) *',
                  helperText: isEdit ? '已有任务 ID 不可修改' : '仅限小写字母、数字、- 和 _',
                  isDense: true,
                ),
              ),
              const SizedBox(height: 10),
              TextField(
                controller: _descCtrl,
                decoration: const InputDecoration(labelText: '简介说明（可选）', isDense: true),
              ),
              const SizedBox(height: 12),
              const Text('调度频率 (Cron)', style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.bold)),
              const SizedBox(height: 6),
              Wrap(
                spacing: 6,
                runSpacing: 6,
                children: [
                  for (final entry in const [
                    (_CadenceMode.hourly, '每小时'),
                    (_CadenceMode.daily, '每天'),
                    (_CadenceMode.weekly, '每周'),
                    (_CadenceMode.custom, '自定义 Cron'),
                  ])
                    ChoiceChip(
                      label: Text(entry.$2, style: const TextStyle(fontSize: 12)),
                      selected: _cadence == entry.$1,
                      onSelected: (_) => setState(() => _cadence = entry.$1),
                    ),
                ],
              ),
              const SizedBox(height: 8),
              if (_cadence == _CadenceMode.hourly)
                TextField(
                  controller: _minuteCtrl,
                  keyboardType: TextInputType.number,
                  onChanged: (_) => setState(() {}),
                  decoration: const InputDecoration(labelText: '每小时第几分钟 (0-59)', isDense: true),
                )
              else if (_cadence == _CadenceMode.daily)
                TextField(
                  controller: _hourCtrl,
                  onChanged: (_) => setState(() {}),
                  decoration: const InputDecoration(labelText: '执行小时（可用逗号分隔多个，如 9,21）', isDense: true),
                )
              else if (_cadence == _CadenceMode.weekly)
                Row(
                  children: [
                    Expanded(
                      child: DropdownButtonFormField<String>(
                        initialValue: _weekday,
                        decoration: const InputDecoration(labelText: '星期', isDense: true),
                        items: const [
                          DropdownMenuItem(value: '1', child: Text('每周一')),
                          DropdownMenuItem(value: '5', child: Text('每周五')),
                          DropdownMenuItem(value: '1-5', child: Text('工作日 (周一至五)')),
                          DropdownMenuItem(value: '0', child: Text('每周日')),
                        ],
                        onChanged: (v) {
                          if (v != null) setState(() => _weekday = v);
                        },
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: TextField(
                        controller: _hourCtrl,
                        onChanged: (_) => setState(() {}),
                        decoration: const InputDecoration(labelText: '小时 (0-23)', isDense: true),
                      ),
                    ),
                  ],
                )
              else
                TextField(
                  controller: _customCronCtrl,
                  onChanged: (_) => setState(() {}),
                  decoration: const InputDecoration(labelText: '5 段 Cron 表达式', isDense: true),
                ),
              const SizedBox(height: 8),
              TextField(
                controller: _tzCtrl,
                onChanged: (_) => setState(() {}),
                decoration: const InputDecoration(labelText: 'IANA 时区', isDense: true),
              ),
              const SizedBox(height: 8),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                decoration: BoxDecoration(
                  color: primary.withValues(alpha: 0.1),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Text(
                  cronPreview,
                  style: TextStyle(fontSize: 12, fontFamily: 'monospace', color: primary),
                ),
              ),
              const SizedBox(height: 10),
              TextField(
                key: const ValueKey('automation_form_prompt'),
                controller: _promptCtrl,
                minLines: 3,
                maxLines: 6,
                decoration: const InputDecoration(
                  labelText: '执行指令 Prompt *',
                  alignLabelWithHint: true,
                ),
              ),
              const SizedBox(height: 10),
              TextField(
                controller: _workspaceCtrl,
                decoration: const InputDecoration(labelText: '关联工作区路径（可选）', isDense: true),
              ),
              if (isEdit) ...[
                const SizedBox(height: 8),
                Text(
                  '说明：保存编辑时会无损保留原有 agent_permissions 授权规则。',
                  style: TextStyle(fontSize: 11.5, color: isDark ? Colors.white54 : Colors.black54),
                ),
              ],
              if (_validationError != null) ...[
                const SizedBox(height: 8),
                Text(
                  _validationError!,
                  style: TextStyle(fontSize: 12, color: AppColors.statusRed(isDark)),
                ),
              ],
            ],
          ),
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('取消')),
        ElevatedButton(
          key: const ValueKey('automation_form_submit'),
          onPressed: _submit,
          style: ElevatedButton.styleFrom(
            backgroundColor: primary,
            foregroundColor: isDark ? const Color(0xFF0E1117) : Colors.white,
          ),
          child: const Text('保存'),
        ),
      ],
    );
  }
}

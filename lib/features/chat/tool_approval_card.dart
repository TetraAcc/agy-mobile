import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/theme/app_colors.dart';
import '../../models/models.dart';

/// Sticky dock displayed above the composer whenever the active session is
/// waiting on one or more interactive tool / permission approvals.
class ToolApprovalDock extends StatefulWidget {
  final List<ToolApprovalItem> approvals;
  final Set<String> resolvingIds;
  final bool canWrite;
  final bool isDark;
  final Future<String?> Function(
    ToolApprovalItem item, {
    required bool allow,
    String scope,
    String denyReason,
    String? editedTarget,
  }) onResolve;

  const ToolApprovalDock({
    super.key,
    required this.approvals,
    required this.resolvingIds,
    required this.canWrite,
    required this.isDark,
    required this.onResolve,
  });

  @override
  State<ToolApprovalDock> createState() => _ToolApprovalDockState();
}

class _ToolApprovalDockState extends State<ToolApprovalDock> {
  String _selectedScope = 'once';
  bool _editingCommand = false;
  bool _showDenyReason = false;
  bool _showMcpArgs = false;
  late TextEditingController _commandCtrl;
  late TextEditingController _denyReasonCtrl;

  ToolApprovalItem? get _current =>
      widget.approvals.isNotEmpty ? widget.approvals.first : null;

  @override
  void initState() {
    super.initState();
    _commandCtrl = TextEditingController(text: _current?.target ?? '');
    _denyReasonCtrl = TextEditingController();
    _syncDefaultsForCurrent();
  }

  @override
  void didUpdateWidget(covariant ToolApprovalDock oldWidget) {
    super.didUpdateWidget(oldWidget);
    final oldId = oldWidget.approvals.isNotEmpty
        ? oldWidget.approvals.first.approvalId
        : null;
    final newId = _current?.approvalId;
    if (oldId != newId) {
      _commandCtrl.text = _current?.target ?? '';
      _denyReasonCtrl.clear();
      _editingCommand = false;
      _showDenyReason = false;
      _showMcpArgs = false;
      _syncDefaultsForCurrent();
    }
  }

  void _syncDefaultsForCurrent() {
    final cur = _current;
    if (cur == null) {
      _selectedScope = 'once';
      return;
    }
    if (!cur.allowedScopes.contains(_selectedScope)) {
      _selectedScope = cur.allowedScopes.contains('once')
          ? 'once'
          : (cur.allowedScopes.isNotEmpty ? cur.allowedScopes.first : 'once');
    }
  }

  @override
  void dispose() {
    _commandCtrl.dispose();
    _denyReasonCtrl.dispose();
    super.dispose();
  }

  static String _scopeLabel(String scope) {
    switch (scope) {
      case 'once':
        return '仅允许此次';
      case 'conversation':
        return '本会话允许';
      case 'workspace':
        return '工作区始终允许';
      case 'project':
        return '本项目允许';
      case 'global':
        return '全局始终允许';
      default:
        return scope;
    }
  }

  static String _allowButtonText(String scope) {
    switch (scope) {
      case 'conversation':
        return '本会话允许';
      case 'workspace':
        return '工作区允许';
      case 'project':
        return '项目允许';
      case 'global':
        return '全局允许';
      default:
        return '允许此次';
    }
  }

  static IconData _categoryIcon(String category) {
    switch (category) {
      case 'command':
        return Icons.terminal_rounded;
      case 'file':
        return Icons.folder_open_rounded;
      case 'mcp':
        return Icons.extension_rounded;
      case 'browser':
        return Icons.public_rounded;
      case 'network':
        return Icons.language_rounded;
      default:
        return Icons.verified_user_outlined;
    }
  }

  Future<void> _submitDecision({required bool allow}) async {
    final item = _current;
    if (item == null || !widget.canWrite) return;
    if (widget.resolvingIds.contains(item.approvalId)) return;

    final edited = (_editingCommand &&
            allow &&
            _commandCtrl.text.trim().isNotEmpty &&
            _commandCtrl.text.trim() != item.target.trim())
        ? _commandCtrl.text.trim()
        : null;
    final denyReason =
        (!allow && _showDenyReason) ? _denyReasonCtrl.text.trim() : '';

    final err = await widget.onResolve(
      item,
      allow: allow,
      scope: allow ? _selectedScope : 'once',
      denyReason: denyReason,
      editedTarget: edited,
    );
    if (!mounted) return;
    if (err != null && err.trim().isNotEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(err),
          backgroundColor: Colors.redAccent.shade700,
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final item = _current;
    if (item == null) return const SizedBox.shrink();

    final isDark = widget.isDark;
    final accent = AppColors.statusAmber(isDark);
    final green = AppColors.statusGreen(isDark);
    final red = AppColors.statusRed(isDark);
    final busy = widget.resolvingIds.contains(item.approvalId);
    final isPermission = item.rawInteractionField == 'permission';
    final mcpArgs = item.detail['arguments_json']?.toString().trim() ?? '';

    final maxCardHeight = (MediaQuery.sizeOf(context).height * 0.42).clamp(140.0, 380.0);

    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      decoration: BoxDecoration(
        color: isDark ? const Color(0xFF1C170F) : const Color(0xFFFFFBF0),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(
          color: accent.withValues(alpha: isDark ? 0.52 : 0.65),
          width: 1.2,
        ),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: isDark ? 0.28 : 0.06),
            blurRadius: 10,
            offset: const Offset(0, 3),
          ),
        ],
      ),
      child: ConstrainedBox(
        constraints: BoxConstraints(maxHeight: maxCardHeight),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              // Pinned Header
              Row(
                children: [
                  Container(
                    width: 24,
                    height: 24,
                    decoration: BoxDecoration(
                      color: accent.withValues(alpha: 0.16),
                      borderRadius: BorderRadius.circular(7),
                    ),
                    child: Icon(_categoryIcon(item.category), size: 14, color: accent),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Wrap(
                      crossAxisAlignment: WrapCrossAlignment.center,
                      spacing: 6,
                      runSpacing: 4,
                      children: [
                        Text(
                          item.title,
                          style: TextStyle(
                            fontSize: 12.5,
                            fontWeight: FontWeight.w700,
                            color: isDark ? Colors.white : const Color(0xFF18181B),
                          ),
                        ),
                        if (widget.approvals.length > 1)
                          Container(
                            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
                            decoration: BoxDecoration(
                              color: accent.withValues(alpha: 0.18),
                              borderRadius: BorderRadius.circular(99),
                            ),
                            child: Text(
                              '队列 1/${widget.approvals.length}',
                              style: TextStyle(
                                fontSize: 10.5,
                                fontWeight: FontWeight.w700,
                                color: accent,
                              ),
                            ),
                          ),
                        if (item.actionLabel.isNotEmpty && item.actionLabel != item.title)
                          Container(
                            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
                            decoration: BoxDecoration(
                              color: isDark ? Colors.white10 : Colors.black.withValues(alpha: 0.05),
                              borderRadius: BorderRadius.circular(5),
                            ),
                            child: Text(
                              item.actionLabel,
                              style: TextStyle(
                                fontSize: 10.5,
                                color: isDark ? Colors.white70 : Colors.black54,
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),
                  if (item.target.isNotEmpty)
                    IconButton(
                      tooltip: '复制目标内容',
                      visualDensity: VisualDensity.compact,
                      constraints: const BoxConstraints(minWidth: 28, minHeight: 28),
                      padding: EdgeInsets.zero,
                      icon: Icon(
                        Icons.copy_rounded,
                        size: 14,
                        color: isDark ? Colors.white54 : Colors.black45,
                      ),
                      onPressed: () {
                        Clipboard.setData(ClipboardData(text: item.target));
                        ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(
                            content: Text('已复制审批目标内容'),
                            duration: Duration(seconds: 1),
                          ),
                        );
                      },
                    ),
                ],
              ),

              Flexible(
                fit: FlexFit.loose,
                child: SingleChildScrollView(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (item.reason.isNotEmpty) ...[
                        const SizedBox(height: 6),
                        Text(
                          item.reason,
                          style: TextStyle(
                            fontSize: 11.5,
                            height: 1.4,
                            color: accent,
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                      ],

                      if (item.cwd.isNotEmpty || item.shellName.isNotEmpty) ...[
                        const SizedBox(height: 5),
                        Wrap(
                          spacing: 6,
                          runSpacing: 4,
                          children: [
                            if (item.shellName.isNotEmpty)
                              _MetaPill(text: item.shellName, isDark: isDark),
                            if (item.cwd.isNotEmpty)
                              _MetaPill(text: '工作目录: ${item.cwd}', isDark: isDark),
                          ],
                        ),
                      ],

                      if (item.target.isNotEmpty || _editingCommand) ...[
                        const SizedBox(height: 7),
                        if (_editingCommand && item.editableCommand)
                          TextField(
                            controller: _commandCtrl,
                            enabled: !busy && widget.canWrite,
                            maxLines: 3,
                            minLines: 1,
                            style: TextStyle(
                              fontFamily: 'monospace',
                              fontSize: 12,
                              color: isDark ? Colors.white : Colors.black87,
                            ),
                            decoration: InputDecoration(
                              isDense: true,
                              labelText: '编辑后执行命令',
                              labelStyle: TextStyle(fontSize: 11, color: accent),
                              filled: true,
                              fillColor: isDark ? const Color(0xFF111114) : Colors.white,
                              border: OutlineInputBorder(
                                borderRadius: BorderRadius.circular(8),
                                borderSide: BorderSide(color: accent.withValues(alpha: 0.45)),
                              ),
                            ),
                          )
                        else
                          Container(
                            width: double.infinity,
                            constraints: const BoxConstraints(maxHeight: 110),
                            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                            decoration: BoxDecoration(
                              color: isDark ? const Color(0xFF111114) : const Color(0xFFF4F4F5),
                              borderRadius: BorderRadius.circular(8),
                              border: Border.all(
                                color: isDark ? const Color(0xFF2B2B32) : const Color(0xFFE4E4E7),
                              ),
                            ),
                            child: SingleChildScrollView(
                              child: SelectableText(
                                item.target,
                                style: TextStyle(
                                  fontFamily: 'monospace',
                                  fontSize: 12,
                                  height: 1.4,
                                  color: isDark ? const Color(0xFFF4F4F5) : const Color(0xFF18181B),
                                ),
                              ),
                            ),
                          ),
                      ],

                      if (mcpArgs.isNotEmpty && mcpArgs != '{}') ...[
                        const SizedBox(height: 5),
                        InkWell(
                          borderRadius: BorderRadius.circular(6),
                          onTap: () => setState(() => _showMcpArgs = !_showMcpArgs),
                          child: Padding(
                            padding: const EdgeInsets.symmetric(vertical: 2),
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Icon(
                                  _showMcpArgs ? Icons.expand_less_rounded : Icons.expand_more_rounded,
                                  size: 14,
                                  color: isDark ? Colors.white54 : Colors.black45,
                                ),
                                const SizedBox(width: 4),
                                Text(
                                  _showMcpArgs ? '收起参数明细' : '查看工具参数',
                                  style: TextStyle(
                                    fontSize: 11,
                                    color: isDark ? Colors.white60 : Colors.black54,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                        if (_showMcpArgs)
                          Container(
                            width: double.infinity,
                            constraints: const BoxConstraints(maxHeight: 84),
                            margin: const EdgeInsets.only(top: 4),
                            padding: const EdgeInsets.all(8),
                            decoration: BoxDecoration(
                              color: isDark ? const Color(0xFF111114) : Colors.white,
                              borderRadius: BorderRadius.circular(7),
                              border: Border.all(
                                color: isDark ? const Color(0xFF2B2B32) : const Color(0xFFE4E4E7),
                              ),
                            ),
                            child: SingleChildScrollView(
                              child: SelectableText(
                                mcpArgs,
                                style: TextStyle(
                                  fontFamily: 'monospace',
                                  fontSize: 11,
                                  color: isDark ? Colors.white70 : Colors.black87,
                                ),
                              ),
                            ),
                          ),
                      ],

                      if (widget.canWrite && item.canRemember && item.allowedScopes.length > 1) ...[
                        const SizedBox(height: 8),
                        Wrap(
                          spacing: 6,
                          runSpacing: 4,
                          crossAxisAlignment: WrapCrossAlignment.center,
                          children: [
                            Text(
                              '授权范围：',
                              style: TextStyle(
                                fontSize: 11,
                                color: isDark ? Colors.white54 : Colors.black54,
                              ),
                            ),
                            for (final sc in item.allowedScopes)
                              ChoiceChip(
                                label: Text(
                                  _scopeLabel(sc),
                                  style: TextStyle(
                                    fontSize: 11,
                                    fontWeight:
                                        _selectedScope == sc ? FontWeight.w600 : FontWeight.w400,
                                  ),
                                ),
                                selected: _selectedScope == sc,
                                visualDensity: VisualDensity.compact,
                                materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                                padding: const EdgeInsets.symmetric(horizontal: 4),
                                onSelected: busy
                                    ? null
                                    : (selected) {
                                        if (selected) setState(() => _selectedScope = sc);
                                      },
                              ),
                          ],
                        ),
                        if (_selectedScope != 'once' && item.suggestedPersistPattern.isNotEmpty)
                          Padding(
                            padding: const EdgeInsets.only(top: 4),
                            child: Text(
                              '将记住规则：${item.suggestedPersistPattern}',
                              style: TextStyle(
                                fontFamily: 'monospace',
                                fontSize: 10.5,
                                color: isDark ? Colors.white54 : Colors.black54,
                              ),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                      ],

                      if (_showDenyReason && isPermission && widget.canWrite) ...[
                        const SizedBox(height: 8),
                        TextField(
                          controller: _denyReasonCtrl,
                          enabled: !busy,
                          style: TextStyle(
                            fontSize: 12,
                            color: isDark ? Colors.white : Colors.black87,
                          ),
                          decoration: InputDecoration(
                            isDense: true,
                            hintText: '可选：告诉 Agent 拒绝原因或替代方案...',
                            hintStyle: TextStyle(
                              fontSize: 11.5,
                              color: isDark ? Colors.white30 : Colors.black38,
                            ),
                            filled: true,
                            fillColor: isDark ? const Color(0xFF111114) : Colors.white,
                            border: OutlineInputBorder(
                              borderRadius: BorderRadius.circular(8),
                              borderSide: BorderSide(color: red.withValues(alpha: 0.4)),
                            ),
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
              ),

              const SizedBox(height: 9),

              // Pinned Action Bar — always visible regardless of scrollable body height
              if (!widget.canWrite)
                Row(
                  children: [
                    Icon(Icons.lock_outline_rounded, size: 14, color: accent),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(
                        '当前账号为只读权限，无权远程审批此操作。',
                        style: TextStyle(
                          fontSize: 11.5,
                          color: isDark ? Colors.white60 : Colors.black54,
                        ),
                      ),
                    ),
                  ],
                )
              else
                Row(
                  children: [
                    if (item.editableCommand)
                      IconButton(
                        tooltip: _editingCommand ? '取消编辑命令' : '编辑命令后再允许',
                        visualDensity: VisualDensity.compact,
                        constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
                        padding: EdgeInsets.zero,
                        icon: Icon(
                          _editingCommand ? Icons.edit_off_outlined : Icons.edit_outlined,
                          size: 16,
                          color: _editingCommand
                              ? accent
                              : (isDark ? Colors.white54 : Colors.black54),
                        ),
                        onPressed: busy
                            ? null
                            : () => setState(() => _editingCommand = !_editingCommand),
                      ),
                    if (isPermission)
                      IconButton(
                        tooltip: _showDenyReason ? '隐藏拒绝附言' : '添加拒绝附言',
                        visualDensity: VisualDensity.compact,
                        constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
                        padding: EdgeInsets.zero,
                        icon: Icon(
                          Icons.rate_review_outlined,
                          size: 16,
                          color: _showDenyReason
                              ? red
                              : (isDark ? Colors.white54 : Colors.black54),
                        ),
                        onPressed: busy
                            ? null
                            : () => setState(() => _showDenyReason = !_showDenyReason),
                      ),
                    const Spacer(),
                    OutlinedButton.icon(
                      onPressed: busy ? null : () => _submitDecision(allow: false),
                      style: OutlinedButton.styleFrom(
                        foregroundColor: red,
                        side: BorderSide(color: red.withValues(alpha: 0.55)),
                        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                        minimumSize: const Size(0, 32),
                        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                      ),
                      icon: const Icon(Icons.close_rounded, size: 15),
                      label: const Text(
                        '拒绝',
                        style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
                      ),
                    ),
                    const SizedBox(width: 8),
                    FilledButton.icon(
                      onPressed: busy ? null : () => _submitDecision(allow: true),
                      style: FilledButton.styleFrom(
                        backgroundColor: green,
                        foregroundColor: Colors.white,
                        padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 6),
                        minimumSize: const Size(0, 32),
                        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                      ),
                      icon: busy
                          ? const SizedBox(
                              width: 13,
                              height: 13,
                              child: CircularProgressIndicator(
                                strokeWidth: 2,
                                color: Colors.white,
                              ),
                            )
                          : const Icon(Icons.check_rounded, size: 15),
                      label: Text(
                        busy ? '提交中' : _allowButtonText(_selectedScope),
                        style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
                      ),
                    ),
                  ],
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _MetaPill extends StatelessWidget {
  final String text;
  final bool isDark;

  const _MetaPill({required this.text, required this.isDark});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: isDark ? Colors.white.withValues(alpha: 0.06) : Colors.black.withValues(alpha: 0.05),
        borderRadius: BorderRadius.circular(5),
      ),
      child: Text(
        text,
        style: TextStyle(
          fontFamily: 'monospace',
          fontSize: 10.5,
          color: isDark ? Colors.white60 : Colors.black54,
        ),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
    );
  }
}

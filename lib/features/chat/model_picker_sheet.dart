import 'package:flutter/material.dart';

import '../../core/config/responsive_layout.dart';
import '../../core/theme/app_colors.dart';
import '../../models/models.dart';

class ModelPickerSheet extends StatefulWidget {
  final bool isDark;
  final List<OfficialModelOption> models;
  final String activeModel;
  final String pendingModel;
  final ValueChanged<String?> onSelectModel;

  const ModelPickerSheet({
    super.key,
    required this.isDark,
    required this.models,
    required this.activeModel,
    required this.pendingModel,
    required this.onSelectModel,
  });

  static Future<void> show(
    BuildContext context, {
    required bool isDark,
    required List<OfficialModelOption> models,
    required String activeModel,
    required String pendingModel,
    required ValueChanged<String?> onSelectModel,
  }) {
    return showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (ctx) => ModelPickerSheet(
        isDark: isDark,
        models: models,
        activeModel: activeModel,
        pendingModel: pendingModel,
        onSelectModel: onSelectModel,
      ),
    );
  }

  @override
  State<ModelPickerSheet> createState() => _ModelPickerSheetState();
}

class _ModelPickerSheetState extends State<ModelPickerSheet> {
  final TextEditingController _searchController = TextEditingController();
  String _query = '';

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  Color _quotaColor(double frac) {
    if (frac >= 0.5) return AppColors.statusGreen(widget.isDark);
    if (frac >= 0.15) return AppColors.statusAmber(widget.isDark);
    return AppColors.statusRed(widget.isDark);
  }

  Future<void> _openCustomModelDialog() async {
    final result = await showDialog<String>(
      context: context,
      builder: (_) => _CustomModelIdDialog(
        isDark: widget.isDark,
        initialValue: widget.pendingModel.isNotEmpty ? widget.pendingModel : widget.activeModel,
      ),
    );
    if (!mounted || result == null || result.trim().isEmpty) return;
    widget.onSelectModel(result.trim());
    Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final isDark = widget.isDark;
    final primary = Theme.of(context).colorScheme.primary;
    final maxWidth = ResponsiveLayout.compactSheetConstraints(context).maxWidth;
    final bottomInset = MediaQuery.of(context).viewInsets.bottom;

    final query = _query.trim().toLowerCase();
    final filtered = widget.models.where((m) {
      if (query.isEmpty) return true;
      return m.displayName.toLowerCase().contains(query) ||
          m.id.toLowerCase().contains(query) ||
          m.group.toLowerCase().contains(query) ||
          m.thinkingBadge.toLowerCase().contains(query);
    }).toList();

    final grouped = <String, List<OfficialModelOption>>{};
    const preferredOrder = ['Gemini', 'Claude', 'Orchestrator', 'GPT', 'Other'];
    for (final m in filtered) {
      final grp = m.group.isNotEmpty ? m.group : 'Other';
      grouped.putIfAbsent(grp, () => <OfficialModelOption>[]).add(m);
    }
    final orderedGroups = grouped.keys.toList()
      ..sort((a, b) {
        final ia = preferredOrder.indexOf(a);
        final ib = preferredOrder.indexOf(b);
        final ra = ia >= 0 ? ia : preferredOrder.length;
        final rb = ib >= 0 ? ib : preferredOrder.length;
        return ra != rb ? ra.compareTo(rb) : a.compareTo(b);
      });

    final activeDisplay = widget.activeModel.isNotEmpty
        ? formatModelDisplayName(widget.activeModel, widget.models)
        : '跟随默认模型';
    final hasPendingSwitch =
        widget.pendingModel.isNotEmpty && widget.pendingModel != widget.activeModel;

    return Padding(
      padding: EdgeInsets.only(bottom: bottomInset),
      child: Center(
        heightFactor: 1,
        child: ConstrainedBox(
          constraints: BoxConstraints(
            maxWidth: maxWidth,
            maxHeight: MediaQuery.of(context).size.height * 0.82,
          ),
          child: Container(
            decoration: BoxDecoration(
              color: isDark ? AppColors.darkCard : Colors.white,
              borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
              border: Border.all(
                color: isDark ? AppColors.darkBorder : AppColors.lightBorder,
              ),
            ),
            child: SafeArea(
              top: false,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const SizedBox(height: 8),
                  Container(
                    width: 36,
                    height: 4,
                    decoration: BoxDecoration(
                      color: isDark ? Colors.white24 : Colors.black12,
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 12, 12, 8),
                    child: Row(
                      children: [
                        Icon(Icons.auto_awesome_rounded, size: 18, color: primary),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                '切换当前会话模型',
                                style: TextStyle(
                                  fontSize: 15,
                                  fontWeight: FontWeight.w700,
                                  color: isDark ? Colors.white : const Color(0xFF18181B),
                                ),
                              ),
                              const SizedBox(height: 2),
                              Text(
                                '当前会话：$activeDisplay · 切换后从下一条消息生效',
                                style: TextStyle(
                                  fontSize: 11.5,
                                  color: isDark ? Colors.white54 : Colors.black54,
                                ),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ],
                          ),
                        ),
                        TextButton.icon(
                          onPressed: _openCustomModelDialog,
                          icon: const Icon(Icons.edit_rounded, size: 14),
                          label: const Text('自定义', style: TextStyle(fontSize: 12)),
                          style: TextButton.styleFrom(
                            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                            minimumSize: Size.zero,
                            tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                          ),
                        ),
                      ],
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 0, 16, 10),
                    child: TextField(
                      controller: _searchController,
                      onChanged: (v) => setState(() => _query = v),
                      style: TextStyle(
                        fontSize: 13.5,
                        color: isDark ? Colors.white : const Color(0xFF18181B),
                      ),
                      decoration: InputDecoration(
                        isDense: true,
                        hintText: '搜索模型名或 ID（如 neon / claude / low）...',
                        hintStyle: TextStyle(
                          fontSize: 13,
                          color: isDark ? Colors.white38 : Colors.black38,
                        ),
                        prefixIcon: Icon(
                          Icons.search_rounded,
                          size: 18,
                          color: isDark ? Colors.white38 : Colors.black38,
                        ),
                        suffixIcon: _query.isNotEmpty
                            ? IconButton(
                                icon: const Icon(Icons.close_rounded, size: 16),
                                onPressed: () {
                                  _searchController.clear();
                                  setState(() => _query = '');
                                },
                              )
                            : null,
                        filled: true,
                        fillColor: isDark ? AppColors.darkBg : AppColors.lightBg,
                        contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(10),
                          borderSide: BorderSide(
                            color: isDark ? AppColors.darkBorder : AppColors.lightBorder,
                          ),
                        ),
                        enabledBorder: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(10),
                          borderSide: BorderSide(
                            color: isDark ? AppColors.darkBorder : AppColors.lightBorder,
                          ),
                        ),
                      ),
                    ),
                  ),
                  if (hasPendingSwitch)
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                      child: InkWell(
                        borderRadius: BorderRadius.circular(10),
                        onTap: () {
                          widget.onSelectModel(null);
                          Navigator.of(context).pop();
                        },
                        child: Container(
                          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
                          decoration: BoxDecoration(
                            color: primary.withValues(alpha: isDark ? 0.14 : 0.08),
                            borderRadius: BorderRadius.circular(10),
                            border: Border.all(color: primary.withValues(alpha: 0.35)),
                          ),
                          child: Row(
                            children: [
                              Icon(Icons.undo_rounded, size: 16, color: primary),
                              const SizedBox(width: 8),
                              Expanded(
                                child: Text(
                                  '取消待切换，恢复沿用当前会话模型 ($activeDisplay)',
                                  style: TextStyle(
                                    fontSize: 12,
                                    fontWeight: FontWeight.w600,
                                    color: primary,
                                  ),
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  Flexible(
                    child: orderedGroups.isEmpty
                        ? Padding(
                            padding: const EdgeInsets.symmetric(vertical: 28),
                            child: Text(
                              '未找到匹配的模型，可点击右上角「自定义」直接输入模型 ID',
                              style: TextStyle(
                                fontSize: 12.5,
                                color: isDark ? Colors.white54 : Colors.black45,
                              ),
                            ),
                          )
                        : ListView(
                            shrinkWrap: true,
                            padding: const EdgeInsets.fromLTRB(12, 0, 12, 14),
                            children: [
                              for (final grp in orderedGroups) ...[
                                Padding(
                                  padding: const EdgeInsets.fromLTRB(6, 10, 6, 4),
                                  child: Text(
                                    grp,
                                    style: TextStyle(
                                      fontSize: 11,
                                      fontWeight: FontWeight.w700,
                                      letterSpacing: 0.4,
                                      color: isDark ? Colors.white54 : Colors.black45,
                                    ),
                                  ),
                                ),
                                for (final m in grouped[grp]!)
                                  _buildModelTile(
                                    context,
                                    m,
                                    isCurrent: widget.activeModel == m.id,
                                    isSelected: (widget.pendingModel.isNotEmpty
                                            ? widget.pendingModel
                                            : widget.activeModel) ==
                                        m.id,
                                  ),
                              ],
                            ],
                          ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildModelTile(
    BuildContext context,
    OfficialModelOption model, {
    required bool isCurrent,
    required bool isSelected,
  }) {
    final isDark = widget.isDark;
    final primary = Theme.of(context).colorScheme.primary;
    final rem = model.remainingFraction;

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: InkWell(
        borderRadius: BorderRadius.circular(10),
        onTap: () {
          widget.onSelectModel(isCurrent ? null : model.id);
          Navigator.of(context).pop();
        },
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 9),
          decoration: BoxDecoration(
            color: isSelected
                ? primary.withValues(alpha: isDark ? 0.14 : 0.08)
                : Colors.transparent,
            borderRadius: BorderRadius.circular(10),
            border: Border.all(
              color: isSelected
                  ? primary.withValues(alpha: 0.45)
                  : Colors.transparent,
            ),
          ),
          child: Row(
            children: [
              Text(model.icon, style: const TextStyle(fontSize: 14)),
              const SizedBox(width: 9),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Flexible(
                          child: Text(
                            model.displayName,
                            style: TextStyle(
                              fontSize: 13.5,
                              fontWeight: isSelected ? FontWeight.w700 : FontWeight.w500,
                              color: isDark ? Colors.white : const Color(0xFF18181B),
                            ),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        if (model.thinkingBadge.isNotEmpty) ...[
                          const SizedBox(width: 6),
                          Container(
                            padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
                            decoration: BoxDecoration(
                              color: isDark
                                  ? Colors.white.withValues(alpha: 0.08)
                                  : Colors.black.withValues(alpha: 0.06),
                              borderRadius: BorderRadius.circular(4),
                            ),
                            child: Text(
                              model.thinkingBadge,
                              style: TextStyle(
                                fontSize: 9.5,
                                color: isDark ? Colors.white60 : Colors.black54,
                              ),
                            ),
                          ),
                        ],
                        if (isCurrent) ...[
                          const SizedBox(width: 6),
                          Container(
                            padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
                            decoration: BoxDecoration(
                              color: primary.withValues(alpha: 0.16),
                              borderRadius: BorderRadius.circular(4),
                            ),
                            child: Text(
                              '当前',
                              style: TextStyle(
                                fontSize: 9.5,
                                fontWeight: FontWeight.w600,
                                color: primary,
                              ),
                            ),
                          ),
                        ],
                      ],
                    ),
                    const SizedBox(height: 1.5),
                    Text(
                      model.id,
                      style: TextStyle(
                        fontSize: 10.5,
                        fontFamily: 'monospace',
                        color: isDark ? Colors.white38 : Colors.black45,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                ),
              ),
              if (rem != null) ...[
                const SizedBox(width: 8),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                  decoration: BoxDecoration(
                    color: _quotaColor(rem).withValues(alpha: isDark ? 0.16 : 0.12),
                    borderRadius: BorderRadius.circular(6),
                  ),
                  child: Text(
                    '${(rem * 100).round()}%',
                    style: TextStyle(
                      fontSize: 10.5,
                      fontWeight: FontWeight.w600,
                      color: _quotaColor(rem),
                    ),
                  ),
                ),
              ],
              if (isSelected) ...[
                const SizedBox(width: 6),
                Icon(Icons.check_rounded, size: 17, color: primary),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class _CustomModelIdDialog extends StatefulWidget {
  final bool isDark;
  final String initialValue;

  const _CustomModelIdDialog({
    required this.isDark,
    required this.initialValue,
  });

  @override
  State<_CustomModelIdDialog> createState() => _CustomModelIdDialogState();
}

class _CustomModelIdDialogState extends State<_CustomModelIdDialog> {
  late final TextEditingController _controller;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: widget.initialValue);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final isDark = widget.isDark;
    return AlertDialog(
      backgroundColor: isDark ? AppColors.darkCard : Colors.white,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
      title: const Text('输入自定义模型 ID', style: TextStyle(fontSize: 15, fontWeight: FontWeight.w700)),
      content: TextField(
        controller: _controller,
        autofocus: true,
        style: const TextStyle(fontSize: 13.5, fontFamily: 'monospace'),
        decoration: const InputDecoration(
          hintText: '如 gemini-4-neon-high 或 claude-sonnet-5-5-medium',
          isDense: true,
        ),
        onSubmitted: (v) {
          if (v.trim().isNotEmpty) Navigator.of(context).pop(v.trim());
        },
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: () {
            final text = _controller.text.trim();
            if (text.isNotEmpty) Navigator.of(context).pop(text);
          },
          child: const Text('应用'),
        ),
      ],
    );
  }
}

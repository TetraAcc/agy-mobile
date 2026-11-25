import 'package:flutter/material.dart';

import '../../core/config/responsive_layout.dart';
import '../../core/theme/app_colors.dart';
import '../../models/models.dart';

class _ModelFamilyGroup {
  final String familyName;
  final String group;
  final String icon;
  final String tag;
  final double? remainingFraction;
  final List<_ModelVariantEntry> variants;

  const _ModelFamilyGroup({
    required this.familyName,
    required this.group,
    required this.icon,
    required this.tag,
    required this.remainingFraction,
    required this.variants,
  });

  bool containsModelId(String id) => id.isNotEmpty && variants.any((v) => v.option.id == id);

  _ModelVariantEntry? findVariant(String id) {
    if (id.isEmpty) return null;
    for (final v in variants) {
      if (v.option.id == id) return v;
    }
    return null;
  }
}

class _ModelVariantEntry {
  final String variantLabel;
  final OfficialModelOption option;

  const _ModelVariantEntry({
    required this.variantLabel,
    required this.option,
  });
}

class ModelPickerSheet extends StatefulWidget {
  final bool isDark;
  final List<OfficialModelOption> models;
  final String activeModel;
  final String pendingModel;
  final ValueChanged<String?> onSelectModel;
  final String sheetTitle;
  final String? subtitleOverride;
  final bool allowKeepCurrent;

  const ModelPickerSheet({
    super.key,
    required this.isDark,
    required this.models,
    required this.activeModel,
    required this.pendingModel,
    required this.onSelectModel,
    this.sheetTitle = '切换当前会话模型',
    this.subtitleOverride,
    this.allowKeepCurrent = true,
  });

  static Future<void> show(
    BuildContext context, {
    required bool isDark,
    required List<OfficialModelOption> models,
    required String activeModel,
    required String pendingModel,
    required ValueChanged<String?> onSelectModel,
    String sheetTitle = '切换当前会话模型',
    String? subtitleOverride,
    bool allowKeepCurrent = true,
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
        sheetTitle: sheetTitle,
        subtitleOverride: subtitleOverride,
        allowKeepCurrent: allowKeepCurrent,
      ),
    );
  }

  @override
  State<ModelPickerSheet> createState() => _ModelPickerSheetState();
}

class _ModelPickerSheetState extends State<ModelPickerSheet> {
  final TextEditingController _searchController = TextEditingController();
  String _query = '';
  String? _expandedFamily;

  static final RegExp _parenVariantRe = RegExp(r'^(.*?)\s*\(([^()]+)\)\s*$');
  static const List<String> _variantOrder = [
    'low',
    'fast',
    'medium',
    'high',
    'xhigh',
    'thinking',
    'neon',
    'carbon',
    'argon',
  ];

  @override
  void initState() {
    super.initState();
    final targetId = widget.pendingModel.isNotEmpty ? widget.pendingModel : widget.activeModel;
    final families = _buildFamilies(widget.models);
    for (final f in families) {
      if (f.variants.length > 1 && f.containsModelId(targetId)) {
        _expandedFamily = f.familyName;
        break;
      }
    }
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  (String family, String variant) _splitFamilyAndVariant(OfficialModelOption opt) {
    final m = _parenVariantRe.firstMatch(opt.displayName.trim());
    if (m != null) {
      final base = (m.group(1) ?? '').trim();
      final variant = (m.group(2) ?? '').trim();
      if (base.isNotEmpty && variant.isNotEmpty) {
        return (base, variant);
      }
    }
    return (opt.displayName.trim(), '');
  }

  int _variantRank(String label) {
    final idx = _variantOrder.indexOf(label.trim().toLowerCase());
    return idx >= 0 ? idx : _variantOrder.length;
  }

  List<_ModelFamilyGroup> _buildFamilies(List<OfficialModelOption> list) {
    final map = <String, List<_ModelVariantEntry>>{};
    final meta = <String, OfficialModelOption>{};
    final order = <String>[];

    for (final opt in list) {
      final (family, variant) = _splitFamilyAndVariant(opt);
      if (!map.containsKey(family)) {
        order.add(family);
        meta[family] = opt;
        map[family] = <_ModelVariantEntry>[];
      }
      map[family]!.add(_ModelVariantEntry(
        variantLabel: variant.isNotEmpty ? variant : '默认',
        option: opt,
      ));
    }

    return order.map((family) {
      final first = meta[family]!;
      final variants = map[family]!
        ..sort((a, b) {
          final ra = _variantRank(a.variantLabel);
          final rb = _variantRank(b.variantLabel);
          return ra != rb ? ra.compareTo(rb) : a.variantLabel.compareTo(b.variantLabel);
        });
      double? rem;
      for (final v in variants) {
        if (v.option.remainingFraction != null) {
          rem = v.option.remainingFraction;
          break;
        }
      }
      return _ModelFamilyGroup(
        familyName: family,
        group: first.group.isNotEmpty ? first.group : 'Other',
        icon: first.icon,
        tag: first.thinkingBadge,
        remainingFraction: rem,
        variants: variants,
      );
    }).toList();
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

  void _selectOption(OfficialModelOption opt) {
    final isCurrent = widget.allowKeepCurrent && widget.activeModel == opt.id;
    widget.onSelectModel(isCurrent ? null : opt.id);
    Navigator.of(context).pop();
  }

  static bool _isLeavingSoon(String tag) => tag.toLowerCase().contains('leaving soon');

  @override
  Widget build(BuildContext context) {
    final isDark = widget.isDark;
    final primary = Theme.of(context).colorScheme.primary;
    final maxWidth = ResponsiveLayout.compactSheetConstraints(context).maxWidth;
    final bottomInset = MediaQuery.of(context).viewInsets.bottom;

    final query = _query.trim().toLowerCase();
    final filteredModels = widget.models.where((m) {
      if (query.isEmpty) return true;
      return m.displayName.toLowerCase().contains(query) ||
          m.id.toLowerCase().contains(query) ||
          m.group.toLowerCase().contains(query) ||
          m.thinkingBadge.toLowerCase().contains(query);
    }).toList();

    final families = _buildFamilies(filteredModels);
    final grouped = <String, List<_ModelFamilyGroup>>{};
    const preferredOrder = ['Gemini', 'Orchestrator', 'Claude', 'GPT', 'Other'];
    for (final f in families) {
      grouped.putIfAbsent(f.group, () => <_ModelFamilyGroup>[]).add(f);
    }
    for (final list in grouped.values) {
      final activeOnes = list.where((f) => !_isLeavingSoon(f.tag)).toList();
      final leavingOnes = list.where((f) => _isLeavingSoon(f.tag)).toList();
      list
        ..clear()
        ..addAll(activeOnes)
        ..addAll(leavingOnes);
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
    final selectedId = widget.pendingModel.isNotEmpty ? widget.pendingModel : widget.activeModel;
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
                                widget.sheetTitle,
                                style: TextStyle(
                                  fontSize: 15,
                                  fontWeight: FontWeight.w700,
                                  color: isDark ? Colors.white : const Color(0xFF18181B),
                                ),
                              ),
                              const SizedBox(height: 2),
                              Text(
                                widget.subtitleOverride ?? '当前：$activeDisplay · 点击系列选思考强度',
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
                    padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                    child: TextField(
                      controller: _searchController,
                      onChanged: (v) => setState(() => _query = v),
                      style: TextStyle(
                        fontSize: 13.5,
                        color: isDark ? Colors.white : const Color(0xFF18181B),
                      ),
                      decoration: InputDecoration(
                        isDense: true,
                        hintText: '搜索模型（如 neon / claude / orchestrator）...',
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
                        contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
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
                          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
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
                                  '取消待切换，恢复沿用 $activeDisplay',
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
                            padding: const EdgeInsets.symmetric(vertical: 28, horizontal: 16),
                            child: Text(
                              widget.models.isEmpty && query.isEmpty
                                  ? '正在加载当前节点可用模型，请稍后重试或点击右上角「自定义」输入模型 ID'
                                  : '未找到匹配的模型，可点击右上角「自定义」直接输入模型 ID',
                              textAlign: TextAlign.center,
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
                                  padding: const EdgeInsets.fromLTRB(6, 8, 6, 4),
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
                                for (final family in grouped[grp]!)
                                  _buildFamilyTile(
                                    context,
                                    family,
                                    selectedId: selectedId,
                                    forceExpand: query.isNotEmpty,
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

  Widget _buildFamilyTile(
    BuildContext context,
    _ModelFamilyGroup family, {
    required String selectedId,
    required bool forceExpand,
  }) {
    final isDark = widget.isDark;
    final primary = Theme.of(context).colorScheme.primary;
    final isSingle = family.variants.length == 1;
    final currentVariant = family.findVariant(widget.activeModel);
    final selectedVariant = family.findVariant(selectedId);
    final hasSelection = selectedVariant != null;
    final isExpanded = !isSingle && (forceExpand || _expandedFamily == family.familyName);
    final rem = family.remainingFraction;

    final isLeavingSoon = _isLeavingSoon(family.tag);
    final familyTextColor = (isLeavingSoon && !hasSelection)
        ? (isDark ? Colors.white60 : Colors.black54)
        : (isDark ? Colors.white : const Color(0xFF18181B));

    return Container(
      margin: const EdgeInsets.symmetric(vertical: 2.5),
      decoration: BoxDecoration(
        color: (hasSelection || isExpanded)
            ? primary.withValues(alpha: isDark ? 0.10 : 0.05)
            : (isDark ? Colors.white.withValues(alpha: 0.025) : Colors.black.withValues(alpha: 0.02)),
        borderRadius: BorderRadius.circular(11),
        border: Border.all(
          color: hasSelection
              ? primary.withValues(alpha: 0.45)
              : (isExpanded
                  ? primary.withValues(alpha: 0.28)
                  : (isDark ? Colors.white.withValues(alpha: 0.06) : Colors.black.withValues(alpha: 0.06))),
          width: 0.8,
        ),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          InkWell(
            borderRadius: BorderRadius.circular(11),
            onTap: () {
              if (isSingle) {
                _selectOption(family.variants.first.option);
              } else {
                setState(() {
                  _expandedFamily = (_expandedFamily == family.familyName) ? null : family.familyName;
                });
              }
            },
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 10),
              child: Row(
                children: [
                  Text(family.icon, style: const TextStyle(fontSize: 14)),
                  const SizedBox(width: 9),
                  Expanded(
                    child: Row(
                      children: [
                        Flexible(
                          child: Text(
                            family.familyName,
                            style: TextStyle(
                              fontSize: 13.5,
                              fontWeight: hasSelection ? FontWeight.w700 : FontWeight.w500,
                              color: familyTextColor,
                            ),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        if (family.tag.isNotEmpty) ...[
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
                              family.tag,
                              style: TextStyle(
                                fontSize: 9.5,
                                color: isDark ? Colors.white60 : Colors.black54,
                              ),
                            ),
                          ),
                        ],
                        if (selectedVariant != null) ...[
                          const SizedBox(width: 6),
                          Container(
                            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1.5),
                            decoration: BoxDecoration(
                              color: primary.withValues(alpha: 0.16),
                              borderRadius: BorderRadius.circular(5),
                            ),
                            child: Text(
                              currentVariant?.option.id == selectedVariant.option.id
                                  ? (isSingle ? '当前' : '当前·${selectedVariant.variantLabel}')
                                  : (isSingle ? '待切换' : '切→${selectedVariant.variantLabel}'),
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
                  const SizedBox(width: 6),
                  Icon(
                    isSingle
                        ? (hasSelection ? Icons.check_rounded : Icons.chevron_right_rounded)
                        : (isExpanded ? Icons.keyboard_arrow_up_rounded : Icons.keyboard_arrow_down_rounded),
                    size: 18,
                    color: hasSelection
                        ? primary
                        : (isDark ? Colors.white38 : Colors.black38),
                  ),
                ],
              ),
            ),
          ),
          if (isExpanded)
            Container(
              width: double.infinity,
              padding: const EdgeInsets.fromLTRB(11, 2, 11, 10),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Divider(
                    height: 1,
                    color: isDark ? Colors.white.withValues(alpha: 0.06) : Colors.black.withValues(alpha: 0.06),
                  ),
                  const SizedBox(height: 8),
                  Wrap(
                    spacing: 7,
                    runSpacing: 7,
                    children: [
                      for (final v in family.variants)
                        _buildVariantChip(
                          context,
                          v,
                          isCurrent: widget.activeModel == v.option.id,
                          isSelected: selectedId == v.option.id,
                        ),
                    ],
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildVariantChip(
    BuildContext context,
    _ModelVariantEntry entry, {
    required bool isCurrent,
    required bool isSelected,
  }) {
    final isDark = widget.isDark;
    final primary = Theme.of(context).colorScheme.primary;
    return InkWell(
      borderRadius: BorderRadius.circular(8),
      onTap: () => _selectOption(entry.option),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 7),
        decoration: BoxDecoration(
          color: isSelected
              ? primary.withValues(alpha: isDark ? 0.24 : 0.14)
              : (isDark ? AppColors.darkBg : Colors.white),
          borderRadius: BorderRadius.circular(8),
          border: Border.all(
            color: isSelected
                ? primary
                : (isDark ? AppColors.darkBorder : AppColors.lightBorder),
            width: isSelected ? 1.2 : 0.8,
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (isSelected) ...[
              Icon(Icons.check_rounded, size: 13, color: primary),
              const SizedBox(width: 4),
            ] else if (isCurrent) ...[
              Container(
                width: 6,
                height: 6,
                margin: const EdgeInsets.only(right: 5),
                decoration: BoxDecoration(shape: BoxShape.circle, color: primary),
              ),
            ],
            Text(
              entry.variantLabel,
              style: TextStyle(
                fontSize: 12.5,
                fontWeight: isSelected ? FontWeight.w700 : FontWeight.w500,
                color: isSelected
                    ? primary
                    : (isDark ? const Color(0xFFE4E4E7) : const Color(0xFF27272A)),
              ),
            ),
          ],
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

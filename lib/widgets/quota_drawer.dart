import 'package:flutter/material.dart';
import '../models/models.dart';
import '../constants/app_colors.dart';

/// 侧边栏抽屉组件：主机切换、官方底座实时额度、新建会话、项目/历史会话列表、明暗主题切换
class QuotaDrawer extends StatelessWidget {
  final List<HostNode> nodes;
  final String selectedNode;
  final ValueChanged<String> onSwitchNode;
  final Map<String, dynamic>? quotaData;
  final bool isLoadingQuota;
  final VoidCallback onRequestQuota;
  final VoidCallback onNewSession;
  final void Function(String projectName, String workspacePath)? onNewSessionInProject;
  final Map<String, List<SessionItem>> projects;
  final List<SessionItem> generalSessions;
  final String? activeSessionId;
  final Set<String> runningSessionIds;
  final ValueChanged<SessionItem> onSwitchSession;
  final ValueChanged<String> onDeleteSession;
  final bool isDark;
  final ValueChanged<bool> onToggleTheme;
  final String currentAccentThemeId;
  final ValueChanged<AccentThemeOption> onSelectAccentTheme;

  const QuotaDrawer({
    super.key,
    required this.nodes,
    required this.selectedNode,
    required this.onSwitchNode,
    required this.quotaData,
    required this.isLoadingQuota,
    required this.onRequestQuota,
    required this.onNewSession,
    this.onNewSessionInProject,
    required this.projects,
    required this.generalSessions,
    required this.activeSessionId,
    this.runningSessionIds = const {},
    required this.onSwitchSession,
    required this.onDeleteSession,
    required this.isDark,
    required this.onToggleTheme,
    this.currentAccentThemeId = 'emerald',
    required this.onSelectAccentTheme,
  });

  @override
  Widget build(BuildContext context) {
    return Drawer(
      backgroundColor: isDark ? const Color(0xFF0F172A) : Colors.white,
      child: SafeArea(
        child: Column(
          children: [
            // 设备切换指示器卡片
            _buildNodeSelector(context),

            // 实时模型额度展示卡片（官方底座真实配额）
            _buildQuotaCard(context),

            // 顶部操作栏: + 新建会话
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                border: Border(
                  bottom: BorderSide(color: isDark ? Colors.white10 : Colors.black12),
                ),
              ),
              child: ElevatedButton.icon(
                onPressed: () {
                  Navigator.pop(context);
                  onNewSession();
                },
                style: ElevatedButton.styleFrom(
                  backgroundColor: isDark ? const Color(0xFF1E293B) : const Color(0xFFF1F5F9),
                  foregroundColor: isDark ? Colors.white : Colors.black87,
                  elevation: 0,
                  minimumSize: const Size(double.infinity, 40),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                ),
                icon: const Icon(Icons.add, size: 18),
                label: const Text("新建会话", style: TextStyle(fontSize: 13)),
              ),
            ),

            // 项目与会话列表
            Expanded(
              child: ListView(
                padding: const EdgeInsets.symmetric(vertical: 8),
                children: [
                  if (projects.isNotEmpty) ...[
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
                      child: Text(
                        "项目列表",
                        style: TextStyle(
                          color: isDark ? Colors.white38 : Colors.black38,
                          fontSize: 11,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ),
                    for (var entry in projects.entries)
                      Theme(
                        data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
                        child: ExpansionTile(
                          initiallyExpanded: entry.value.any((s) => s.id == activeSessionId),
                          tilePadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 0),
                          leading: Icon(
                            Icons.folder_outlined,
                            color: Theme.of(context).colorScheme.primary,
                            size: 18,
                          ),
                          title: Text(
                            entry.key,
                            style: TextStyle(
                              color: isDark ? Colors.white : Colors.black87,
                              fontSize: 13,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                          trailing: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              IconButton(
                                icon: const Icon(Icons.add_circle_outline_rounded, size: 18),
                                color: Theme.of(context).colorScheme.primary,
                                tooltip: '在此项目内新建会话',
                                splashRadius: 16,
                                constraints: const BoxConstraints(minWidth: 28, minHeight: 28),
                                padding: EdgeInsets.zero,
                                onPressed: () {
                                  final wsPath = entry.value.firstWhere(
                                    (s) => s.workspacePath.isNotEmpty,
                                    orElse: () => entry.value.first,
                                  ).workspacePath;
                                  onNewSessionInProject?.call(entry.key, wsPath);
                                },
                              ),
                              const SizedBox(width: 2),
                              Icon(
                                Icons.expand_more_rounded,
                                size: 18,
                                color: isDark ? Colors.white54 : Colors.black45,
                              ),
                            ],
                          ),
                          children: entry.value
                              .map((s) => _buildSessionTile(context, s, isIndented: true))
                              .toList(),
                        ),
                      ),
                    Divider(color: isDark ? Colors.white10 : Colors.black12, height: 16),
                  ],

                  if (generalSessions.isNotEmpty) ...[
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
                      child: Text(
                        "会话列表",
                        style: TextStyle(
                          color: isDark ? Colors.white38 : Colors.black38,
                          fontSize: 11,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ),
                    for (var s in generalSessions)
                      _buildSessionTile(context, s, isIndented: false),
                  ],
                ],
              ),
            ),

            // 强调色主题选择面板
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              decoration: BoxDecoration(
                border: Border(
                  top: BorderSide(color: isDark ? Colors.white10 : Colors.black12),
                ),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text(
                        "护眼强调色",
                        style: TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.bold,
                          color: isDark ? Colors.white60 : Colors.black54,
                        ),
                      ),
                      Text(
                        AppColors.getThemeById(currentAccentThemeId).name.split(' ').first,
                        style: TextStyle(
                          fontSize: 11,
                          color: Theme.of(context).colorScheme.primary,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: AppColors.accentThemes.map((theme) {
                      final isSelected = theme.id == currentAccentThemeId;
                      return InkWell(
                        onTap: () => onSelectAccentTheme(theme),
                        borderRadius: BorderRadius.circular(16),
                        child: AnimatedContainer(
                          duration: const Duration(milliseconds: 200),
                          width: 28,
                          height: 28,
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            color: theme.previewColor,
                            border: Border.all(
                              color: isSelected ? (isDark ? Colors.white : Colors.black87) : Colors.transparent,
                              width: 2.5,
                            ),
                            boxShadow: [
                              if (isSelected)
                                BoxShadow(
                                  color: theme.previewColor.withOpacity(0.4),
                                  blurRadius: 6,
                                  spreadRadius: 1,
                                ),
                            ],
                          ),
                          child: isSelected
                              ? const Center(
                                  child: Icon(Icons.check_rounded, size: 14, color: Colors.white),
                                )
                              : null,
                        ),
                      );
                    }).toList(),
                  ),
                ],
              ),
            ),

            // 抽屉底部：日间 / 夜间模式一键切换
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
              decoration: BoxDecoration(
                border: Border(
                  top: BorderSide(color: isDark ? Colors.white10 : Colors.black12),
                ),
              ),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Row(
                    children: [
                      Icon(
                        isDark ? Icons.dark_mode_outlined : Icons.light_mode_outlined,
                        size: 18,
                        color: Theme.of(context).colorScheme.primary,
                      ),
                      const SizedBox(width: 8),
                      Text(
                        isDark ? "夜间模式" : "日间模式",
                        style: TextStyle(
                          fontSize: 13,
                          color: isDark ? Colors.white70 : Colors.black87,
                        ),
                      ),
                    ],
                  ),
                  Switch(
                    value: isDark,
                    activeColor: Theme.of(context).colorScheme.primary,
                    onChanged: (val) => onToggleTheme(val),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildNodeSelector(BuildContext context) {
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      padding: const EdgeInsets.all(8),
      decoration: BoxDecoration(
        color: isDark ? const Color(0xFF1E293B) : const Color(0xFFF8FAFC),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: isDark ? Colors.white10 : Colors.black12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.hub_rounded, size: 14, color: isDark ? Colors.white54 : Colors.black45),
              const SizedBox(width: 6),
              Text(
                "目标控制主机",
                style: TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.bold,
                  color: isDark ? Colors.white54 : Colors.black45,
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Row(
            children: nodes.map((node) {
              final isSelected = node.id == selectedNode;
              final isDeck = node.id == "deck";
              return Expanded(
                child: InkWell(
                  onTap: () => onSwitchNode(node.id),
                  borderRadius: BorderRadius.circular(8),
                  child: Container(
                    padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 4),
                    margin: const EdgeInsets.symmetric(horizontal: 2),
                    decoration: BoxDecoration(
                      color: isSelected
                          ? (isDark ? const Color(0xFF0284C7).withOpacity(0.3) : const Color(0xFFE0F2FE))
                          : Colors.transparent,
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(
                        color: isSelected ? const Color(0xFF38BDF8) : Colors.transparent,
                        width: 1,
                      ),
                    ),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(
                          isDeck ? Icons.videogame_asset_rounded : Icons.desktop_windows_rounded,
                          size: 13,
                          color: isSelected ? const Color(0xFF38BDF8) : (isDark ? Colors.white60 : Colors.black54),
                        ),
                        const SizedBox(width: 4),
                        Flexible(
                          child: Text(
                            node.name,
                            style: TextStyle(
                              fontSize: 11,
                              fontWeight: isSelected ? FontWeight.bold : FontWeight.normal,
                              color: isSelected
                                  ? (isDark ? Colors.white : const Color(0xFF0284C7))
                                  : (isDark ? Colors.white70 : Colors.black87),
                            ),
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        const SizedBox(width: 4),
                        Container(
                          width: 6,
                          height: 6,
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            color: node.isOnline ? Colors.greenAccent : (isDark ? Colors.white24 : Colors.black26),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              );
            }).toList(),
          ),
        ],
      ),
    );
  }

  Widget _buildQuotaCard(BuildContext context) {
    final groups = (quotaData != null && quotaData!['groups'] is List)
        ? (quotaData!['groups'] as List)
        : [];

    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: isDark ? const Color(0xFF161F30) : const Color(0xFFF8FAFC),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: isDark ? const Color(0xFF23324A) : const Color(0xFFE2E8F0)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Row(
                children: [
                  Icon(
                    Icons.speed_rounded,
                    size: 14,
                    color: isDark ? const Color(0xFF38BDF8) : const Color(0xFF0284C7),
                  ),
                  const SizedBox(width: 5),
                  Text(
                    "模型实时额度",
                    style: TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.bold,
                      color: isDark ? Colors.white70 : Colors.black87,
                    ),
                  ),
                ],
              ),
              InkWell(
                onTap: isLoadingQuota ? null : onRequestQuota,
                borderRadius: BorderRadius.circular(12),
                child: Padding(
                  padding: const EdgeInsets.all(2),
                  child: isLoadingQuota
                      ? SizedBox(
                          width: 11,
                          height: 11,
                          child: CircularProgressIndicator(
                            strokeWidth: 1.5,
                            color: Theme.of(context).colorScheme.primary,
                          ),
                        )
                      : Icon(
                          Icons.refresh_rounded,
                          size: 14,
                          color: isDark ? Colors.white54 : Colors.black45,
                        ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          if (groups.isEmpty)
            Center(
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 4),
                child: InkWell(
                  onTap: onRequestQuota,
                  child: Text(
                    isLoadingQuota ? "正在拉取配额..." : "点击同步官方实时配额",
                    style: TextStyle(
                      fontSize: 11,
                      color: isDark ? Colors.white38 : Colors.black38,
                    ),
                  ),
                ),
              ),
            )
          else
            Column(
              children: [
                for (int i = 0; i < groups.length; i++) ...[
                  if (i > 0)
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 5),
                      child: Divider(
                        color: isDark ? Colors.white10 : Colors.black12,
                        height: 1,
                      ),
                    ),
                  _buildQuotaGroup(groups[i]),
                ],
              ],
            ),
        ],
      ),
    );
  }

  Widget _buildQuotaGroup(dynamic groupData) {
    if (groupData is! Map) return const SizedBox.shrink();
    final group = Map<String, dynamic>.from(groupData);
    final rawName = group['displayName']?.toString() ?? "";
    String groupTitle = rawName;
    if (rawName.toLowerCase().contains("gemini")) {
      groupTitle = "Gemini 系列";
    } else if (rawName.toLowerCase().contains("claude")) {
      groupTitle = "Claude & GPT";
    }

    final buckets = (group['buckets'] is List) ? (group['buckets'] as List) : [];

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          groupTitle,
          style: TextStyle(
            fontSize: 10.5,
            fontWeight: FontWeight.bold,
            color: isDark ? const Color(0xFF94A3B8) : const Color(0xFF475569),
          ),
        ),
        const SizedBox(height: 3),
        for (var bData in buckets)
          if (bData is Map) _buildBucketProgress(Map<String, dynamic>.from(bData)),
      ],
    );
  }

  Widget _buildBucketProgress(Map<String, dynamic> bucket) {
    final rawId = bucket['bucketId']?.toString().toLowerCase() ?? "";
    final rawName = bucket['displayName']?.toString().toLowerCase() ?? "";
    final window = bucket['window']?.toString().toLowerCase() ?? "";

    String bucketLabel = "额度";
    if (rawId.contains("weekly") || rawName.contains("weekly") || window == "weekly") {
      bucketLabel = "周额度";
    } else if (rawId.contains("5h") || rawName.contains("5h") || window == "5h") {
      bucketLabel = "5小时滑动";
    }

    final double fraction = ((bucket['remainingFraction'] as num?)?.toDouble() ?? 1.0).clamp(0.0, 1.0);
    final pctText = "${(fraction * 100).toStringAsFixed(1)}%";
    final resetText = _formatResetTime(bucket['resetTime']?.toString());

    Color barColor;
    if (fraction >= 0.5) {
      barColor = isDark ? const Color(0xFF38BDF8) : const Color(0xFF0284C7);
    } else if (fraction >= 0.2) {
      barColor = const Color(0xFFFBBF24);
    } else {
      barColor = const Color(0xFFF87171);
    }

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2.5),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                bucketLabel,
                style: TextStyle(
                  fontSize: 10,
                  color: isDark ? Colors.white60 : Colors.black54,
                ),
              ),
              Row(
                children: [
                  if (resetText.isNotEmpty) ...[
                    Text(
                      resetText,
                      style: TextStyle(
                        fontSize: 9,
                        color: isDark ? Colors.white30 : Colors.black26,
                      ),
                    ),
                    const SizedBox(width: 5),
                  ],
                  Text(
                    pctText,
                    style: TextStyle(
                      fontSize: 10,
                      fontWeight: FontWeight.bold,
                      color: barColor,
                    ),
                  ),
                ],
              ),
            ],
          ),
          const SizedBox(height: 2),
          ClipRRect(
            borderRadius: BorderRadius.circular(2.5),
            child: LinearProgressIndicator(
              value: fraction,
              minHeight: 4,
              backgroundColor: isDark ? const Color(0xFF0B0F19) : const Color(0xFFE2E8F0),
              valueColor: AlwaysStoppedAnimation<Color>(barColor),
            ),
          ),
        ],
      ),
    );
  }

  String _formatResetTime(String? resetTimeStr) {
    if (resetTimeStr == null || resetTimeStr.isEmpty) return "";
    try {
      final resetTime = DateTime.parse(resetTimeStr).toLocal();
      final now = DateTime.now();
      final diff = resetTime.difference(now);
      if (diff.isNegative) return "已刷新";
      final days = diff.inDays;
      final hours = diff.inHours % 24;
      final minutes = diff.inMinutes % 60;
      if (days > 0) {
        return "$days天$hours时重置";
      } else if (hours > 0) {
        return "$hours时$minutes分重置";
      } else {
        return "$minutes分重置";
      }
    } catch (_) {
      return "";
    }
  }

  Widget _buildSessionTile(BuildContext context, SessionItem s, {required bool isIndented}) {
    final isCurrent = s.id == activeSessionId;
    final isRunning = runningSessionIds.contains(s.id);

    return Container(
      margin: EdgeInsets.only(left: isIndented ? 28 : 10, right: 10, bottom: 2),
      decoration: BoxDecoration(
        color: isCurrent ? (isDark ? const Color(0xFF1E293B) : const Color(0xFFE2E8F0)) : Colors.transparent,
        borderRadius: BorderRadius.circular(6),
      ),
      child: ListTile(
        dense: true,
        visualDensity: const VisualDensity(vertical: -3),
        leading: isRunning
            ? SizedBox(
                width: 14,
                height: 14,
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  valueColor: AlwaysStoppedAnimation<Color>(
                    isDark ? const Color(0xFF38BDF8) : const Color(0xFF0284C7),
                  ),
                ),
              )
            : Icon(
                Icons.chat_bubble_outline_rounded,
                size: 14,
                color: isCurrent ? Theme.of(context).colorScheme.primary : (isDark ? Colors.white38 : Colors.black38),
              ),
        title: Row(
          children: [
            Expanded(
              child: Text(
                s.title,
                style: TextStyle(
                  color: isCurrent ? Theme.of(context).colorScheme.primary : (isDark ? Colors.white70 : Colors.black87),
                  fontSize: 12,
                  fontWeight: isCurrent ? FontWeight.bold : FontWeight.normal,
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            if (isRunning) ...[
              const SizedBox(width: 4),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
                decoration: BoxDecoration(
                  color: Colors.redAccent.withOpacity(0.15),
                  borderRadius: BorderRadius.circular(3),
                  border: Border.all(color: Colors.redAccent.withOpacity(0.4), width: 0.8),
                ),
                child: const Text(
                  "运行中",
                  style: TextStyle(color: Colors.redAccent, fontSize: 9, fontWeight: FontWeight.bold),
                ),
              ),
            ],
          ],
        ),
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (s.time.isNotEmpty && !isRunning)
              Text(
                s.time,
                style: TextStyle(color: isDark ? Colors.white24 : Colors.black26, fontSize: 9),
              ),
            const SizedBox(width: 4),
            InkWell(
              onTap: () => _confirmDeleteSession(context, s),
              borderRadius: BorderRadius.circular(12),
              child: Padding(
                padding: const EdgeInsets.all(4),
                child: Icon(
                  Icons.delete_outline_rounded,
                  size: 15,
                  color: isDark ? Colors.white30 : Colors.black38,
                ),
              ),
            ),
          ],
        ),
        onTap: () => onSwitchSession(s),
      ),
    );
  }

  void _confirmDeleteSession(BuildContext context, SessionItem s) {
    showDialog(
      context: context,
      builder: (ctx) {
        return AlertDialog(
          backgroundColor: isDark ? const Color(0xFF1E293B) : Colors.white,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
          title: const Text("删除此会话？", style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
          content: Text(
            "确定要删除「${s.title}」吗？\n删除后会话记录与本地上下文将被永久移除。",
            style: TextStyle(fontSize: 13, color: isDark ? Colors.white70 : Colors.black87),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: Text("取消", style: TextStyle(color: isDark ? Colors.white60 : Colors.black54)),
            ),
            ElevatedButton(
              onPressed: () {
                Navigator.pop(ctx);
                onDeleteSession(s.id);
              },
              style: ElevatedButton.styleFrom(
                backgroundColor: Colors.redAccent.shade700,
                foregroundColor: Colors.white,
                elevation: 0,
              ),
              child: const Text("确认删除"),
            ),
          ],
        );
      },
    );
  }
}

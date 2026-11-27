import 'package:flutter/material.dart';

import '../../core/config/responsive_layout.dart';
import '../../core/theme/app_colors.dart';
import '../../models/models.dart';

class QuotaDrawer extends StatefulWidget {
  final List<HostNode> nodes;
  final String selectedNode;
  final ValueChanged<String> onSwitchNode;
  final VoidCallback? onRefreshNodes;
  final QuotaData? quotaData;
  final bool isLoadingQuota;
  final VoidCallback onRequestQuota;
  final bool canWrite;
  final bool canDelete;
  final VoidCallback onNewSession;
  final void Function(String projectName, String workspacePath, String rootId)? onNewSessionInProject;
  final Map<String, List<SessionItem>> projects;
  final List<SessionItem> generalSessions;
  final String? activeSessionId;
  final Set<String> runningSessionIds;
  final ValueChanged<SessionItem> onSwitchSession;
  final ValueChanged<SessionItem>? onTogglePinSession;
  final ValueChanged<String> onDeleteSession;
  final bool isDark;
  final ValueChanged<bool> onToggleTheme;
  final String currentAccentThemeId;
  final ValueChanged<AccentThemeOption> onSelectAccentTheme;
  final String currentDisplayName;
  final VoidCallback? onLogout;
  final bool isPermanentSidebar;

  const QuotaDrawer({
    super.key,
    required this.nodes,
    required this.selectedNode,
    required this.onSwitchNode,
    this.onRefreshNodes,
    required this.quotaData,
    required this.isLoadingQuota,
    required this.onRequestQuota,
    this.canWrite = true,
    this.canDelete = false,
    required this.onNewSession,
    this.onNewSessionInProject,
    required this.projects,
    required this.generalSessions,
    required this.activeSessionId,
    this.runningSessionIds = const {},
    required this.onSwitchSession,
    this.onTogglePinSession,
    required this.onDeleteSession,
    required this.isDark,
    required this.onToggleTheme,
    this.currentAccentThemeId = 'emerald',
    required this.onSelectAccentTheme,
    this.currentDisplayName = '',
    this.onLogout,
    this.isPermanentSidebar = false,
  });

  @override
  State<QuotaDrawer> createState() => _QuotaDrawerState();
}

class _QuotaDrawerState extends State<QuotaDrawer> {
  final TextEditingController _searchController = TextEditingController();
  String _searchQuery = '';
  bool _isQuotaExpanded = false;

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  bool get isDark => widget.isDark;

  void _closeIfDrawer(BuildContext context) {
    if (!widget.isPermanentSidebar) {
      Navigator.pop(context);
    }
  }

  List<SessionItem> _sortPinnedFirst(List<SessionItem> items) {
    if (items.length <= 1) return items;
    final pinned = <SessionItem>[];
    final rest = <SessionItem>[];
    for (final s in items) {
      if (s.isPinned) {
        pinned.add(s);
      } else {
        rest.add(s);
      }
    }
    if (pinned.isEmpty) return items;
    return [...pinned, ...rest];
  }

  List<({SessionItem session, String? projectName})> _collectPinnedEntries() {
    final seen = <String>{};
    final out = <({SessionItem session, String? projectName})>[];
    for (final entry in widget.projects.entries) {
      for (final s in entry.value) {
        if (s.isPinned && seen.add(s.id)) {
          out.add((session: s, projectName: entry.key));
        }
      }
    }
    for (final s in widget.generalSessions) {
      if (s.isPinned && seen.add(s.id)) {
        out.add((session: s, projectName: null));
      }
    }
    return out;
  }

  Widget _buildSearchResults(BuildContext context) {
    final query = _searchQuery.toLowerCase();
    final List<({SessionItem session, String? projectName})> results = [];

    for (final entry in widget.projects.entries) {
      for (final s in entry.value) {
        if (s.title.toLowerCase().contains(query) ||
            s.preview.toLowerCase().contains(query) ||
            entry.key.toLowerCase().contains(query)) {
          results.add((session: s, projectName: entry.key));
        }
      }
    }

    for (final s in widget.generalSessions) {
      if (s.title.toLowerCase().contains(query) || s.preview.toLowerCase().contains(query)) {
        results.add((session: s, projectName: null));
      }
    }
    results.sort((a, b) => (b.session.isPinned ? 1 : 0).compareTo(a.session.isPinned ? 1 : 0));

    if (results.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 36, horizontal: 20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.search_off_rounded, size: 36, color: isDark ? Colors.white24 : Colors.black26),
              const SizedBox(height: 10),
              Text(
                '未找到与「$_searchQuery」相关的会话',
                style: TextStyle(fontSize: 12, color: isDark ? Colors.white38 : Colors.black45),
                textAlign: TextAlign.center,
              ),
            ],
          ),
        ),
      );
    }

    return ListView(
      padding: const EdgeInsets.symmetric(vertical: 8),
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
          child: Text(
            '搜索结果 (${results.length})',
            style: TextStyle(
              color: isDark ? Colors.white38 : Colors.black38,
              fontSize: 11,
              fontWeight: FontWeight.bold,
            ),
          ),
        ),
        for (final item in results)
          _buildSessionTile(context, item.session, isIndented: false, projectTag: item.projectName),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final content = SafeArea(
      right: !widget.isPermanentSidebar,
      child: Column(
        children: [
          _buildNodeSelector(context),
          _buildQuotaCard(context),
          Container(
            padding: const EdgeInsets.fromLTRB(12, 6, 12, 6),
            decoration: BoxDecoration(
              border: Border(bottom: BorderSide(color: isDark ? Colors.white10 : Colors.black12)),
            ),
            child: Column(
              children: [
                ElevatedButton.icon(
                  onPressed: widget.canWrite
                      ? () {
                          _closeIfDrawer(context);
                          widget.onNewSession();
                        }
                      : null,
                    style: ElevatedButton.styleFrom(
                      backgroundColor: isDark ? const Color(0xFF222226) : const Color(0xFFF4F4F5),
                      foregroundColor: isDark ? Colors.white : Colors.black87,
                      elevation: 0,
                      minimumSize: const Size(double.infinity, 34),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                    ),
                    icon: const Icon(Icons.add, size: 16),
                    label: Text(
                      widget.canWrite ? '新建会话' : '只读权限 (不可新建)',
                      style: const TextStyle(fontSize: 12.5),
                    ),
                  ),
                  const SizedBox(height: 6),
                  Container(
                    height: 32,
                    decoration: BoxDecoration(
                      color: isDark ? const Color(0xFF18181B) : const Color(0xFFF8F8F9),
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(
                        color: isDark ? const Color(0xFF2C2C32) : const Color(0xFFCBD5E1),
                        width: 0.8,
                      ),
                    ),
                    child: TextField(
                      controller: _searchController,
                      style: TextStyle(fontSize: 12, color: isDark ? Colors.white : Colors.black87),
                      decoration: InputDecoration(
                        hintText: '搜索会话标题、所属工程...',
                        hintStyle: TextStyle(
                          fontSize: 11.5,
                          color: isDark ? Colors.white38 : Colors.black38,
                        ),
                        prefixIcon: Icon(
                          Icons.search_rounded,
                          size: 15,
                          color: isDark ? Colors.white38 : Colors.black38,
                        ),
                        suffixIcon: _searchQuery.isNotEmpty
                            ? InkWell(
                                onTap: () {
                                  _searchController.clear();
                                  setState(() => _searchQuery = '');
                                },
                                child: Icon(
                                  Icons.clear_rounded,
                                  size: 15,
                                  color: isDark ? Colors.white38 : Colors.black38,
                                ),
                              )
                            : null,
                        border: InputBorder.none,
                        isDense: true,
                        contentPadding: const EdgeInsets.symmetric(vertical: 8),
                      ),
                      onChanged: (val) => setState(() => _searchQuery = val.trim()),
                    ),
                  ),
                ],
              ),
            ),
            Expanded(
              child: _searchQuery.isNotEmpty
                  ? _buildSearchResults(context)
                  : Builder(
                      builder: (context) {
                        final pinnedEntries = _collectPinnedEntries();
                        final sortedGeneral = _sortPinnedFirst(widget.generalSessions);
                        return ListView(
                          padding: const EdgeInsets.symmetric(vertical: 8),
                          children: [
                            if (pinnedEntries.isNotEmpty) ...[
                              Padding(
                                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
                                child: Row(
                                  children: [
                                    Icon(
                                      Icons.push_pin_rounded,
                                      size: 12,
                                      color: Theme.of(context).colorScheme.primary,
                                    ),
                                    const SizedBox(width: 5),
                                    Text(
                                      '已置顶 (${pinnedEntries.length})',
                                      style: TextStyle(
                                        color: isDark ? Colors.white54 : Colors.black54,
                                        fontSize: 11,
                                        fontWeight: FontWeight.bold,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                              for (final item in pinnedEntries)
                                _buildSessionTile(
                                  context,
                                  item.session,
                                  isIndented: false,
                                  projectTag: item.projectName,
                                ),
                              Divider(color: isDark ? Colors.white10 : Colors.black12, height: 16),
                            ],
                            if (widget.projects.isNotEmpty) ...[
                              Padding(
                                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
                                child: Text(
                                  '项目列表',
                                  style: TextStyle(
                                    color: isDark ? Colors.white38 : Colors.black38,
                                    fontSize: 11,
                                    fontWeight: FontWeight.bold,
                                  ),
                                ),
                              ),
                              for (final entry in widget.projects.entries) ...[
                                Builder(
                                  builder: (context) {
                                    final runningCount = entry.value
                                        .where((s) => widget.runningSessionIds.contains(s.id) || s.isRunning)
                                        .length;
                                    return Theme(
                                      data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
                                      child: ExpansionTile(
                                        initiallyExpanded: entry.value.any((s) => s.id == widget.activeSessionId),
                                        tilePadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 0),
                                        leading: Icon(
                                          Icons.folder_outlined,
                                          color: Theme.of(context).colorScheme.primary,
                                          size: 18,
                                        ),
                                        title: Row(
                                          children: [
                                            Flexible(
                                              child: Text(
                                                entry.key,
                                                overflow: TextOverflow.ellipsis,
                                                style: TextStyle(
                                                  color: isDark ? Colors.white : Colors.black87,
                                                  fontSize: 13,
                                                  fontWeight: FontWeight.bold,
                                                ),
                                              ),
                                            ),
                                            if (runningCount > 0) ...[
                                              const SizedBox(width: 8),
                                              _ProjectBreathingDot(
                                                key: ValueKey('proj_breathing_${entry.key}'),
                                                color: AppColors.statusGreen(isDark),
                                                count: runningCount,
                                              ),
                                            ],
                                          ],
                                        ),
                                    trailing: Row(
                                      mainAxisSize: MainAxisSize.min,
                                      children: [
                                        if (widget.canWrite && entry.value.isNotEmpty)
                                          IconButton(
                                            icon: const Icon(Icons.add_circle_outline_rounded, size: 18),
                                            color: Theme.of(context).colorScheme.primary,
                                            tooltip: '在此项目内新建会话',
                                            splashRadius: 16,
                                            constraints: const BoxConstraints(minWidth: 28, minHeight: 28),
                                            padding: EdgeInsets.zero,
                                            onPressed: () {
                                              final firstWithWs = entry.value.firstWhere(
                                                (s) => s.workspacePath.isNotEmpty,
                                                orElse: () => entry.value.first,
                                              );
                                              _closeIfDrawer(context);
                                              widget.onNewSessionInProject?.call(
                                                entry.key,
                                                firstWithWs.workspacePath,
                                                firstWithWs.rootId,
                                              );
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
                                    children: _sortPinnedFirst(entry.value)
                                        .map((s) => _buildSessionTile(context, s, isIndented: true))
                                        .toList(),
                                  ),
                                );
                                  },
                                ),
                              ],
                              Divider(color: isDark ? Colors.white10 : Colors.black12, height: 16),
                            ],
                            if (sortedGeneral.isNotEmpty) ...[
                              Padding(
                                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
                                child: Text(
                                  '会话列表',
                                  style: TextStyle(
                                    color: isDark ? Colors.white38 : Colors.black38,
                                    fontSize: 11,
                                    fontWeight: FontWeight.bold,
                                  ),
                                ),
                              ),
                              for (final s in sortedGeneral)
                                _buildSessionTile(context, s, isIndented: false),
                            ],
                          ],
                        );
                      },
                    ),
            ),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
              decoration: BoxDecoration(
                border: Border(top: BorderSide(color: isDark ? Colors.white10 : Colors.black12)),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text(
                        '护眼强调色',
                        style: TextStyle(
                          fontSize: 11,
                          fontWeight: FontWeight.bold,
                          color: isDark ? Colors.white60 : Colors.black54,
                        ),
                      ),
                      Text(
                        AppColors.getThemeById(widget.currentAccentThemeId).name.split(' ').first,
                        style: TextStyle(
                          fontSize: 10.5,
                          color: Theme.of(context).colorScheme.primary,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 6),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: AppColors.accentThemes.map((theme) {
                      final isSelected = theme.id == widget.currentAccentThemeId;
                      final swatch = theme.previewFor(isDark);
                      return InkWell(
                        onTap: () => widget.onSelectAccentTheme(theme),
                        borderRadius: BorderRadius.circular(16),
                        child: AnimatedContainer(
                          duration: const Duration(milliseconds: 200),
                          width: 25,
                          height: 25,
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            color: swatch,
                            border: Border.all(
                              color: isSelected
                                  ? (isDark ? Colors.white : Colors.black87)
                                  : Colors.transparent,
                              width: 2,
                            ),
                            boxShadow: [
                              if (isSelected)
                                BoxShadow(
                                  color: swatch.withValues(alpha: 0.4),
                                  blurRadius: 6,
                                  spreadRadius: 1,
                                ),
                            ],
                          ),
                          child: isSelected
                              ? Center(
                                  child: Icon(
                                    Icons.check_rounded,
                                    size: 13,
                                    color: isDark ? const Color(0xFF111113) : Colors.white,
                                  ),
                                )
                              : null,
                        ),
                      );
                    }).toList(),
                  ),
                ],
              ),
            ),
            if (widget.currentDisplayName.isNotEmpty)
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                decoration: BoxDecoration(
                  border: Border(top: BorderSide(color: isDark ? Colors.white10 : Colors.black12)),
                ),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Row(
                      children: [
                        CircleAvatar(
                          radius: 12,
                          backgroundColor: Theme.of(context).colorScheme.primary.withValues(alpha: 0.2),
                          child: Icon(
                            Icons.person_rounded,
                            size: 14,
                            color: Theme.of(context).colorScheme.primary,
                          ),
                        ),
                        const SizedBox(width: 8),
                        Text(
                          widget.currentDisplayName,
                          style: TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.bold,
                            color: isDark ? Colors.white : Colors.black87,
                          ),
                        ),
                      ],
                    ),
                    IconButton(
                      icon: const Icon(Icons.logout_rounded, size: 18),
                      tooltip: '退出登录',
                      color: Colors.redAccent.shade200,
                      splashRadius: 16,
                      constraints: const BoxConstraints(minWidth: 28, minHeight: 28),
                      padding: EdgeInsets.zero,
                      onPressed: widget.onLogout,
                    ),
                  ],
                ),
              ),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 4),
              decoration: BoxDecoration(
                border: Border(top: BorderSide(color: isDark ? Colors.white10 : Colors.black12)),
              ),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Row(
                    children: [
                      Icon(
                        isDark ? Icons.dark_mode_outlined : Icons.light_mode_outlined,
                        size: 16,
                        color: Theme.of(context).colorScheme.primary,
                      ),
                      const SizedBox(width: 6),
                      Text(
                        isDark ? '夜间模式' : '日间模式',
                        style: TextStyle(
                          fontSize: 12,
                          color: isDark ? Colors.white70 : Colors.black87,
                        ),
                      ),
                    ],
                  ),
                  Row(
                    children: [
                      Text(
                        const String.fromEnvironment('APP_VERSION', defaultValue: 'v2.2.0'),
                        style: TextStyle(
                          fontSize: 10,
                          color: isDark ? Colors.white24 : Colors.black26,
                          letterSpacing: 0.5,
                        ),
                      ),
                      const SizedBox(width: 4),
                      Transform.scale(
                        scale: 0.8,
                        child: Switch(
                          value: isDark,
                          activeThumbColor: Theme.of(context).colorScheme.primary,
                          onChanged: widget.onToggleTheme,
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ],
        ),
      );

    if (widget.isPermanentSidebar) {
      return SizedBox(
        width: ResponsiveLayout.permanentSidebarWidth,
        child: Material(
          color: isDark ? const Color(0xFF111113) : Colors.white,
          child: DecoratedBox(
            decoration: BoxDecoration(
              border: Border(
                right: BorderSide(
                  color: isDark ? AppColors.darkBorder : AppColors.lightBorder,
                  width: 0.6,
                ),
              ),
            ),
            child: content,
          ),
        ),
      );
    }

    return Drawer(
      backgroundColor: isDark ? const Color(0xFF111113) : Colors.white,
      child: content,
    );
  }

  Widget _buildNodeSelector(BuildContext context) {
    return Container(
      margin: const EdgeInsets.fromLTRB(12, 6, 12, 3),
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
      decoration: BoxDecoration(
        color: isDark ? const Color(0xFF222226) : const Color(0xFFF8F8F9),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: isDark ? Colors.white10 : Colors.black12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.hub_rounded, size: 13, color: isDark ? Colors.white54 : Colors.black45),
              const SizedBox(width: 5),
              Text(
                '目标控制主机',
                style: TextStyle(
                  fontSize: 10.5,
                  fontWeight: FontWeight.bold,
                  color: isDark ? Colors.white54 : Colors.black45,
                ),
              ),
              if (widget.onRefreshNodes != null) ...[
                const Spacer(),
                Tooltip(
                  message: '刷新节点状态',
                  child: InkWell(
                    onTap: widget.onRefreshNodes,
                    borderRadius: BorderRadius.circular(10),
                    child: Padding(
                      padding: const EdgeInsets.all(2),
                      child: Icon(
                        Icons.refresh_rounded,
                        size: 13,
                        color: isDark ? Colors.white54 : Colors.black45,
                      ),
                    ),
                  ),
                ),
              ],
            ],
          ),
          const SizedBox(height: 4),
          if (widget.nodes.isEmpty)
            Text(
              '暂无可用节点',
              style: TextStyle(fontSize: 11, color: isDark ? Colors.white38 : Colors.black38),
            )
          else
            Row(
              children: widget.nodes.map((node) {
                final isSelected = node.id == widget.selectedNode;
                final isDeck = node.id == 'deck';
                return Expanded(
                  child: InkWell(
                    onTap: () => widget.onSwitchNode(node.id),
                    borderRadius: BorderRadius.circular(8),
                    child: Container(
                      padding: const EdgeInsets.symmetric(vertical: 5, horizontal: 4),
                      margin: const EdgeInsets.symmetric(horizontal: 2),
                      decoration: BoxDecoration(
                        color: isSelected
                            ? Theme.of(context).colorScheme.primary.withValues(alpha: isDark ? 0.16 : 0.10)
                            : Colors.transparent,
                        borderRadius: BorderRadius.circular(8),
                        border: Border.all(
                          color: isSelected
                              ? Theme.of(context).colorScheme.primary.withValues(alpha: 0.45)
                              : Colors.transparent,
                          width: 1,
                        ),
                      ),
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Icon(
                            isDeck ? Icons.videogame_asset_rounded : Icons.desktop_windows_rounded,
                            size: 13,
                            color: isSelected
                                ? Theme.of(context).colorScheme.primary
                                : (isDark ? Colors.white60 : Colors.black54),
                          ),
                          const SizedBox(width: 4),
                          Flexible(
                            child: Text(
                              node.name,
                              style: TextStyle(
                                fontSize: 11,
                                fontWeight: isSelected ? FontWeight.bold : FontWeight.normal,
                                color: isSelected
                                    ? (isDark ? Colors.white : Theme.of(context).colorScheme.primary)
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
                              color: !node.isOnline
                                  ? (isDark ? Colors.white24 : Colors.black26)
                                  : (node.engineAlive ? Colors.greenAccent : Colors.amberAccent),
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
    final groups = widget.quotaData?.groups ?? const <QuotaGroup>[];

    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 3),
      decoration: BoxDecoration(
        color: isDark ? const Color(0xFF18181B) : const Color(0xFFF8F8F9),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: isDark ? const Color(0xFF2C2C32) : const Color(0xFFE4E4E7)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          InkWell(
            onTap: () => setState(() => _isQuotaExpanded = !_isQuotaExpanded),
            borderRadius: BorderRadius.circular(10),
            child: Padding(
              padding: EdgeInsets.symmetric(horizontal: 10, vertical: _isQuotaExpanded ? 8 : 6),
              child: Row(
                children: [
                  Icon(
                    Icons.speed_rounded,
                    size: 14,
                    color: Theme.of(context).colorScheme.primary,
                  ),
                  const SizedBox(width: 5),
                  Text(
                    _isQuotaExpanded ? '模型实时额度' : '额度',
                    style: TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.bold,
                      color: isDark ? Colors.white70 : Colors.black87,
                    ),
                  ),
                  const SizedBox(width: 6),
                  if (!_isQuotaExpanded)
                    Expanded(
                      child: SingleChildScrollView(
                        scrollDirection: Axis.horizontal,
                        physics: const BouncingScrollPhysics(),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: _buildCompactQuotaBadges(groups),
                        ),
                      ),
                    )
                  else
                    const Spacer(),
                  InkWell(
                    onTap: widget.isLoadingQuota ? null : widget.onRequestQuota,
                    borderRadius: BorderRadius.circular(12),
                    child: Padding(
                      padding: const EdgeInsets.all(2.5),
                      child: widget.isLoadingQuota
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
                              size: 13,
                              color: isDark ? Colors.white54 : Colors.black45,
                            ),
                    ),
                  ),
                  const SizedBox(width: 4),
                  Icon(
                    _isQuotaExpanded ? Icons.keyboard_arrow_up_rounded : Icons.keyboard_arrow_down_rounded,
                    size: 16,
                    color: isDark ? Colors.white38 : Colors.black38,
                  ),
                ],
              ),
            ),
          ),
          AnimatedCrossFade(
            firstChild: const SizedBox.shrink(),
            secondChild: Padding(
              padding: const EdgeInsets.fromLTRB(10, 0, 10, 8),
              child: groups.isEmpty
                  ? Center(
                      child: Padding(
                        padding: const EdgeInsets.symmetric(vertical: 4),
                        child: InkWell(
                          onTap: widget.onRequestQuota,
                          child: Text(
                            widget.isLoadingQuota ? '正在拉取配额...' : '点击同步官方实时配额',
                            style: TextStyle(
                              fontSize: 11,
                              color: isDark ? Colors.white38 : Colors.black38,
                            ),
                          ),
                        ),
                      ),
                    )
                  : Column(
                      children: [
                        for (int i = 0; i < groups.length; i++) ...[
                          if (i > 0)
                            Padding(
                              padding: const EdgeInsets.symmetric(vertical: 4),
                              child: Divider(color: isDark ? Colors.white10 : Colors.black12, height: 1),
                            ),
                          _buildQuotaGroup(groups[i]),
                        ],
                      ],
                    ),
            ),
            crossFadeState: _isQuotaExpanded ? CrossFadeState.showSecond : CrossFadeState.showFirst,
            duration: const Duration(milliseconds: 200),
          ),
        ],
      ),
    );
  }

  List<Widget> _buildCompactQuotaBadges(List<QuotaGroup> groups) {
    if (groups.isEmpty) {
      return [
        Text(
          widget.isLoadingQuota ? '拉取中...' : '点击展开/同步',
          style: TextStyle(fontSize: 10, color: isDark ? Colors.white38 : Colors.black38),
        ),
      ];
    }

    final List<Widget> badges = [];
    for (final group in groups) {
      final rawName = group.displayName;
      var name = rawName;
      if (rawName.toLowerCase().contains('gemini')) {
        name = 'Gemini';
      } else if (rawName.toLowerCase().contains('claude')) {
        name = 'Claude';
      }

      var minFraction = 1.0;
      var foundBucket = false;
      for (final b in group.buckets) {
        foundBucket = true;
        final f = b.remainingFraction.clamp(0.0, 1.0);
        if (f < minFraction) minFraction = f;
      }

      final pctText = foundBucket ? '${(minFraction * 100).toStringAsFixed(1)}%' : '--';
      final badgeColor = minFraction >= 0.5
          ? Theme.of(context).colorScheme.primary
          : (minFraction >= 0.2 ? const Color(0xFFFBBF24) : const Color(0xFFF87171));

      badges.add(
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1.5),
          margin: const EdgeInsets.only(right: 5),
          decoration: BoxDecoration(
            color: badgeColor.withValues(alpha: 0.12),
            borderRadius: BorderRadius.circular(4),
            border: Border.all(color: badgeColor.withValues(alpha: 0.3), width: 0.8),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                name,
                style: TextStyle(
                  fontSize: 9.5,
                  fontWeight: FontWeight.bold,
                  color: isDark ? Colors.white70 : Colors.black87,
                ),
              ),
              const SizedBox(width: 3),
              Text(
                pctText,
                style: TextStyle(fontSize: 9.5, fontWeight: FontWeight.bold, color: badgeColor),
              ),
            ],
          ),
        ),
      );
    }
    return badges;
  }

  Widget _buildQuotaGroup(QuotaGroup group) {
    var groupTitle = group.displayName;
    if (groupTitle.toLowerCase().contains('gemini')) {
      groupTitle = 'Gemini 系列';
    } else if (groupTitle.toLowerCase().contains('claude')) {
      groupTitle = 'Claude & GPT';
    }

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
        for (final b in group.buckets) _buildBucketProgress(b),
      ],
    );
  }

  Widget _buildBucketProgress(QuotaBucket bucket) {
    final rawId = bucket.bucketId.toLowerCase();
    final rawName = bucket.displayName.toLowerCase();
    final window = bucket.window.toLowerCase();

    var bucketLabel = '额度';
    if (rawId.contains('weekly') || rawName.contains('weekly') || window == 'weekly') {
      bucketLabel = '周额度';
    } else if (rawId.contains('5h') || rawName.contains('5h') || window == '5h') {
      bucketLabel = '5小时滑动';
    }

    final fraction = bucket.remainingFraction.clamp(0.0, 1.0);
    final pctText = '${(fraction * 100).toStringAsFixed(1)}%';
    final resetText = _formatResetTime(bucket.resetTime);

    final barColor = fraction >= 0.5
        ? Theme.of(context).colorScheme.primary
        : (fraction >= 0.2 ? const Color(0xFFFBBF24) : const Color(0xFFF87171));

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
                style: TextStyle(fontSize: 10, color: isDark ? Colors.white60 : Colors.black54),
              ),
              Row(
                children: [
                  if (resetText.isNotEmpty) ...[
                    Text(
                      resetText,
                      style: TextStyle(fontSize: 9, color: isDark ? Colors.white30 : Colors.black26),
                    ),
                    const SizedBox(width: 5),
                  ],
                  Text(
                    pctText,
                    style: TextStyle(fontSize: 10, fontWeight: FontWeight.bold, color: barColor),
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
              backgroundColor: isDark ? const Color(0xFF111113) : const Color(0xFFE4E4E7),
              valueColor: AlwaysStoppedAnimation<Color>(barColor),
            ),
          ),
        ],
      ),
    );
  }

  String _formatResetTime(String resetTimeStr) {
    if (resetTimeStr.isEmpty) return '';
    try {
      final resetTime = DateTime.parse(resetTimeStr).toLocal();
      final diff = resetTime.difference(DateTime.now());
      if (diff.isNegative) return '已刷新';
      final days = diff.inDays;
      final hours = diff.inHours % 24;
      final minutes = diff.inMinutes % 60;
      if (days > 0) return '$days天$hours时重置';
      if (hours > 0) return '$hours时$minutes分重置';
      return '$minutes分重置';
    } catch (_) {
      return '';
    }
  }

  Widget _buildSessionTile(BuildContext context, SessionItem s, {required bool isIndented, String? projectTag}) {
    final isCurrent = s.id == widget.activeSessionId;
    final isRunning = widget.runningSessionIds.contains(s.id) || s.isRunning;
    final primary = Theme.of(context).colorScheme.primary;
    final showPinButton = widget.canWrite && widget.onTogglePinSession != null;
    final showTimestamp = s.updatedAt.isNotEmpty && !isRunning;
    final hasProjectTag = projectTag != null && projectTag.isNotEmpty;
    final showMetaRow = hasProjectTag || showTimestamp || showPinButton || widget.canDelete;

    return Padding(
      padding: EdgeInsets.only(left: isIndented ? 18 : 8, right: 8, bottom: 2),
      child: Material(
        color: isCurrent ? (isDark ? const Color(0xFF222226) : const Color(0xFFE4E4E7)) : Colors.transparent,
        borderRadius: BorderRadius.circular(6),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: () {
            _closeIfDrawer(context);
            widget.onSwitchSession(s);
          },
          onLongPress: showPinButton || widget.canDelete
              ? () => _showSessionActionSheet(context, s)
              : null,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Row(
                  children: [
                    isRunning
                        ? SizedBox(
                            width: 14,
                            height: 14,
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              valueColor: AlwaysStoppedAnimation<Color>(primary),
                            ),
                          )
                        : Icon(
                            s.isPinned ? Icons.push_pin_rounded : Icons.chat_bubble_outline_rounded,
                            size: 14,
                            color: s.isPinned
                                ? primary
                                : (isCurrent
                                    ? primary
                                    : (isDark ? Colors.white38 : Colors.black38)),
                          ),
                    const SizedBox(width: 7),
                    Expanded(
                      child: Text(
                        s.title,
                        style: TextStyle(
                          color: isCurrent
                              ? primary
                              : (isDark ? Colors.white70 : Colors.black87),
                          fontSize: 12.5,
                          fontWeight: isCurrent ? FontWeight.bold : FontWeight.normal,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    if (isRunning) ...[
                      const SizedBox(width: 6),
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
                        decoration: BoxDecoration(
                          color: Colors.redAccent.withValues(alpha: 0.15),
                          borderRadius: BorderRadius.circular(3),
                          border: Border.all(color: Colors.redAccent.withValues(alpha: 0.4), width: 0.8),
                        ),
                        child: const Text(
                          '运行中',
                          style: TextStyle(color: Colors.redAccent, fontSize: 9, fontWeight: FontWeight.bold),
                        ),
                      ),
                    ],
                  ],
                ),
                if (showMetaRow) ...[
                  const SizedBox(height: 3),
                  Row(
                    children: [
                      const SizedBox(width: 21),
                      Expanded(
                        child: Row(
                          children: [
                            if (hasProjectTag) ...[
                              Icon(Icons.folder_outlined, size: 10.5, color: isDark ? Colors.white38 : Colors.black45),
                              const SizedBox(width: 3),
                              Flexible(
                                child: Text(
                                  projectTag,
                                  style: TextStyle(fontSize: 10, color: isDark ? Colors.white38 : Colors.black45),
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                            ],
                            if (hasProjectTag && showTimestamp)
                              Padding(
                                padding: const EdgeInsets.symmetric(horizontal: 4),
                                child: Text(
                                  '·',
                                  style: TextStyle(fontSize: 10, color: isDark ? Colors.white24 : Colors.black26),
                                ),
                              ),
                            if (showTimestamp)
                              Text(
                                s.updatedAt,
                                style: TextStyle(color: isDark ? Colors.white30 : Colors.black38, fontSize: 10),
                                maxLines: 1,
                              ),
                          ],
                        ),
                      ),
                      if (showPinButton || widget.canDelete)
                        Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            if (showPinButton)
                              Tooltip(
                                message: s.isPinned ? '取消置顶' : '置顶会话',
                                child: InkWell(
                                  onTap: () => widget.onTogglePinSession!(s),
                                  borderRadius: BorderRadius.circular(12),
                                  child: Padding(
                                    padding: const EdgeInsets.all(3),
                                    child: Icon(
                                      s.isPinned ? Icons.push_pin_rounded : Icons.push_pin_outlined,
                                      size: 13.5,
                                      color: s.isPinned
                                          ? primary
                                          : (isDark ? Colors.white30 : Colors.black38),
                                    ),
                                  ),
                                ),
                              ),
                            if (widget.canDelete) ...[
                              const SizedBox(width: 2),
                              InkWell(
                                onTap: () => _confirmDeleteSession(context, s),
                                borderRadius: BorderRadius.circular(12),
                                child: Padding(
                                  padding: const EdgeInsets.all(3),
                                  child: Icon(
                                    Icons.delete_outline_rounded,
                                    size: 14,
                                    color: isDark ? Colors.white30 : Colors.black38,
                                  ),
                                ),
                              ),
                            ],
                          ],
                        ),
                    ],
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }

  void _showSessionActionSheet(BuildContext context, SessionItem s) {
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: isDark ? const Color(0xFF1E1E22) : Colors.white,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (ctx) {
        return SafeArea(
          child: ConstrainedBox(
            constraints: ResponsiveLayout.compactSheetConstraints(ctx),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 14, 16, 8),
                  child: Text(
                    s.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 13.5,
                      fontWeight: FontWeight.w600,
                      color: isDark ? Colors.white70 : Colors.black87,
                    ),
                  ),
                ),
                const Divider(height: 1),
                if (widget.canWrite && widget.onTogglePinSession != null)
                  ListTile(
                    leading: Icon(
                      s.isPinned ? Icons.push_pin_outlined : Icons.push_pin_rounded,
                      color: Theme.of(context).colorScheme.primary,
                    ),
                    title: Text(s.isPinned ? '取消置顶' : '置顶会话'),
                    onTap: () {
                      Navigator.pop(ctx);
                      widget.onTogglePinSession!(s);
                    },
                  ),
                if (widget.canDelete)
                  ListTile(
                    leading: const Icon(Icons.delete_outline_rounded, color: Colors.redAccent),
                    title: const Text('归档并移除会话', style: TextStyle(color: Colors.redAccent)),
                    onTap: () {
                      Navigator.pop(ctx);
                      _confirmDeleteSession(context, s);
                    },
                  ),
              ],
            ),
          ),
        );
      },
    );
  }

  void _confirmDeleteSession(BuildContext context, SessionItem s) {
    showDialog(
      context: context,
      builder: (ctx) {
        return AlertDialog(
          backgroundColor: isDark ? const Color(0xFF222226) : Colors.white,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
          title: const Text('归档并移除会话？', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
          content: Text(
            '确定要从列表归档移除「${s.title}」吗？\n不会破坏桌面端底层 SQLite 主库。',
            style: TextStyle(fontSize: 13, color: isDark ? Colors.white70 : Colors.black87),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: Text('取消', style: TextStyle(color: isDark ? Colors.white60 : Colors.black54)),
            ),
            ElevatedButton(
              onPressed: () {
                Navigator.pop(ctx);
                widget.onDeleteSession(s.id);
              },
              style: ElevatedButton.styleFrom(
                backgroundColor: Colors.redAccent.shade700,
                foregroundColor: Colors.white,
                elevation: 0,
              ),
              child: const Text('确认归档'),
            ),
          ],
        );
      },
    );
  }
}

class _ProjectBreathingDot extends StatefulWidget {
  final Color color;
  final int count;

  const _ProjectBreathingDot({
    super.key,
    required this.color,
    this.count = 1,
  });

  @override
  State<_ProjectBreathingDot> createState() => _ProjectBreathingDotState();
}

class _ProjectBreathingDotState extends State<_ProjectBreathingDot>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1200),
    )..repeat(reverse: true);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Semantics(
      label: '项目内有 ${widget.count} 个运行中会话',
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          AnimatedBuilder(
            animation: _controller,
            builder: (context, child) {
              final t = Curves.easeInOut.transform(_controller.value);
              return SizedBox(
                width: 14,
                height: 14,
                child: Stack(
                  alignment: Alignment.center,
                  children: [
                    Transform.scale(
                      scale: 0.75 + 0.50 * t,
                      child: Container(
                        width: 11,
                        height: 11,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: widget.color.withValues(alpha: 0.42 - 0.28 * t),
                        ),
                      ),
                    ),
                    child!,
                  ],
                ),
              );
            },
            child: Container(
              width: 7,
              height: 7,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: widget.color,
                boxShadow: [
                  BoxShadow(
                    color: widget.color.withValues(alpha: 0.45),
                    blurRadius: 4,
                  ),
                ],
              ),
            ),
          ),
          if (widget.count > 1) ...[
            const SizedBox(width: 4),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 0.5),
              decoration: BoxDecoration(
                color: widget.color.withValues(alpha: 0.16),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Text(
                '${widget.count}',
                style: TextStyle(
                  fontSize: 9.5,
                  fontWeight: FontWeight.w700,
                  color: widget.color,
                  height: 1.2,
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

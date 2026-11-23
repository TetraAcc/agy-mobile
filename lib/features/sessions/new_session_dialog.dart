import 'package:flutter/material.dart';

import '../../core/theme/app_colors.dart';
import '../../models/models.dart';

class NewSessionDialog extends StatefulWidget {
  final String initialMode;
  final String initialModel;
  final List<OfficialModelOption> models;
  final Map<String, ({String workspacePath, String rootId})>? availableProjects;
  final String? initialProjectName;
  final void Function(
    String prompt,
    String mode,
    String model,
    String? workspacePath,
    String? rootId,
  ) onStart;

  const NewSessionDialog({
    super.key,
    required this.initialMode,
    required this.initialModel,
    required this.models,
    this.availableProjects,
    this.initialProjectName,
    required this.onStart,
  });

  @override
  State<NewSessionDialog> createState() => _NewSessionDialogState();
}

class _NewSessionDialogState extends State<NewSessionDialog> {
  late final TextEditingController _promptController;
  late String _selectedMode;
  late String _selectedModel;
  String? _selectedProject;

  @override
  void initState() {
    super.initState();
    _promptController = TextEditingController();
    _selectedMode = (widget.initialMode == 'turbo' || widget.initialMode.isEmpty) ? 'auto' : widget.initialMode;
    _selectedModel = widget.initialModel;
    _selectedProject = widget.initialProjectName;
  }

  @override
  void dispose() {
    _promptController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final projectList = widget.availableProjects?.keys.toList() ?? [];

    return AlertDialog(
      backgroundColor: isDark ? AppColors.darkCard : Colors.white,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      title: Row(
        children: [
          Icon(Icons.add_comment_rounded, size: 20, color: Theme.of(context).colorScheme.primary),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              _selectedProject != null ? '在「$_selectedProject」开启新会话' : '开启全新会话',
              style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (projectList.isNotEmpty) ...[
              Text(
                '所属项目 / 关联工作区：',
                style: TextStyle(fontSize: 12, color: isDark ? Colors.white60 : Colors.black54),
              ),
              const SizedBox(height: 6),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 2),
                decoration: BoxDecoration(
                  color: isDark ? AppColors.darkBg : AppColors.lightBg,
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(
                    color: _selectedProject != null
                        ? Theme.of(context).colorScheme.primary.withValues(alpha: 0.5)
                        : (isDark ? AppColors.darkBorder : AppColors.lightBorder),
                  ),
                ),
                child: DropdownButtonHideUnderline(
                  child: DropdownButton<String?>(
                    value: projectList.contains(_selectedProject) ? _selectedProject : null,
                    isExpanded: true,
                    dropdownColor: isDark ? AppColors.darkCard : Colors.white,
                    icon: Icon(Icons.arrow_drop_down_rounded, color: isDark ? Colors.white70 : Colors.black54),
                    items: [
                      DropdownMenuItem<String?>(
                        value: null,
                        child: Row(
                          children: [
                            Icon(Icons.public_rounded, size: 16, color: isDark ? Colors.white60 : Colors.black54),
                            const SizedBox(width: 8),
                            Text(
                              '🌐 通用任务 (无项目绑定)',
                              style: TextStyle(fontSize: 12, color: isDark ? Colors.white70 : Colors.black87),
                            ),
                          ],
                        ),
                      ),
                      ...projectList.map(
                        (p) => DropdownMenuItem<String?>(
                          value: p,
                          child: Row(
                            children: [
                              Icon(Icons.folder_outlined, size: 16, color: Theme.of(context).colorScheme.primary),
                              const SizedBox(width: 8),
                              Expanded(
                                child: Text(
                                  p,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                    fontSize: 12,
                                    fontWeight: p == _selectedProject ? FontWeight.bold : FontWeight.normal,
                                    color: isDark ? Colors.white : Colors.black87,
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ],
                    onChanged: (val) => setState(() => _selectedProject = val),
                  ),
                ),
              ),
              const SizedBox(height: 14),
            ],
            Text(
              '初始任务或探讨主题：',
              style: TextStyle(fontSize: 12, color: isDark ? Colors.white60 : Colors.black54),
            ),
            const SizedBox(height: 6),
            TextField(
              controller: _promptController,
              autofocus: true,
              style: TextStyle(color: isDark ? Colors.white : Colors.black87),
              decoration: InputDecoration(
                hintText: _selectedProject != null
                    ? '例如：梳理 $_selectedProject 代码结构 / 实现新功能...'
                    : '例如：帮我梳理项目结构 / 编写一段经典算法...',
                hintStyle: TextStyle(color: isDark ? Colors.white24 : Colors.black26, fontSize: 12),
                filled: true,
                fillColor: isDark ? AppColors.darkBg : AppColors.lightBg,
                border: OutlineInputBorder(borderRadius: BorderRadius.circular(10), borderSide: BorderSide.none),
              ),
            ),
            const SizedBox(height: 14),
            Text(
              '运行模式：',
              style: TextStyle(fontSize: 12, color: isDark ? Colors.white60 : Colors.black54),
            ),
            const SizedBox(height: 6),
            Row(
              children: [
                _buildModeChip('auto', '🤖 Auto', isDark),
                const SizedBox(width: 6),
                _buildModeChip('accept-edits', '✏️ 自动编辑', isDark),
                const SizedBox(width: 6),
                _buildModeChip('plan', '📝 仅规划', isDark),
              ],
            ),
            const SizedBox(height: 6),
            Text(
              'Deck 节点直接应用运行模式；Windows 节点沿用桌面端安全策略',
              style: TextStyle(fontSize: 10.5, color: isDark ? Colors.white38 : Colors.black45),
            ),
            const SizedBox(height: 12),
            Text(
              '官方推理模型与思考分级：',
              style: TextStyle(fontSize: 12, color: isDark ? Colors.white60 : Colors.black54),
            ),
            const SizedBox(height: 6),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 2),
              decoration: BoxDecoration(
                color: isDark ? AppColors.darkBg : AppColors.lightBg,
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: isDark ? AppColors.darkBorder : AppColors.lightBorder),
              ),
              child: DropdownButtonHideUnderline(
                child: DropdownButton<String>(
                  value: widget.models.any((m) => m.id == _selectedModel)
                      ? _selectedModel
                      : widget.models.first.id,
                  isExpanded: true,
                  dropdownColor: isDark ? AppColors.darkCard : Colors.white,
                  icon: Icon(Icons.arrow_drop_down_rounded, color: isDark ? Colors.white70 : Colors.black54),
                  items: widget.models.map((m) {
                    return DropdownMenuItem<String>(
                      value: m.id,
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          Flexible(
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Text(m.icon, style: const TextStyle(fontSize: 13)),
                                const SizedBox(width: 8),
                                Flexible(
                                  child: Text(
                                    m.displayName,
                                    overflow: TextOverflow.ellipsis,
                                    style: TextStyle(
                                      fontSize: 12,
                                      fontWeight: m.id == _selectedModel ? FontWeight.bold : FontWeight.normal,
                                      color: isDark ? Colors.white : Colors.black87,
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ),
                          if (m.thinkingBadge.isNotEmpty)
                            Container(
                              padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1.5),
                              decoration: BoxDecoration(
                                color: m.thinkingBadge == 'High' || m.thinkingBadge == 'Thinking'
                                    ? (isDark
                                        ? AppColors.primaryBlue.withValues(alpha: 0.3)
                                        : const Color(0xFFE0F2FE))
                                    : (isDark ? Colors.white10 : Colors.black12),
                                borderRadius: BorderRadius.circular(4),
                              ),
                              child: Text(
                                m.thinkingBadge,
                                style: TextStyle(
                                  fontSize: 9.5,
                                  fontWeight: FontWeight.bold,
                                  color: m.thinkingBadge == 'High' || m.thinkingBadge == 'Thinking'
                                      ? (isDark ? AppColors.primarySky : AppColors.primaryBlue)
                                      : (isDark ? Colors.white60 : Colors.black54),
                                ),
                              ),
                            ),
                        ],
                      ),
                    );
                  }).toList(),
                  onChanged: (val) {
                    if (val != null) setState(() => _selectedModel = val);
                  },
                ),
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text('取消', style: TextStyle(color: isDark ? Colors.white60 : Colors.black54)),
        ),
        ElevatedButton(
          onPressed: () {
            final prompt = _promptController.text.trim();
            final info = (_selectedProject != null && widget.availableProjects != null)
                ? widget.availableProjects![_selectedProject]
                : null;
            Navigator.pop(context);
            widget.onStart(
              prompt.isEmpty ? '你好，开始新任务' : prompt,
              _selectedMode,
              _selectedModel,
              info?.workspacePath,
              info?.rootId,
            );
          },
          style: ElevatedButton.styleFrom(
            backgroundColor: Theme.of(context).colorScheme.primary,
            foregroundColor: Colors.white,
            elevation: 0,
          ),
          child: const Text('立即开启'),
        ),
      ],
    );
  }

  Widget _buildModeChip(String id, String label, bool isDark) {
    final isSelected = id == _selectedMode;
    return InkWell(
      onTap: () => setState(() => _selectedMode = id),
      borderRadius: BorderRadius.circular(8),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
        decoration: BoxDecoration(
          color: isSelected
              ? Theme.of(context).colorScheme.primary.withValues(alpha: 0.2)
              : (isDark ? Colors.white.withValues(alpha: 0.06) : Colors.black12),
          borderRadius: BorderRadius.circular(8),
          border: Border.all(
            color: isSelected ? Theme.of(context).colorScheme.primary : Colors.transparent,
          ),
        ),
        child: Text(
          label,
          style: TextStyle(
            fontSize: 11,
            fontWeight: isSelected ? FontWeight.bold : FontWeight.normal,
            color: isSelected
                ? Theme.of(context).colorScheme.primary
                : (isDark ? Colors.white70 : Colors.black87),
          ),
        ),
      ),
    );
  }
}

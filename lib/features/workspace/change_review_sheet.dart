import 'dart:async';

import 'package:flutter/material.dart';

import '../../core/config/responsive_layout.dart';
import '../../core/theme/app_colors.dart';
import '../../core/utils/file_utils.dart';
import '../../models/models.dart';

class ChangeReviewSheet extends StatefulWidget {
  final SessionChangesData? initialSessionChanges;
  final String? initialFilePath;
  final int? initialStepIndex;
  final int initialTabIndex;
  final String initialScope;
  final String? preferredRootId;
  final bool canWrite;
  final List<ReviewCommentItem> initialComments;
  final ValueChanged<List<ReviewCommentItem>>? onCommentsChanged;
  final Future<SessionChangesData> Function()? onLoadSessionChanges;
  final Future<SessionChangesData> Function({String scope, int? stepIndex})? onLoadSessionChangesScoped;
  final Future<List<GitRepoItem>> Function()? onLoadGitRepos;
  final Future<GitDiffData> Function(String rootId, String subPath, String scope)? onLoadGitDiff;
  final ValueChanged<String> onFillPrompt;
  final Future<String?> Function(String prompt) onSendPrompt;

  const ChangeReviewSheet({
    super.key,
    this.initialSessionChanges,
    this.initialFilePath,
    this.initialStepIndex,
    this.initialTabIndex = 0,
    this.initialScope = 'all',
    this.preferredRootId,
    this.canWrite = true,
    this.initialComments = const [],
    this.onCommentsChanged,
    this.onLoadSessionChanges,
    this.onLoadSessionChangesScoped,
    this.onLoadGitRepos,
    this.onLoadGitDiff,
    required this.onFillPrompt,
    required this.onSendPrompt,
  });

  static void show(
    BuildContext context, {
    SessionChangesData? initialSessionChanges,
    String? initialFilePath,
    int? initialStepIndex,
    int initialTabIndex = 0,
    String initialScope = 'all',
    String? preferredRootId,
    bool canWrite = true,
    List<ReviewCommentItem> initialComments = const [],
    ValueChanged<List<ReviewCommentItem>>? onCommentsChanged,
    Future<SessionChangesData> Function()? onLoadSessionChanges,
    Future<SessionChangesData> Function({String scope, int? stepIndex})? onLoadSessionChangesScoped,
    Future<List<GitRepoItem>> Function()? onLoadGitRepos,
    Future<GitDiffData> Function(String rootId, String subPath, String scope)? onLoadGitDiff,
    required ValueChanged<String> onFillPrompt,
    required Future<String?> Function(String prompt) onSendPrompt,
  }) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      constraints: ResponsiveLayout.workspaceSheetConstraints(context),
      backgroundColor: isDark ? const Color(0xFF111113) : Colors.white,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (ctx) => ChangeReviewSheet(
        initialSessionChanges: initialSessionChanges,
        initialFilePath: initialFilePath,
        initialStepIndex: initialStepIndex,
        initialTabIndex: initialTabIndex,
        initialScope: initialScope,
        preferredRootId: preferredRootId,
        canWrite: canWrite,
        initialComments: initialComments,
        onCommentsChanged: onCommentsChanged,
        onLoadSessionChanges: onLoadSessionChanges,
        onLoadSessionChangesScoped: onLoadSessionChangesScoped,
        onLoadGitRepos: onLoadGitRepos,
        onLoadGitDiff: onLoadGitDiff,
        onFillPrompt: onFillPrompt,
        onSendPrompt: onSendPrompt,
      ),
    );
  }

  @override
  State<ChangeReviewSheet> createState() => _ChangeReviewSheetState();
}

class _ChangeReviewSheetState extends State<ChangeReviewSheet> {
  late int _tabIndex;
  late List<ReviewCommentItem> _comments;

  // Session changes state
  late String _activeScope;
  SessionChangesData _sessionChanges = const SessionChangesData();
  bool _loadingSession = false;
  String? _sessionError;
  String? _selectedFilePath;
  bool _inlineWordMode = true;

  // Git state
  List<GitRepoItem> _gitRepos = const [];
  GitRepoItem? _selectedRepo;
  GitDiffData? _gitDiff;
  String _gitScope = 'uncommitted';
  bool _loadingGitRepos = false;
  bool _loadingGitDiff = false;
  String? _gitError;
  bool _gitLoadedOnce = false;

  // Submission state
  bool _submitting = false;
  String? _submitError;

  @override
  void initState() {
    super.initState();
    _tabIndex = widget.initialTabIndex;
    _activeScope = widget.initialScope;
    _comments = List<ReviewCommentItem>.from(widget.initialComments);
    _sessionChanges = widget.initialSessionChanges ?? const SessionChangesData();
    _selectedFilePath = _matchFilePath(_sessionChanges.files, widget.initialFilePath);
    if (_selectedFilePath != null) {
      _inlineWordMode = _defaultInlineMode(_selectedFilePath!);
    }
    if (widget.onLoadSessionChangesScoped != null || widget.onLoadSessionChanges != null) {
      unawaited(_loadSessionChanges());
    }
    if (_tabIndex == 1 && widget.onLoadGitRepos != null) {
      unawaited(_loadGitRepos());
    }
  }

  static String _normPath(String p) => p.trim().replaceAll('\\', '/').toLowerCase();

  String? _matchFilePath(List<SessionFileChange> files, String? target) {
    if (target == null || target.trim().isEmpty || files.isEmpty) return null;
    final normTarget = _normPath(target);
    for (final f in files) {
      if (_normPath(f.filePath) == normTarget) return f.filePath;
    }
    final targetName = normTarget.split('/').last;
    for (final f in files) {
      if (_normPath(f.fileName) == targetName) return f.filePath;
    }
    return null;
  }

  bool _defaultInlineMode(String filePath) {
    final lower = filePath.toLowerCase();
    const proseExts = {'.md', '.txt', '.tex', '.rst', '.org', '.csv', '.markdown'};
    return proseExts.any(lower.endsWith) || !lower.split('/').last.contains('.');
  }

  Future<void> _loadSessionChanges() async {
    final scopedLoader = widget.onLoadSessionChangesScoped;
    final legacyLoader = widget.onLoadSessionChanges;
    if (scopedLoader == null && legacyLoader == null) return;
    setState(() {
      _loadingSession = true;
      _sessionError = null;
    });
    try {
      final SessionChangesData data;
      if (scopedLoader != null) {
        if (_activeScope == 'step' && widget.initialStepIndex != null) {
          data = await scopedLoader(scope: 'all', stepIndex: widget.initialStepIndex);
        } else if (_activeScope == 'latest_turn') {
          data = await scopedLoader(scope: 'latest_turn');
        } else {
          data = await scopedLoader(scope: 'all');
        }
      } else {
        data = await legacyLoader!();
      }
      if (!mounted) return;
      final matched = _matchFilePath(data.files, _selectedFilePath ?? widget.initialFilePath);
      setState(() {
        _sessionChanges = data;
        _selectedFilePath = matched;
        if (matched != null) {
          _inlineWordMode = _defaultInlineMode(matched);
        }
        _loadingSession = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loadingSession = false;
        _sessionError = '加载本会话修改失败: $e';
      });
    }
  }

  void _switchSessionScope(String nextScope) {
    if (_activeScope == nextScope) return;
    setState(() {
      _activeScope = nextScope;
    });
    unawaited(_loadSessionChanges());
  }

  Future<void> _loadGitRepos() async {
    final loader = widget.onLoadGitRepos;
    if (loader == null) return;
    _gitLoadedOnce = true;
    setState(() {
      _loadingGitRepos = true;
      _gitError = null;
    });
    try {
      final repos = await loader();
      if (!mounted) return;
      GitRepoItem? initialRepo;
      if (repos.isNotEmpty) {
        if (widget.preferredRootId != null && widget.preferredRootId!.isNotEmpty) {
          for (final r in repos) {
            if (r.rootId == widget.preferredRootId) {
              initialRepo = r;
              break;
            }
          }
        }
        initialRepo ??= repos.firstWhere((r) => r.changeCount > 0, orElse: () => repos.first);
      }
      setState(() {
        _gitRepos = repos;
        _selectedRepo = initialRepo;
        _loadingGitRepos = false;
      });
      if (initialRepo != null) {
        await _loadGitDiff(initialRepo, _gitScope);
      }
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loadingGitRepos = false;
        _gitError = '扫描 Git 仓库失败: $e';
      });
    }
  }

  Future<void> _loadGitDiff(GitRepoItem repo, String scope) async {
    final loader = widget.onLoadGitDiff;
    if (loader == null) return;
    setState(() {
      _selectedRepo = repo;
      _gitScope = scope;
      _loadingGitDiff = true;
      _gitError = null;
    });
    try {
      final data = await loader(repo.rootId, repo.subPath, scope);
      if (!mounted) return;
      setState(() {
        _gitDiff = data;
        _loadingGitDiff = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loadingGitDiff = false;
        _gitError = '加载 Git Diff 失败: $e';
      });
    }
  }

  void _updateComments(List<ReviewCommentItem> next) {
    setState(() => _comments = next);
    widget.onCommentsChanged?.call(next);
  }

  Future<void> _openCommentEditor({
    required String filePath,
    required String fileName,
    required String locationLabel,
    required String excerpt,
    String? hunkId,
    int? stepIndex,
    ReviewCommentItem? existing,
  }) async {
    final result = await showDialog<String>(
      context: context,
      builder: (_) => _CommentEditorDialog(
        title: existing == null ? '添加批注 · $fileName' : '编辑批注 · $fileName',
        locationLabel: locationLabel,
        excerpt: excerpt,
        initialText: existing?.comment ?? '',
      ),
    );
    if (!mounted || result == null || result.isEmpty) return;

    final next = List<ReviewCommentItem>.from(_comments);
    if (existing != null) {
      final idx = next.indexWhere((c) => c.id == existing.id);
      if (idx >= 0) {
        next[idx] = existing.copyWith(comment: result);
      }
    } else {
      next.add(
        ReviewCommentItem(
          id: '${DateTime.now().microsecondsSinceEpoch}_${next.length}',
          filePath: filePath,
          fileName: fileName,
          locationLabel: locationLabel,
          excerpt: excerpt,
          comment: result,
          hunkId: hunkId,
          stepIndex: stepIndex,
        ),
      );
    }
    _updateComments(next);
  }

  Future<void> _submitComments({required bool sendImmediately}) async {
    if (_comments.isEmpty) return;
    final formatted = ReviewCommentItem.formatReviewPrompt(_comments);
    if (!sendImmediately) {
      widget.onFillPrompt(formatted);
      Navigator.pop(context);
      return;
    }

    setState(() {
      _submitting = true;
      _submitError = null;
    });
    final err = await widget.onSendPrompt(formatted);
    if (!mounted) return;
    if (err != null) {
      setState(() {
        _submitting = false;
        _submitError = err;
      });
      return;
    }
    _updateComments(const []);
    Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final primary = Theme.of(context).colorScheme.primary;
    final borderColor = isDark ? const Color(0xFF2C2C32) : const Color(0xFFE4E4E7);

    return Container(
      height: MediaQuery.of(context).size.height * 0.90,
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.rate_review_outlined, color: primary, size: 20),
              const SizedBox(width: 8),
              Text(
                '变更评审 (Diff)',
                style: TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.bold,
                  color: isDark ? Colors.white : Colors.black87,
                ),
              ),
              const Spacer(),
              IconButton(
                icon: const Icon(Icons.close_rounded, size: 20),
                onPressed: () => Navigator.pop(context),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Row(
            children: [
              _buildTabButton(0, '本会话修改 (${_sessionChanges.totalFiles})', isDark, primary),
              const SizedBox(width: 8),
              _buildTabButton(1, '工程 Git 变更', isDark, primary),
            ],
          ),
          const SizedBox(height: 10),
          Divider(height: 1, color: borderColor),
          const SizedBox(height: 10),
          Expanded(
            child: _tabIndex == 0 ? _buildSessionTab(isDark, primary, borderColor) : _buildGitTab(isDark, primary, borderColor),
          ),
          if (_comments.isNotEmpty) _buildCommentFooter(isDark, primary, borderColor),
        ],
      ),
    );
  }

  Widget _buildTabButton(int idx, String label, bool isDark, Color primary) {
    final selected = _tabIndex == idx;
    return InkWell(
      onTap: () {
        setState(() => _tabIndex = idx);
        if (idx == 1 && !_gitLoadedOnce && widget.onLoadGitRepos != null) {
          unawaited(_loadGitRepos());
        }
      },
      borderRadius: BorderRadius.circular(8),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        decoration: BoxDecoration(
          color: selected
              ? primary.withValues(alpha: isDark ? 0.2 : 0.12)
              : (isDark ? const Color(0xFF18181B) : const Color(0xFFF4F4F5)),
          borderRadius: BorderRadius.circular(8),
          border: Border.all(
            color: selected ? primary : (isDark ? Colors.white12 : Colors.black12),
          ),
        ),
        child: Text(
          label,
          style: TextStyle(
            fontSize: 12.5,
            fontWeight: selected ? FontWeight.bold : FontWeight.w500,
            color: selected ? primary : (isDark ? Colors.white70 : Colors.black87),
          ),
        ),
      ),
    );
  }

  Widget _buildScopeChip({
    required String label,
    required String scopeValue,
    required bool isDark,
    required Color primary,
    required Color borderColor,
  }) {
    final selected = _activeScope == scopeValue;
    return InkWell(
      onTap: () => _switchSessionScope(scopeValue),
      borderRadius: BorderRadius.circular(6),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
        decoration: BoxDecoration(
          color: selected
              ? primary.withValues(alpha: 0.16)
              : (isDark ? const Color(0xFF18181B) : const Color(0xFFF4F4F5)),
          borderRadius: BorderRadius.circular(6),
          border: Border.all(color: selected ? primary : borderColor),
        ),
        child: Text(
          label,
          style: TextStyle(
            fontSize: 11.5,
            fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
            color: selected ? primary : (isDark ? Colors.white70 : Colors.black87),
          ),
        ),
      ),
    );
  }

  Widget _buildScopeSelectorRow(bool isDark, Color primary, Color borderColor) {
    final hasLoader = widget.onLoadSessionChangesScoped != null || widget.onLoadSessionChanges != null;
    final hasStep = widget.initialStepIndex != null;
    if (!hasLoader && !hasStep && widget.initialScope == 'all') {
      return const SizedBox.shrink();
    }
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        children: [
          Text(
            '范围:',
            style: TextStyle(
              fontSize: 11.5,
              color: isDark ? Colors.white54 : Colors.black54,
            ),
          ),
          const SizedBox(width: 6),
          if (hasStep) ...[
            _buildScopeChip(
              label: '单步 #${widget.initialStepIndex}',
              scopeValue: 'step',
              isDark: isDark,
              primary: primary,
              borderColor: borderColor,
            ),
            const SizedBox(width: 6),
          ],
          _buildScopeChip(
            label: '最新修改',
            scopeValue: 'latest_turn',
            isDark: isDark,
            primary: primary,
            borderColor: borderColor,
          ),
          const SizedBox(width: 6),
          _buildScopeChip(
            label: '全部修改',
            scopeValue: 'all',
            isDark: isDark,
            primary: primary,
            borderColor: borderColor,
          ),
          const Spacer(),
          if (hasLoader)
            IconButton(
              tooltip: '刷新修改记录',
              visualDensity: VisualDensity.compact,
              padding: EdgeInsets.zero,
              constraints: const BoxConstraints(minWidth: 28, minHeight: 28),
              icon: _loadingSession
                  ? const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2))
                  : const Icon(Icons.refresh_rounded, size: 17),
              onPressed: _loadingSession ? null : _loadSessionChanges,
            ),
        ],
      ),
    );
  }

  Widget _buildSessionTab(bool isDark, Color primary, Color borderColor) {
    final scopeBar = _buildScopeSelectorRow(isDark, primary, borderColor);
    if (_loadingSession && _sessionChanges.files.isEmpty) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          scopeBar,
          const Expanded(child: Center(child: CircularProgressIndicator())),
        ],
      );
    }
    if (_sessionError != null && _sessionChanges.files.isEmpty) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          scopeBar,
          Expanded(
            child: Center(
              child: Text(_sessionError!, style: TextStyle(color: AppColors.statusRed(isDark), fontSize: 13)),
            ),
          ),
        ],
      );
    }
    if (_sessionChanges.files.isEmpty) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          scopeBar,
          Expanded(
            child: Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.fact_check_outlined, size: 46, color: isDark ? Colors.white24 : Colors.black26),
                  const SizedBox(height: 10),
                  Text(
                    '当前范围暂无文件修改记录',
                    style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: isDark ? Colors.white70 : Colors.black87),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    '可切换上方「全部修改」或「Git 变更」查看完整历史',
                    style: TextStyle(fontSize: 12, color: isDark ? Colors.white38 : Colors.black45),
                  ),
                ],
              ),
            ),
          ),
        ],
      );
    }

    SessionFileChange? selectedFile;
    if (_selectedFilePath != null) {
      for (final f in _sessionChanges.files) {
        if (_normPath(f.filePath) == _normPath(_selectedFilePath!)) {
          selectedFile = f;
          break;
        }
      }
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        scopeBar,
        Expanded(
          child: selectedFile == null
              ? _buildSessionFileList(isDark, primary, borderColor)
              : _buildSessionFileDetail(selectedFile, isDark, primary, borderColor),
        ),
      ],
    );
  }

  Widget _buildSessionFileList(bool isDark, Color primary, Color borderColor) {
    final files = _sessionChanges.files;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(bottom: 8),
          child: Row(
            children: [
              Text(
                '共 ${files.length} 个修改文件',
                style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.bold, color: isDark ? Colors.white70 : Colors.black87),
              ),
              const SizedBox(width: 8),
              Text(
                '+${_sessionChanges.totalAdded}',
                style: const TextStyle(fontSize: 12, fontFamily: 'monospace', fontWeight: FontWeight.bold, color: Color(0xFF4ADE80)),
              ),
              const SizedBox(width: 4),
              Text(
                '-${_sessionChanges.totalRemoved}',
                style: const TextStyle(fontSize: 12, fontFamily: 'monospace', fontWeight: FontWeight.bold, color: Color(0xFFF87171)),
              ),
            ],
          ),
        ),
        Expanded(
          child: ListView.separated(
            itemCount: files.length,
            separatorBuilder: (_, __) => const SizedBox(height: 6),
            itemBuilder: (ctx, idx) {
              final f = files[idx];
              final fileComments = _comments.where((c) => _normPath(c.filePath) == _normPath(f.filePath)).length;
              return InkWell(
                onTap: () {
                  setState(() {
                    _selectedFilePath = f.filePath;
                    _inlineWordMode = _defaultInlineMode(f.filePath);
                  });
                },
                borderRadius: BorderRadius.circular(10),
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                  decoration: BoxDecoration(
                    color: isDark ? const Color(0xFF18181B) : const Color(0xFFF8F8F9),
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(color: borderColor),
                  ),
                  child: Row(
                    children: [
                      Icon(
                        FileUtils.getFileIconData(f.fileName, false),
                        size: 18,
                        color: FileUtils.getFileIconColor(f.fileName, false, context),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              children: [
                                Flexible(
                                  child: Text(
                                    f.fileName,
                                    style: TextStyle(
                                      fontSize: 13.5,
                                      fontWeight: FontWeight.bold,
                                      color: isDark ? Colors.white : Colors.black87,
                                    ),
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                ),
                                const SizedBox(width: 6),
                                Text(
                                  '${f.editCount} 次修改',
                                  style: TextStyle(fontSize: 10.5, color: isDark ? Colors.white38 : Colors.black45),
                                ),
                                if (fileComments > 0) ...[
                                  const SizedBox(width: 6),
                                  Container(
                                    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
                                    decoration: BoxDecoration(
                                      color: primary.withValues(alpha: 0.16),
                                      borderRadius: BorderRadius.circular(10),
                                    ),
                                    child: Text(
                                      '$fileComments 批注',
                                      style: TextStyle(fontSize: 10, color: primary, fontWeight: FontWeight.bold),
                                    ),
                                  ),
                                ],
                              ],
                            ),
                            if (f.directory.isNotEmpty)
                              Padding(
                                padding: const EdgeInsets.only(top: 2),
                                child: Text(
                                  f.directory,
                                  style: TextStyle(
                                    fontSize: 11,
                                    fontFamily: 'monospace',
                                    color: isDark ? Colors.white38 : Colors.black45,
                                  ),
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                          ],
                        ),
                      ),
                      const SizedBox(width: 8),
                      Text(
                        '+${f.addedLines}',
                        style: const TextStyle(fontSize: 12, fontFamily: 'monospace', fontWeight: FontWeight.bold, color: Color(0xFF4ADE80)),
                      ),
                      const SizedBox(width: 4),
                      Text(
                        '-${f.removedLines}',
                        style: const TextStyle(fontSize: 12, fontFamily: 'monospace', fontWeight: FontWeight.bold, color: Color(0xFFF87171)),
                      ),
                      const SizedBox(width: 4),
                      Icon(Icons.chevron_right_rounded, size: 18, color: isDark ? Colors.white30 : Colors.black26),
                    ],
                  ),
                ),
              );
            },
          ),
        ),
      ],
    );
  }

  Widget _buildSessionFileDetail(SessionFileChange file, bool isDark, Color primary, Color borderColor) {
    var hunks = List<SessionEditHunk>.from(file.hunks);
    if (_activeScope == 'step' && widget.initialStepIndex != null) {
      final stepOnly = hunks.where((h) => h.stepIndex == widget.initialStepIndex).toList();
      if (stepOnly.isNotEmpty) {
        hunks = stepOnly;
      }
    } else if (widget.initialStepIndex != null) {
      hunks.sort((a, b) {
        final aMatch = a.stepIndex == widget.initialStepIndex ? 0 : 1;
        final bMatch = b.stepIndex == widget.initialStepIndex ? 0 : 1;
        if (aMatch != bMatch) return aMatch.compareTo(bMatch);
        return a.stepIndex.compareTo(b.stepIndex);
      });
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            TextButton.icon(
              style: TextButton.styleFrom(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                minimumSize: Size.zero,
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              ),
              onPressed: () => setState(() => _selectedFilePath = null),
              icon: const Icon(Icons.arrow_back_rounded, size: 16),
              label: Text('全部文件 (${_sessionChanges.files.length})', style: const TextStyle(fontSize: 12)),
            ),
            const Spacer(),
            SegmentedButton<bool>(
              segments: const [
                ButtonSegment<bool>(value: true, label: Text('句词对比', style: TextStyle(fontSize: 11.5))),
                ButtonSegment<bool>(value: false, label: Text('行级 Diff', style: TextStyle(fontSize: 11.5))),
              ],
              selected: {_inlineWordMode},
              showSelectedIcon: false,
              style: ButtonStyle(
                visualDensity: VisualDensity.compact,
                padding: WidgetStateProperty.all(const EdgeInsets.symmetric(horizontal: 10)),
              ),
              onSelectionChanged: (sel) {
                if (sel.isNotEmpty) setState(() => _inlineWordMode = sel.first);
              },
            ),
          ],
        ),
        const SizedBox(height: 6),
        Row(
          children: [
            Expanded(
              child: Text(
                file.filePath,
                style: TextStyle(
                  fontSize: 11.5,
                  fontFamily: 'monospace',
                  color: isDark ? Colors.white60 : Colors.black54,
                ),
                overflow: TextOverflow.ellipsis,
              ),
            ),
            const SizedBox(width: 8),
            Text(
              '+${file.addedLines}',
              style: const TextStyle(fontSize: 12, fontFamily: 'monospace', fontWeight: FontWeight.bold, color: Color(0xFF4ADE80)),
            ),
            const SizedBox(width: 4),
            Text(
              '-${file.removedLines}',
              style: const TextStyle(fontSize: 12, fontFamily: 'monospace', fontWeight: FontWeight.bold, color: Color(0xFFF87171)),
            ),
          ],
        ),
        const SizedBox(height: 8),
        Expanded(
          child: (_loadingSession && hunks.isEmpty)
              ? const Center(child: CircularProgressIndicator())
              : (hunks.isEmpty
                  ? Center(
                      child: Text(
                        '暂无该文件的具体改动详情',
                        style: TextStyle(fontSize: 13, color: isDark ? Colors.white54 : Colors.black45),
                      ),
                    )
                  : ListView.separated(
                      itemCount: hunks.length,
                      separatorBuilder: (_, __) => const SizedBox(height: 10),
                      itemBuilder: (ctx, idx) => _buildHunkCard(file, hunks[idx], isDark, primary, borderColor),
                    )),
        ),
      ],
    );
  }

  Widget _buildHunkCard(
    SessionFileChange file,
    SessionEditHunk hunk,
    bool isDark,
    Color primary,
    Color borderColor,
  ) {
    final hunkComments = _comments.where((c) => c.hunkId == hunk.hunkId && _normPath(c.filePath) == _normPath(file.filePath)).toList();
    final isHighlightedStep = widget.initialStepIndex != null && hunk.stepIndex == widget.initialStepIndex;

    return Container(
      decoration: BoxDecoration(
        color: isDark ? const Color(0xFF090D16) : const Color(0xFFF8F8F9),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(
          color: isHighlightedStep ? primary.withValues(alpha: 0.7) : borderColor,
          width: isHighlightedStep ? 1.5 : 1,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
            decoration: BoxDecoration(
              color: isDark ? const Color(0xFF18181B) : const Color(0xFFF4F4F5),
              borderRadius: const BorderRadius.vertical(top: Radius.circular(9)),
            ),
            child: Row(
              children: [
                Text(
                  '${hunk.lineLabel} (${hunk.toolName})',
                  style: TextStyle(
                    fontSize: 11.5,
                    fontFamily: 'monospace',
                    fontWeight: FontWeight.w600,
                    color: isDark ? Colors.white70 : Colors.black87,
                  ),
                ),
                const SizedBox(width: 8),
                Text(
                  '+${hunk.addedLines}',
                  style: const TextStyle(fontSize: 11, fontFamily: 'monospace', fontWeight: FontWeight.bold, color: Color(0xFF4ADE80)),
                ),
                const SizedBox(width: 4),
                Text(
                  '-${hunk.removedLines}',
                  style: const TextStyle(fontSize: 11, fontFamily: 'monospace', fontWeight: FontWeight.bold, color: Color(0xFFF87171)),
                ),
                const Spacer(),
                TextButton.icon(
                  style: TextButton.styleFrom(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                    minimumSize: Size.zero,
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  ),
                  onPressed: () => _openCommentEditor(
                    filePath: file.filePath,
                    fileName: file.fileName,
                    locationLabel: hunk.lineLabel,
                    excerpt: hunk.afterText.isNotEmpty ? hunk.afterText : hunk.beforeText,
                    hunkId: hunk.hunkId,
                    stepIndex: hunk.stepIndex,
                  ),
                  icon: Icon(Icons.add_comment_outlined, size: 14, color: primary),
                  label: Text('批注', style: TextStyle(fontSize: 11.5, color: primary)),
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.all(10),
            child: _inlineWordMode
                ? _buildInlineRichDiff(hunk, isDark)
                : _buildUnifiedDiffLines(
                    hunk.unifiedDiff,
                    isDark: isDark,
                    onTapLine: (line) => _openCommentEditor(
                      filePath: file.filePath,
                      fileName: file.fileName,
                      locationLabel: hunk.lineLabel,
                      excerpt: line,
                      hunkId: hunk.hunkId,
                      stepIndex: hunk.stepIndex,
                    ),
                  ),
          ),
          for (final comment in hunkComments) _buildInlineCommentBox(comment, isDark, primary),
        ],
      ),
    );
  }

  Widget _buildInlineRichDiff(SessionEditHunk hunk, bool isDark) {
    if (hunk.inlineSegments.isEmpty) {
      return Text(
        hunk.afterText.isNotEmpty ? hunk.afterText : hunk.beforeText,
        style: TextStyle(fontSize: 13.5, height: 1.65, color: isDark ? const Color(0xFFE4E4E7) : const Color(0xFF222226)),
      );
    }
    final baseStyle = TextStyle(
      fontSize: 13.5,
      height: 1.7,
      color: isDark ? const Color(0xFFE4E4E7) : const Color(0xFF222226),
    );
    return SelectableText.rich(
      TextSpan(
        style: baseStyle,
        children: hunk.inlineSegments.map((seg) {
          if (seg.kind == 'delete') {
            return TextSpan(
              text: seg.text,
              style: baseStyle.copyWith(
                backgroundColor: const Color(0x38EF4444),
                color: isDark ? const Color(0xFFFCA5A5) : const Color(0xFFB91C1C),
                decoration: TextDecoration.lineThrough,
                decorationColor: const Color(0xFFEF4444),
              ),
            );
          }
          if (seg.kind == 'insert') {
            return TextSpan(
              text: seg.text,
              style: baseStyle.copyWith(
                backgroundColor: const Color(0x3822C55E),
                color: isDark ? const Color(0xFF86EFAC) : const Color(0xFF15803D),
                fontWeight: FontWeight.w500,
              ),
            );
          }
          return TextSpan(text: seg.text, style: baseStyle);
        }).toList(),
      ),
    );
  }

  Widget _buildUnifiedDiffLines(
    String diffText, {
    required bool isDark,
    required ValueChanged<String> onTapLine,
  }) {
    final lines = diffText.isEmpty ? <String>[] : diffText.split('\n');
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: lines.map((line) {
          Color? bgColor;
          var textColor = isDark ? const Color(0xFFE4E4E7) : const Color(0xFF222226);
          var fontWeight = FontWeight.normal;
          var tappable = false;

          if (line.startsWith('+') && !line.startsWith('+++')) {
            bgColor = const Color(0x2822C55E);
            textColor = isDark ? const Color(0xFF4ADE80) : const Color(0xFF15803D);
            tappable = true;
          } else if (line.startsWith('-') && !line.startsWith('---')) {
            bgColor = const Color(0x28EF4444);
            textColor = isDark ? const Color(0xFFF87171) : const Color(0xFFB91C1C);
            tappable = true;
          } else if (line.startsWith('@@')) {
            bgColor = const Color(0x1F38BDF8);
            textColor = const Color(0xFF38BDF8);
            fontWeight = FontWeight.bold;
          } else if (line.startsWith('diff --git')) {
            textColor = Theme.of(context).colorScheme.primary;
            fontWeight = FontWeight.bold;
          }

          final row = Container(
            color: bgColor,
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1.5),
            child: Text(
              line,
              style: TextStyle(
                fontFamily: 'monospace',
                fontSize: 11.5,
                color: textColor,
                fontWeight: fontWeight,
                height: 1.45,
              ),
            ),
          );

          if (!tappable) return row;
          return InkWell(
            onTap: () => onTapLine(line),
            child: row,
          );
        }).toList(),
      ),
    );
  }

  Widget _buildInlineCommentBox(ReviewCommentItem item, bool isDark, Color primary) {
    return Container(
      margin: const EdgeInsets.fromLTRB(10, 0, 10, 10),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: BoxDecoration(
        color: primary.withValues(alpha: isDark ? 0.14 : 0.08),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: primary.withValues(alpha: 0.45)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.comment_outlined, size: 15, color: primary),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (item.locationLabel.isNotEmpty)
                  Text(
                    item.locationLabel,
                    style: TextStyle(fontSize: 10.5, fontFamily: 'monospace', color: primary, fontWeight: FontWeight.bold),
                  ),
                Text(
                  item.comment,
                  style: TextStyle(fontSize: 12.5, color: isDark ? Colors.white : Colors.black87),
                ),
              ],
            ),
          ),
          IconButton(
            tooltip: '编辑批注',
            icon: const Icon(Icons.edit_outlined, size: 15),
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints(minWidth: 26, minHeight: 26),
            onPressed: () => _openCommentEditor(
              filePath: item.filePath,
              fileName: item.fileName,
              locationLabel: item.locationLabel,
              excerpt: item.excerpt,
              hunkId: item.hunkId,
              stepIndex: item.stepIndex,
              existing: item,
            ),
          ),
          IconButton(
            tooltip: '删除批注',
            icon: Icon(Icons.delete_outline_rounded, size: 15, color: AppColors.statusRed(isDark)),
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints(minWidth: 26, minHeight: 26),
            onPressed: () => _updateComments(_comments.where((c) => c.id != item.id).toList()),
          ),
        ],
      ),
    );
  }

  Widget _buildGitTab(bool isDark, Color primary, Color borderColor) {
    if (_loadingGitRepos) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_gitError != null && _gitRepos.isEmpty) {
      return Center(child: Text(_gitError!, style: TextStyle(color: AppColors.statusRed(isDark), fontSize: 13)));
    }
    if (_gitRepos.isEmpty) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.source_outlined, size: 46, color: isDark ? Colors.white24 : Colors.black26),
            const SizedBox(height: 10),
            Text(
              '当前节点未扫描到 Git 仓库',
              style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: isDark ? Colors.white70 : Colors.black87),
            ),
            const SizedBox(height: 4),
            Text(
              '普通文稿/小说项目可直接在「本会话修改」查看逐句 Diff',
              style: TextStyle(fontSize: 12, color: isDark ? Colors.white38 : Colors.black45),
            ),
          ],
        ),
      );
    }

    final diffText = (_gitDiff?.diff ?? '').trim();
    final statusLines = (_gitDiff?.status ?? '').trim().isEmpty
        ? <String>[]
        : _gitDiff!.status.split('\n').where((s) => s.trim().isNotEmpty).toList();
    final repoComments = _selectedRepo == null
        ? <ReviewCommentItem>[]
        : _comments.where((c) => c.hunkId == 'git:${_selectedRepo!.id}').toList();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 10),
                decoration: BoxDecoration(
                  color: isDark ? const Color(0xFF18181B) : const Color(0xFFF4F4F5),
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: borderColor),
                ),
                child: DropdownButtonHideUnderline(
                  child: DropdownButton<String>(
                    value: _selectedRepo?.id,
                    isExpanded: true,
                    isDense: true,
                    dropdownColor: isDark ? const Color(0xFF222226) : Colors.white,
                    items: _gitRepos
                        .map(
                          (r) => DropdownMenuItem<String>(
                            value: r.id,
                            child: Text(
                              r.displayLabel,
                              style: TextStyle(fontSize: 12.5, color: isDark ? Colors.white : Colors.black87),
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                        )
                        .toList(),
                    onChanged: (val) {
                      if (val == null) return;
                      final target = _gitRepos.firstWhere((r) => r.id == val);
                      unawaited(_loadGitDiff(target, _gitScope));
                    },
                  ),
                ),
              ),
            ),
            const SizedBox(width: 8),
            SegmentedButton<String>(
              segments: const [
                ButtonSegment<String>(value: 'uncommitted', label: Text('未提交', style: TextStyle(fontSize: 11.5))),
                ButtonSegment<String>(value: 'head', label: Text('最近提交', style: TextStyle(fontSize: 11.5))),
              ],
              selected: {_gitScope},
              showSelectedIcon: false,
              style: ButtonStyle(
                visualDensity: VisualDensity.compact,
                padding: WidgetStateProperty.all(const EdgeInsets.symmetric(horizontal: 10)),
              ),
              onSelectionChanged: (sel) {
                if (sel.isNotEmpty && _selectedRepo != null) {
                  unawaited(_loadGitDiff(_selectedRepo!, sel.first));
                }
              },
            ),
          ],
        ),
        const SizedBox(height: 8),
        if (statusLines.isNotEmpty) ...[
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: statusLines.map((s) {
              final isModified = s.contains('M');
              final isAdded = s.contains('A') || s.contains('?');
              final isDeleted = s.contains('D');
              final color = isModified
                  ? const Color(0xFFF59E0B)
                  : (isAdded ? const Color(0xFF10B981) : (isDeleted ? const Color(0xFFEF4444) : Colors.blueGrey));
              return Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                decoration: BoxDecoration(
                  color: color.withValues(alpha: 0.15),
                  borderRadius: BorderRadius.circular(6),
                  border: Border.all(color: color.withValues(alpha: 0.3)),
                ),
                child: Text(
                  s.trim(),
                  style: TextStyle(fontSize: 11, fontFamily: 'monospace', color: color, fontWeight: FontWeight.bold),
                ),
              );
            }).toList(),
          ),
          const SizedBox(height: 8),
        ],
        Expanded(
          child: _loadingGitDiff
              ? const Center(child: CircularProgressIndicator())
              : (_gitError != null)
                  ? Center(child: Text(_gitError!, style: TextStyle(color: AppColors.statusRed(isDark), fontSize: 13)))
                  : (diffText.isEmpty || diffText == 'No commits yet')
                      ? Center(
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(Icons.check_circle_outline_rounded, color: AppColors.statusGreen(isDark), size: 42),
                              const SizedBox(height: 8),
                              Text(
                                diffText == 'No commits yet'
                                    ? '该 Git 仓库尚无任何提交记录'
                                    : (statusLines.isEmpty ? '工作区干净 (Clean)' : '当前仅有未跟踪文件'),
                                style: TextStyle(fontWeight: FontWeight.bold, color: isDark ? Colors.white70 : Colors.black87),
                              ),
                              const SizedBox(height: 4),
                              Text(
                                '可切换右上角「最近提交」查看上次 commit，或点击任何 Diff 行挂批注',
                                style: TextStyle(fontSize: 11.5, color: isDark ? Colors.white38 : Colors.black45),
                              ),
                            ],
                          ),
                        )
                      : Container(
                          width: double.infinity,
                          padding: const EdgeInsets.all(8),
                          decoration: BoxDecoration(
                            color: isDark ? const Color(0xFF090D16) : const Color(0xFFF8F8F9),
                            borderRadius: BorderRadius.circular(10),
                            border: Border.all(color: borderColor),
                          ),
                          child: SingleChildScrollView(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                _buildUnifiedDiffLines(
                                  diffText,
                                  isDark: isDark,
                                  onTapLine: (line) {
                                    final repo = _selectedRepo!;
                                    _openCommentEditor(
                                      filePath: _gitDiff?.workspace ?? repo.name,
                                      fileName: repo.name,
                                      locationLabel: _gitScope == 'head' ? 'Git HEAD' : 'Git Diff',
                                      excerpt: line,
                                      hunkId: 'git:${repo.id}',
                                    );
                                  },
                                ),
                                for (final c in repoComments) ...[
                                  const SizedBox(height: 8),
                                  _buildInlineCommentBox(c, isDark, primary),
                                ],
                              ],
                            ),
                          ),
                        ),
        ),
      ],
    );
  }

  Widget _buildCommentFooter(bool isDark, Color primary, Color borderColor) {
    return Container(
      margin: const EdgeInsets.only(top: 10),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: isDark ? const Color(0xFF18181B) : const Color(0xFFF8F8F9),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: primary.withValues(alpha: 0.4)),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (_submitError != null)
            Padding(
              padding: const EdgeInsets.only(bottom: 6),
              child: Text(_submitError!, style: TextStyle(color: AppColors.statusRed(isDark), fontSize: 12)),
            ),
          Row(
            children: [
              Icon(Icons.checklist_rounded, size: 16, color: primary),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  '已添加 ${_comments.length} 条批注',
                  style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.bold, color: isDark ? Colors.white : Colors.black87),
                ),
              ),
              TextButton(
                onPressed: _submitting ? null : () => _submitComments(sendImmediately: false),
                child: const Text('填入输入框', style: TextStyle(fontSize: 12)),
              ),
              if (widget.canWrite) ...[
                const SizedBox(width: 6),
                ElevatedButton.icon(
                  onPressed: _submitting ? null : () => _submitComments(sendImmediately: true),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: primary,
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                    minimumSize: Size.zero,
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  ),
                  icon: _submitting
                      ? const SizedBox(width: 13, height: 13, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                      : const Icon(Icons.send_rounded, size: 14),
                  label: const Text('提交批注', style: TextStyle(fontSize: 12)),
                ),
              ],
            ],
          ),
        ],
      ),
    );
  }
}

class _CommentEditorDialog extends StatefulWidget {
  final String title;
  final String locationLabel;
  final String excerpt;
  final String initialText;

  const _CommentEditorDialog({
    required this.title,
    required this.locationLabel,
    required this.excerpt,
    required this.initialText,
  });

  @override
  State<_CommentEditorDialog> createState() => _CommentEditorDialogState();
}

class _CommentEditorDialogState extends State<_CommentEditorDialog> {
  late final TextEditingController _controller;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: widget.initialText);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final excerpt = widget.excerpt.trim();
    return AlertDialog(
      backgroundColor: isDark ? const Color(0xFF222226) : Colors.white,
      title: Text(
        widget.title,
        style: TextStyle(fontSize: 15, color: isDark ? Colors.white : Colors.black87),
      ),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (widget.locationLabel.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(bottom: 6),
                child: Text(
                  widget.locationLabel,
                  style: TextStyle(
                    fontSize: 11,
                    fontFamily: 'monospace',
                    color: Theme.of(context).colorScheme.primary,
                  ),
                ),
              ),
            if (excerpt.isNotEmpty)
              Container(
                width: double.infinity,
                margin: const EdgeInsets.only(bottom: 10),
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: isDark ? const Color(0xFF111113) : const Color(0xFFF4F4F5),
                  borderRadius: BorderRadius.circular(6),
                  border: Border.all(color: isDark ? Colors.white12 : Colors.black12),
                ),
                child: Text(
                  excerpt.length > 200 ? '${excerpt.substring(0, 200)}...' : excerpt,
                  style: TextStyle(
                    fontSize: 11.5,
                    color: isDark ? Colors.white70 : Colors.black87,
                  ),
                ),
              ),
            TextField(
              controller: _controller,
              autofocus: true,
              maxLines: 4,
              minLines: 2,
              style: TextStyle(color: isDark ? Colors.white : Colors.black87, fontSize: 13),
              decoration: InputDecoration(
                hintText: '输入评审意见 / 修改要求...',
                hintStyle: TextStyle(color: isDark ? Colors.white30 : Colors.black26, fontSize: 12.5),
                filled: true,
                fillColor: isDark ? const Color(0xFF111113) : const Color(0xFFF8F8F9),
                border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('取消')),
        ElevatedButton(
          onPressed: () {
            final txt = _controller.text.trim();
            if (txt.isEmpty) return;
            Navigator.pop(context, txt);
          },
          style: ElevatedButton.styleFrom(
            backgroundColor: Theme.of(context).colorScheme.primary,
            foregroundColor: Colors.white,
          ),
          child: const Text('保存批注'),
        ),
      ],
    );
  }
}

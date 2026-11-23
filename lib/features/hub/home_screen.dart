import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/config/composer_prefs.dart';
import '../../core/network/api_client.dart';
import '../../core/platform/platform_bridge.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/theme_provider.dart';
import '../../models/models.dart';
import '../auth/auth_controller.dart';
import '../chat/bottom_input_bar.dart';
import '../chat/context_menu_sheet.dart';
import '../chat/message_card.dart';
import '../chat/session_queue_bar.dart';
import '../chat/session_steps_bar.dart';
import '../sessions/new_session_dialog.dart';
import '../sessions/quota_drawer.dart';
import '../workspace/change_review_sheet.dart';
import '../workspace/file_viewer_sheet.dart';
import '../workspace/session_artifacts_sheet.dart';
import '../workspace/session_changes_bar.dart';
import '../workspace/tool_detail_sheet.dart';
import '../workspace/workspace_file_picker_dialog.dart';
import 'hub_controller.dart';

class HomeScreen extends ConsumerStatefulWidget {
  final UserProfile user;

  const HomeScreen({super.key, required this.user});

  @override
  ConsumerState<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends ConsumerState<HomeScreen> with WidgetsBindingObserver {
  final GlobalKey<ScaffoldState> _scaffoldKey = GlobalKey<ScaffoldState>();
  final TextEditingController _inputController = TextEditingController();
  final TextEditingController _chatSearchController = TextEditingController();
  final ScrollController _scrollController = ScrollController();

  bool _showScrollToBottom = false;
  bool _isChatSearching = false;
  String _chatSearchQuery = '';
  VoidCallback? _disposeWebPaste;
  String _commentSessionId = '';
  List<ReviewCommentItem> _draftComments = const [];
  DateTime? _lastBackPressAt;

  List<ReviewCommentItem> _commentsForSession(String sessionId) {
    if (sessionId.isEmpty || sessionId != _commentSessionId) return const [];
    return _draftComments;
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _scrollController.addListener(_onScrollChanged);
    _disposeWebPaste = PlatformBridge.registerWebDropAndPaste(_onPickedLocalFile);
    Future.microtask(() {
      ref.read(hubControllerProvider.notifier).initializeForUser(widget.user);
    });
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final notifier = ref.read(hubControllerProvider.notifier);
    if (state == AppLifecycleState.paused || state == AppLifecycleState.hidden) {
      notifier.handleAppPaused();
    } else if (state == AppLifecycleState.resumed) {
      notifier.handleAppResumed();
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _disposeWebPaste?.call();
    _scrollController.removeListener(_onScrollChanged);
    _scrollController.dispose();
    _chatSearchController.dispose();
    _inputController.dispose();
    super.dispose();
  }

  void _onScrollChanged() {
    if (!_scrollController.hasClients) return;
    final isFar = _scrollController.offset > 120;
    if (isFar != _showScrollToBottom) {
      setState(() => _showScrollToBottom = isFar);
    }
  }

  void _scrollToBottom() {
    if (_scrollController.hasClients) {
      _scrollController.animateTo(
        0,
        duration: const Duration(milliseconds: 300),
        curve: Curves.easeOutCubic,
      );
    }
  }

  void _showSnack(String message, {bool isError = false}) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        backgroundColor: isError ? Colors.redAccent.shade700 : null,
        behavior: SnackBarBehavior.floating,
        duration: const Duration(seconds: 2),
      ),
    );
  }

  Future<void> _onPickedLocalFile(PickedLocalFile picked) async {
    HapticFeedback.mediumImpact();
    final err = await ref.read(hubControllerProvider.notifier).uploadAttachment(
          filename: picked.filename,
          bytes: picked.bytes,
          isImage: picked.isImage,
        );
    if (err != null) {
      _showSnack(err, isError: true);
    } else {
      _showSnack('📎 附件已就绪: ${picked.filename}');
    }
  }

  Future<void> _pickAndUpload({required bool imagesOnly}) async {
    final picked = await PlatformBridge.pickFile(imagesOnly: imagesOnly);
    if (picked != null) {
      await _onPickedLocalFile(picked);
    }
  }

  Future<void> _handleSendMessage() async {
    final text = _inputController.text;
    final hubState = ref.read(hubControllerProvider);
    if (text.trim().isEmpty && hubState.pendingAttachments.isEmpty) {
      return;
    }
    final prefs = ref.read(composerPrefsProvider);
    final expectQueue = prefs.isQueueEnabled &&
        (hubState.isActiveSessionRunning || hubState.sessionQueue.items.isNotEmpty);

    _inputController.clear();
    if (_scrollController.hasClients) {
      _scrollToBottom();
    }
    final err = await ref.read(hubControllerProvider.notifier).sendMessage(
          text,
          deliveryMode: prefs.queueMode,
        );
    if (err != null) {
      _showSnack(err, isError: true);
    } else {
      HapticFeedback.lightImpact();
      if (expectQueue) {
        _showSnack('已加入待发队列');
      }
    }
  }

  Future<void> _handleStopTask() async {
    HapticFeedback.heavyImpact();
    final err = await ref.read(hubControllerProvider.notifier).stopActiveSession();
    if (err != null) {
      _showSnack(err, isError: true);
    } else {
      _showSnack('已向 Agent 发送停止指令');
    }
  }

  Future<void> _handleSwitchNode(String nodeId) async {
    final err = await ref.read(hubControllerProvider.notifier).switchNode(nodeId);
    if (err != null) {
      _showSnack(err, isError: true);
    }
  }

  Future<void> _handleDeleteSession(String sessionId) async {
    final err = await ref.read(hubControllerProvider.notifier).deleteSession(sessionId);
    if (err != null) {
      _showSnack(err, isError: true);
    } else {
      _showSnack('已归档移除该会话');
    }
  }

  void _showNewSessionDialog({
    String? initialProjectName,
    String? initialWorkspacePath,
    String? initialRootId,
  }) {
    final hubState = ref.read(hubControllerProvider);
    final projectMap = <String, ({String workspacePath, String rootId})>{};
    for (final entry in hubState.projects.entries) {
      if (entry.value.isEmpty) continue;
      final firstWithWs = entry.value.firstWhere(
        (s) => s.workspacePath.isNotEmpty,
        orElse: () => entry.value.first,
      );
      if (firstWithWs.workspacePath.isNotEmpty) {
        projectMap[entry.key] = (
          workspacePath: firstWithWs.workspacePath,
          rootId: firstWithWs.rootId.isNotEmpty ? firstWithWs.rootId : 'scratch',
        );
      }
    }

    showDialog(
      context: context,
      builder: (ctx) => NewSessionDialog(
        initialMode: hubState.selectedMode,
        initialModel: hubState.selectedModel,
        models: kAllOfficialModels,
        availableProjects: projectMap,
        initialProjectName: initialProjectName,
        onStart: (prompt, mode, model, wsPath, rootId) async {
          final err = await ref.read(hubControllerProvider.notifier).createNewSession(
                content: prompt,
                mode: mode,
                model: model,
                workspacePath: wsPath ?? initialWorkspacePath,
                rootId: rootId ?? initialRootId,
              );
          if (err != null) {
            _showSnack(err, isError: true);
          }
        },
      ),
    );
  }

  Future<String?> _readAndOpenTextFile(String rootId, String relPath) async {
    final hub = ref.read(hubControllerProvider.notifier);
    final hubState = ref.read(hubControllerProvider);
    try {
      final data = await hub.readFileContent(rootId, relPath);
      if (!mounted) return null;
      final isProtectedBrain = rootId == 'brain' &&
          (relPath.contains('.system_generated') || relPath.contains('.user_uploaded'));
      FileViewerSheet.show(
        context,
        rootId: data.rootId,
        name: data.name,
        path: data.path,
        content: data.content,
        totalLines: data.totalLines,
        truncated: data.truncated,
        size: data.size,
        mtime: data.mtime,
        canWrite: hubState.canWrite && !isProtectedBrain,
        onSave: (newContent, expectedMtime) => hub.saveFileContent(
          data.rootId,
          data.path,
          newContent,
          expectedMtime: expectedMtime,
        ),
        onInsertReference: _insertText,
        onDownloadFallback: (p) => _downloadFile(p, rootId: rootId, filename: data.name),
      );
      return null;
    } on BinaryFileApiException {
      return await _downloadFileResult(relPath, rootId: rootId);
    } on ApiException catch (e) {
      return '读取失败: ${e.message}';
    } catch (e) {
      return '读取异常: $e';
    }
  }

  Future<void> _openWorkspaceFilePicker() async {
    final hub = ref.read(hubControllerProvider.notifier);
    final roots = await hub.refreshFileRoots();
    final state = ref.read(hubControllerProvider);
    if (roots.isEmpty) {
      _showSnack('当前节点没有配置可浏览的文件根目录', isError: true);
      return;
    }

    final initialRoot = roots.any((r) => r.id == state.activeRootId) ? state.activeRootId : roots.first.id;
    if (!mounted) return;
    final isDark = Theme.of(context).brightness == Brightness.dark;

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: isDark ? const Color(0xFF161F30) : Colors.white,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (ctx) => _WorkspaceBrowserSheet(
        roots: roots,
        initialRootId: initialRoot,
        isDark: isDark,
        onBrowse: (rootId, subPath) => hub.browseFiles(rootId, subPath: subPath),
        onReadFile: _readAndOpenTextFile,
        onDownload: (rootId, relPath) => _downloadFileResult(relPath, rootId: rootId),
        onOpenMediaExternal: (rootId, relPath) => hub.openMediaExternal(relPath, rootId: rootId),
        buildDirectMediaUrl: (rootId, relPath) => hub.buildDirectMediaUrlForRoot(rootId, relPath),
        mediaHeaders: hub.mediaHeaders,
        onInsertRef: _insertText,
      ),
    );
  }

  void _openToolDetail(int stepIndex, ToolCallItem tool) {
    final hub = ref.read(hubControllerProvider.notifier);
    final isDark = Theme.of(context).brightness == Brightness.dark;
    ToolDetailSheet.show(
      context,
      stepIndex: stepIndex,
      initialTool: tool,
      isDark: isDark,
      onLoadOutput: (idx) => hub.fetchStepToolOutput(idx),
    );
  }

  Future<String?> _sendPromptDirect(String prompt) async {
    final err = await ref.read(hubControllerProvider.notifier).sendMessage(prompt);
    if (err == null && mounted) {
      _scrollToBottom();
    }
    return err;
  }

  void _openSessionArtifacts() {
    final hubState = ref.read(hubControllerProvider);
    final hub = ref.read(hubControllerProvider.notifier);
    if (hubState.activeSessionId.isEmpty) {
      _showSnack('请先选择一个会话');
      return;
    }
    final isDark = Theme.of(context).brightness == Brightness.dark;
    SessionArtifactsSheet.show(
      context,
      sessionTitle: hubState.activeSessionTitle,
      isDark: isDark,
      canWrite: hubState.canWrite,
      onLoadArtifacts: () => hub.fetchSessionArtifacts(),
      onPreviewText: (item) async {
        final err = await _readAndOpenTextFile(item.rootId, item.relPath);
        if (err != null && mounted) {
          _showSnack(err, isError: true);
        }
      },
      onPreviewImage: (item) {
        final url = hub.buildDirectMediaUrlForRoot(item.rootId, item.relPath);
        if (url == null) return;
        showDialog(
          context: context,
          builder: (ctx) => Dialog(
            backgroundColor: Colors.black87,
            insetPadding: const EdgeInsets.all(14),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                AppBar(
                  backgroundColor: Colors.transparent,
                  elevation: 0,
                  title: Text(item.name, style: const TextStyle(color: Colors.white, fontSize: 13)),
                  leading: IconButton(
                    icon: const Icon(Icons.close_rounded, color: Colors.white),
                    onPressed: () => Navigator.pop(ctx),
                  ),
                ),
                Flexible(
                  child: InteractiveViewer(
                    child: Image.network(url, headers: hub.mediaHeaders, fit: BoxFit.contain),
                  ),
                ),
                const SizedBox(height: 12),
              ],
            ),
          ),
        );
      },
      onDownload: (item) => _downloadFile(item.relPath, rootId: item.rootId, filename: item.name),
      onSendPrompt: _sendPromptDirect,
    );
  }

  void _openChangeReview({
    String? initialFilePath,
    int? initialStepIndex,
    int initialTabIndex = 0,
  }) {
    final hubState = ref.read(hubControllerProvider);
    final hubNotifier = ref.read(hubControllerProvider.notifier);
    final sid = hubState.activeSessionId;

    ChangeReviewSheet.show(
      context,
      initialSessionChanges: hubState.sessionChanges,
      initialFilePath: initialFilePath,
      initialStepIndex: initialStepIndex,
      initialTabIndex: initialTabIndex,
      preferredRootId: hubState.activeRootId,
      canWrite: hubState.canWrite,
      initialComments: _commentsForSession(sid),
      onCommentsChanged: (next) {
        if (!mounted) return;
        setState(() {
          _commentSessionId = sid;
          _draftComments = List<ReviewCommentItem>.from(next);
        });
      },
      onLoadSessionChanges: sid.isEmpty ? null : () => hubNotifier.fetchSessionChangesDetail(),
      onLoadGitRepos: () => hubNotifier.fetchGitRepos(),
      onLoadGitDiff: (rid, sub, scope) => hubNotifier.fetchGitDiff(rootId: rid, subPath: sub, scope: scope),
      onFillPrompt: _insertText,
      onSendPrompt: (prompt) async {
        final err = await hubNotifier.sendMessage(prompt);
        if (err == null && mounted) {
          _scrollToBottom();
        }
        return err;
      },
    );
  }

  Future<String?> _downloadFileResult(String pathOrUri, {String? rootId, String? filename}) async {
    return ref
        .read(hubControllerProvider.notifier)
        .downloadFile(pathOrUri, rootId: rootId, filename: filename);
  }

  Future<void> _downloadFile(String pathOrUri, {String? rootId, String? filename}) async {
    final err = await _downloadFileResult(pathOrUri, rootId: rootId, filename: filename);
    if (err != null) {
      _showSnack(err, isError: true);
    } else {
      _showSnack('已发起安全下载');
    }
  }

  Future<void> _openMediaExternal(String rawPath, {String? rootId}) async {
    final err = await ref.read(hubControllerProvider.notifier).openMediaExternal(rawPath, rootId: rootId);
    if (err != null) {
      _showSnack(err, isError: true);
    }
  }

  void _insertText(String text) {
    final val = _inputController.value;
    final sel = val.selection;
    final oldText = val.text;
    if (!sel.isValid || sel.start < 0 || sel.end > oldText.length) {
      final nextText = '$oldText$text';
      _inputController.value = TextEditingValue(
        text: nextText,
        selection: TextSelection.collapsed(offset: nextText.length),
      );
      return;
    }
    final nextText = oldText.replaceRange(sel.start, sel.end, text);
    _inputController.value = TextEditingValue(
      text: nextText,
      selection: TextSelection.collapsed(offset: sel.start + text.length),
    );
  }

  void _showSettingsDialog() {
    final auth = ref.read(authControllerProvider);
    showDialog(
      context: context,
      builder: (_) => _GeneralSettingsDialog(
        currentUrl: auth.serverConfig.baseUrl,
        onSaveUrl: (newUrl) async {
          await ref.read(authControllerProvider.notifier).updateServerUrl(newUrl);
          if (mounted) {
            _showSnack('已保存网关地址: $newUrl（下次重连生效）');
          }
        },
      ),
    );
  }

  Future<void> _confirmLogout() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('退出登录'),
        content: const Text('确定要退出当前账号吗？'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('取消')),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: FilledButton.styleFrom(backgroundColor: Colors.redAccent),
            child: const Text('退出'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    await ref.read(hubControllerProvider.notifier).reset();
    await ref.read(authControllerProvider.notifier).logout();
  }

  Widget _buildNodeSwitchButton(BuildContext context, HubState hubState, bool isDark) {
    if (hubState.nodes.isEmpty) return const SizedBox.shrink();
    final currentNode = hubState.currentNode ?? hubState.nodes.first;
    final isWin = currentNode.id != 'deck';

    return PopupMenuButton<String>(
      tooltip: '切换目标电脑',
      offset: const Offset(0, 45),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      color: isDark ? const Color(0xFF1E293B) : Colors.white,
      onSelected: _handleSwitchNode,
      itemBuilder: (context) {
        return hubState.nodes.map((node) {
          final isSelected = node.id == hubState.selectedNodeId;
          final isDeck = node.id == 'deck';
          return PopupMenuItem<String>(
            value: node.id,
            child: Row(
              children: [
                Icon(
                  isDeck ? Icons.videogame_asset_rounded : Icons.desktop_windows_rounded,
                  size: 18,
                  color: isSelected
                      ? Theme.of(context).colorScheme.primary
                      : (isDark ? Colors.white70 : Colors.black87),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    node.name,
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight: isSelected ? FontWeight.bold : FontWeight.normal,
                      color: isDark ? Colors.white : Colors.black87,
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                Container(
                  width: 7,
                  height: 7,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: !node.isOnline
                        ? (isDark ? Colors.white24 : Colors.black26)
                        : (node.engineAlive ? AppColors.statusGreen(isDark) : AppColors.statusAmber(isDark)),
                  ),
                ),
                const SizedBox(width: 4),
                Text(
                  !node.isOnline ? '离线' : (node.engineAlive ? '在线' : '未启动'),
                  style: TextStyle(
                    fontSize: 10,
                    color: !node.isOnline
                        ? (isDark ? Colors.white38 : Colors.black38)
                        : (node.engineAlive ? AppColors.statusGreen(isDark) : AppColors.statusAmber(isDark)),
                  ),
                ),
              ],
            ),
          );
        }).toList();
      },
      child: Container(
        margin: const EdgeInsets.symmetric(vertical: 10, horizontal: 4),
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
        decoration: BoxDecoration(
          color: isDark
              ? (isWin
                  ? const Color(0xFF1E3A8A).withValues(alpha: 0.4)
                  : const Color(0xFF334155).withValues(alpha: 0.5))
              : (isWin ? const Color(0xFFE0F2FE) : const Color(0xFFF1F5F9)),
          borderRadius: BorderRadius.circular(16),
          border: Border.all(
            color: isWin
                ? const Color(0xFF38BDF8).withValues(alpha: 0.6)
                : (isDark ? Colors.white12 : Colors.black12),
            width: 1,
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              isWin ? Icons.desktop_windows_rounded : Icons.videogame_asset_rounded,
              size: 14,
              color: isWin ? const Color(0xFF38BDF8) : (isDark ? Colors.white70 : Colors.black87),
            ),
            const SizedBox(width: 5),
            ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 88),
              child: Text(
                currentNode.name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  color: isDark ? Colors.white : Colors.black87,
                ),
              ),
            ),
            const SizedBox(width: 3),
            Icon(Icons.arrow_drop_down_rounded, size: 16, color: isDark ? Colors.white38 : Colors.black38),
          ],
        ),
      ),
    );
  }

  Widget _buildThinkingIndicator(BuildContext context, bool isDark, String focusText) {
    final label = focusText.trim().isNotEmpty ? focusText.trim() : 'Agent 正在思考并执行指令...';
    return Container(
      margin: const EdgeInsets.only(bottom: 12, top: 4),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(
        color: isDark ? const Color(0xFF161F30) : Colors.white,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(
          color: Theme.of(context).colorScheme.primary.withValues(alpha: 0.4),
          width: 1,
        ),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: isDark ? 0.2 : 0.05),
            blurRadius: 8,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          SizedBox(
            width: 14,
            height: 14,
            child: CircularProgressIndicator(
              strokeWidth: 2,
              valueColor: AlwaysStoppedAnimation<Color>(Theme.of(context).colorScheme.primary),
            ),
          ),
          const SizedBox(width: 10),
          Flexible(
            child: Text(
              label,
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w500,
                color: isDark ? Colors.white70 : Colors.black87,
              ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final hubState = ref.watch(hubControllerProvider);
    final themeState = ref.watch(themeProvider);
    final composerPrefs = ref.watch(composerPrefsProvider);
    final authState = ref.watch(authControllerProvider);
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final hubNotifier = ref.read(hubControllerProvider.notifier);

    final allMessages = hubState.messages;
    final query = _chatSearchQuery.trim().toLowerCase();
    final messages = (_isChatSearching && query.isNotEmpty)
        ? allMessages.where((m) {
            if (m.content.toLowerCase().contains(query)) return true;
            if (m.thinking.toLowerCase().contains(query)) return true;
            return m.toolCalls.any(
              (tc) =>
                  tc.name.toLowerCase().contains(query) ||
                  tc.args.values.any((v) => v.toString().toLowerCase().contains(query)),
            );
          }).toList()
        : allMessages;
    final planSteps = hubState.activePlanSteps;
    final activeFocus = hubState.activeFocusText;
    final hasThinking = hubState.isActiveSessionRunning && !(_isChatSearching && query.isNotEmpty);
    final hasLoadMore = hubState.hasMoreMessages && !(_isChatSearching && query.isNotEmpty);
    final totalItems = messages.length + (hasThinking ? 1 : 0) + (hasLoadMore ? 1 : 0);
    final rawBaseUrl = authState.serverConfig.baseUrl;
    final parsedHost = Uri.tryParse(rawBaseUrl)?.host;
    final displayServerLabel = (parsedHost != null && parsedHost.isNotEmpty) ? parsedHost : rawBaseUrl;

    return PopScope(
      canPop: kIsWeb,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) return;
        if (_scaffoldKey.currentState?.isDrawerOpen == true) {
          Navigator.of(context).pop();
          return;
        }
        if (_isChatSearching) {
          setState(() {
            _isChatSearching = false;
            _chatSearchQuery = '';
            _chatSearchController.clear();
          });
          return;
        }
        final primaryFocus = FocusManager.instance.primaryFocus;
        if (primaryFocus != null && primaryFocus.hasPrimaryFocus) {
          primaryFocus.unfocus();
          return;
        }
        final now = DateTime.now();
        if (_lastBackPressAt == null ||
            now.difference(_lastBackPressAt!) > const Duration(seconds: 2)) {
          _lastBackPressAt = now;
          _showSnack('再按一次返回键退出应用');
          return;
        }
        SystemNavigator.pop();
      },
      child: Scaffold(
        key: _scaffoldKey,
        drawer: QuotaDrawer(
        nodes: hubState.nodes,
        selectedNode: hubState.selectedNodeId,
        onSwitchNode: _handleSwitchNode,
        quotaData: hubState.quota,
        isLoadingQuota: hubState.isLoadingQuota,
        onRequestQuota: () => hubNotifier.fetchQuota(),
        canWrite: hubState.canWrite,
        canDelete: hubState.canDelete,
        onNewSession: () => _showNewSessionDialog(),
        onNewSessionInProject: (projName, wsPath, rootId) => _showNewSessionDialog(
          initialProjectName: projName,
          initialWorkspacePath: wsPath,
          initialRootId: rootId,
        ),
        projects: hubState.projects,
        generalSessions: hubState.generalSessions,
        activeSessionId: hubState.activeSessionId,
        runningSessionIds: hubState.runningSessionIds,
        onSwitchSession: (s) => hubNotifier.selectSession(s),
        onDeleteSession: _handleDeleteSession,
        isDark: isDark,
        onToggleTheme: (val) {
          HapticFeedback.lightImpact();
          ref.read(themeProvider.notifier).setDarkMode(val);
        },
        currentAccentThemeId: themeState.accent.id,
        onSelectAccentTheme: (opt) => ref.read(themeProvider.notifier).setAccentTheme(opt),
        currentDisplayName: widget.user.displayName,
        onLogout: _confirmLogout,
      ),
      onDrawerChanged: (isOpen) {
        if (isOpen) hubNotifier.fetchQuota();
      },
      appBar: AppBar(
        backgroundColor: isDark ? const Color(0xFF161F30) : Colors.white,
        elevation: isDark ? 0 : 1,
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              hubState.activeSessionTitle,
              style: TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.bold,
                color: isDark ? Colors.white : Colors.black87,
              ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            Row(
              children: [
                Container(
                  width: 7,
                  height: 7,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: hubState.isConnected
                        ? AppColors.statusGreen(isDark)
                        : (hubState.isConnecting ? AppColors.statusAmber(isDark) : AppColors.statusRed(isDark)),
                  ),
                ),
                const SizedBox(width: 5),
                Flexible(
                  child: Text(
                    hubState.isConnected
                        ? '已连接 ($displayServerLabel)'
                        : (hubState.isConnecting ? '事件流连接中...' : '未连接'),
                    style: TextStyle(fontSize: 10, color: isDark ? Colors.white54 : Colors.black45),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
            ),
          ],
        ),
        actions: [
          _buildNodeSwitchButton(context, hubState, isDark),
          if (hubState.activeSessionId.isNotEmpty) ...[
            IconButton(
              visualDensity: VisualDensity.compact,
              icon: Icon(_isChatSearching ? Icons.search_off_rounded : Icons.search_rounded, size: 20),
              tooltip: '搜索对话内容',
              onPressed: () {
                setState(() {
                  _isChatSearching = !_isChatSearching;
                  if (!_isChatSearching) {
                    _chatSearchQuery = '';
                    _chatSearchController.clear();
                  }
                });
              },
            ),
            IconButton(
              visualDensity: VisualDensity.compact,
              icon: const Icon(Icons.auto_awesome_mosaic_outlined, size: 20),
              tooltip: '会话文档 (Artifacts)',
              onPressed: _openSessionArtifacts,
            ),
          ],
          IconButton(
            visualDensity: VisualDensity.compact,
            icon: Icon(isDark ? Icons.light_mode_rounded : Icons.dark_mode_rounded, size: 20),
            tooltip: isDark ? '切换为日间模式' : '切换为夜间模式',
            onPressed: () {
              HapticFeedback.lightImpact();
              ref.read(themeProvider.notifier).setDarkMode(!isDark);
            },
          ),
          IconButton(
            visualDensity: VisualDensity.compact,
            icon: const Icon(Icons.settings_outlined),
            tooltip: '通用设置',
            onPressed: _showSettingsDialog,
          ),
        ],
      ),
      body: Column(
        children: [
          if (_isChatSearching)
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
              decoration: BoxDecoration(
                color: isDark ? const Color(0xFF111927) : const Color(0xFFF8FAFC),
                border: Border(
                  bottom: BorderSide(color: isDark ? const Color(0xFF1E293B) : const Color(0xFFE2E8F0)),
                ),
              ),
              child: Row(
                children: [
                  const Icon(Icons.search_rounded, size: 16),
                  const SizedBox(width: 8),
                  Expanded(
                    child: TextField(
                      controller: _chatSearchController,
                      autofocus: true,
                      onChanged: (val) => setState(() => _chatSearchQuery = val),
                      style: TextStyle(fontSize: 13, color: isDark ? Colors.white : Colors.black87),
                      decoration: InputDecoration(
                        isDense: true,
                        hintText: '在当前会话内搜索...',
                        hintStyle: TextStyle(fontSize: 12, color: isDark ? Colors.white38 : Colors.black38),
                        border: InputBorder.none,
                      ),
                    ),
                  ),
                  if (query.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.only(right: 6),
                      child: Text(
                        '${messages.length} 条',
                        style: TextStyle(fontSize: 11, color: isDark ? Colors.white54 : Colors.black45),
                      ),
                    ),
                  IconButton(
                    icon: const Icon(Icons.close_rounded, size: 18),
                    visualDensity: VisualDensity.compact,
                    onPressed: () {
                      setState(() {
                        _isChatSearching = false;
                        _chatSearchQuery = '';
                        _chatSearchController.clear();
                      });
                    },
                  ),
                ],
              ),
            )
          else if (planSteps.isNotEmpty)
            SessionStepsBar(steps: planSteps, isDark: isDark),
          Expanded(
            child: GestureDetector(
              behavior: HitTestBehavior.translucent,
              onTap: () => FocusScope.of(context).unfocus(),
              child: hubState.isLoadingMessages
                  ? const Center(child: CircularProgressIndicator())
                  : messages.isEmpty
                      ? Center(
                          child: Text(
                            (_isChatSearching && query.isNotEmpty)
                                ? '未找到包含「$_chatSearchQuery」的消息'
                                : hubState.selectedNodeId.isEmpty
                                    ? '尚未配置可用控制节点'
                                    : (hubState.activeSessionId.isEmpty
                                        ? '点击左上角 [≡] 选择会话或新建任务'
                                        : '暂无消息记录，请在下方发送第一条指令'),
                            textAlign: TextAlign.center,
                            style: TextStyle(
                              color: isDark ? Colors.white38 : Colors.black38,
                              fontSize: 13,
                              height: 1.5,
                            ),
                          ),
                        )
                      : Stack(
                          children: [
                            ListView.builder(
                              controller: _scrollController,
                              reverse: true,
                              keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
                              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                            itemCount: totalItems,
                            itemBuilder: (ctx, idx) {
                              if (hasThinking && idx == 0) {
                                return _buildThinkingIndicator(context, isDark, activeFocus);
                              }
                              final shiftedIdx = hasThinking ? idx - 1 : idx;
                              if (shiftedIdx < messages.length) {
                                final msg = messages[messages.length - 1 - shiftedIdx];
                                return MessageCard(
                                  key: ValueKey(msg.messageKey),
                                  msg: msg,
                                  isDark: isDark,
                                  resolveMediaUrl: (p) => hubNotifier.resolveMediaUrl(p),
                                  mediaHeaders: hubNotifier.mediaHeaders,
                                  onDownloadFile: (p, {filename}) => _downloadFile(p, filename: filename),
                                  onOpenUrl: PlatformBridge.openExternalUrl,
                                  onOpenMediaExternal: (p) => _openMediaExternal(p),
                                  onOpenEditDiff: (filePath, stepIdx) => _openChangeReview(
                                    initialFilePath: filePath,
                                    initialStepIndex: stepIdx,
                                  ),
                                  onOpenToolDetail: _openToolDetail,
                                  onSubmitQuickReply: _sendPromptDirect,
                                );
                              }
                              return Padding(
                                padding: const EdgeInsets.only(bottom: 12),
                                child: Center(
                                  child: TextButton.icon(
                                    onPressed: hubState.isLoadingMore
                                        ? null
                                        : () => hubNotifier.loadEarlierMessages(),
                                    icon: hubState.isLoadingMore
                                        ? const SizedBox(
                                            width: 14,
                                            height: 14,
                                            child: CircularProgressIndicator(strokeWidth: 2),
                                          )
                                        : const Icon(Icons.history_rounded, size: 16),
                                    label: Text(
                                      hubState.isLoadingMore ? '加载中...' : '加载更早消息',
                                      style: const TextStyle(fontSize: 12),
                                    ),
                                  ),
                                ),
                              );
                            },
                          ),
                          if (_showScrollToBottom)
                            Positioned(
                              bottom: 14,
                              right: 18,
                              child: InkWell(
                                onTap: _scrollToBottom,
                                borderRadius: BorderRadius.circular(20),
                                child: AnimatedContainer(
                                  duration: const Duration(milliseconds: 200),
                                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                                  decoration: BoxDecoration(
                                    color: Theme.of(context).colorScheme.primary,
                                    borderRadius: BorderRadius.circular(20),
                                    boxShadow: [
                                      BoxShadow(
                                        color: Colors.black.withValues(alpha: 0.3),
                                        blurRadius: 8,
                                        offset: const Offset(0, 3),
                                      ),
                                    ],
                                  ),
                                  child: const Row(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      Icon(Icons.arrow_downward_rounded, size: 14, color: Colors.white),
                                      SizedBox(width: 4),
                                      Text(
                                        '回到底部',
                                        style: TextStyle(
                                          color: Colors.white,
                                          fontSize: 11.5,
                                          fontWeight: FontWeight.bold,
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                              ),
                            ),
                        ],
                      ),
            ),
          ),
          BottomInputBar(
            inputController: _inputController,
            isConnected: hubState.selectedNodeId.isNotEmpty,
            isThinking: hubState.isActiveSessionRunning,
            canWrite: hubState.canWrite,
            isDark: isDark,
            queueMode: composerPrefs.queueMode,
            sendKey: composerPrefs.sendKey,
            changesBar: hubState.sessionChanges.totalFiles > 0
                ? SessionChangesBar(
                    changes: hubState.sessionChanges,
                    pendingCommentCount: _commentsForSession(hubState.activeSessionId).length,
                    isDark: isDark,
                    onOpenReview: () => _openChangeReview(),
                    onOpenFile: (f) => _openChangeReview(
                      initialFilePath: f.filePath,
                      initialStepIndex: f.lastStepIndex,
                    ),
                  )
                : null,
            queueBar: hubState.sessionQueue.items.isNotEmpty
                ? SessionQueueBar(
                    queue: hubState.sessionQueue,
                    isDark: isDark,
                    canWrite: hubState.canWrite,
                    onTogglePause: (paused) async {
                      final err = await hubNotifier.setSessionQueuePaused(paused);
                      if (err != null) _showSnack(err, isError: true);
                    },
                    onEditItem: (itemId, newContent) async {
                      final err = await hubNotifier.updateQueuedMessage(itemId, newContent);
                      if (err != null) _showSnack(err, isError: true);
                    },
                    onDeleteItem: (itemId) async {
                      final err = await hubNotifier.deleteQueuedMessage(itemId);
                      if (err != null) _showSnack(err, isError: true);
                    },
                    onSendNow: (itemId) async {
                      final err = await hubNotifier.sendQueuedMessageNow(itemId);
                      if (err != null) _showSnack(err, isError: true);
                    },
                    onClearAll: () async {
                      final err = await hubNotifier.clearSessionQueue();
                      if (err != null) _showSnack(err, isError: true);
                    },
                  )
                : null,
            pendingAttachments: hubState.pendingAttachments,
            onRemoveAttachment: (idx) => hubNotifier.removePendingAttachment(idx),
            onShowAddContext: () {
              ContextMenuSheet.show(
                context,
                isDark: isDark,
                canWrite: hubState.canWrite,
                onPickFile: () => _pickAndUpload(imagesOnly: false),
                onPickImage: () => _pickAndUpload(imagesOnly: true),
                onRequestGitDiff: () => _openChangeReview(),
                onOpenWorkspaceFiles: _openWorkspaceFilePicker,
                onOpenSessionArtifacts: hubState.activeSessionId.isEmpty ? null : _openSessionArtifacts,
              );
            },
            onSendMessage: _handleSendMessage,
            onStopTask: _handleStopTask,
            onInsertRichContent: _onPickedLocalFile,
          ),
        ],
      ),
      ),
    );
  }
}

class _WorkspaceBrowserSheet extends StatefulWidget {
  final List<FileRootItem> roots;
  final String initialRootId;
  final bool isDark;
  final Future<FileTreeData> Function(String rootId, String subPath) onBrowse;
  final Future<String?> Function(String rootId, String relPath) onReadFile;
  final Future<String?> Function(String rootId, String relPath) onDownload;
  final Future<String?> Function(String rootId, String relPath) onOpenMediaExternal;
  final String? Function(String rootId, String relPath) buildDirectMediaUrl;
  final Map<String, String>? mediaHeaders;
  final ValueChanged<String> onInsertRef;

  const _WorkspaceBrowserSheet({
    required this.roots,
    required this.initialRootId,
    required this.isDark,
    required this.onBrowse,
    required this.onReadFile,
    required this.onDownload,
    required this.onOpenMediaExternal,
    required this.buildDirectMediaUrl,
    this.mediaHeaders,
    required this.onInsertRef,
  });

  @override
  State<_WorkspaceBrowserSheet> createState() => _WorkspaceBrowserSheetState();
}

class _WorkspaceBrowserSheetState extends State<_WorkspaceBrowserSheet> {
  late String _rootId;
  String _rootName = '';
  String _subPath = '';
  List<FileItem> _files = const [];
  bool _isLoading = true;
  String? _error;
  String? _statusMessage;
  bool _statusIsError = false;
  bool _statusIsBusy = false;

  @override
  void initState() {
    super.initState();
    _rootId = widget.initialRootId;
    _loadDir(_rootId, '');
  }

  String _basename(String relPath) {
    final parts = relPath.split(RegExp(r'[\\/]'));
    return parts.isEmpty ? relPath : parts.last;
  }

  Future<void> _loadDir(String rootId, String subPath) async {
    setState(() {
      _isLoading = true;
      _error = null;
    });
    try {
      final tree = await widget.onBrowse(rootId, subPath);
      if (!mounted) return;
      setState(() {
        _rootId = tree.rootId;
        _rootName = tree.rootName;
        _subPath = tree.currentPath;
        _files = tree.items;
        _isLoading = false;
      });
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() {
        _isLoading = false;
        _error = e.message;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _isLoading = false;
        _error = '加载目录失败: $e';
      });
    }
  }

  Future<void> _handleDownload(String relPath) async {
    final name = _basename(relPath);
    setState(() {
      _statusMessage = '正在准备下载: $name...';
      _statusIsError = false;
      _statusIsBusy = true;
    });
    final err = await widget.onDownload(_rootId, relPath);
    if (!mounted) return;
    setState(() {
      _statusIsBusy = false;
      if (err != null) {
        _statusMessage = '下载失败: $err';
        _statusIsError = true;
      } else {
        _statusMessage = '已发起下载: $name';
        _statusIsError = false;
      }
    });
  }

  Future<void> _handleReadFile(String relPath) async {
    final err = await widget.onReadFile(_rootId, relPath);
    if (!mounted || err == null) return;
    setState(() {
      _statusIsBusy = false;
      _statusMessage = err;
      _statusIsError = true;
    });
  }

  Future<void> _handlePreviewPdf(String relPath) async {
    final name = _basename(relPath);
    if (kIsWeb) {
      final directUrl = widget.buildDirectMediaUrl(_rootId, relPath);
      if (directUrl == null) {
        setState(() {
          _statusMessage = '无法生成 PDF 预览链接（未选中有效工作区）';
          _statusIsError = true;
          _statusIsBusy = false;
        });
        return;
      }
      // Synchronous call preserves browser user-gesture context so popup blocker stays happy.
      PlatformBridge.openExternalUrl(directUrl);
      setState(() {
        _statusMessage = '已在新标签页打开 PDF 预览: $name（若被拦截请允许弹窗或点右侧下载）';
        _statusIsError = false;
        _statusIsBusy = false;
      });
      return;
    }

    setState(() {
      _statusMessage = '正在打开 PDF 预览: $name...';
      _statusIsError = false;
      _statusIsBusy = true;
    });
    final err = await widget.onOpenMediaExternal(_rootId, relPath);
    if (!mounted) return;
    setState(() {
      _statusIsBusy = false;
      if (err != null) {
        _statusMessage = err;
        _statusIsError = true;
      } else {
        _statusMessage = '已调用外部应用打开 PDF: $name';
        _statusIsError = false;
      }
    });
  }

  void _handlePreviewImage(String relPath) {
    final name = _basename(relPath);
    final imageUrl = widget.buildDirectMediaUrl(_rootId, relPath);
    if (imageUrl == null) {
      setState(() {
        _statusMessage = '无法生成图片预览链接';
        _statusIsError = true;
        _statusIsBusy = false;
      });
      return;
    }

    showDialog(
      context: context,
      builder: (ctx) => Dialog(
        backgroundColor: Colors.transparent,
        insetPadding: const EdgeInsets.all(12),
        child: Container(
          constraints: BoxConstraints(
            maxWidth: MediaQuery.of(ctx).size.width * 0.95,
            maxHeight: MediaQuery.of(ctx).size.height * 0.85,
          ),
          decoration: BoxDecoration(
            color: widget.isDark ? const Color(0xFF0F172A) : Colors.white,
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: widget.isDark ? const Color(0xFF334155) : const Color(0xFFE2E8F0)),
            boxShadow: const [BoxShadow(color: Colors.black54, blurRadius: 24, spreadRadius: 4)],
          ),
          clipBehavior: Clip.antiAlias,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                color: widget.isDark ? const Color(0xFF1E293B) : const Color(0xFFF8FAFC),
                child: Row(
                  children: [
                    Icon(Icons.image_outlined, size: 16, color: Theme.of(context).colorScheme.primary),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        name,
                        style: TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.bold,
                          color: widget.isDark ? Colors.white : Colors.black87,
                        ),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    IconButton(
                      tooltip: '下载到本地',
                      icon: const Icon(Icons.download_rounded, size: 18),
                      onPressed: () => _handleDownload(relPath),
                    ),
                    IconButton(
                      tooltip: '在新标签页打开原图',
                      icon: const Icon(Icons.open_in_new_rounded, size: 18),
                      onPressed: () {
                        if (kIsWeb) {
                          PlatformBridge.openExternalUrl(imageUrl);
                        } else {
                          widget.onOpenMediaExternal(_rootId, relPath);
                        }
                      },
                    ),
                    IconButton(
                      tooltip: '关闭',
                      icon: const Icon(Icons.close_rounded, size: 20),
                      onPressed: () => Navigator.of(ctx).pop(),
                    ),
                  ],
                ),
              ),
              Flexible(
                child: InteractiveViewer(
                  panEnabled: true,
                  scaleEnabled: true,
                  minScale: 0.8,
                  maxScale: 4.0,
                  child: Center(
                    child: Image.network(
                      imageUrl,
                      headers: widget.mediaHeaders,
                      fit: BoxFit.contain,
                      errorBuilder: (_, __, ___) => Padding(
                        padding: const EdgeInsets.all(24),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            const Icon(Icons.broken_image_rounded, size: 42, color: Colors.grey),
                            const SizedBox(height: 8),
                            const Text('图片加载失败', style: TextStyle(fontSize: 13)),
                            const SizedBox(height: 8),
                            TextButton.icon(
                              onPressed: () => _handleDownload(relPath),
                              icon: const Icon(Icons.download_rounded, size: 16),
                              label: const Text('直接下载文件'),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return WorkspaceFilePickerDialog(
      roots: widget.roots,
      activeRootId: _rootId,
      rootName: _rootName.isEmpty ? _rootId : _rootName,
      currentSubPath: _subPath,
      files: _files,
      isLoading: _isLoading,
      errorMessage: _error,
      statusMessage: _statusMessage,
      statusIsError: _statusIsError,
      statusIsBusy: _statusIsBusy,
      onDismissStatus: () => setState(() => _statusMessage = null),
      isDark: widget.isDark,
      onSelectRoot: (newRoot) => _loadDir(newRoot, ''),
      onNavigate: (sub) => _loadDir(_rootId, sub),
      onDownload: _handleDownload,
      onReadFile: _handleReadFile,
      onPreviewPdf: _handlePreviewPdf,
      onPreviewImage: _handlePreviewImage,
      onInsertRef: widget.onInsertRef,
    );
  }
}

class _GeneralSettingsDialog extends ConsumerStatefulWidget {
  final String currentUrl;
  final ValueChanged<String> onSaveUrl;

  const _GeneralSettingsDialog({
    required this.currentUrl,
    required this.onSaveUrl,
  });

  @override
  ConsumerState<_GeneralSettingsDialog> createState() => _GeneralSettingsDialogState();
}

class _GeneralSettingsDialogState extends ConsumerState<_GeneralSettingsDialog> {
  late final TextEditingController _urlController;

  @override
  void initState() {
    super.initState();
    _urlController = TextEditingController(text: widget.currentUrl);
  }

  @override
  void dispose() {
    _urlController.dispose();
    super.dispose();
  }

  Widget _buildSegmented({
    required String title,
    required String subtitle,
    required List<({String id, String label})> options,
    required String selectedId,
    required ValueChanged<String> onSelected,
    required bool isDark,
    required Color primary,
  }) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                title,
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                  color: isDark ? Colors.white : Colors.black87,
                ),
              ),
              const SizedBox(height: 2),
              Text(
                subtitle,
                style: TextStyle(fontSize: 11, color: isDark ? Colors.white54 : Colors.black54),
              ),
            ],
          ),
        ),
        const SizedBox(width: 10),
        Container(
          padding: const EdgeInsets.all(3),
          decoration: BoxDecoration(
            color: isDark ? const Color(0xFF0B0F19) : const Color(0xFFF1F5F9),
            borderRadius: BorderRadius.circular(18),
            border: Border.all(color: isDark ? Colors.white12 : Colors.black12),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: options.map((opt) {
              final active = opt.id == selectedId;
              return InkWell(
                onTap: () => onSelected(opt.id),
                borderRadius: BorderRadius.circular(14),
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                  decoration: BoxDecoration(
                    color: active ? (isDark ? const Color(0xFF334155) : Colors.white) : Colors.transparent,
                    borderRadius: BorderRadius.circular(14),
                    boxShadow: active && !isDark
                        ? [
                            BoxShadow(
                              color: Colors.black.withValues(alpha: 0.06),
                              blurRadius: 3,
                              offset: const Offset(0, 1),
                            ),
                          ]
                        : null,
                  ),
                  child: Text(
                    opt.label,
                    style: TextStyle(
                      fontSize: 11.5,
                      fontWeight: active ? FontWeight.bold : FontWeight.normal,
                      color: active ? primary : (isDark ? Colors.white60 : Colors.black54),
                    ),
                  ),
                ),
              );
            }).toList(),
          ),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final primary = Theme.of(context).colorScheme.primary;
    final prefs = ref.watch(composerPrefsProvider);
    final prefsNotifier = ref.read(composerPrefsProvider.notifier);

    return AlertDialog(
      backgroundColor: isDark ? const Color(0xFF161F30) : Colors.white,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      title: Text(
        '通用设置',
        style: TextStyle(fontSize: 17, fontWeight: FontWeight.bold, color: isDark ? Colors.white : Colors.black87),
      ),
      content: SizedBox(
        width: 440,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Input Box',
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.bold,
                  color: primary,
                ),
              ),
              const SizedBox(height: 10),
              _buildSegmented(
                title: '队列消息',
                subtitle: '配置运行中发消息的时机',
                options: const [
                  (id: ComposerPrefs.queueModeQueue, label: '排队入列'),
                  (id: ComposerPrefs.queueModeImmediate, label: '立即发送'),
                ],
                selectedId: prefs.queueMode,
                onSelected: prefsNotifier.setQueueMode,
                isDark: isDark,
                primary: primary,
              ),
              const SizedBox(height: 14),
              _buildSegmented(
                title: '发送消息',
                subtitle: prefs.isCtrlEnterToSend ? 'Ctrl+Enter 发送 / Enter 换行' : 'Enter 发送 / Shift+Enter 换行',
                options: const [
                  (id: ComposerPrefs.sendKeyEnter, label: 'Enter'),
                  (id: ComposerPrefs.sendKeyCtrlEnter, label: 'Ctrl+Enter'),
                ],
                selectedId: prefs.sendKey,
                onSelected: prefsNotifier.setSendKey,
                isDark: isDark,
                primary: primary,
              ),
              const SizedBox(height: 16),
              Divider(color: isDark ? Colors.white12 : Colors.black12, height: 1),
              const SizedBox(height: 12),
              Text(
                '网关连接',
                style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: primary),
              ),
              const SizedBox(height: 6),
              if (kIsWeb) ...[
                Text(
                  widget.currentUrl,
                  style: TextStyle(
                    fontSize: 12,
                    fontFamily: 'monospace',
                    color: isDark ? Colors.white70 : Colors.black87,
                  ),
                ),
                const SizedBox(height: 3),
                Text(
                  'Web 版自动连接当前同源网关。',
                  style: TextStyle(fontSize: 11, color: isDark ? Colors.white38 : Colors.black45),
                ),
              ] else
                TextField(
                  controller: _urlController,
                  keyboardType: TextInputType.url,
                  style: TextStyle(color: isDark ? Colors.white : Colors.black87, fontSize: 13),
                  decoration: InputDecoration(
                    hintText: 'https://agy.example.com',
                    hintStyle: TextStyle(color: isDark ? Colors.white24 : Colors.black26),
                    filled: true,
                    fillColor: isDark ? const Color(0xFF0B0F19) : const Color(0xFFF1F5F9),
                    border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
                  ),
                ),
            ],
          ),
        ),
      ),
      actions: [
        if (kIsWeb)
          ElevatedButton(
            onPressed: () => Navigator.pop(context),
            style: ElevatedButton.styleFrom(
              backgroundColor: primary,
              foregroundColor: isDark ? const Color(0xFF0F172A) : Colors.white,
            ),
            child: const Text('完成'),
          )
        else ...[
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('取消')),
          ElevatedButton(
            onPressed: () {
              final url = _urlController.text.trim();
              Navigator.pop(context);
              if (url.isNotEmpty) {
                widget.onSaveUrl(url);
              }
            },
            style: ElevatedButton.styleFrom(
              backgroundColor: primary,
              foregroundColor: isDark ? const Color(0xFF0F172A) : Colors.white,
            ),
            child: const Text('保存'),
          ),
        ],
      ],
    );
  }
}

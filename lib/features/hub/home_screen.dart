import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/config/composer_prefs.dart';
import '../../core/config/responsive_layout.dart';
import '../../core/network/api_client.dart';
import '../../core/platform/android_native_bridge.dart';
import '../../core/platform/platform_bridge.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/app_fonts.dart';
import '../../core/theme/theme_provider.dart';
import '../../core/utils/duration_utils.dart';
import '../../core/utils/file_utils.dart';
import '../../models/models.dart';
import '../auth/auth_controller.dart';
import '../chat/bottom_input_bar.dart';
import '../chat/context_menu_sheet.dart';
import '../chat/message_card.dart';
import '../chat/offline_outbox_bar.dart';
import '../chat/quick_commands_sheet.dart';
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
import 'download_progress_dialog.dart';
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
  StreamSubscription<SharedIncomingPayload>? _shareSub;
  final List<SharedIncomingPayload> _queuedShares = [];
  bool _drainingShares = false;
  bool _isSidebarCollapsed = false;

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
    if (AndroidNativeBridge.isAndroidNative) {
      AndroidNativeBridge.ensureInitialized();
      _shareSub = AndroidNativeBridge.incomingShares.listen(_enqueueIncomingShare);
      unawaited(_loadInitialShares());
      unawaited(AndroidNativeBridge.requestNotificationPermission());
    }
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
    _shareSub?.cancel();
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

  Future<void> _loadInitialShares() async {
    final items = await AndroidNativeBridge.consumePendingShares();
    if (!mounted || items.isEmpty) return;
    for (final item in items) {
      _enqueueIncomingShare(item);
    }
  }

  void _enqueueIncomingShare(SharedIncomingPayload payload) {
    if (!mounted || payload.isEmpty) return;
    _queuedShares.add(payload);
    if (ref.read(hubControllerProvider).selectedNodeId.isNotEmpty) {
      unawaited(_drainQueuedShares());
    }
  }

  Future<void> _drainQueuedShares() async {
    if (_drainingShares || !mounted) return;
    final hubState = ref.read(hubControllerProvider);
    if (hubState.selectedNodeId.isEmpty) return;
    _drainingShares = true;
    try {
      while (_queuedShares.isNotEmpty && mounted) {
        final payload = _queuedShares.removeAt(0);
        final sharedText = payload.text?.trim() ?? '';
        if (sharedText.isNotEmpty) {
          final prefix = _inputController.text.trim().isNotEmpty ? '\n' : '';
          _insertText('$prefix$sharedText');
          if (payload.files.isEmpty) {
            _showSnack('已填入来自其他应用的分享内容');
          }
        }
        if (payload.files.isNotEmpty) {
          if (!ref.read(hubControllerProvider).canWrite) {
            _showSnack('当前节点为只读权限，无法上传分享的文件', isError: true);
            for (final f in payload.files) {
              unawaited(PlatformBridge.deleteLocalFile(f.path));
            }
            continue;
          }
          for (final f in payload.files) {
            final bytes = await PlatformBridge.readLocalFileBytes(f.path);
            unawaited(PlatformBridge.deleteLocalFile(f.path));
            if (bytes != null && bytes.isNotEmpty && mounted) {
              await _onPickedLocalFile(
                PickedLocalFile(
                  filename: f.name,
                  bytes: bytes,
                  isImage: f.isImage,
                ),
              );
            }
          }
        }
      }
    } finally {
      _drainingShares = false;
    }
  }

  Future<void> _captureAndUploadPhoto() async {
    final photo = await AndroidNativeBridge.capturePhoto();
    if (photo == null || !mounted) return;
    final bytes = await PlatformBridge.readLocalFileBytes(photo.path);
    unawaited(PlatformBridge.deleteLocalFile(photo.path));
    if (bytes == null || bytes.isEmpty) {
      _showSnack('未能读取拍摄的照片', isError: true);
      return;
    }
    await _onPickedLocalFile(
      PickedLocalFile(
        filename: photo.name,
        bytes: bytes,
        isImage: true,
      ),
    );
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
      constraints: ResponsiveLayout.workspaceSheetConstraints(context),
      backgroundColor: isDark ? const Color(0xFF18181B) : Colors.white,
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
        onOpenMediaExternal: (rootId, relPath) => _openMediaExternalResult(relPath, rootId: rootId),
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

  Future<String?> _submitAskQuestionReply(String prompt) async {
    final err = await ref.read(hubControllerProvider.notifier).sendMessage(
          prompt,
          deliveryMode: 'immediate',
          interrupt: true,
        );
    if (err == null && mounted) {
      _scrollToBottom();
    }
    return err;
  }

  void _openQuickCommandsSheet() {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    QuickCommandsSheet.show(
      context,
      isDark: isDark,
      onFillPrompt: (prompt) {
        final cur = _inputController.text.trim();
        _inputController.text = cur.isEmpty ? prompt : '$cur\n$prompt';
        _inputController.selection = TextSelection.collapsed(
          offset: _inputController.text.length,
        );
      },
      onSendPrompt: _sendPromptDirect,
    );
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
    int? initialTurnId,
    SessionChangesData? initialSessionChangesOverride,
    int initialTabIndex = 0,
    String initialScope = 'all',
  }) {
    final hubState = ref.read(hubControllerProvider);
    final hubNotifier = ref.read(hubControllerProvider.notifier);
    final sid = hubState.activeSessionId;

    ChangeReviewSheet.show(
      context,
      initialSessionChanges: initialSessionChangesOverride ??
          (initialScope == 'latest_turn' ? hubState.sessionChanges : null),
      initialFilePath: initialFilePath,
      initialStepIndex: initialStepIndex,
      initialTurnId: initialTurnId,
      initialTabIndex: initialTabIndex,
      initialScope: initialScope,
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
      onLoadSessionChangesScoped: sid.isEmpty
          ? null
          : ({String scope = 'all', int? stepIndex, int? turnId}) =>
              hubNotifier.fetchSessionChangesDetail(
                scope: scope,
                stepIndex: stepIndex,
                turnId: turnId,
              ),
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

  Map<int, SessionTurnChange> _buildTurnChangesByMessageIndex(
    List<AgentMessage> messages,
    List<SessionTurnChange> turns,
  ) {
    if (messages.isEmpty || turns.isEmpty) {
      return const <int, SessionTurnChange>{};
    }

    bool isStandaloneVisibleAi(AgentMessage m) {
      if (m.content.trim().isNotEmpty) return true;
      if (m.status == 'WAITING_APPROVAL' || m.status == 'WAITING_INPUT') return true;
      return m.toolCalls.any((t) => t.name == 'ask_question');
    }

    final result = <int, SessionTurnChange>{};
    final usedTurnIds = <int>{};
    var i = 0;
    while (i < messages.length) {
      if (messages[i].isUser) {
        i++;
        continue;
      }
      final startIdx = i;
      while (i + 1 < messages.length && !messages[i + 1].isUser) {
        i++;
      }
      final endIdx = i;

      var targetMsgIdx = endIdx;
      for (var k = endIdx; k >= startIdx; k--) {
        if (isStandaloneVisibleAi(messages[k])) {
          targetMsgIdx = k;
          break;
        }
      }

      final prevUserStep = (startIdx > 0 && messages[startIdx - 1].isUser && messages[startIdx - 1].stepIndex > 0)
          ? messages[startIdx - 1].stepIndex
          : null;
      final nextUserStep = (endIdx + 1 < messages.length && messages[endIdx + 1].isUser && messages[endIdx + 1].stepIndex > 0)
          ? messages[endIdx + 1].stepIndex
          : null;

      SessionTurnChange? matched;
      if (prevUserStep != null) {
        for (final t in turns) {
          if (t.turnId == prevUserStep && !usedTurnIds.contains(t.turnId)) {
            matched = t;
            break;
          }
        }
      }
      if (matched == null) {
        final firstAiStep = messages[startIdx].stepIndex;
        final lastAiStep = messages[endIdx].stepIndex;
        for (final t in turns) {
          if (usedTurnIds.contains(t.turnId)) continue;
          final afterPrev = prevUserStep == null || t.firstStepIndex > prevUserStep;
          final beforeNext = nextUserStep == null
              ? t.firstStepIndex <= lastAiStep
              : t.lastStepIndex < nextUserStep;
          if (afterPrev && beforeNext && t.lastStepIndex >= firstAiStep) {
            matched = t;
            break;
          }
        }
      }

      if (matched != null && matched.totalFiles > 0 && matched.files.isNotEmpty) {
        usedTurnIds.add(matched.turnId);
        result[targetMsgIdx] = matched;
      }
      i++;
    }
    return result;
  }

  String _formatBytes(int bytes) {
    if (bytes <= 0) return '未知大小';
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    return '${(bytes / (1024 * 1024)).toStringAsFixed(2)} MB';
  }

  Future<void> _showAndroidDownloadCompleteSheet(DownloadedLocalFile file) async {
    if (!mounted) return;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    await showModalBottomSheet<void>(
      context: context,
      constraints: ResponsiveLayout.compactSheetConstraints(context),
      backgroundColor: isDark ? const Color(0xFF18181B) : Colors.white,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (ctx) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(
                    Icons.download_done_rounded,
                    color: AppColors.statusGreen(isDark),
                    size: 22,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      file.filename,
                      style: TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.bold,
                        color: isDark ? Colors.white : Colors.black87,
                      ),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 6),
              Text(
                '已下载到本地缓存 (${_formatBytes(file.sizeBytes)})',
                style: TextStyle(
                  fontSize: 12,
                  color: isDark ? Colors.white54 : Colors.black54,
                ),
              ),
              const SizedBox(height: 16),
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton.icon(
                      icon: const Icon(Icons.share_rounded, size: 18),
                      label: const Text('转发 / 分享'),
                      onPressed: () async {
                        Navigator.pop(ctx);
                        final ok = await AndroidNativeBridge.shareLocalFile(
                          file.path,
                          mimeType: file.mimeType,
                          title: '分享 ${file.filename}',
                        );
                        if (!ok && mounted) {
                          _showSnack('未能唤起系统分享面板', isError: true);
                        }
                      },
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: FilledButton.icon(
                      icon: const Icon(Icons.open_in_new_rounded, size: 18),
                      label: const Text('直接打开'),
                      onPressed: () async {
                        Navigator.pop(ctx);
                        final ok = await AndroidNativeBridge.openLocalFile(
                          file.path,
                          mimeType: file.mimeType,
                        );
                        if (!ok && mounted) {
                          _showSnack('未找到可打开此类型文件的应用，可尝试转发给其他应用', isError: true);
                        }
                      },
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

  Future<String?> _downloadWithAndroidSheet(
    String pathOrUri, {
    String? rootId,
    String? filename,
    bool autoOpen = false,
  }) async {
    final res = await runWithDownloadProgressDialog(
      context: context,
      autoOpen: autoOpen,
      formatBytes: _formatBytes,
      task: (onProgress, cancelToken) {
        return ref.read(hubControllerProvider.notifier).downloadFileToLocal(
              pathOrUri,
              rootId: rootId,
              filename: filename,
              onProgress: onProgress,
              cancelToken: cancelToken,
            );
      },
    );

    if (res.cancelled) {
      return null;
    }
    if (res.error != null || res.file == null) {
      return res.error ?? '下载失败';
    }
    final file = res.file!;
    if (autoOpen) {
      final opened = await AndroidNativeBridge.openLocalFile(
        file.path,
        mimeType: file.mimeType,
      );
      if (!opened && mounted) {
        await _showAndroidDownloadCompleteSheet(file);
      }
    } else if (mounted) {
      await _showAndroidDownloadCompleteSheet(file);
    }
    return null;
  }

  Future<String?> _downloadFileResult(String pathOrUri, {String? rootId, String? filename}) async {
    if (AndroidNativeBridge.isAndroidNative) {
      final res = await ref.read(hubControllerProvider.notifier).enqueueAndroidSystemDownload(
            pathOrUri,
            rootId: rootId,
            filename: filename,
          );
      return res.error;
    }
    return ref
        .read(hubControllerProvider.notifier)
        .downloadFile(pathOrUri, rootId: rootId, filename: filename);
  }

  Future<void> _downloadFile(String pathOrUri, {String? rootId, String? filename}) async {
    final err = await _downloadFileResult(pathOrUri, rootId: rootId, filename: filename);
    if (err != null) {
      _showSnack(err, isError: true);
    } else if (AndroidNativeBridge.isAndroidNative) {
      _showSnack('已交由系统下载器后台下载，进度请见通知栏');
    } else {
      _showSnack('已发起安全下载');
    }
  }

  Future<String?> _openMediaExternalResult(String rawPath, {String? rootId}) async {
    if (AndroidNativeBridge.isAndroidNative) {
      if (FileUtils.isMediaStreamFile(rawPath)) {
        final signed = await ref
            .read(hubControllerProvider.notifier)
            .createSignedMediaUrl(rawPath, rootId: rootId);
        if (signed.url != null) {
          final mime = AndroidNativeBridge.inferMimeType(signed.filename ?? rawPath);
          final opened = await AndroidNativeBridge.openRemoteMedia(
            signed.url!,
            mimeType: mime,
          );
          if (opened) {
            return null;
          }
        }
      }
      return _downloadWithAndroidSheet(
        rawPath,
        rootId: rootId,
        autoOpen: true,
      );
    }
    return ref.read(hubControllerProvider.notifier).openMediaExternal(rawPath, rootId: rootId);
  }

  Future<void> _openMediaExternal(String rawPath, {String? rootId}) async {
    final err = await _openMediaExternalResult(rawPath, rootId: rootId);
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

    return PopupMenuButton<String>(
      tooltip: '切换目标电脑',
      offset: const Offset(0, 45),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      color: isDark ? const Color(0xFF222226) : Colors.white,
      onOpened: () => ref.read(hubControllerProvider.notifier).refreshNodes(),
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
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 6),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 6,
              height: 6,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: !currentNode.isOnline
                    ? (isDark ? Colors.white24 : Colors.black26)
                    : (currentNode.engineAlive
                        ? AppColors.statusGreen(isDark)
                        : AppColors.statusAmber(isDark)),
              ),
            ),
            const SizedBox(width: 6),
            ConstrainedBox(
              constraints: BoxConstraints(maxWidth: ResponsiveLayout.nodeBadgeMaxWidth(context)),
              child: Text(
                currentNode.name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 12.5,
                  fontWeight: FontWeight.w500,
                  color: isDark ? const Color(0xFFD4D4D8) : const Color(0xFF3F3F46),
                ),
              ),
            ),
            const SizedBox(width: 1),
            Icon(
              Icons.expand_more_rounded,
              size: 15,
              color: isDark ? Colors.white38 : Colors.black38,
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildSidebar(
    HubState hubState,
    HubController hubNotifier,
    ThemeState themeState,
    bool isDark, {
    required bool isPermanent,
  }) {
    return QuotaDrawer(
      nodes: hubState.nodes,
      selectedNode: hubState.selectedNodeId,
      onSwitchNode: _handleSwitchNode,
      onRefreshNodes: () => hubNotifier.refreshNodes(),
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
      isPermanentSidebar: isPermanent,
    );
  }

  @override
  Widget build(BuildContext context) {
    ref.listen<HubState>(hubControllerProvider, (prev, next) {
      if (next.selectedNodeId.isNotEmpty && _queuedShares.isNotEmpty) {
        unawaited(_drainQueuedShares());
      }
    });
    final hubState = ref.watch(hubControllerProvider);
    final themeState = ref.watch(themeProvider);
    final composerPrefs = ref.watch(composerPrefsProvider);
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final hubNotifier = ref.read(hubControllerProvider.notifier);

    final usePermanentSidebar = ResponsiveLayout.usePermanentSidebar(context);
    final showPermanentSidebar = usePermanentSidebar && !_isSidebarCollapsed;
    final contentMaxWidth = ResponsiveLayout.contentMaxWidth(context);

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
    final isFilteringMessages = _isChatSearching && query.isNotEmpty;
    final turnChangesByMsgIdx = isFilteringMessages
        ? const <int, SessionTurnChange>{}
        : _buildTurnChangesByMessageIndex(
            messages,
            hubState.sessionChanges.turns,
          );
    final turnDurationsByMsgIdx = isFilteringMessages
        ? const <int, Duration>{}
        : computeTurnDurationsByMsgIdx(messages);
    final activeTurnStartedAt = findActiveTurnStartTime(allMessages);
    final hasThinking = hubState.isActiveSessionRunning && !isFilteringMessages;
    final hasLoadMore = hubState.hasMoreMessages && !isFilteringMessages;
    final totalItems = messages.length + (hasThinking ? 1 : 0) + (hasLoadMore ? 1 : 0);

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
        drawer: usePermanentSidebar
            ? null
            : _buildSidebar(hubState, hubNotifier, themeState, isDark, isPermanent: false),
      onDrawerChanged: (isOpen) {
        if (isOpen) {
          hubNotifier.refreshNodes();
          hubNotifier.fetchQuota();
        }
      },
      appBar: AppBar(
        backgroundColor: isDark ? AppColors.darkBg : AppColors.lightBg,
        elevation: 0,
        scrolledUnderElevation: 0,
        leading: usePermanentSidebar
            ? IconButton(
                tooltip: _isSidebarCollapsed ? '展开侧边栏' : '收起侧边栏',
                icon: Icon(
                  _isSidebarCollapsed ? Icons.menu_rounded : Icons.menu_open_rounded,
                  size: 21,
                ),
                onPressed: () {
                  setState(() => _isSidebarCollapsed = !_isSidebarCollapsed);
                },
              )
            : null,
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(0.5),
          child: Container(
            height: 0.5,
            color: isDark ? AppColors.darkBorder : AppColors.lightBorder,
          ),
        ),
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              hubState.activeSessionTitle,
              style: TextStyle(
                fontSize: 14.5,
                fontWeight: FontWeight.w600,
                color: isDark ? AppColors.darkTextPrimary : AppColors.lightTextPrimary,
              ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            if (!hubState.isConnected)
              Padding(
                padding: const EdgeInsets.only(top: 1),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Container(
                      width: 6,
                      height: 6,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: hubState.isConnecting
                            ? AppColors.statusAmber(isDark)
                            : AppColors.statusRed(isDark),
                      ),
                    ),
                    const SizedBox(width: 5),
                    Text(
                      hubState.isConnecting ? '事件流连接中...' : '未连接',
                      style: TextStyle(
                        fontSize: 10.5,
                        color: isDark ? AppColors.darkTextSecondary : AppColors.lightTextSecondary,
                      ),
                    ),
                  ],
                ),
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
      body: Row(
        children: [
          if (showPermanentSidebar)
            _buildSidebar(hubState, hubNotifier, themeState, isDark, isPermanent: true),
          Expanded(
            child: Column(
              children: [
          if (_isChatSearching)
            Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
              decoration: BoxDecoration(
                color: isDark ? const Color(0xFF18181B) : const Color(0xFFF8F8F9),
                border: Border(
                  bottom: BorderSide(color: isDark ? const Color(0xFF222226) : const Color(0xFFE4E4E7)),
                ),
              ),
              child: Center(
                child: ConstrainedBox(
                  constraints: BoxConstraints(maxWidth: contentMaxWidth),
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
                ),
              ),
            )
          else if (planSteps.isNotEmpty)
            Center(
              child: ConstrainedBox(
                constraints: BoxConstraints(maxWidth: contentMaxWidth),
                child: SessionStepsBar(steps: planSteps, isDark: isDark),
              ),
            ),
          Expanded(
            child: GestureDetector(
              behavior: HitTestBehavior.translucent,
              onTap: () => FocusScope.of(context).unfocus(),
              child: hubState.isLoadingMessages
                  ? const Center(child: CircularProgressIndicator())
                  : messages.isEmpty
                      ? Center(
                          child: Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 28),
                            child: Column(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Icon(
                                  Icons.change_history_rounded,
                                  size: 32,
                                  color: isDark ? Colors.white24 : Colors.black26,
                                ),
                                const SizedBox(height: 12),
                                Text(
                                  (_isChatSearching && query.isNotEmpty)
                                      ? '未找到包含「$_chatSearchQuery」的消息'
                                      : hubState.selectedNodeId.isEmpty
                                          ? '尚未配置可用控制节点'
                                          : (hubState.activeSessionId.isEmpty
                                              ? '点击左上角选择会话或新建任务'
                                              : '输入指令，开始远程协作'),
                                  textAlign: TextAlign.center,
                                  style: TextStyle(
                                    color: isDark ? AppColors.darkTextSecondary : AppColors.lightTextSecondary,
                                    fontSize: 13.5,
                                    height: 1.5,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        )
                      : Stack(
                          children: [
                            ListView.builder(
                              controller: _scrollController,
                              reverse: true,
                              keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
                              padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 16),
                              itemCount: totalItems,
                              itemBuilder: (ctx, idx) {
                                Widget rowChild;
                                if (hasThinking && idx == 0) {
                                  rowChild = Align(
                                    alignment: Alignment.centerLeft,
                                    child: _LiveThinkingIndicator(
                                      isDark: isDark,
                                      focusText: activeFocus,
                                      startedAt: activeTurnStartedAt,
                                    ),
                                  );
                                } else {
                                  final shiftedIdx = hasThinking ? idx - 1 : idx;
                                  if (shiftedIdx < messages.length) {
                                    final msgIdx = messages.length - 1 - shiftedIdx;
                                    final msg = messages[msgIdx];
                                    final msgTurnChanges = turnChangesByMsgIdx[msgIdx];
                                    rowChild = MessageCard(
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
                                        initialScope: 'step',
                                      ),
                                      onOpenToolDetail: _openToolDetail,
                                      onSubmitQuickReply: _submitAskQuestionReply,
                                      turnChanges: msgTurnChanges,
                                      turnDuration: turnDurationsByMsgIdx[msgIdx],
                                      onOpenTurnReview: msgTurnChanges == null
                                          ? null
                                          : () => _openChangeReview(
                                                initialTurnId: msgTurnChanges.turnId,
                                                initialSessionChangesOverride: msgTurnChanges.toChangesData(
                                                  sessionId: hubState.activeSessionId,
                                                ),
                                                initialScope: 'turn',
                                              ),
                                      onOpenTurnFile: msgTurnChanges == null
                                          ? null
                                          : (f) => _openChangeReview(
                                                initialFilePath: f.filePath,
                                                initialTurnId: msgTurnChanges.turnId,
                                                initialSessionChangesOverride: msgTurnChanges.toChangesData(
                                                  sessionId: hubState.activeSessionId,
                                                ),
                                                initialScope: 'turn',
                                              ),
                                    );
                                  } else {
                                    rowChild = Padding(
                                      padding: const EdgeInsets.only(bottom: 14),
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
                                  }
                                }
                                return Center(
                                  child: ConstrainedBox(
                                    constraints: BoxConstraints(maxWidth: contentMaxWidth),
                                    child: rowChild,
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
            maxContentWidth: contentMaxWidth,
            queueMode: composerPrefs.queueMode,
            sendKey: composerPrefs.sendKey,
            changesBar: hubState.sessionChanges.totalFiles > 0
                ? SessionChangesBar(
                    changes: hubState.sessionChanges,
                    pendingCommentCount: _commentsForSession(hubState.activeSessionId).length,
                    isDark: isDark,
                    onOpenReview: () => _openChangeReview(initialScope: 'latest_turn'),
                    onOpenFile: (f) => _openChangeReview(
                      initialFilePath: f.filePath,
                      initialScope: 'latest_turn',
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
            outboxBar: hubState.activeSessionOutbox.isNotEmpty
                ? OfflineOutboxBar(
                    items: hubState.activeSessionOutbox,
                    isDark: isDark,
                    isFlushing: hubState.isFlushingOutbox,
                    onRetryAll: () async {
                      final err = await hubNotifier.flushOfflineOutbox(manual: true);
                      if (err != null) _showSnack(err, isError: true);
                    },
                    onRetryItem: (itemId) async {
                      final err = await hubNotifier.flushOfflineOutbox(
                        manual: true,
                        onlyItemId: itemId,
                      );
                      if (err != null) _showSnack(err, isError: true);
                    },
                    onEditItem: (itemId, newContent) =>
                        hubNotifier.editOfflineOutboxItem(itemId, newContent),
                    onDeleteItem: (itemId) => hubNotifier.removeOfflineOutboxItem(itemId),
                    onClearAll: () => hubNotifier.clearActiveOfflineOutbox(),
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
                onTakePhoto: (AndroidNativeBridge.isAndroidNative && hubState.canWrite)
                    ? _captureAndUploadPhoto
                    : null,
                onRequestGitDiff: () => _openChangeReview(),
                onOpenWorkspaceFiles: _openWorkspaceFilePicker,
                onOpenSessionArtifacts: hubState.activeSessionId.isEmpty ? null : _openSessionArtifacts,
                onOpenQuickCommands: _openQuickCommandsSheet,
              );
            },
            onSendMessage: _handleSendMessage,
            onStopTask: _handleStopTask,
            onInsertRichContent: _onPickedLocalFile,
          ),
              ],
            ),
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
            color: widget.isDark ? const Color(0xFF111113) : Colors.white,
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: widget.isDark ? const Color(0xFF2C2C32) : const Color(0xFFE4E4E7)),
            boxShadow: const [BoxShadow(color: Colors.black54, blurRadius: 24, spreadRadius: 4)],
          ),
          clipBehavior: Clip.antiAlias,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                color: widget.isDark ? const Color(0xFF222226) : const Color(0xFFF8F8F9),
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
                      tooltip: kIsWeb ? '在新标签页打开原图' : '用系统相册打开',
                      icon: const Icon(Icons.open_in_new_rounded, size: 18),
                      onPressed: () {
                        if (kIsWeb) {
                          PlatformBridge.openExternalUrl(imageUrl);
                        } else {
                          Navigator.of(ctx).pop();
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
      onPreviewMedia: _handlePreviewPdf,
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
  bool _loadingNotifyStatus = true;
  bool _discordConfigured = false;
  double _notifyMinRunSeconds = 15;
  double _notifyAskDelaySeconds = 10;
  bool _sendingTestNotify = false;

  @override
  void initState() {
    super.initState();
    _urlController = TextEditingController(text: widget.currentUrl);
    _loadNotifyStatus();
  }

  Future<void> _loadNotifyStatus() async {
    try {
      final st = await ref.read(apiClientProvider).getNotificationStatus();
      if (!mounted) return;
      setState(() {
        _discordConfigured = st.discordConfigured;
        _notifyMinRunSeconds = st.minRunSeconds;
        _notifyAskDelaySeconds = st.askQuestionDelaySeconds;
        _loadingNotifyStatus = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() => _loadingNotifyStatus = false);
    }
  }

  Future<void> _sendTestNotification() async {
    if (_sendingTestNotify) return;
    setState(() => _sendingTestNotify = true);
    try {
      final (ok, msg) = await ref.read(apiClientProvider).sendTestNotification();
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(msg.isNotEmpty ? msg : (ok ? '测试通知已发送' : '测试通知发送失败')),
          backgroundColor: ok ? null : Colors.redAccent.shade700,
        ),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('测试通知失败: $e'),
          backgroundColor: Colors.redAccent.shade700,
        ),
      );
    } finally {
      if (mounted) {
        setState(() => _sendingTestNotify = false);
      }
    }
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
            color: isDark ? const Color(0xFF111113) : const Color(0xFFF4F4F5),
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
                    color: active ? (isDark ? const Color(0xFF2C2C32) : Colors.white) : Colors.transparent,
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
    final themeState = ref.watch(themeProvider);
    final themeNotifier = ref.read(themeProvider.notifier);

    return AlertDialog(
      backgroundColor: isDark ? const Color(0xFF18181B) : Colors.white,
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
                '界面字体',
                style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: primary),
              ),
              const SizedBox(height: 8),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: AppFonts.options.map((opt) {
                  final isSelected = themeState.font.id == opt.id;
                  final isLoading = themeState.loadingFontId == opt.id;
                  return InkWell(
                    borderRadius: BorderRadius.circular(10),
                    onTap: themeState.loadingFontId != null
                        ? null
                        : () async {
                            final ok = await themeNotifier.setFont(
                              opt,
                              baseUrl: widget.currentUrl,
                            );
                            if (!ok && context.mounted) {
                              ScaffoldMessenger.of(context).showSnackBar(
                                SnackBar(
                                  content: Text('字体文件暂不可用，已切换为系统相近字体 (${opt.name})'),
                                  duration: const Duration(seconds: 2),
                                ),
                              );
                            }
                          },
                    child: Container(
                      width: 196,
                      padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 9),
                      decoration: BoxDecoration(
                        color: isSelected
                            ? primary.withValues(alpha: isDark ? 0.14 : 0.08)
                            : (isDark ? const Color(0xFF111113) : const Color(0xFFF4F4F5)),
                        borderRadius: BorderRadius.circular(10),
                        border: Border.all(
                          color: isSelected
                              ? primary.withValues(alpha: 0.7)
                              : (isDark ? const Color(0xFF2C2C32) : const Color(0xFFE4E4E7)),
                          width: isSelected ? 1.2 : 1,
                        ),
                      ),
                      child: Row(
                        children: [
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Text(
                                  opt.name,
                                  style: TextStyle(
                                    fontSize: 13,
                                    fontWeight: isSelected ? FontWeight.w600 : FontWeight.w500,
                                    color: isSelected
                                        ? primary
                                        : (isDark ? Colors.white : Colors.black87),
                                  ),
                                ),
                                const SizedBox(height: 2),
                                Text(
                                  opt.description,
                                  style: TextStyle(
                                    fontSize: 10.5,
                                    color: isDark ? Colors.white54 : Colors.black54,
                                  ),
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ],
                            ),
                          ),
                          if (isLoading)
                            SizedBox(
                              width: 14,
                              height: 14,
                              child: CircularProgressIndicator(strokeWidth: 1.8, color: primary),
                            )
                          else if (isSelected)
                            Icon(Icons.check_rounded, size: 16, color: primary),
                        ],
                      ),
                    ),
                  );
                }).toList(),
              ),
              const SizedBox(height: 16),
              Divider(color: isDark ? Colors.white12 : Colors.black12, height: 1),
              const SizedBox(height: 12),
              Row(
                children: [
                  Text(
                    'Discord 离线通知',
                    style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: primary),
                  ),
                  const Spacer(),
                  if (_loadingNotifyStatus)
                    const SizedBox(
                      width: 12,
                      height: 12,
                      child: CircularProgressIndicator(strokeWidth: 1.6),
                    )
                  else
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
                      decoration: BoxDecoration(
                        color: (_discordConfigured
                                ? AppColors.statusGreen(isDark)
                                : (isDark ? Colors.white30 : Colors.black26))
                            .withValues(alpha: 0.14),
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Text(
                        _discordConfigured ? '已在网关启用' : '未配置 Webhook',
                        style: TextStyle(
                          fontSize: 10.5,
                          fontWeight: FontWeight.w600,
                          color: _discordConfigured
                              ? AppColors.statusGreen(isDark)
                              : (isDark ? Colors.white54 : Colors.black45),
                        ),
                      ),
                    ),
                ],
              ),
              const SizedBox(height: 6),
              Text(
                _discordConfigured
                    ? '离线或无活跃连接时，运行 >= ${_notifyMinRunSeconds.toInt()}s 完成、报错或 ask_question 超过 ${_notifyAskDelaySeconds.toInt()}s 未确认会自动推送至 Discord。'
                    : '在网关 gateway_config.json 中填写 discord_webhook_url 后重启网关即可启用。',
                style: TextStyle(fontSize: 11, color: isDark ? Colors.white54 : Colors.black54),
              ),
              if (_discordConfigured && ref.watch(authControllerProvider).user?.role == 'admin') ...[
                const SizedBox(height: 8),
                Align(
                  alignment: Alignment.centerLeft,
                  child: OutlinedButton.icon(
                    onPressed: _sendingTestNotify ? null : _sendTestNotification,
                    icon: _sendingTestNotify
                        ? const SizedBox(
                            width: 13,
                            height: 13,
                            child: CircularProgressIndicator(strokeWidth: 1.8),
                          )
                        : const Icon(Icons.notifications_active_outlined, size: 15),
                    label: Text(
                      _sendingTestNotify ? '发送中...' : '发送测试通知',
                      style: const TextStyle(fontSize: 12),
                    ),
                    style: OutlinedButton.styleFrom(visualDensity: VisualDensity.compact),
                  ),
                ),
              ],
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
                    fillColor: isDark ? const Color(0xFF111113) : const Color(0xFFF4F4F5),
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
              foregroundColor: isDark ? const Color(0xFF111113) : Colors.white,
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
              foregroundColor: isDark ? const Color(0xFF111113) : Colors.white,
            ),
            child: const Text('保存'),
          ),
        ],
      ],
    );
  }
}

class _LiveThinkingIndicator extends StatefulWidget {
  final bool isDark;
  final String focusText;
  final DateTime? startedAt;

  const _LiveThinkingIndicator({
    required this.isDark,
    required this.focusText,
    required this.startedAt,
  });

  @override
  State<_LiveThinkingIndicator> createState() => _LiveThinkingIndicatorState();
}

class _LiveThinkingIndicatorState extends State<_LiveThinkingIndicator> {
  Timer? _ticker;
  late DateTime _anchorTime;

  @override
  void initState() {
    super.initState();
    _syncAnchor();
    _ticker = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void didUpdateWidget(covariant _LiveThinkingIndicator oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.startedAt != widget.startedAt) {
      _syncAnchor();
    }
  }

  void _syncAnchor() {
    final s = widget.startedAt;
    if (s != null && !DateTime.now().difference(s).isNegative) {
      _anchorTime = s;
    } else {
      _anchorTime = DateTime.now();
    }
  }

  @override
  void dispose() {
    _ticker?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final baseLabel =
        widget.focusText.trim().isNotEmpty ? widget.focusText.trim() : '正在思考并执行...';
    final elapsed = DateTime.now().difference(_anchorTime);
    final elapsedText = formatLiveElapsed(elapsed);
    final mutedColor = widget.isDark ? const Color(0xFFA1A1AA) : const Color(0xFF71717A);

    return Padding(
      padding: const EdgeInsets.only(bottom: 16, top: 2),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          SizedBox(
            width: 13,
            height: 13,
            child: CircularProgressIndicator(
              strokeWidth: 1.8,
              valueColor: AlwaysStoppedAnimation<Color>(Theme.of(context).colorScheme.primary),
            ),
          ),
          const SizedBox(width: 9),
          Flexible(
            child: Text(
              '$baseLabel · $elapsedText',
              style: TextStyle(
                fontSize: 12.5,
                fontWeight: FontWeight.w500,
                color: mutedColor,
              ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
    );
  }
}

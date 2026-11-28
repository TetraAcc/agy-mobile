import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/config/app_update_service.dart';
import '../../core/config/composer_prefs.dart';
import '../../core/config/responsive_layout.dart';
import '../../core/config/sidebar_prefs.dart';
import '../../core/network/api_client.dart';
import '../../core/platform/android_native_bridge.dart';
import '../../core/platform/platform_bridge.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/theme_provider.dart';
import '../../core/utils/duration_utils.dart';
import '../../core/utils/file_utils.dart';
import '../../core/utils/search_highlight_utils.dart';
import '../../models/models.dart';
import '../auth/auth_controller.dart';
import '../automations/automations_panel.dart';
import '../chat/bottom_input_bar.dart';
import '../chat/context_menu_sheet.dart';
import '../chat/message_card.dart';
import '../chat/model_picker_sheet.dart';
import '../chat/offline_outbox_bar.dart';
import '../chat/quick_commands_sheet.dart';
import '../chat/session_queue_bar.dart';
import '../chat/session_steps_bar.dart';
import '../chat/tool_approval_card.dart';
import '../sessions/archived_sessions_dialog.dart';
import '../sessions/new_session_dialog.dart';
import '../sessions/quota_drawer.dart';
import '../settings/settings_view.dart';
import '../workspace/change_review_sheet.dart';
import '../workspace/file_viewer_sheet.dart';
import '../workspace/session_artifacts_sheet.dart';
import '../workspace/session_changes_bar.dart';
import '../workspace/terminal_panel.dart';
import '../workspace/tool_detail_sheet.dart';
import '../workspace/workspace_file_picker_dialog.dart';
import 'download_progress_dialog.dart';
import 'hub_controller.dart';
import 'node_power_banner.dart';

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
  int _activeSearchMatchPos = -1;
  final Map<String, GlobalKey> _messageItemKeys = {};
  int _searchJumpSeq = 0;
  String _lastSearchSessionId = '';
  VoidCallback? _disposeWebPaste;
  String _commentSessionId = '';
  List<ReviewCommentItem> _draftComments = const [];
  DateTime? _lastBackPressAt;
  StreamSubscription<SharedIncomingPayload>? _shareSub;
  final List<SharedIncomingPayload> _queuedShares = [];
  bool _drainingShares = false;
  bool _isSidebarCollapsed = false;
  bool _rightPanelOpen = false;
  int _rightPanelTab = 0; // 0: 文件预览, 1: 远程终端
  double _rightPanelWidth = 480.0;
  bool _terminalMounted = false;
  bool _terminalLive = false;
  bool _mobileTerminalOpen = false;
  final GlobalKey _terminalPanelKey = GlobalKey(debugLabel: 'persistent_terminal_key');
  ({
    FileContentData data,
    bool canWrite,
    bool isOfficePreview,
    String? pdfEmbedUrl,
    VoidCallback? onOpenExternal,
    int? startLine,
    int? endLine,
  })? _sidePreviewFile;
  bool _loadingSidePreview = false;
  String? _sidePreviewError;
  int _sidePreviewReqId = 0;
  String _currentAppVersion = kFallbackAppVersion;
  AppReleaseInfo? _availableAppUpdate;
  bool _showAutomationsView = false;
  int _enabledAutomationsCount = 0;
  int _automationsCountReqId = 0;

  List<ReviewCommentItem> _commentsForSession(String sessionId) {
    if (sessionId.isEmpty || sessionId != _commentSessionId) return const [];
    return _draftComments;
  }

  GlobalKey _messageKeyFor(String messageKey) {
    return _messageItemKeys.putIfAbsent(messageKey, () => GlobalKey());
  }

  List<int> _collectMatchedMessageIndices(List<AgentMessage> allMessages, String rawQuery) {
    final query = rawQuery.trim();
    if (query.isEmpty) return const [];
    final matched = <int>[];
    for (var i = 0; i < allMessages.length; i++) {
      if (messageMatchesSearchQuery(allMessages[i], query)) {
        matched.add(i);
      }
    }
    return matched;
  }

  void _closeChatSearch() {
    setState(() {
      _isChatSearching = false;
      _chatSearchQuery = '';
      _activeSearchMatchPos = -1;
      _searchJumpSeq++;
      _chatSearchController.clear();
    });
  }

  void _onChatSearchQueryChanged(String val, List<AgentMessage> allMessages, bool hasThinking, bool hasLoadMore) {
    final matched = _collectMatchedMessageIndices(allMessages, val);
    final nextPos = matched.isEmpty ? -1 : matched.length - 1;
    setState(() {
      _chatSearchQuery = val;
      _activeSearchMatchPos = nextPos;
    });
    if (nextPos >= 0) {
      _scrollToMatchedMessage(
        allMessages: allMessages,
        msgIdx: matched[nextPos],
        hasThinking: hasThinking,
        hasLoadMore: hasLoadMore,
      );
    }
  }

  void _stepSearchMatch({
    required int delta,
    required List<AgentMessage> allMessages,
    required List<int> matchedIndices,
    required bool hasThinking,
    required bool hasLoadMore,
  }) {
    if (matchedIndices.isEmpty) return;
    final len = matchedIndices.length;
    final current = (_activeSearchMatchPos >= 0 && _activeSearchMatchPos < len)
        ? _activeSearchMatchPos
        : len - 1;
    final nextPos = (current + delta) % len;
    final normalizedPos = nextPos < 0 ? nextPos + len : nextPos;
    setState(() {
      _activeSearchMatchPos = normalizedPos;
    });
    _scrollToMatchedMessage(
      allMessages: allMessages,
      msgIdx: matchedIndices[normalizedPos],
      hasThinking: hasThinking,
      hasLoadMore: hasLoadMore,
    );
  }

  void _scrollToMatchedMessage({
    required List<AgentMessage> allMessages,
    required int msgIdx,
    required bool hasThinking,
    required bool hasLoadMore,
    int attempt = 0,
    int? seq,
  }) {
    if (msgIdx < 0 || msgIdx >= allMessages.length) return;
    final jumpSeq = seq ?? ++_searchJumpSeq;
    final targetKey = _messageKeyFor(allMessages[msgIdx].messageKey);

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || jumpSeq != _searchJumpSeq) return;
      final ctx = targetKey.currentContext;
      if (ctx != null) {
        Scrollable.ensureVisible(
          ctx,
          duration: const Duration(milliseconds: 220),
          alignment: 0.35,
          curve: Curves.easeOutCubic,
        );
        return;
      }
      if (!_scrollController.hasClients || attempt >= 4) return;
      final totalItems = allMessages.length + (hasThinking ? 1 : 0) + (hasLoadMore ? 1 : 0);
      if (totalItems <= 1) return;
      final listIdx = (hasThinking ? 1 : 0) + (allMessages.length - 1 - msgIdx);
      final maxExtent = _scrollController.position.maxScrollExtent;
      final ratio = (listIdx / (totalItems - 1)).clamp(0.0, 1.0);
      final targetOffset = (maxExtent * ratio).clamp(0.0, maxExtent);
      _scrollController.jumpTo(targetOffset);
      _scrollToMatchedMessage(
        allMessages: allMessages,
        msgIdx: msgIdx,
        hasThinking: hasThinking,
        hasLoadMore: hasLoadMore,
        attempt: attempt + 1,
        seq: jumpSeq,
      );
    });
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
      Future<void>.delayed(const Duration(milliseconds: 1500), _checkAppUpdateSilently);
    }
    Future.microtask(() {
      ref.read(hubControllerProvider.notifier).initializeForUser(widget.user);
    });
  }

  Future<void> _checkAppUpdateSilently() async {
    if (!mounted || !AndroidNativeBridge.isAndroidNative) return;
    try {
      final current = await AppUpdateService.resolveCurrentVersion();
      final ignored = await AppUpdateService.getIgnoredVersion();
      final latest = await ref.read(apiClientProvider).getAppLatestRelease();
      if (!mounted) return;
      final hasNew = isAppUpdateAvailable(current, latest.latestVersion) &&
          normalizeSemver(latest.latestVersion) != ignored;
      setState(() {
        _currentAppVersion = current;
        _availableAppUpdate = hasNew ? latest : null;
      });
    } catch (_) {}
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

  Future<void> _refreshAutomationsCount([String? nodeIdOverride]) async {
    final targetNode = nodeIdOverride ?? ref.read(hubControllerProvider).selectedNodeId;
    if (targetNode.isEmpty) {
      if (mounted && _enabledAutomationsCount != 0) {
        setState(() => _enabledAutomationsCount = 0);
      }
      return;
    }
    final reqId = ++_automationsCountReqId;
    try {
      final resp = await ref.read(apiClientProvider).getAutomations(targetNode);
      if (!mounted || reqId != _automationsCountReqId) return;
      final currentNode = ref.read(hubControllerProvider).selectedNodeId;
      if (currentNode != targetNode) return;
      final count = resp.items.where((e) => e.enabled).length;
      if (_enabledAutomationsCount != count) {
        setState(() => _enabledAutomationsCount = count);
      }
    } catch (_) {
      if (!mounted || reqId != _automationsCountReqId) return;
      if (_enabledAutomationsCount != 0) {
        setState(() => _enabledAutomationsCount = 0);
      }
    }
  }

  Future<void> _openAutomationSession(String sessionId, String title) async {
    if (sessionId.isEmpty) return;
    final hubState = ref.read(hubControllerProvider);
    final hubNotifier = ref.read(hubControllerProvider.notifier);
    SessionItem? found;
    for (final list in hubState.projects.values) {
      for (final s in list) {
        if (s.id == sessionId) {
          found = s;
          break;
        }
      }
      if (found != null) break;
    }
    found ??= hubState.generalSessions.cast<SessionItem?>().firstWhere(
          (s) => s?.id == sessionId,
          orElse: () => null,
        );
    final target = found ?? SessionItem(id: sessionId, title: title.isNotEmpty ? title : '自动化任务');
    if (mounted && _showAutomationsView) {
      setState(() => _showAutomationsView = false);
    }
    await hubNotifier.selectSession(target);
    unawaited(hubNotifier.refreshSessionTree());
  }

  Future<void> _handleSwitchNode(String nodeId) async {
    if (mounted && _showAutomationsView) {
      setState(() => _showAutomationsView = false);
    }
    final err = await ref.read(hubControllerProvider.notifier).switchNode(nodeId);
    if (err != null) {
      _showSnack(err, isError: true);
    } else {
      unawaited(_refreshAutomationsCount(nodeId));
    }
  }

  Future<void> _handleDeleteSession(String sessionId) async {
    final err = await ref.read(hubControllerProvider.notifier).deleteSession(sessionId);
    if (err != null) {
      _showSnack(err, isError: true);
    } else {
      _showSnack('已归档会话');
    }
  }

  void _showArchivedSessionsDialog() {
    final hubState = ref.read(hubControllerProvider);
    final nodeId = hubState.selectedNodeId;
    if (nodeId.isEmpty) {
      _showSnack('尚未选择控制节点');
      return;
    }
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final api = ref.read(apiClientProvider);
    final hubNotifier = ref.read(hubControllerProvider.notifier);

    showDialog<void>(
      context: context,
      builder: (ctx) => ArchivedSessionsDialog(
        isDark: isDark,
        canWrite: hubState.canWrite,
        onLoad: () => api.getArchivedSessions(nodeId),
        onRestore: (item) => hubNotifier.restoreSession(item.id),
        onOpenSession: (item) {
          if (mounted && _showAutomationsView) {
            setState(() => _showAutomationsView = false);
          }
          hubNotifier.selectSession(item.toSessionItem());
        },
      ),
    );
  }

  Future<void> _handleTogglePinSession(SessionItem session) async {
    HapticFeedback.lightImpact();
    final res = await ref.read(hubControllerProvider.notifier).toggleSessionPin(session);
    if (!mounted) return;
    if (res.error != null) {
      _showSnack(res.error!, isError: true);
    } else if (res.message.isNotEmpty) {
      _showSnack(res.message);
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

    final modelOptions =
        hubState.availableModels.isNotEmpty ? hubState.availableModels : kAllOfficialModels;
    final initialModel = modelOptions.any((m) => m.id == hubState.selectedModel)
        ? hubState.selectedModel
        : modelOptions.first.id;

    showDialog(
      context: context,
      builder: (ctx) => NewSessionDialog(
        initialMode: hubState.selectedMode,
        initialModel: initialModel,
        models: modelOptions,
        availableProjects: projectMap,
        initialProjectName: initialProjectName,
        onStart: (prompt, mode, model, wsPath, rootId) async {
          HapticFeedback.lightImpact();
          final err = await ref.read(hubControllerProvider.notifier).createNewSession(
                content: prompt,
                mode: mode,
                model: model,
                workspacePath: wsPath ?? initialWorkspacePath,
                rootId: rootId ?? initialRootId,
              );
          if (err != null) {
            _showSnack(err, isError: true);
          } else {
            _showSnack('已开启新对话，等待 Agent 响应...');
          }
        },
      ),
    );
  }

  void _showModelPicker(HubState hubState, HubController hubNotifier, bool isDark) {
    unawaited(hubNotifier.fetchModels());
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (ctx) => Consumer(
        builder: (_, sheetRef, __) {
          final liveState = sheetRef.watch(hubControllerProvider);
          final models =
              liveState.availableModels.isNotEmpty ? liveState.availableModels : kAllOfficialModels;
          return ModelPickerSheet(
            isDark: isDark,
            models: models,
            activeModel: liveState.activeSessionModel,
            pendingModel: liveState.pendingSwitchModel,
            onSelectModel: (selectedId) {
              hubNotifier.setSessionPendingModel(selectedId);
              if (selectedId == null ||
                  selectedId.trim().isEmpty ||
                  selectedId == liveState.activeSessionModel) {
                _showSnack('已恢复沿用当前会话模型');
              } else {
                final label = formatModelDisplayName(selectedId, models);
                _showSnack('下一条消息将切换为 $label');
              }
            },
          );
        },
      ),
    );
  }

  Future<String?> _readAndOpenTextFile(
    String rootId,
    String relPath, {
    int? startLine,
    int? endLine,
  }) async {
    final hub = ref.read(hubControllerProvider.notifier);
    final hubState = ref.read(hubControllerProvider);
    final useSidePanel = mounted && ResponsiveLayout.useSideWorkspacePanel(context);
    VoidCallback? externalCbFor(String rId, String pathVal) =>
        FileUtils.isHtmlFile(pathVal) ? () => _openMediaExternal(pathVal, rootId: rId) : null;

    if (useSidePanel) {
      final reqId = ++_sidePreviewReqId;
      setState(() {
        _rightPanelOpen = true;
        _rightPanelTab = 0;
        _loadingSidePreview = true;
        _sidePreviewError = null;
      });
      try {
        final data = await hub.readFileContent(rootId, relPath);
        if (!mounted || reqId != _sidePreviewReqId) return null;
        if (data.content.contains('\x00') || FileUtils.isBinaryFile(data.name)) {
          setState(() {
            _loadingSidePreview = false;
            if (_sidePreviewFile == null && !_terminalMounted) {
              _rightPanelOpen = false;
            }
          });
          _showSnack('📦 文件 [${data.name}] 为二进制文件，已自动转为下载通道');
          return await _downloadFileResult(relPath, rootId: rootId, filename: data.name);
        }
        final isProtectedBrain = rootId == 'brain' &&
            (relPath.contains('.system_generated') || relPath.contains('.user_uploaded'));
        setState(() {
          _loadingSidePreview = false;
          _sidePreviewError = null;
          _sidePreviewFile = (
            data: data,
            canWrite: hubState.canWrite && !isProtectedBrain,
            isOfficePreview: false,
            pdfEmbedUrl: null,
            onOpenExternal: externalCbFor(data.rootId, data.path),
            startLine: startLine,
            endLine: endLine,
          );
        });
        return null;
      } on BinaryFileApiException {
        if (mounted && reqId == _sidePreviewReqId) {
          setState(() {
            _loadingSidePreview = false;
            if (_sidePreviewFile == null && !_terminalMounted) {
              _rightPanelOpen = false;
            }
          });
        }
        return await _downloadFileResult(relPath, rootId: rootId);
      } on ApiException catch (e) {
        final msg = '读取失败: ${e.message}';
        if (mounted && reqId == _sidePreviewReqId) {
          setState(() {
            _loadingSidePreview = false;
            _sidePreviewError = msg;
          });
        }
        return msg;
      } catch (e) {
        final msg = '读取异常: $e';
        if (mounted && reqId == _sidePreviewReqId) {
          setState(() {
            _loadingSidePreview = false;
            _sidePreviewError = msg;
          });
        }
        return msg;
      }
    }

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
        highlightStartLine: startLine,
        highlightEndLine: endLine,
        onOpenExternal: externalCbFor(data.rootId, data.path),
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

  Future<String?> _openOfficePreview(
    String rootId,
    String relPath, {
    String? filename,
  }) async {
    final hub = ref.read(hubControllerProvider.notifier);
    final useSidePanel = mounted && ResponsiveLayout.useSideWorkspacePanel(context);

    if (useSidePanel) {
      final reqId = ++_sidePreviewReqId;
      setState(() {
        _rightPanelOpen = true;
        _rightPanelTab = 0;
        _loadingSidePreview = true;
        _sidePreviewError = null;
      });
      try {
        final data = await hub.previewOfficeFile(rootId, relPath);
        if (!mounted || reqId != _sidePreviewReqId) return null;
        setState(() {
          _loadingSidePreview = false;
          _sidePreviewError = null;
          _sidePreviewFile = (
            data: data,
            canWrite: false,
            isOfficePreview: true,
            pdfEmbedUrl: null,
            onOpenExternal: null,
            startLine: null,
            endLine: null,
          );
        });
        return null;
      } on ApiException catch (e) {
        final msg = '文档预览失败: ${e.message}';
        if (mounted && reqId == _sidePreviewReqId) {
          setState(() {
            _loadingSidePreview = false;
            _sidePreviewError = msg;
          });
        }
        return msg;
      } catch (e) {
        final msg = '文档预览异常: $e';
        if (mounted && reqId == _sidePreviewReqId) {
          setState(() {
            _loadingSidePreview = false;
            _sidePreviewError = msg;
          });
        }
        return msg;
      }
    }

    try {
      final data = await hub.previewOfficeFile(rootId, relPath);
      if (!mounted) return null;
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
        canWrite: false,
        isOfficePreview: true,
        onInsertReference: _insertText,
        onDownloadFallback: (p) => _downloadFile(
          p,
          rootId: data.rootId,
          filename: filename ?? data.name,
        ),
      );
      return null;
    } on ApiException catch (e) {
      return '文档预览失败: ${e.message}';
    } catch (e) {
      return '文档预览异常: $e';
    }
  }

  Future<void> _openPdfInlineOrExternal(
    String cleanPath, {
    String? rootId,
    String? filename,
  }) async {
    if (!kIsWeb) {
      await _openMediaExternal(cleanPath, rootId: rootId);
      return;
    }
    final hub = ref.read(hubControllerProvider.notifier);
    final resolved = await hub.resolveFileTargetWithRefresh(cleanPath, rootId: rootId);
    if (!mounted) return;
    if (resolved == null || resolved.relPath.isEmpty) {
      await _openMediaExternal(cleanPath, rootId: rootId);
      return;
    }
    final embedUrl = hub.buildDirectMediaUrlForRoot(resolved.rootId, resolved.relPath);
    if (embedUrl == null || embedUrl.isEmpty) {
      await _openMediaExternal(cleanPath, rootId: rootId);
      return;
    }
    final displayName = (filename != null && filename.trim().isNotEmpty)
        ? filename.trim()
        : FileUtils.extractFilename(resolved.relPath);
    final data = FileContentData(
      rootId: resolved.rootId,
      path: resolved.relPath,
      name: displayName,
      content: '',
      totalLines: 0,
      truncated: false,
      size: 0,
    );
    void openExternal() => _openMediaExternal(resolved.relPath, rootId: resolved.rootId);

    if (ResponsiveLayout.useSideWorkspacePanel(context)) {
      _sidePreviewReqId++;
      setState(() {
        _rightPanelOpen = true;
        _rightPanelTab = 0;
        _loadingSidePreview = false;
        _sidePreviewError = null;
        _sidePreviewFile = (
          data: data,
          canWrite: false,
          isOfficePreview: false,
          pdfEmbedUrl: embedUrl,
          onOpenExternal: openExternal,
          startLine: null,
          endLine: null,
        );
      });
      return;
    }

    FileViewerSheet.show(
      context,
      rootId: resolved.rootId,
      name: displayName,
      path: resolved.relPath,
      content: '',
      totalLines: 0,
      truncated: false,
      size: 0,
      canWrite: false,
      pdfEmbedUrl: embedUrl,
      onOpenExternal: openExternal,
      onDownloadFallback: (p) => _downloadFile(
        p,
        rootId: resolved.rootId,
        filename: displayName,
      ),
    );
  }

  void _openTerminalPanel(HubState hubState) {
    if (hubState.selectedNodeId.isEmpty) {
      _showSnack('当前尚未连接节点', isError: true);
      return;
    }
    if (widget.user.role != 'admin' || !hubState.canWrite) {
      _showSnack('仅具备写权限的管理员可打开远程终端', isError: true);
      return;
    }
    if (ResponsiveLayout.useSideWorkspacePanel(context)) {
      setState(() {
        if (_rightPanelOpen && _rightPanelTab == 1) {
          // 收起但保持后台 PTY 会话运行，不销毁终端
          _rightPanelOpen = false;
        } else {
          _rightPanelOpen = true;
          _rightPanelTab = 1;
          _terminalMounted = true;
          _mobileTerminalOpen = false;
        }
      });
      return;
    }
    setState(() {
      if (_mobileTerminalOpen) {
        // 手机端收起但保持后台 PTY 会话运行
        _mobileTerminalOpen = false;
      } else {
        _mobileTerminalOpen = true;
        _terminalMounted = true;
        _rightPanelOpen = false;
      }
    });
  }

  void _openImagePreviewDialog(String cleanPath, {String? rootId, String? filename}) {
    final hub = ref.read(hubControllerProvider.notifier);
    final mediaUrl = hub.resolveMediaUrl(cleanPath, rootId: rootId);
    final headers = hub.mediaHeaders;
    final displayName = (filename != null && filename.trim().isNotEmpty)
        ? filename.trim()
        : FileUtils.extractFilename(cleanPath);
    final isDark = Theme.of(context).brightness == Brightness.dark;

    showDialog(
      context: context,
      builder: (ctx) => Dialog(
        backgroundColor: isDark ? const Color(0xFF141418) : Colors.white,
        insetPadding: const EdgeInsets.all(20),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 960, maxHeight: 740),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 10, 8, 10),
                child: Row(
                  children: [
                    Icon(
                      Icons.image_outlined,
                      size: 18,
                      color: isDark ? Colors.cyanAccent : Colors.blue,
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        displayName,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontSize: 13.5, fontWeight: FontWeight.w600),
                      ),
                    ),
                    IconButton(
                      icon: const Icon(Icons.open_in_new_rounded, size: 18),
                      tooltip: '外部打开',
                      onPressed: () {
                        Navigator.of(ctx).pop();
                        _openMediaExternal(cleanPath, rootId: rootId);
                      },
                    ),
                    IconButton(
                      icon: const Icon(Icons.download_rounded, size: 18),
                      tooltip: '下载图片',
                      onPressed: () {
                        Navigator.of(ctx).pop();
                        _downloadFile(cleanPath, rootId: rootId, filename: displayName);
                      },
                    ),
                    IconButton(
                      icon: const Icon(Icons.close_rounded, size: 18),
                      tooltip: '关闭',
                      onPressed: () => Navigator.of(ctx).pop(),
                    ),
                  ],
                ),
              ),
              Divider(
                height: 1,
                color: isDark ? const Color(0xFF27272A) : const Color(0xFFE4E4E7),
              ),
              Flexible(
                child: Container(
                  width: double.infinity,
                  color: isDark ? const Color(0xFF0A0A0D) : const Color(0xFFF4F4F5),
                  child: InteractiveViewer(
                    minScale: 0.4,
                    maxScale: 5.0,
                    child: Center(
                      child: Image.network(
                        mediaUrl,
                        headers: headers,
                        fit: BoxFit.contain,
                        loadingBuilder: (_, child, progress) {
                          if (progress == null) return child;
                          return const Padding(
                            padding: EdgeInsets.all(36),
                            child: CircularProgressIndicator(strokeWidth: 2.2),
                          );
                        },
                        errorBuilder: (_, __, ___) => Padding(
                          padding: const EdgeInsets.all(24),
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              const Icon(Icons.broken_image_outlined, size: 36, color: Colors.grey),
                              const SizedBox(height: 8),
                              const Text('图片预览加载失败', style: TextStyle(fontSize: 12.5)),
                              const SizedBox(height: 10),
                              OutlinedButton.icon(
                                onPressed: () {
                                  Navigator.of(ctx).pop();
                                  _downloadFile(cleanPath, rootId: rootId, filename: displayName);
                                },
                                icon: const Icon(Icons.download_rounded, size: 16),
                                label: const Text('转为下载'),
                              ),
                            ],
                          ),
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

  Future<void> _openChatFile(
    String rawPath, {
    String? rootId,
    String? filename,
  }) async {
    final target = FileUtils.parseFileLinkTarget(rawPath);
    final cleanPath = target.cleanPath.trim();
    if (cleanPath.isEmpty) return;

    if (FileUtils.isImageFile(cleanPath)) {
      _openImagePreviewDialog(cleanPath, rootId: rootId, filename: filename);
      return;
    }
    if (FileUtils.isPdfFile(cleanPath)) {
      await _openPdfInlineOrExternal(cleanPath, rootId: rootId, filename: filename);
      return;
    }
    if (FileUtils.isMediaStreamFile(cleanPath)) {
      await _openMediaExternal(cleanPath, rootId: rootId);
      return;
    }
    if (FileUtils.isOfficePreviewableFile(cleanPath)) {
      final hub = ref.read(hubControllerProvider.notifier);
      final resolved = await hub.resolveFileTargetWithRefresh(cleanPath, rootId: rootId);
      if (!mounted) return;
      if (resolved != null && resolved.relPath.isNotEmpty) {
        final err = await _openOfficePreview(
          resolved.rootId,
          resolved.relPath,
          filename: filename,
        );
        if (err != null && mounted && !ResponsiveLayout.useSideWorkspacePanel(context)) {
          _showSnack(err, isError: true);
        }
        return;
      }
      await _downloadFile(cleanPath, rootId: rootId, filename: filename);
      return;
    }
    if (FileUtils.isBinaryFile(cleanPath)) {
      await _downloadFile(cleanPath, rootId: rootId, filename: filename);
      return;
    }

    final hub = ref.read(hubControllerProvider.notifier);
    final resolved = await hub.resolveFileTargetWithRefresh(cleanPath, rootId: rootId);
    if (!mounted) return;
    if (resolved != null && resolved.relPath.isNotEmpty) {
      final err = await _readAndOpenTextFile(
        resolved.rootId,
        resolved.relPath,
        startLine: target.startLine,
        endLine: target.endLine,
      );
      if (err != null && mounted && !ResponsiveLayout.useSideWorkspacePanel(context)) {
        _showSnack(err, isError: true);
      }
      return;
    }
    await _downloadFile(cleanPath, rootId: rootId, filename: filename);
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
        onReadOfficeFile: (rootId, relPath) => _openOfficePreview(rootId, relPath),
        onOpenPdfInline: kIsWeb
            ? (rootId, relPath) {
                Navigator.of(ctx).pop();
                unawaited(_openPdfInlineOrExternal(relPath, rootId: rootId));
              }
            : null,
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
        if (FileUtils.isPdfFile(item.relPath) || FileUtils.isOfficePreviewableFile(item.relPath)) {
          await _openChatFile(item.relPath, rootId: item.rootId, filename: item.name);
          return;
        }
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

  Widget _buildCachedSessionBanner(
    HubState hubState,
    HubController hubNotifier,
    bool isDark,
    double contentMaxWidth,
  ) {
    final syncing = hubState.isInitializing || hubState.isConnecting;
    final updatedAt = hubState.activeCacheUpdatedAt;
    final timeStr = updatedAt != null
        ? ' · ${updatedAt.hour.toString().padLeft(2, '0')}:${updatedAt.minute.toString().padLeft(2, '0')}'
        : '';
    final bgColor = syncing
        ? (isDark ? const Color(0xFF1A1A1F) : const Color(0xFFF4F4F6))
        : (isDark ? const Color(0xFF282114) : const Color(0xFFFFFBEB));
    final borderColor = syncing
        ? (isDark ? AppColors.darkBorder : AppColors.lightBorder)
        : (isDark ? const Color(0xFF5C461B) : const Color(0xFFFDE68A));
    final textColor = syncing
        ? (isDark ? AppColors.darkTextSecondary : AppColors.lightTextSecondary)
        : AppColors.statusAmber(isDark);

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
      decoration: BoxDecoration(
        color: bgColor,
        border: Border(bottom: BorderSide(color: borderColor, width: 0.7)),
      ),
      child: Center(
        child: ConstrainedBox(
          constraints: BoxConstraints(maxWidth: contentMaxWidth),
          child: Row(
            children: [
              if (syncing)
                SizedBox(
                  width: 12,
                  height: 12,
                  child: CircularProgressIndicator(
                    strokeWidth: 1.8,
                    color: textColor,
                  ),
                )
              else
                Icon(Icons.cloud_off_rounded, size: 14, color: textColor),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  syncing
                      ? '正在同步最新对话（当前显示本地缓存$timeStr）'
                      : '离线只读缓存（电脑断联时可浏览最近对话$timeStr）',
                  style: TextStyle(fontSize: 11.5, color: textColor, fontWeight: FontWeight.w500),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              if (!syncing && hubState.selectedNodeId.isNotEmpty)
                InkWell(
                  borderRadius: BorderRadius.circular(6),
                  onTap: () => unawaited(hubNotifier.switchNode(hubState.selectedNodeId)),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                    child: Text(
                      '重连',
                      style: TextStyle(
                        fontSize: 11.5,
                        fontWeight: FontWeight.w700,
                        color: textColor,
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

  void _showSettingsDialog({SettingsCategory? initialCategory}) {
    final auth = ref.read(authControllerProvider);
    SettingsView.open(
      context,
      initialCategory: initialCategory,
      user: widget.user,
      currentUrl: auth.serverConfig.baseUrl,
      currentAppVersion: _currentAppVersion,
      initialAppUpdate: _availableAppUpdate,
      onUpdateBadgeChanged: (nextUpdate) {
        if (mounted) {
          setState(() => _availableAppUpdate = nextUpdate);
        }
      },
      onSaveUrl: (newUrl) async {
        await ref.read(authControllerProvider.notifier).updateServerUrl(newUrl);
        if (mounted) {
          _showSnack('已保存网关地址: $newUrl（下次重连生效）');
        }
      },
      onLogout: _confirmLogout,
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
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        node.name,
                        style: TextStyle(
                          fontSize: 13,
                          fontWeight: isSelected ? FontWeight.bold : FontWeight.normal,
                          color: isDark ? Colors.white : Colors.black87,
                        ),
                      ),
                      if (node.version.isNotEmpty)
                        Text(
                          'v${node.version}',
                          style: TextStyle(
                            fontSize: 10,
                            fontFamily: 'monospace',
                            color: isDark ? Colors.white38 : Colors.black45,
                          ),
                        ),
                    ],
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

  Widget _buildAutomationsBody(HubState hubState, bool isDark) {
    final api = ref.read(apiClientProvider);
    final nodeId = hubState.selectedNodeId;
    final nodeName = hubState.currentNode?.name ?? nodeId;
    return AutomationsPanel(
      nodeId: nodeId,
      nodeName: nodeName,
      isDark: isDark,
      canWrite: hubState.canWrite,
      canDelete: hubState.canDelete,
      onLoad: (nid) => api.getAutomations(nid),
      onToggle: (nid, id, enabled) => api.toggleAutomation(nid, id, enabled: enabled),
      onRunNow: (nid, id) => api.runAutomationNow(nid, id),
      onCreate: (nid, form) => api.createAutomation(
        nid,
        id: form.id,
        displayName: form.displayName,
        description: form.description,
        cronExpr: form.cronExpr,
        timezone: form.timezone,
        prompt: form.prompt,
        workspacePath: form.workspacePath,
      ),
      onUpdate: (nid, id, form) => api.updateAutomation(
        nid,
        id,
        displayName: form.displayName,
        description: form.description,
        cronExpr: form.cronExpr,
        timezone: form.timezone,
        prompt: form.prompt,
        workspacePath: form.workspacePath,
      ),
      onDelete: (nid, id) => api.deleteAutomation(nid, id),
      onLoadLogs: (nid, id) => api.getAutomationLogs(nid, id),
      onOpenSession: _openAutomationSession,
      onClose: () => setState(() => _showAutomationsView = false),
      onCountChanged: (count) {
        if (mounted && _enabledAutomationsCount != count) {
          setState(() => _enabledAutomationsCount = count);
        }
      },
    );
  }

  Widget _buildSidebar(
    HubState hubState,
    HubController hubNotifier,
    ThemeState themeState,
    bool isDark, {
    required bool isPermanent,
  }) {
    final sidebarGroupBy = ref.watch(sidebarPrefsProvider);
    return QuotaDrawer(
      nodes: hubState.nodes,
      selectedNode: hubState.selectedNodeId,
      onSwitchNode: _handleSwitchNode,
      onRefreshNodes: () => hubNotifier.refreshNodes(),
      quotaData: hubState.quota,
      isLoadingQuota: hubState.isLoadingQuota,
      onRequestQuota: () {
        hubNotifier.fetchQuota();
        unawaited(hubNotifier.fetchModels());
      },
      canWrite: hubState.canWrite,
      canDelete: hubState.canDelete,
      onNewSession: () {
        if (_showAutomationsView) {
          setState(() => _showAutomationsView = false);
        }
        _showNewSessionDialog();
      },
      onNewSessionInProject: (projName, wsPath, rootId) {
        if (_showAutomationsView) {
          setState(() => _showAutomationsView = false);
        }
        _showNewSessionDialog(
          initialProjectName: projName,
          initialWorkspacePath: wsPath,
          initialRootId: rootId,
        );
      },
      projects: hubState.projects,
      generalSessions: hubState.generalSessions,
      activeSessionId: hubState.activeSessionId,
      runningSessionIds: hubState.runningSessionIds,
      onSwitchSession: (s) {
        if (_showAutomationsView) {
          setState(() => _showAutomationsView = false);
        }
        hubNotifier.selectSession(s);
      },
      onTogglePinSession: _handleTogglePinSession,
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
      groupBy: sidebarGroupBy,
      onGroupByChanged: (mode) {
        HapticFeedback.selectionClick();
        ref.read(sidebarPrefsProvider.notifier).setGroupBy(mode);
      },
      onOpenAutomations: () {
        setState(() => _showAutomationsView = true);
      },
      enabledAutomationsCount: _enabledAutomationsCount,
      isAutomationsOpen: _showAutomationsView,
      onOpenArchivedSessions: _showArchivedSessionsDialog,
      archivedSessionsCount: hubState.archivedSessionsCount,
      onOpenSettings: () => _showSettingsDialog(),
      onOpenAccountSettings: () => _showSettingsDialog(initialCategory: SettingsCategory.account),
      hasAppUpdate: _availableAppUpdate != null,
    );
  }

  @override
  Widget build(BuildContext context) {
    ref.listen<HubState>(hubControllerProvider, (prev, next) {
      if (prev != null && prev.selectedNodeId != next.selectedNodeId) {
        if (mounted) {
          setState(() {
            _sidePreviewReqId++;
            _sidePreviewFile = null;
            _loadingSidePreview = false;
            _sidePreviewError = null;
            _terminalMounted = false;
            _terminalLive = false;
            _mobileTerminalOpen = false;
            _showAutomationsView = false;
            if (next.selectedNodeId.isEmpty) {
              _rightPanelOpen = false;
              _enabledAutomationsCount = 0;
            }
          });
          if (next.selectedNodeId.isNotEmpty) {
            unawaited(_refreshAutomationsCount(next.selectedNodeId));
          }
        }
      }
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
    final useSideWorkspacePanel = ResponsiveLayout.useSideWorkspacePanel(context);
    final canUseTerminal = widget.user.role == 'admin' &&
        hubState.canWrite &&
        hubState.selectedNodeId.isNotEmpty;
    final needsTerminalReset = !canUseTerminal &&
        (_terminalMounted || _terminalLive || _mobileTerminalOpen);
    final needsSideToMobileMigration = !useSideWorkspacePanel && _rightPanelOpen;
    final needsMobileToSideMigration = useSideWorkspacePanel && _mobileTerminalOpen;
    if (needsTerminalReset || needsSideToMobileMigration || needsMobileToSideMigration) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        final curSide = ResponsiveLayout.useSideWorkspacePanel(context);
        final curHub = ref.read(hubControllerProvider);
        final curCanTerm = widget.user.role == 'admin' &&
            curHub.canWrite &&
            curHub.selectedNodeId.isNotEmpty;
        setState(() {
          if (!curCanTerm) {
            _terminalMounted = false;
            _terminalLive = false;
            _mobileTerminalOpen = false;
            _rightPanelOpen = false;
          } else if (!curSide && _rightPanelOpen) {
            if (_rightPanelTab == 1 && _terminalMounted) {
              _mobileTerminalOpen = true;
            }
            _rightPanelOpen = false;
          } else if (curSide && _mobileTerminalOpen) {
            if (_terminalMounted) {
              _rightPanelOpen = true;
              _rightPanelTab = 1;
            }
            _mobileTerminalOpen = false;
          }
        });
      });
    }
    final contentMaxWidth = ResponsiveLayout.contentMaxWidth(context);

    final allMessages = hubState.messages;
    if (_lastSearchSessionId != hubState.activeSessionId) {
      _lastSearchSessionId = hubState.activeSessionId;
      _messageItemKeys.clear();
      _activeSearchMatchPos = -1;
    }
    final query = _chatSearchQuery.trim();
    final isChatSearchActive = _isChatSearching && query.isNotEmpty;
    final matchedIndices = isChatSearchActive
        ? _collectMatchedMessageIndices(allMessages, query)
        : const <int>[];
    final effectiveMatchPos = matchedIndices.isEmpty
        ? -1
        : (_activeSearchMatchPos >= 0 && _activeSearchMatchPos < matchedIndices.length)
            ? _activeSearchMatchPos
            : matchedIndices.length - 1;
    final focusedSearchMsgIdx = effectiveMatchPos >= 0 ? matchedIndices[effectiveMatchPos] : -1;
    final messages = allMessages;
    final planSteps = hubState.activePlanSteps;
    final activeFocus = hubState.activeFocusText;
    final turnChangesByMsgIdx = _buildTurnChangesByMessageIndex(
      messages,
      hubState.sessionChanges.turns,
    );
    final turnDurationsByMsgIdx = computeTurnDurationsByMsgIdx(messages);
    final activeTurnStartedAt = findActiveTurnStartTime(allMessages);
    final hasThinking = hubState.isActiveSessionRunning;
    final hasLoadMore = hubState.hasMoreMessages;
    final totalItems = messages.length + (hasThinking ? 1 : 0) + (hasLoadMore ? 1 : 0);

    return PopScope(
      canPop: kIsWeb,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) return;
        if (_scaffoldKey.currentState?.isDrawerOpen == true) {
          Navigator.of(context).pop();
          return;
        }
        if (_showAutomationsView) {
          setState(() => _showAutomationsView = false);
          return;
        }
        if (!useSideWorkspacePanel && _mobileTerminalOpen) {
          setState(() => _mobileTerminalOpen = false);
          return;
        }
        if (_isChatSearching) {
          _closeChatSearch();
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
          unawaited(hubNotifier.fetchModels());
          unawaited(_refreshAutomationsCount());
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
              _showAutomationsView ? 'Automations 自动化' : hubState.activeSessionTitle,
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
          if (!_showAutomationsView && hubState.activeSessionId.isNotEmpty) ...[
            IconButton(
              visualDensity: VisualDensity.compact,
              icon: Icon(_isChatSearching ? Icons.search_off_rounded : Icons.search_rounded, size: 20),
              tooltip: '搜索对话内容',
              onPressed: () {
                if (_isChatSearching) {
                  _closeChatSearch();
                } else {
                  setState(() => _isChatSearching = true);
                }
              },
            ),
            IconButton(
              visualDensity: VisualDensity.compact,
              icon: const Icon(Icons.auto_awesome_mosaic_outlined, size: 20),
              tooltip: '会话文档 (Artifacts)',
              onPressed: _openSessionArtifacts,
            ),
          ],
          if (canUseTerminal)
            Builder(
              builder: (context) {
                final terminalExpanded = (useSideWorkspacePanel && _rightPanelOpen && _rightPanelTab == 1) ||
                    (!useSideWorkspacePanel && _mobileTerminalOpen);
                final terminalBgActive = _terminalMounted && !terminalExpanded;
                return IconButton(
                  visualDensity: VisualDensity.compact,
                  icon: Stack(
                    clipBehavior: Clip.none,
                    children: [
                      Icon(
                        Icons.terminal_rounded,
                        size: 20,
                        color: terminalExpanded
                            ? Theme.of(context).colorScheme.primary
                            : null,
                      ),
                      if (terminalBgActive)
                        Positioned(
                          right: -2,
                          top: -2,
                          child: Container(
                            width: 7,
                            height: 7,
                            decoration: BoxDecoration(
                              shape: BoxShape.circle,
                              color: _terminalLive ? Colors.greenAccent : AppColors.statusAmber(isDark),
                              border: Border.all(
                                color: isDark ? AppColors.darkBg : AppColors.lightBg,
                                width: 1.2,
                              ),
                            ),
                          ),
                        ),
                    ],
                  ),
                  tooltip: terminalExpanded
                      ? '收起终端（后台保持运行）'
                      : (terminalBgActive
                          ? (_terminalLive ? '展开后台终端（运行中）' : '展开后台终端（已断开）')
                          : '远程终端 (PTY)'),
                  onPressed: () => _openTerminalPanel(hubState),
                );
              },
            ),
          if (useSideWorkspacePanel && _sidePreviewFile != null && !_rightPanelOpen)
            IconButton(
              visualDensity: VisualDensity.compact,
              icon: const Icon(Icons.vertical_split_rounded, size: 20),
              tooltip: '展开右侧文件预览',
              onPressed: () {
                setState(() {
                  _rightPanelOpen = true;
                  _rightPanelTab = 0;
                });
              },
            ),
          if (usePermanentSidebar) ...[
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
              icon: Stack(
                clipBehavior: Clip.none,
                children: [
                  const Icon(Icons.settings_outlined),
                  if (_availableAppUpdate != null)
                    Positioned(
                      right: -2,
                      top: -2,
                      child: Container(
                        width: 8,
                        height: 8,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: Colors.redAccent,
                          border: Border.all(
                            color: isDark ? AppColors.darkBg : AppColors.lightBg,
                            width: 1.2,
                          ),
                        ),
                      ),
                    ),
                ],
              ),
              tooltip: _availableAppUpdate != null
                  ? '通用设置（有新版本 v${_availableAppUpdate!.latestVersion}）'
                  : '通用设置',
              onPressed: () => _showSettingsDialog(),
            ),
          ],
        ],
      ),
      body: Stack(
        children: [
          Row(
            children: [
              if (showPermanentSidebar)
                _buildSidebar(hubState, hubNotifier, themeState, isDark, isPermanent: true),
          Expanded(
            child: _showAutomationsView
                ? _buildAutomationsBody(hubState, isDark)
                : Column(
              children: [
          if (hubState.nodePowerStatus != null && hubState.nodePowerStatus!.enabled)
            NodePowerBanner(
              nodeName: hubState.currentNode?.name ?? hubState.selectedNodeId,
              status: hubState.nodePowerStatus!,
              isDark: isDark,
              isUpdating: hubState.isUpdatingNodePower,
              maxContentWidth: contentMaxWidth,
              onCancel: () async {
                final err = await hubNotifier.cancelNodePower();
                if (err != null && context.mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(err)));
                }
              },
            ),
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
                          textInputAction: TextInputAction.search,
                          onChanged: (val) => _onChatSearchQueryChanged(
                            val,
                            allMessages,
                            hasThinking,
                            hasLoadMore,
                          ),
                          onSubmitted: (_) => _stepSearchMatch(
                            delta: -1,
                            allMessages: allMessages,
                            matchedIndices: matchedIndices,
                            hasThinking: hasThinking,
                            hasLoadMore: hasLoadMore,
                          ),
                          style: TextStyle(fontSize: 13, color: isDark ? Colors.white : Colors.black87),
                          decoration: InputDecoration(
                            isDense: true,
                            hintText: '在当前会话内搜索...',
                            hintStyle: TextStyle(fontSize: 12, color: isDark ? Colors.white38 : Colors.black38),
                            border: InputBorder.none,
                          ),
                        ),
                      ),
                      if (query.isNotEmpty) ...[
                        Padding(
                          padding: const EdgeInsets.only(right: 2),
                          child: Text(
                            matchedIndices.isEmpty
                                ? '0/0'
                                : '${effectiveMatchPos + 1}/${matchedIndices.length}',
                            style: TextStyle(
                              fontSize: 11.5,
                              fontWeight: FontWeight.w600,
                              color: matchedIndices.isEmpty
                                  ? (isDark ? const Color(0xFFFCA5A5) : const Color(0xFFDC2626))
                                  : (isDark ? Colors.white70 : Colors.black54),
                            ),
                          ),
                        ),
                        IconButton(
                          tooltip: '上一条匹配（更早）',
                          icon: const Icon(Icons.keyboard_arrow_up_rounded, size: 20),
                          visualDensity: VisualDensity.compact,
                          padding: EdgeInsets.zero,
                          constraints: const BoxConstraints(minWidth: 30, minHeight: 30),
                          onPressed: matchedIndices.isEmpty
                              ? null
                              : () => _stepSearchMatch(
                                    delta: -1,
                                    allMessages: allMessages,
                                    matchedIndices: matchedIndices,
                                    hasThinking: hasThinking,
                                    hasLoadMore: hasLoadMore,
                                  ),
                        ),
                        IconButton(
                          tooltip: '下一条匹配（更新）',
                          icon: const Icon(Icons.keyboard_arrow_down_rounded, size: 20),
                          visualDensity: VisualDensity.compact,
                          padding: EdgeInsets.zero,
                          constraints: const BoxConstraints(minWidth: 30, minHeight: 30),
                          onPressed: matchedIndices.isEmpty
                              ? null
                              : () => _stepSearchMatch(
                                    delta: 1,
                                    allMessages: allMessages,
                                    matchedIndices: matchedIndices,
                                    hasThinking: hasThinking,
                                    hasLoadMore: hasLoadMore,
                                  ),
                        ),
                      ],
                      IconButton(
                        tooltip: '关闭搜索',
                        icon: const Icon(Icons.close_rounded, size: 18),
                        visualDensity: VisualDensity.compact,
                        onPressed: _closeChatSearch,
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
          if (hubState.isShowingCachedData && messages.isNotEmpty)
            _buildCachedSessionBanner(hubState, hubNotifier, isDark, contentMaxWidth),
          Expanded(
            child: GestureDetector(
              behavior: HitTestBehavior.translucent,
              onTap: () => FocusScope.of(context).unfocus(),
              child: (hubState.isLoadingMessages || (hubState.isInitializing && messages.isEmpty))
                  ? Center(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const CircularProgressIndicator(),
                          if (hubState.isInitializing) ...[
                            const SizedBox(height: 12),
                            Text(
                              '正在连接节点并恢复最近对话...',
                              style: TextStyle(
                                fontSize: 12.5,
                                color: isDark
                                    ? AppColors.darkTextSecondary
                                    : AppColors.lightTextSecondary,
                              ),
                            ),
                          ],
                        ],
                      ),
                    )
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
                              cacheExtent: isChatSearchActive ? 1800 : null,
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
                                      focusText: hubState.isCreatingSession
                                          ? '正在创建新对话并发送指令...'
                                          : activeFocus,
                                      startedAt: activeTurnStartedAt,
                                    ),
                                  );
                                } else {
                                  final shiftedIdx = hasThinking ? idx - 1 : idx;
                                  if (shiftedIdx < messages.length) {
                                    final msgIdx = messages.length - 1 - shiftedIdx;
                                    final msg = messages[msgIdx];
                                    final msgTurnChanges = turnChangesByMsgIdx[msgIdx];
                                    rowChild = KeyedSubtree(
                                      key: _messageKeyFor(msg.messageKey),
                                      child: MessageCard(
                                        key: ValueKey(msg.messageKey),
                                        msg: msg,
                                        isDark: isDark,
                                        nodeName: hubState.currentNode?.name ?? '',
                                        searchQuery: isChatSearchActive ? query : '',
                                        isFocusedSearchMatch: isChatSearchActive && msgIdx == focusedSearchMsgIdx,
                                        resolveMediaUrl: (p) => hubNotifier.resolveMediaUrl(p),
                                        mediaHeaders: hubNotifier.mediaHeaders,
                                        onOpenFile: (p, {filename}) => _openChatFile(p, filename: filename),
                                        onDownloadFile: (p, {filename}) => _downloadFile(p, filename: filename),
                                        onOpenUrl: PlatformBridge.openExternalUrl,
                                        onOpenMediaExternal: (p) => _openMediaExternal(p),
                                        onOpenEditDiff: (filePath, stepIdx) => _openChangeReview(
                                          initialFilePath: filePath,
                                          initialStepIndex: stepIdx,
                                          initialScope: 'step',
                                        ),
                                        onOpenToolDetail: _openToolDetail,
                                        onSubmitQuickReply: hubState.canWrite ? _submitAskQuestionReply : null,
                                        turnChanges: msgTurnChanges,
                                        turnDuration: turnDurationsByMsgIdx[msgIdx],
                                        modelLabel: msg.model.isNotEmpty
                                            ? formatModelDisplayName(msg.model, hubState.availableModels)
                                            : '',
                                        onSwitchModel: hubState.canWrite
                                            ? () => _showModelPicker(hubState, hubNotifier, isDark)
                                            : null,
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
            approvalBar: hubState.pendingApprovals.isNotEmpty
                ? ToolApprovalDock(
                    approvals: hubState.pendingApprovals,
                    resolvingIds: hubState.resolvingApprovalIds,
                    canWrite: hubState.canWrite,
                    isDark: isDark,
                    onResolve: (
                      item, {
                      required bool allow,
                      String scope = 'once',
                      String denyReason = '',
                      String? editedTarget,
                    }) =>
                        hubNotifier.resolveToolApproval(
                      item,
                      allow: allow,
                      scope: scope,
                      denyReason: denyReason,
                      editedTarget: editedTarget,
                    ),
                  )
                : null,
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
            activeModelLabel: hubState.effectiveSessionModel.isNotEmpty
                ? formatModelDisplayName(
                    hubState.effectiveSessionModel,
                    hubState.availableModels,
                  )
                : '',
            isModelSwitchPending: hubState.hasPendingModelSwitch,
            onPickModel: (hubState.activeSessionId.isNotEmpty && hubState.canWrite)
                ? () => _showModelPicker(hubState, hubNotifier, isDark)
                : null,
          ),
              ],
            ),
          ),
          if (useSideWorkspacePanel && _rightPanelOpen)
            MouseRegion(
              cursor: SystemMouseCursors.resizeColumn,
              child: GestureDetector(
                behavior: HitTestBehavior.translucent,
                onHorizontalDragUpdate: (details) {
                  final screenW = MediaQuery.sizeOf(context).width;
                  final maxW = (screenW * 0.54).clamp(360.0, 760.0);
                  setState(() {
                    _rightPanelWidth = (_rightPanelWidth - details.delta.dx).clamp(320.0, maxW);
                  });
                },
                child: Container(
                  width: 6,
                  color: Colors.transparent,
                  child: Center(
                    child: Container(
                      width: 1,
                      color: isDark ? AppColors.darkBorder : AppColors.lightBorder,
                    ),
                  ),
                ),
              ),
            ),
          if (useSideWorkspacePanel && (_rightPanelOpen || _terminalMounted))
            Offstage(
              offstage: !_rightPanelOpen,
              child: TickerMode(
                enabled: _rightPanelOpen,
                child: SizedBox(
                  width: _rightPanelWidth.clamp(
                    320.0,
                    (MediaQuery.sizeOf(context).width * 0.54).clamp(360.0, 760.0),
                  ),
                  child: _buildRightWorkspacePanel(
                    hubState: hubState,
                    hubNotifier: hubNotifier,
                    isDark: isDark,
                    canUseTerminal: canUseTerminal,
                  ),
                ),
              ),
            ),
            ],
          ),
          if (!useSideWorkspacePanel && _terminalMounted && canUseTerminal)
            _buildMobileTerminalOverlay(hubState, hubNotifier, isDark),
        ],
      ),
      ),
    );
  }

  Widget _buildRightWorkspacePanel({
    required HubState hubState,
    required HubController hubNotifier,
    required bool isDark,
    required bool canUseTerminal,
  }) {
    final effectiveTab = (!canUseTerminal && _rightPanelTab == 1) ? 0 : _rightPanelTab;
    final primary = Theme.of(context).colorScheme.primary;
    final bgColor = isDark ? const Color(0xFF111216) : Colors.white;
    final headerBg = isDark ? const Color(0xFF16181E) : const Color(0xFFF6F7F9);
    final borderColor = isDark ? AppColors.darkBorder : AppColors.lightBorder;
    final previewFileName = _sidePreviewFile?.data.name ?? '';

    Widget buildTabChip({
      required int tabIndex,
      required IconData icon,
      required String label,
      bool showStatusDot = false,
      bool statusLive = false,
    }) {
      final active = effectiveTab == tabIndex;
      return InkWell(
        onTap: () {
          setState(() {
            _rightPanelTab = tabIndex;
            if (tabIndex == 1 && canUseTerminal) {
              _terminalMounted = true;
            }
          });
        },
        borderRadius: BorderRadius.circular(8),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
          decoration: BoxDecoration(
            color: active
                ? primary.withValues(alpha: isDark ? 0.18 : 0.12)
                : Colors.transparent,
            borderRadius: BorderRadius.circular(8),
            border: Border.all(
              color: active ? primary.withValues(alpha: 0.45) : Colors.transparent,
            ),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                icon,
                size: 14,
                color: active
                    ? primary
                    : (isDark ? AppColors.darkTextSecondary : AppColors.lightTextSecondary),
              ),
              const SizedBox(width: 5),
              Text(
                label,
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: active ? FontWeight.w600 : FontWeight.w500,
                  color: active
                      ? (isDark ? AppColors.darkTextPrimary : AppColors.lightTextPrimary)
                      : (isDark ? AppColors.darkTextSecondary : AppColors.lightTextSecondary),
                ),
              ),
              if (showStatusDot) ...[
                const SizedBox(width: 5),
                Container(
                  width: 6,
                  height: 6,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: statusLive ? Colors.greenAccent : AppColors.statusAmber(isDark),
                  ),
                ),
              ],
            ],
          ),
        ),
      );
    }

    return Container(
      decoration: BoxDecoration(
        color: bgColor,
        border: Border(left: BorderSide(color: borderColor, width: 0.5)),
      ),
      child: Column(
        children: [
          Container(
            height: 44,
            padding: const EdgeInsets.symmetric(horizontal: 10),
            decoration: BoxDecoration(
              color: headerBg,
              border: Border(bottom: BorderSide(color: borderColor, width: 0.5)),
            ),
            child: Row(
              children: [
                buildTabChip(
                  tabIndex: 0,
                  icon: Icons.description_outlined,
                  label: previewFileName.isEmpty
                      ? '文件预览'
                      : '预览 · ${previewFileName.length > 14 ? '${previewFileName.substring(0, 13)}…' : previewFileName}',
                ),
                if (canUseTerminal) ...[
                  const SizedBox(width: 6),
                  buildTabChip(
                    tabIndex: 1,
                    icon: Icons.terminal_rounded,
                    label: '远程终端',
                    showStatusDot: _terminalMounted,
                    statusLive: _terminalLive,
                  ),
                ],
                const Spacer(),
                if (_terminalMounted && canUseTerminal)
                  IconButton(
                    visualDensity: VisualDensity.compact,
                    tooltip: '结束终端会话并释放',
                    icon: Icon(
                      Icons.power_settings_new_rounded,
                      size: 17,
                      color: AppColors.statusRed(isDark),
                    ),
                    onPressed: () {
                      setState(() {
                        _terminalMounted = false;
                        _terminalLive = false;
                        if (_rightPanelTab == 1 || _sidePreviewFile == null) {
                          _rightPanelOpen = false;
                        }
                      });
                    },
                  ),
                IconButton(
                  visualDensity: VisualDensity.compact,
                  tooltip: _terminalMounted
                      ? (_terminalLive ? '收起右侧栏（终端后台保持运行）' : '收起右侧栏')
                      : '收起右侧栏',
                  icon: const Icon(Icons.keyboard_double_arrow_right_rounded, size: 19),
                  onPressed: () {
                    setState(() {
                      _rightPanelOpen = false;
                    });
                  },
                ),
              ],
            ),
          ),
          Expanded(
            child: IndexedStack(
              index: effectiveTab,
              children: [
                _buildSideFilePreviewPane(hubNotifier, isDark),
                if (canUseTerminal)
                  _buildSideTerminalPane(hubState, hubNotifier),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSideFilePreviewPane(HubController hubNotifier, bool isDark) {
    if (_loadingSidePreview) {
      return const Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            SizedBox(
              width: 24,
              height: 24,
              child: CircularProgressIndicator(strokeWidth: 2.2),
            ),
            SizedBox(height: 10),
            Text('正在读取文件内容...', style: TextStyle(fontSize: 12.5, color: Colors.grey)),
          ],
        ),
      );
    }
    if (_sidePreviewError != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.error_outline_rounded, size: 32, color: Colors.orangeAccent),
              const SizedBox(height: 8),
              Text(
                _sidePreviewError!,
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 12.5,
                  color: isDark ? Colors.white70 : Colors.black87,
                ),
              ),
            ],
          ),
        ),
      );
    }
    final preview = _sidePreviewFile;
    if (preview == null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                Icons.article_outlined,
                size: 36,
                color: isDark ? Colors.white24 : Colors.black26,
              ),
              const SizedBox(height: 10),
              Text(
                '点击对话中的文件链接或工作区文件\n即可在此侧边预览、编辑或高亮跳转行号',
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 12.5,
                  height: 1.5,
                  color: isDark ? Colors.white54 : Colors.black54,
                ),
              ),
            ],
          ),
        ),
      );
    }

    final data = preview.data;
    return FileViewerSheet(
      key: ValueKey(
        'side-file-${data.rootId}:${data.path}:${preview.isOfficePreview}:${preview.pdfEmbedUrl}:${preview.startLine}:${preview.endLine}',
      ),
      rootId: data.rootId,
      name: data.name,
      path: data.path,
      content: data.content,
      totalLines: data.totalLines,
      truncated: data.truncated,
      size: data.size,
      mtime: data.mtime,
      canWrite: preview.canWrite,
      isEmbedded: true,
      isOfficePreview: preview.isOfficePreview,
      pdfEmbedUrl: preview.pdfEmbedUrl,
      highlightStartLine: preview.startLine,
      highlightEndLine: preview.endLine,
      onOpenExternal: preview.onOpenExternal,
      onDownload: () => _downloadFile(data.path, rootId: data.rootId, filename: data.name),
      onSave: (preview.isOfficePreview || (preview.pdfEmbedUrl != null && preview.pdfEmbedUrl!.isNotEmpty))
          ? null
          : (newContent, expectedMtime) async {
              final result = await hubNotifier.saveFileContent(
                data.rootId,
                data.path,
                newContent,
                expectedMtime: expectedMtime,
              );
              if (mounted) {
                setState(() {
                  _sidePreviewFile = (
                    data: FileContentData(
                      rootId: data.rootId,
                      path: data.path,
                      name: data.name,
                      content: newContent,
                      totalLines: result.totalLines,
                      truncated: false,
                      size: result.size,
                      mtime: result.mtime,
                    ),
                    canWrite: preview.canWrite,
                    isOfficePreview: preview.isOfficePreview,
                    pdfEmbedUrl: preview.pdfEmbedUrl,
                    onOpenExternal: preview.onOpenExternal,
                    startLine: preview.startLine,
                    endLine: preview.endLine,
                  );
                });
              }
              return result;
            },
      onInsertReference: _insertText,
    );
  }

  Widget _buildSideTerminalPane(HubState hubState, HubController hubNotifier) {
    if (!_terminalMounted) {
      return const SizedBox.shrink();
    }
    return _buildPersistentTerminal(
      hubState,
      hubNotifier,
      isActive: _rightPanelOpen && _rightPanelTab == 1,
      withMobileControls: false,
    );
  }

  Widget _buildPersistentTerminal(
    HubState hubState,
    HubController hubNotifier, {
    required bool isActive,
    required bool withMobileControls,
  }) {
    final api = ref.read(apiClientProvider);
    return TerminalPanel(
      key: _terminalPanelKey,
      serverConfig: api.serverConfig,
      tokenStore: api.tokenStore,
      onRefreshAuth: api.refreshSessionLocked,
      nodeId: hubState.selectedNodeId,
      nodeName: hubState.currentNode?.name ?? hubState.selectedNodeId,
      initialCwd: hubNotifier.activeWorkspacePath,
      activeSessionId: hubState.activeSessionId,
      isEmbedded: true,
      isActive: isActive,
      onMinimize: withMobileControls
          ? () {
              setState(() => _mobileTerminalOpen = false);
            }
          : null,
      onClose: withMobileControls
          ? () {
              setState(() {
                _terminalMounted = false;
                _terminalLive = false;
                _mobileTerminalOpen = false;
              });
            }
          : null,
      onConnectionChanged: (alive) {
        if (!mounted || _terminalLive == alive) return;
        setState(() => _terminalLive = alive);
      },
    );
  }

  Widget _buildMobileTerminalOverlay(
    HubState hubState,
    HubController hubNotifier,
    bool isDark,
  ) {
    final bgColor = isDark ? const Color(0xFF0E1016) : Colors.white;
    final handleColor = isDark ? Colors.white24 : Colors.black26;
    return Positioned.fill(
      child: Offstage(
        offstage: !_mobileTerminalOpen,
        child: TickerMode(
          enabled: _mobileTerminalOpen,
          child: Stack(
            children: [
              GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: () => setState(() => _mobileTerminalOpen = false),
                child: Container(color: Colors.black54),
              ),
              Align(
                alignment: Alignment.bottomCenter,
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 1080.0),
                  child: LayoutBuilder(
                    builder: (ctx, box) {
                      final maxH = box.maxHeight.isFinite ? box.maxHeight : 600.0;
                      final targetH = (maxH * 0.90).clamp(160.0, maxH);
                      return Material(
                        color: bgColor,
                        borderRadius: const BorderRadius.vertical(top: Radius.circular(16)),
                        clipBehavior: Clip.antiAlias,
                        elevation: 16,
                        child: SizedBox(
                          height: targetH,
                          child: Column(
                            children: [
                              GestureDetector(
                                behavior: HitTestBehavior.opaque,
                                onVerticalDragEnd: (details) {
                                  if ((details.primaryVelocity ?? 0) > 260) {
                                    setState(() => _mobileTerminalOpen = false);
                                  }
                                },
                                child: SizedBox(
                                  width: double.infinity,
                                  height: 22,
                                  child: Center(
                                    child: Container(
                                      width: 36,
                                      height: 4,
                                      decoration: BoxDecoration(
                                        color: handleColor,
                                        borderRadius: BorderRadius.circular(2),
                                      ),
                                    ),
                                  ),
                                ),
                              ),
                              Expanded(
                                child: _buildPersistentTerminal(
                                  hubState,
                                  hubNotifier,
                                  isActive: _mobileTerminalOpen,
                                  withMobileControls: true,
                                ),
                              ),
                            ],
                          ),
                        ),
                      );
                    },
                  ),
                ),
              ),
            ],
          ),
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
  final Future<String?> Function(String rootId, String relPath)? onReadOfficeFile;
  final void Function(String rootId, String relPath)? onOpenPdfInline;
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
    this.onReadOfficeFile,
    this.onOpenPdfInline,
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
    final err = FileUtils.isOfficePreviewableFile(relPath) && widget.onReadOfficeFile != null
        ? await widget.onReadOfficeFile!(_rootId, relPath)
        : await widget.onReadFile(_rootId, relPath);
    if (!mounted || err == null) return;
    setState(() {
      _statusIsBusy = false;
      _statusMessage = err;
      _statusIsError = true;
    });
  }

  Future<void> _handlePreviewPdf(String relPath) async {
    final name = _basename(relPath);
    if (kIsWeb && FileUtils.isPdfFile(relPath) && widget.onOpenPdfInline != null) {
      widget.onOpenPdfInline!(_rootId, relPath);
      return;
    }
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

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/config/app_update_service.dart';
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
import '../../core/utils/search_highlight_utils.dart';
import '../../models/models.dart';
import '../auth/auth_controller.dart';
import '../chat/bottom_input_bar.dart';
import '../chat/context_menu_sheet.dart';
import '../chat/message_card.dart';
import '../chat/model_picker_sheet.dart';
import '../chat/offline_outbox_bar.dart';
import '../chat/quick_commands_sheet.dart';
import '../chat/session_queue_bar.dart';
import '../chat/session_steps_bar.dart';
import '../chat/tool_approval_card.dart';
import '../sessions/new_session_dialog.dart';
import '../sessions/quota_drawer.dart';
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
    int? startLine,
    int? endLine,
  })? _sidePreviewFile;
  bool _loadingSidePreview = false;
  String? _sidePreviewError;
  int _sidePreviewReqId = 0;
  String _currentAppVersion = kFallbackAppVersion;
  AppReleaseInfo? _availableAppUpdate;

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
    if (FileUtils.isPdfFile(cleanPath) || FileUtils.isMediaStreamFile(cleanPath)) {
      await _openMediaExternal(cleanPath, rootId: rootId);
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

  void _showSettingsDialog() {
    final auth = ref.read(authControllerProvider);
    showDialog(
      context: context,
      builder: (_) => _GeneralSettingsDialog(
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
      onRequestQuota: () {
        hubNotifier.fetchQuota();
        unawaited(hubNotifier.fetchModels());
      },
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
            if (next.selectedNodeId.isEmpty) {
              _rightPanelOpen = false;
            }
          });
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
            onPressed: _showSettingsDialog,
          ),
        ],
      ),
      body: Stack(
        children: [
          Row(
            children: [
              if (showPermanentSidebar)
                _buildSidebar(hubState, hubNotifier, themeState, isDark, isPermanent: true),
          Expanded(
            child: Column(
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
      key: ValueKey('side-file-${data.rootId}:${data.path}:${preview.startLine}:${preview.endLine}'),
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
      highlightStartLine: preview.startLine,
      highlightEndLine: preview.endLine,
      onDownload: () => _downloadFile(data.path, rootId: data.rootId, filename: data.name),
      onSave: (newContent, expectedMtime) async {
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
  final String currentAppVersion;
  final AppReleaseInfo? initialAppUpdate;
  final ValueChanged<AppReleaseInfo?>? onUpdateBadgeChanged;
  final ValueChanged<String> onSaveUrl;

  const _GeneralSettingsDialog({
    required this.currentUrl,
    this.currentAppVersion = kFallbackAppVersion,
    this.initialAppUpdate,
    this.onUpdateBadgeChanged,
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

  late String _appVersion;
  AppReleaseInfo? _latestRelease;
  bool _checkingAppUpdate = false;
  bool _appUpdateChecked = false;
  String? _appUpdateError;
  String? _downloadedApkPath;
  bool _installingApk = false;

  bool _loadingAdminNodes = false;
  List<HostNode> _adminNodes = const [];
  final Map<String, NodeUpdateStatus> _nodeUpdateStatuses = {};
  final Map<String, String> _nodeUpdateErrors = {};
  final Set<String> _checkingNodeIds = {};
  final Set<String> _updatingNodeIds = {};
  String _selectedPowerAction = 'shutdown';

  @override
  void initState() {
    super.initState();
    _urlController = TextEditingController(text: widget.currentUrl);
    _appVersion = widget.currentAppVersion;
    _latestRelease = widget.initialAppUpdate;
    _appUpdateChecked = widget.initialAppUpdate != null;
    final initialPower = ref.read(hubControllerProvider).nodePowerStatus;
    if (initialPower != null && initialPower.enabled) {
      _selectedPowerAction = initialPower.action;
    }
    _loadNotifyStatus();
    unawaited(ref.read(hubControllerProvider.notifier).refreshNodePowerStatus());
    if (AndroidNativeBridge.isAndroidNative) {
      unawaited(_initAppUpdateSection());
    }
    if (ref.read(authControllerProvider).user?.role == 'admin') {
      _loadAdminNodes();
    }
  }

  Future<void> _initAppUpdateSection() async {
    final ver = await AppUpdateService.resolveCurrentVersion();
    if (!mounted) return;
    setState(() => _appVersion = ver);
    if (_latestRelease == null) {
      await _checkAppUpdate(force: false);
    }
  }

  Future<void> _checkAppUpdate({required bool force}) async {
    if (_checkingAppUpdate) return;
    setState(() {
      _checkingAppUpdate = true;
      _appUpdateError = null;
    });
    try {
      final info = await ref.read(apiClientProvider).getAppLatestRelease(force: force);
      if (!mounted) return;
      final hasNew = isAppUpdateAvailable(_appVersion, info.latestVersion);
      if (hasNew && force) {
        await AppUpdateService.clearIgnoredVersion();
      }
      setState(() {
        _latestRelease = info;
        _appUpdateChecked = true;
        _checkingAppUpdate = false;
        if (info.error.isNotEmpty && info.source == 'gateway_fallback') {
          _appUpdateError = '暂未连接到 GitHub Releases：${info.error}';
        }
      });
      widget.onUpdateBadgeChanged?.call(hasNew ? info : null);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _checkingAppUpdate = false;
        _appUpdateChecked = true;
        _appUpdateError = '检查版本失败: $e';
      });
    }
  }

  String _formatApkSize(int bytes) {
    if (bytes <= 0) return '';
    if (bytes >= 1048576) {
      return '${(bytes / 1048576).toStringAsFixed(1)} MB';
    }
    if (bytes >= 1024) {
      return '${(bytes / 1024).toStringAsFixed(0)} KB';
    }
    return '$bytes B';
  }

  Future<void> _downloadAndInstallApk(AppReleaseInfo release) async {
    if (_installingApk) return;
    if (_downloadedApkPath != null) {
      await _triggerInstallApk(_downloadedApkPath!, release);
      return;
    }
    if (release.apkUrl.trim().isEmpty) {
      await PlatformBridge.openExternalUrl(release.htmlUrl);
      return;
    }
    setState(() {
      _installingApk = true;
      _appUpdateError = null;
    });
    try {
      final dl = await runWithDownloadProgressDialog<({String? path, String? error, bool cancelled})>(
        context: context,
        autoOpen: false,
        titleOverride: '正在下载新版安装包...',
        formatBytes: _formatApkSize,
        task: (onProgress, cancelToken) => AppUpdateService.downloadApkToCache(
          apkUrl: release.apkUrl,
          filename: release.apkName.isNotEmpty
              ? release.apkName
              : 'agy-remote-v${release.latestVersion}.apk',
          onProgress: onProgress,
          cancelToken: cancelToken,
        ),
      );
      if (!mounted) return;
      if (dl.cancelled) return;
      if (dl.error != null || dl.path == null) {
        setState(() {
          _appUpdateError = dl.error ?? '下载安装包失败，可尝试使用浏览器下载';
        });
        return;
      }
      _downloadedApkPath = dl.path;
      await _triggerInstallApk(dl.path!, release);
    } finally {
      if (mounted) {
        setState(() => _installingApk = false);
      }
    }
  }

  Future<void> _triggerInstallApk(String apkPath, AppReleaseInfo release) async {
    final res = await AndroidNativeBridge.installApk(apkPath);
    if (!mounted) return;
    if (res.ok) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('已拉起系统安装界面，请按提示完成覆盖升级')),
      );
      return;
    }
    setState(() {
      _appUpdateError = res.error ?? '拉起安装器失败，可点击「浏览器下载」手动安装';
    });
    if (res.needsPermission) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('请先开启「允许安装未知应用」权限，返回后再次点击「立即安装」'),
          duration: Duration(seconds: 4),
        ),
      );
    } else if (release.htmlUrl.isNotEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(_appUpdateError!),
          action: SnackBarAction(
            label: '浏览器下载',
            onPressed: () => PlatformBridge.openExternalUrl(release.htmlUrl),
          ),
        ),
      );
    }
  }

  Future<void> _loadAdminNodes() async {
    setState(() => _loadingAdminNodes = true);
    try {
      final list = await ref.read(apiClientProvider).getAdminNodes();
      if (!mounted) return;
      setState(() {
        _adminNodes = list;
        _loadingAdminNodes = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _adminNodes = ref.read(hubControllerProvider).nodes;
        _loadingAdminNodes = false;
      });
    }
  }

  Future<void> _checkNodeUpdate(HostNode node) async {
    if (_checkingNodeIds.contains(node.id) || _updatingNodeIds.contains(node.id)) return;
    setState(() {
      _checkingNodeIds.add(node.id);
      _nodeUpdateErrors.remove(node.id);
    });
    try {
      final st = await ref.read(apiClientProvider).getNodeUpdateStatus(node.id, fetch: true);
      if (!mounted) return;
      setState(() {
        _nodeUpdateStatuses[node.id] = st;
      });
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() {
        _nodeUpdateErrors[node.id] = e.statusCode == 404
            ? '该节点版本过旧，尚未支持远程更新（请先在该电脑运行一次 update_windows_agent.ps1）'
            : e.message;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _nodeUpdateErrors[node.id] = '检查失败: $e';
      });
    } finally {
      if (mounted) {
        setState(() => _checkingNodeIds.remove(node.id));
      }
    }
  }

  Future<void> _applyNodeUpdate(HostNode node, {bool force = false}) async {
    if (_updatingNodeIds.contains(node.id)) return;
    setState(() {
      _updatingNodeIds.add(node.id);
      _nodeUpdateErrors.remove(node.id);
    });
    try {
      final res = await ref.read(apiClientProvider).applyNodeUpdate(node.id, force: force);
      if (!mounted) return;
      if (res.ok) {
        setState(() {
          _nodeUpdateErrors[node.id] = res.message.isNotEmpty ? res.message : '节点更新指令已发送';
          _nodeUpdateStatuses.remove(node.id);
        });
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(res.message.isNotEmpty ? res.message : '${node.name} 正在重启升级...')),
        );
        if (res.restarting) {
          Future.delayed(const Duration(seconds: 7), () {
            if (!mounted) return;
            _loadAdminNodes();
            unawaited(ref.read(hubControllerProvider.notifier).refreshNodes());
          });
        }
      } else {
        setState(() {
          _nodeUpdateErrors[node.id] = res.message.isNotEmpty ? res.message : '更新未执行';
        });
      }
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() {
        _nodeUpdateErrors[node.id] = e.statusCode == 404
            ? '该节点版本过旧，请先手动更新一次'
            : e.message;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _nodeUpdateErrors[node.id] = '更新失败: $e';
      });
    } finally {
      if (mounted) {
        setState(() => _updatingNodeIds.remove(node.id));
      }
    }
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

  Widget _buildAppUpdateSection(bool isDark, Color primary) {
    final release = _latestRelease;
    final hasUpdate = release != null && isAppUpdateAvailable(_appVersion, release.latestVersion);
    final sizeText = release != null ? _formatApkSize(release.apkSize) : '';

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Text(
              '应用版本与更新',
              style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: primary),
            ),
            const Spacer(),
            TextButton(
              onPressed: _checkingAppUpdate ? null : () => _checkAppUpdate(force: true),
              style: TextButton.styleFrom(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                minimumSize: Size.zero,
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              ),
              child: Text(
                _checkingAppUpdate ? '检查中...' : '检查更新',
                style: const TextStyle(fontSize: 11.5),
              ),
            ),
          ],
        ),
        const SizedBox(height: 6),
        Row(
          children: [
            Text(
              '当前版本 v$_appVersion',
              style: TextStyle(
                fontSize: 12.5,
                fontFamily: 'monospace',
                color: isDark ? Colors.white70 : Colors.black87,
              ),
            ),
            if (_appUpdateChecked && !hasUpdate && _appUpdateError == null) ...[
              const SizedBox(width: 8),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                decoration: BoxDecoration(
                  color: AppColors.statusGreen(isDark).withValues(alpha: 0.14),
                  borderRadius: BorderRadius.circular(6),
                ),
                child: Text(
                  '已是最新',
                  style: TextStyle(
                    fontSize: 10,
                    fontWeight: FontWeight.w600,
                    color: AppColors.statusGreen(isDark),
                  ),
                ),
              ),
            ],
          ],
        ),
        if (hasUpdate) ...[
          const SizedBox(height: 8),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: primary.withValues(alpha: isDark ? 0.12 : 0.08),
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: primary.withValues(alpha: 0.45)),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Icon(Icons.system_update_rounded, size: 16, color: primary),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(
                        '发现新版本 v${release.latestVersion}${sizeText.isNotEmpty ? ' ($sizeText)' : ''}',
                        style: TextStyle(
                          fontSize: 12.5,
                          fontWeight: FontWeight.w700,
                          color: isDark ? Colors.white : Colors.black87,
                        ),
                      ),
                    ),
                  ],
                ),
                if (release.releaseNotes.isNotEmpty) ...[
                  const SizedBox(height: 4),
                  Text(
                    release.releaseNotes,
                    maxLines: 4,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 11,
                      height: 1.4,
                      color: isDark ? Colors.white70 : Colors.black54,
                    ),
                  ),
                ],
                const SizedBox(height: 8),
                Wrap(
                  spacing: 8,
                  runSpacing: 6,
                  children: [
                    FilledButton.icon(
                      onPressed: _installingApk ? null : () => _downloadAndInstallApk(release),
                      icon: Icon(
                        _downloadedApkPath != null
                            ? Icons.install_mobile_rounded
                            : Icons.download_rounded,
                        size: 14,
                      ),
                      label: Text(
                        _downloadedApkPath != null ? '立即安装' : '下载并安装',
                        style: const TextStyle(fontSize: 11.5),
                      ),
                      style: FilledButton.styleFrom(
                        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                        minimumSize: Size.zero,
                        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                      ),
                    ),
                    if (release.htmlUrl.isNotEmpty)
                      OutlinedButton(
                        onPressed: () => PlatformBridge.openExternalUrl(
                          release.apkUrl.isNotEmpty ? release.apkUrl : release.htmlUrl,
                        ),
                        style: OutlinedButton.styleFrom(
                          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                          minimumSize: Size.zero,
                          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                        ),
                        child: const Text('浏览器下载', style: TextStyle(fontSize: 11.5)),
                      ),
                    TextButton(
                      onPressed: () async {
                        await AppUpdateService.setIgnoredVersion(release.latestVersion);
                        if (!mounted) return;
                        setState(() => _latestRelease = null);
                        widget.onUpdateBadgeChanged?.call(null);
                      },
                      style: TextButton.styleFrom(
                        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
                        minimumSize: Size.zero,
                        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                      ),
                      child: Text(
                        '忽略此版本',
                        style: TextStyle(
                          fontSize: 11.5,
                          color: isDark ? Colors.white54 : Colors.black54,
                        ),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ],
        if (_appUpdateError != null) ...[
          const SizedBox(height: 6),
          Text(
            _appUpdateError!,
            style: TextStyle(
              fontSize: 11,
              color: AppColors.statusAmber(isDark),
            ),
          ),
        ],
      ],
    );
  }

  Widget _buildNodePowerSection(bool isDark, Color primary) {
    final hubState = ref.watch(hubControllerProvider);
    final hubNotifier = ref.read(hubControllerProvider.notifier);
    final node = hubState.currentNode;
    final power = hubState.nodePowerStatus;
    final armed = power != null && power.enabled;
    final activeAction = armed ? power.action : _selectedPowerAction;
    final nodeName = node?.name ?? hubState.selectedNodeId;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Text(
              '完成后自动电源',
              style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: primary),
            ),
            const Spacer(),
            if (nodeName.isNotEmpty)
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
                decoration: BoxDecoration(
                  color: (armed ? AppColors.statusAmber(isDark) : primary).withValues(alpha: 0.14),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Text(
                  armed ? '$nodeName · 已预约${power.actionLabel}' : nodeName,
                  style: TextStyle(
                    fontSize: 10.5,
                    fontWeight: FontWeight.w600,
                    color: armed ? AppColors.statusAmber(isDark) : primary,
                  ),
                ),
              ),
          ],
        ),
        const SizedBox(height: 6),
        if (node == null)
          Text(
            '请先选择一个可用节点。',
            style: TextStyle(fontSize: 11.5, color: isDark ? Colors.white54 : Colors.black54),
          )
        else if (node.isLocal)
          Text(
            '当前为网关宿主机（${node.name}），系统策略禁止远程关机或睡眠。',
            style: TextStyle(fontSize: 11.5, color: isDark ? Colors.white54 : Colors.black54),
          )
        else if (!node.canWrite)
          Text(
            '当前账号对 ${node.name} 为只读权限，无法预约关机或睡眠。',
            style: TextStyle(fontSize: 11.5, color: isDark ? Colors.white54 : Colors.black54),
          )
        else if (power != null && !power.supported)
          Text(
            power.message.isNotEmpty ? power.message : '该节点未开启远程电源控制支持。',
            style: TextStyle(fontSize: 11.5, color: isDark ? Colors.white54 : Colors.black54),
          )
        else ...[
          Text(
            armed && power.message.isNotEmpty
                ? power.message
                : '当该节点所有会话、排队队列和工具审批全部清空后，静默确认 20s 并进入 60s 可取消倒计时。',
            style: TextStyle(
              fontSize: 11,
              color: armed
                  ? AppColors.statusAmber(isDark)
                  : (isDark ? Colors.white54 : Colors.black54),
            ),
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              Container(
                decoration: BoxDecoration(
                  color: isDark ? const Color(0xFF111113) : const Color(0xFFF4F4F5),
                  borderRadius: BorderRadius.circular(8),
                ),
                padding: const EdgeInsets.all(3),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: const [
                    (id: 'shutdown', label: '关机'),
                    (id: 'sleep', label: '睡眠'),
                  ].map((opt) {
                    final selected = activeAction == opt.id;
                    return InkWell(
                      borderRadius: BorderRadius.circular(6),
                      onTap: hubState.isUpdatingNodePower
                          ? null
                          : () async {
                              setState(() => _selectedPowerAction = opt.id);
                              if (armed && opt.id != power.action) {
                                final err = await hubNotifier.scheduleNodePower(action: opt.id);
                                if (err != null && mounted) {
                                  ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(err)));
                                }
                              }
                            },
                      child: Container(
                        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                        decoration: BoxDecoration(
                          color: selected
                              ? primary.withValues(alpha: isDark ? 0.22 : 0.14)
                              : Colors.transparent,
                          borderRadius: BorderRadius.circular(6),
                        ),
                        child: Text(
                          opt.label,
                          style: TextStyle(
                            fontSize: 11.5,
                            fontWeight: selected ? FontWeight.bold : FontWeight.normal,
                            color: selected ? primary : (isDark ? Colors.white60 : Colors.black54),
                          ),
                        ),
                      ),
                    );
                  }).toList(),
                ),
              ),
              const Spacer(),
              if (armed)
                OutlinedButton.icon(
                  onPressed: hubState.isUpdatingNodePower
                      ? null
                      : () async {
                          final err = await hubNotifier.cancelNodePower();
                          if (err != null && mounted) {
                            ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(err)));
                          }
                        },
                  icon: Icon(Icons.close_rounded, size: 15, color: AppColors.statusRed(isDark)),
                  label: Text(
                    '取消预约',
                    style: TextStyle(fontSize: 11.5, color: AppColors.statusRed(isDark)),
                  ),
                  style: OutlinedButton.styleFrom(
                    side: BorderSide(color: AppColors.statusRed(isDark).withValues(alpha: 0.6)),
                    visualDensity: VisualDensity.compact,
                  ),
                )
              else
                FilledButton.icon(
                  onPressed: hubState.isUpdatingNodePower
                      ? null
                      : () async {
                          final err = await hubNotifier.scheduleNodePower(action: _selectedPowerAction);
                          if (err != null && mounted) {
                            ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(err)));
                          }
                        },
                  icon: Icon(
                    _selectedPowerAction == 'sleep'
                        ? Icons.bedtime_rounded
                        : Icons.power_settings_new_rounded,
                    size: 15,
                  ),
                  label: Text(
                    hubState.isUpdatingNodePower
                        ? '提交中...'
                        : '开启完成后${_selectedPowerAction == 'sleep' ? '睡眠' : '关机'}',
                    style: const TextStyle(fontSize: 11.5),
                  ),
                  style: FilledButton.styleFrom(
                    visualDensity: VisualDensity.compact,
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                  ),
                ),
            ],
          ),
        ],
      ],
    );
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
      insetPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 24),
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
              if (AndroidNativeBridge.isAndroidNative) ...[
                _buildAppUpdateSection(isDark, primary),
                const SizedBox(height: 16),
                Divider(color: isDark ? Colors.white12 : Colors.black12, height: 1),
                const SizedBox(height: 12),
              ],
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
              LayoutBuilder(
                builder: (context, constraints) {
                  const spacing = 8.0;
                  final maxWidth = constraints.maxWidth.isFinite ? constraints.maxWidth : 440.0;
                  final itemWidth = ((maxWidth - spacing) / 2).floorToDouble();
                  return Wrap(
                    spacing: spacing,
                    runSpacing: spacing,
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
                          width: itemWidth > 0 ? itemWidth : null,
                          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
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
                                        fontSize: 12.5,
                                        fontWeight: isSelected ? FontWeight.w600 : FontWeight.w500,
                                        color: isSelected
                                            ? primary
                                            : (isDark ? Colors.white : Colors.black87),
                                      ),
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                    ),
                                    const SizedBox(height: 2),
                                    Text(
                                      opt.description,
                                      style: TextStyle(
                                        fontSize: 10,
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
                                Icon(Icons.check_rounded, size: 15, color: primary),
                            ],
                          ),
                        ),
                      );
                    }).toList(),
                  );
                },
              ),
              const SizedBox(height: 16),
              Divider(color: isDark ? Colors.white12 : Colors.black12, height: 1),
              const SizedBox(height: 12),
              Row(
                children: [
                  Text(
                    '界面字号',
                    style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: primary),
                  ),
                  const SizedBox(width: 8),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
                    decoration: BoxDecoration(
                      color: primary.withValues(alpha: isDark ? 0.16 : 0.10),
                      borderRadius: BorderRadius.circular(6),
                    ),
                    child: Text(
                      '${(themeState.fontScale * 100).round()}%',
                      style: TextStyle(fontSize: 11, fontWeight: FontWeight.w700, color: primary),
                    ),
                  ),
                  const Spacer(),
                  if ((themeState.fontScale - ThemeState.defaultFontScale).abs() > 0.001)
                    TextButton(
                      onPressed: () => themeNotifier.resetFontScale(),
                      style: TextButton.styleFrom(
                        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                        minimumSize: Size.zero,
                        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                      ),
                      child: const Text('重置', style: TextStyle(fontSize: 11.5)),
                    ),
                ],
              ),
              const SizedBox(height: 6),
              Row(
                children: [
                  IconButton(
                    tooltip: '减小字号',
                    icon: const Icon(Icons.text_decrease_rounded, size: 18),
                    visualDensity: VisualDensity.compact,
                    onPressed: themeState.fontScale <= ThemeState.minFontScale + 0.001
                        ? null
                        : () => themeNotifier.stepFontScale(-ThemeState.fontScaleStep),
                  ),
                  Expanded(
                    child: Slider(
                      value: themeState.fontScale.clamp(ThemeState.minFontScale, ThemeState.maxFontScale),
                      min: ThemeState.minFontScale,
                      max: ThemeState.maxFontScale,
                      divisions: 16,
                      label: '${(themeState.fontScale * 100).round()}%',
                      onChanged: (val) => themeNotifier.setFontScale(val),
                    ),
                  ),
                  IconButton(
                    tooltip: '增大字号',
                    icon: const Icon(Icons.text_increase_rounded, size: 18),
                    visualDensity: VisualDensity.compact,
                    onPressed: themeState.fontScale >= ThemeState.maxFontScale - 0.001
                        ? null
                        : () => themeNotifier.stepFontScale(ThemeState.fontScaleStep),
                  ),
                ],
              ),
              const SizedBox(height: 4),
              Wrap(
                spacing: 6,
                runSpacing: 6,
                children: const [
                  (label: '紧凑 90%', scale: 0.90),
                  (label: '标准 100%', scale: 1.00),
                  (label: '舒适 115%', scale: 1.15),
                  (label: '大号 130%', scale: 1.30),
                ].map((preset) {
                  final selected = (themeState.fontScale - preset.scale).abs() < 0.015;
                  return InkWell(
                    borderRadius: BorderRadius.circular(8),
                    onTap: () => themeNotifier.setFontScale(preset.scale),
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                      decoration: BoxDecoration(
                        color: selected
                            ? primary.withValues(alpha: isDark ? 0.16 : 0.10)
                            : (isDark ? const Color(0xFF111113) : const Color(0xFFF4F4F5)),
                        borderRadius: BorderRadius.circular(8),
                        border: Border.all(
                          color: selected
                              ? primary.withValues(alpha: 0.7)
                              : (isDark ? const Color(0xFF2C2C32) : const Color(0xFFE4E4E7)),
                          width: selected ? 1.1 : 1,
                        ),
                      ),
                      child: Text(
                        preset.label,
                        style: TextStyle(
                          fontSize: 11.5,
                          fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
                          color: selected ? primary : (isDark ? Colors.white70 : Colors.black87),
                        ),
                      ),
                    ),
                  );
                }).toList(),
              ),
              if (kIsWeb) ...[
                const SizedBox(height: 6),
                Text(
                  'Web 端支持 Ctrl + 滚轮、Ctrl + / - 快捷缩放，Ctrl + 0 恢复默认',
                  style: TextStyle(fontSize: 11, color: isDark ? Colors.white54 : Colors.black45),
                ),
              ],
              const SizedBox(height: 16),
              Divider(color: isDark ? Colors.white12 : Colors.black12, height: 1),
              const SizedBox(height: 12),
              _buildNodePowerSection(isDark, primary),
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
              if (ref.watch(authControllerProvider).user?.role == 'admin') ...[
                const SizedBox(height: 16),
                Divider(color: isDark ? Colors.white12 : Colors.black12, height: 1),
                const SizedBox(height: 12),
                Row(
                  children: [
                    Text(
                      '节点版本与远程更新',
                      style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: primary),
                    ),
                    const Spacer(),
                    if (_loadingAdminNodes)
                      const SizedBox(
                        width: 12,
                        height: 12,
                        child: CircularProgressIndicator(strokeWidth: 1.6),
                      )
                    else
                      InkWell(
                        onTap: _loadAdminNodes,
                        borderRadius: BorderRadius.circular(6),
                        child: Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(Icons.refresh_rounded, size: 13, color: isDark ? Colors.white54 : Colors.black54),
                              const SizedBox(width: 3),
                              Text(
                                '刷新',
                                style: TextStyle(fontSize: 11, color: isDark ? Colors.white54 : Colors.black54),
                              ),
                            ],
                          ),
                        ),
                      ),
                  ],
                ),
                const SizedBox(height: 8),
                if (_adminNodes.isEmpty && !_loadingAdminNodes)
                  Text(
                    '暂无已注册节点',
                    style: TextStyle(fontSize: 11.5, color: isDark ? Colors.white38 : Colors.black45),
                  )
                else
                  ..._adminNodes.map((node) {
                    final st = _nodeUpdateStatuses[node.id];
                    final note = _nodeUpdateErrors[node.id] ?? st?.message ?? '';
                    final isChecking = _checkingNodeIds.contains(node.id);
                    final isUpdating = _updatingNodeIds.contains(node.id);
                    final canTriggerUpdate = st != null && st.updateAvailable && st.canUpdate;
                    final versionLabel = node.version.isNotEmpty ? 'v${node.version}' : '旧版 / 未知';
                    return Container(
                      margin: const EdgeInsets.only(bottom: 8),
                      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                      decoration: BoxDecoration(
                        color: isDark ? const Color(0xFF111113) : const Color(0xFFF8F8F9),
                        borderRadius: BorderRadius.circular(10),
                        border: Border.all(
                          color: isDark ? const Color(0xFF2C2C32) : const Color(0xFFE4E4E7),
                        ),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              Container(
                                width: 7,
                                height: 7,
                                decoration: BoxDecoration(
                                  shape: BoxShape.circle,
                                  color: node.isOnline
                                      ? AppColors.statusGreen(isDark)
                                      : (isDark ? Colors.white24 : Colors.black26),
                                ),
                              ),
                              const SizedBox(width: 7),
                              Expanded(
                                child: Text(
                                  '${node.name} ($versionLabel)',
                                  style: TextStyle(
                                    fontSize: 12.5,
                                    fontWeight: FontWeight.w600,
                                    color: isDark ? Colors.white : Colors.black87,
                                  ),
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                              if (node.isOnline) ...[
                                TextButton(
                                  onPressed: (isChecking || isUpdating) ? null : () => _checkNodeUpdate(node),
                                  style: TextButton.styleFrom(
                                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                                    minimumSize: Size.zero,
                                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                                  ),
                                  child: Text(
                                    isChecking ? '检查中...' : '检查更新',
                                    style: const TextStyle(fontSize: 11.5),
                                  ),
                                ),
                                if (canTriggerUpdate) ...[
                                  const SizedBox(width: 4),
                                  FilledButton(
                                    onPressed: isUpdating
                                        ? null
                                        : () => _applyNodeUpdate(
                                              node,
                                              force: st.runningSessions > 0,
                                            ),
                                    style: FilledButton.styleFrom(
                                      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                                      minimumSize: Size.zero,
                                      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                                    ),
                                    child: Text(
                                      isUpdating
                                          ? '更新中...'
                                          : (st.runningSessions > 0 ? '强制更新' : '一键更新'),
                                      style: const TextStyle(fontSize: 11.5),
                                    ),
                                  ),
                                ],
                              ] else
                                Text(
                                  '离线',
                                  style: TextStyle(
                                    fontSize: 11,
                                    color: isDark ? Colors.white38 : Colors.black38,
                                  ),
                                ),
                            ],
                          ),
                          if (note.isNotEmpty) ...[
                            const SizedBox(height: 4),
                            Text(
                              note,
                              style: TextStyle(
                                fontSize: 11,
                                color: st != null && st.dirty
                                    ? AppColors.statusAmber(isDark)
                                    : (isDark ? Colors.white60 : Colors.black54),
                              ),
                            ),
                          ],
                        ],
                      ),
                    );
                  }),
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

import 'dart:async';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../core/config/offline_outbox_store.dart';
import '../../core/config/server_config.dart';
import '../../core/config/session_cache_store.dart';
import '../../core/network/api_client.dart';
import '../../core/network/token_store.dart';
import '../../core/platform/android_native_bridge.dart';
import '../../core/platform/platform_bridge.dart';
import '../../core/realtime/node_event_socket.dart';
import '../../models/models.dart';
import '../auth/auth_controller.dart';

typedef EventSocketFactory = EventSocketClient Function({
  required ServerConfig serverConfig,
  required String nodeId,
  required TokenStore tokenStore,
  Future<bool> Function()? onRefreshAuth,
});

final eventSocketFactoryProvider = Provider<EventSocketFactory>((ref) {
  return ({
    required ServerConfig serverConfig,
    required String nodeId,
    required TokenStore tokenStore,
    Future<bool> Function()? onRefreshAuth,
  }) {
    return NodeEventSocket(
      serverConfig: serverConfig,
      nodeId: nodeId,
      tokenStore: tokenStore,
      onRefreshAuth: onRefreshAuth,
    );
  };
});

class HubState {
  final List<HostNode> nodes;
  final String selectedNodeId;
  final WsConnState wsState;
  final Map<String, List<SessionItem>> projects;
  final List<SessionItem> generalSessions;
  final String activeSessionId;
  final String activeSessionTitle;
  final String activeRootId;
  final List<AgentMessage> messages;
  final bool hasMoreMessages;
  final int? nextBeforeStep;
  final bool isLoadingMessages;
  final bool isLoadingMore;
  final Set<String> runningSessionIds;
  final QuotaData? quota;
  final bool isLoadingQuota;
  final List<UploadedAttachment> pendingAttachments;
  final String selectedMode;
  final String selectedModel;
  final List<OfficialModelOption> availableModels;
  final String activeSessionModel;
  final String pendingSwitchModel;
  final List<FileRootItem> cachedRoots;
  final SessionChangesData sessionChanges;
  final SessionQueueData sessionQueue;
  final List<OfflineOutboxItem> offlineOutbox;
  final bool isFlushingOutbox;
  final bool isInitializing;
  final bool isShowingCachedData;
  final DateTime? activeCacheUpdatedAt;

  const HubState({
    this.nodes = const [],
    this.selectedNodeId = '',
    this.wsState = WsConnState.disconnected,
    this.projects = const {},
    this.generalSessions = const [],
    this.activeSessionId = '',
    this.activeSessionTitle = '当前会话',
    this.activeRootId = 'scratch',
    this.messages = const [],
    this.hasMoreMessages = false,
    this.nextBeforeStep,
    this.isLoadingMessages = false,
    this.isLoadingMore = false,
    this.runningSessionIds = const {},
    this.quota,
    this.isLoadingQuota = false,
    this.pendingAttachments = const [],
    this.selectedMode = 'auto',
    this.selectedModel = 'gemini-4-neon-high',
    this.availableModels = kAllOfficialModels,
    this.activeSessionModel = '',
    this.pendingSwitchModel = '',
    this.cachedRoots = const [],
    this.sessionChanges = const SessionChangesData(),
    this.sessionQueue = const SessionQueueData(),
    this.offlineOutbox = const [],
    this.isFlushingOutbox = false,
    this.isInitializing = false,
    this.isShowingCachedData = false,
    this.activeCacheUpdatedAt,
  });

  String get effectiveSessionModel =>
      pendingSwitchModel.isNotEmpty ? pendingSwitchModel : activeSessionModel;

  bool get hasPendingModelSwitch =>
      pendingSwitchModel.isNotEmpty && pendingSwitchModel != activeSessionModel;

  HostNode? get currentNode {
    if (selectedNodeId.isEmpty || nodes.isEmpty) return null;
    for (final n in nodes) {
      if (n.id == selectedNodeId) return n;
    }
    return null;
  }

  List<OfflineOutboxItem> get activeSessionOutbox {
    if (selectedNodeId.isEmpty || activeSessionId.isEmpty || offlineOutbox.isEmpty) {
      return const [];
    }
    return offlineOutbox
        .where((e) => e.nodeId == selectedNodeId && e.sessionId == activeSessionId)
        .toList();
  }

  bool get isConnected => wsState == WsConnState.connected;
  bool get isConnecting => wsState == WsConnState.connecting;
  bool get canWrite => currentNode?.canWrite ?? false;
  bool get canDelete => currentNode?.canDelete ?? false;
  bool get isActiveSessionRunning =>
      activeSessionId.isNotEmpty && runningSessionIds.contains(activeSessionId);
  List<PlanStepItem> get activePlanSteps => PlanStepItem.extractLatestSteps(messages);
  String get activeFocusText => PlanStepItem.extractLatestFocus(messages);

  HubState copyWith({
    List<HostNode>? nodes,
    String? selectedNodeId,
    WsConnState? wsState,
    Map<String, List<SessionItem>>? projects,
    List<SessionItem>? generalSessions,
    String? activeSessionId,
    String? activeSessionTitle,
    String? activeRootId,
    List<AgentMessage>? messages,
    bool? hasMoreMessages,
    int? nextBeforeStep,
    bool clearNextBeforeStep = false,
    bool? isLoadingMessages,
    bool? isLoadingMore,
    Set<String>? runningSessionIds,
    QuotaData? quota,
    bool clearQuota = false,
    bool? isLoadingQuota,
    List<UploadedAttachment>? pendingAttachments,
    String? selectedMode,
    String? selectedModel,
    List<OfficialModelOption>? availableModels,
    String? activeSessionModel,
    String? pendingSwitchModel,
    bool clearPendingSwitchModel = false,
    List<FileRootItem>? cachedRoots,
    SessionChangesData? sessionChanges,
    bool clearSessionChanges = false,
    SessionQueueData? sessionQueue,
    bool clearSessionQueue = false,
    List<OfflineOutboxItem>? offlineOutbox,
    bool? isFlushingOutbox,
    bool? isInitializing,
    bool? isShowingCachedData,
    DateTime? activeCacheUpdatedAt,
    bool clearActiveCacheUpdatedAt = false,
  }) {
    return HubState(
      nodes: nodes ?? this.nodes,
      selectedNodeId: selectedNodeId ?? this.selectedNodeId,
      wsState: wsState ?? this.wsState,
      projects: projects ?? this.projects,
      generalSessions: generalSessions ?? this.generalSessions,
      activeSessionId: activeSessionId ?? this.activeSessionId,
      activeSessionTitle: activeSessionTitle ?? this.activeSessionTitle,
      activeRootId: activeRootId ?? this.activeRootId,
      messages: messages ?? this.messages,
      hasMoreMessages: hasMoreMessages ?? this.hasMoreMessages,
      nextBeforeStep: clearNextBeforeStep ? null : (nextBeforeStep ?? this.nextBeforeStep),
      isLoadingMessages: isLoadingMessages ?? this.isLoadingMessages,
      isLoadingMore: isLoadingMore ?? this.isLoadingMore,
      runningSessionIds: runningSessionIds ?? this.runningSessionIds,
      quota: clearQuota ? null : (quota ?? this.quota),
      isLoadingQuota: isLoadingQuota ?? this.isLoadingQuota,
      pendingAttachments: pendingAttachments ?? this.pendingAttachments,
      selectedMode: selectedMode ?? this.selectedMode,
      selectedModel: selectedModel ?? this.selectedModel,
      availableModels: availableModels ?? this.availableModels,
      activeSessionModel: activeSessionModel ?? this.activeSessionModel,
      pendingSwitchModel: clearPendingSwitchModel ? '' : (pendingSwitchModel ?? this.pendingSwitchModel),
      cachedRoots: cachedRoots ?? this.cachedRoots,
      sessionChanges: clearSessionChanges ? const SessionChangesData() : (sessionChanges ?? this.sessionChanges),
      sessionQueue: clearSessionQueue ? const SessionQueueData() : (sessionQueue ?? this.sessionQueue),
      offlineOutbox: offlineOutbox ?? this.offlineOutbox,
      isFlushingOutbox: isFlushingOutbox ?? this.isFlushingOutbox,
      isInitializing: isInitializing ?? this.isInitializing,
      isShowingCachedData: isShowingCachedData ?? this.isShowingCachedData,
      activeCacheUpdatedAt: clearActiveCacheUpdatedAt
          ? null
          : (activeCacheUpdatedAt ?? this.activeCacheUpdatedAt),
    );
  }
}

class HubController extends Notifier<HubState> {
  static const _selectedNodePrefKey = 'v2_selected_node';
  static const _editToolNames = {'edit_file', 'write_file', 'replace_file_content', 'multi_replace_file_content'};

  EventSocketClient? _socket;
  StreamSubscription<WsServerEvent>? _wsEventSub;
  StreamSubscription<WsConnState>? _wsStateSub;
  Timer? _quotaTimer;
  bool _disposed = false;
  DateTime? _pausedAt;
  DateTime? _lastResumedAt;
  bool _isAppInBackground = false;
  String _lastNotifiedRunningTitle = '';
  String _lastNotifiedRunningBody = '';
  int _lastAskQuestionStep = -1;
  Future<List<HostNode>>? _inFlightRefreshNodes;
  bool _isFlushingOutbox = false;
  CachedHubSnapshot _cacheSnapshot = const CachedHubSnapshot();
  Timer? _cachePersistTimer;
  String _subscribedSessionId = '';

  @override
  HubState build() {
    ref.onDispose(() {
      _disposed = true;
      _quotaTimer?.cancel();
      _cachePersistTimer?.cancel();
      _disposeSocketSync();
      if (AndroidNativeBridge.isAndroidNative) {
        unawaited(AndroidNativeBridge.stopRunningNotification());
      }
    });
    return const HubState();
  }

  ApiClient get _api => ref.read(apiClientProvider);

  void _disposeSocketSync() {
    _subscribedSessionId = '';
    _wsEventSub?.cancel();
    _wsEventSub = null;
    _wsStateSub?.cancel();
    _wsStateSub = null;
    final old = _socket;
    _socket = null;
    old?.dispose();
  }

  void _subscribeSession(String sessionId, {int? sinceStep}) {
    final socket = _socket;
    if (socket == null || sessionId.isEmpty) return;
    _subscribedSessionId = sessionId;
    socket.subscribe(sessionId, sinceStep: sinceStep);
  }

  void _updateMemoryCacheForActiveSession({
    required String nodeId,
    required String sessionId,
    required String title,
    required String rootId,
    required String activeModel,
    required List<AgentMessage> messages,
  }) {
    if (nodeId.isEmpty || sessionId.isEmpty) return;
    final confirmed = messages.where((m) => m.stepIndex >= 0).toList();
    if (confirmed.isEmpty) return;
    final sliced = confirmed.length > SessionCacheStore.maxMessagesPerSession
        ? confirmed.sublist(confirmed.length - SessionCacheStore.maxMessagesPerSession)
        : confirmed;
    final nowMs = DateTime.now().millisecondsSinceEpoch;
    final nextSessions = Map<String, CachedSessionMessages>.from(_cacheSnapshot.sessionsByKey);
    nextSessions[CachedHubSnapshot.sessionKey(nodeId, sessionId)] = CachedSessionMessages(
      nodeId: nodeId,
      sessionId: sessionId,
      title: title,
      rootId: rootId.isNotEmpty ? rootId : 'scratch',
      activeModel: activeModel,
      messages: sliced,
      updatedAtMs: nowMs,
    );
    final nextLast = Map<String, String>.from(_cacheSnapshot.lastSessionIdByNode);
    nextLast[nodeId] = sessionId;
    _cacheSnapshot = CachedHubSnapshot(
      nodes: _cacheSnapshot.nodes,
      lastNodeId: nodeId,
      lastSessionIdByNode: nextLast,
      treesByNode: _cacheSnapshot.treesByNode,
      sessionsByKey: nextSessions,
    );
  }

  void _schedulePersistActiveSessionCache({bool immediate = false}) {
    final nodeId = state.selectedNodeId;
    final sid = state.activeSessionId;
    if (nodeId.isEmpty || sid.isEmpty) return;
    final msgs = state.messages;
    if (msgs.where((m) => m.stepIndex >= 0).isEmpty) return;

    final title = state.activeSessionTitle;
    final rootId = state.activeRootId;
    final activeModel = state.activeSessionModel;

    _updateMemoryCacheForActiveSession(
      nodeId: nodeId,
      sessionId: sid,
      title: title,
      rootId: rootId,
      activeModel: activeModel,
      messages: msgs,
    );

    _cachePersistTimer?.cancel();
    if (immediate) {
      unawaited(
        SessionCacheStore.saveSessionMessages(
          nodeId: nodeId,
          sessionId: sid,
          title: title,
          rootId: rootId,
          activeModel: activeModel,
          messages: msgs,
        ),
      );
      return;
    }

    _cachePersistTimer = Timer(const Duration(milliseconds: 1200), () {
      if (_disposed) return;
      unawaited(
        SessionCacheStore.saveSessionMessages(
          nodeId: nodeId,
          sessionId: sid,
          title: title,
          rootId: rootId,
          activeModel: activeModel,
          messages: msgs,
        ),
      );
    });
  }

  void _applyNodeCacheToState(String nodeId, {List<HostNode>? nodesOverride}) {
    final cachedTree = _cacheSnapshot.treesByNode[nodeId];
    final cachedSession = _cacheSnapshot.latestSessionForNode(nodeId);
    final nextNodes = nodesOverride ??
        (_cacheSnapshot.nodes.isNotEmpty
            ? _cacheSnapshot.nodes
                .map(
                  (n) => HostNode(
                    id: n.id,
                    name: n.name,
                    isOnline: false,
                    engineAlive: false,
                    isLocal: n.isLocal,
                    lastSeen: n.lastSeen,
                    canWrite: n.canWrite,
                    canDelete: n.canDelete,
                  ),
                )
                .toList()
            : state.nodes);

    state = state.copyWith(
      nodes: nextNodes,
      selectedNodeId: nodeId,
      projects: cachedTree?.projects ?? const {},
      generalSessions: cachedTree?.generalSessions ?? const [],
      activeSessionId: cachedSession?.sessionId ?? '',
      activeSessionTitle: cachedSession?.title ?? '暂无缓存会话',
      activeRootId: cachedSession?.rootId ?? 'scratch',
      messages: cachedSession?.messages ?? const [],
      hasMoreMessages: false,
      clearNextBeforeStep: true,
      isLoadingMessages: false,
      runningSessionIds: const {},
      activeSessionModel: cachedSession?.activeModel ?? '',
      clearPendingSwitchModel: true,
      clearSessionChanges: true,
      clearSessionQueue: true,
      isShowingCachedData: cachedSession != null && cachedSession.messages.isNotEmpty,
      activeCacheUpdatedAt: cachedSession?.updatedAt,
      clearActiveCacheUpdatedAt: cachedSession == null,
    );
  }

  Future<void> initializeForUser(UserProfile user) async {
    _disposed = false;
    state = state.copyWith(isInitializing: true);
    try {
      final results = await Future.wait<dynamic>([
        OfflineOutboxStore.load(),
        SessionCacheStore.loadSnapshot(),
      ]);
      if (_disposed) return;

      final loadedOutbox = results[0] as List<OfflineOutboxItem>;
      _cacheSnapshot = results[1] as CachedHubSnapshot;

      if (loadedOutbox.isNotEmpty) {
        state = state.copyWith(offlineOutbox: loadedOutbox);
      }

      String? savedNode;
      try {
        final prefs = await SharedPreferences.getInstance();
        savedNode = prefs.getString(_selectedNodePrefKey);
      } catch (_) {}

      var warmedNodeId = '';
      if (savedNode != null && _cacheSnapshot.hasCacheForNode(savedNode)) {
        warmedNodeId = savedNode;
      } else if (_cacheSnapshot.lastNodeId.isNotEmpty &&
          _cacheSnapshot.hasCacheForNode(_cacheSnapshot.lastNodeId)) {
        warmedNodeId = _cacheSnapshot.lastNodeId;
      } else if (_cacheSnapshot.nodes.isNotEmpty) {
        warmedNodeId = _cacheSnapshot.nodes.first.id;
      }

      if (warmedNodeId.isNotEmpty) {
        _applyNodeCacheToState(warmedNodeId);
      }

      List<HostNode> nodes = const [];
      var defaultNode = '';
      try {
        final res = await _api.getNodes();
        nodes = res.$1;
        defaultNode = res.$2;
      } catch (_) {
        if (!_disposed) {
          state = state.copyWith(isInitializing: false);
        }
        return;
      }
      if (_disposed) return;

      var targetNodeId = '';
      if (savedNode != null && nodes.any((n) => n.id == savedNode)) {
        targetNodeId = savedNode;
      } else if (defaultNode.isNotEmpty && nodes.any((n) => n.id == defaultNode)) {
        targetNodeId = defaultNode;
      } else if (nodes.isNotEmpty) {
        targetNodeId = nodes.first.id;
      }

      if (targetNodeId.isNotEmpty) {
        _cacheSnapshot = CachedHubSnapshot(
          nodes: nodes,
          lastNodeId: targetNodeId,
          lastSessionIdByNode: _cacheSnapshot.lastSessionIdByNode,
          treesByNode: _cacheSnapshot.treesByNode,
          sessionsByKey: _cacheSnapshot.sessionsByKey,
        );
        unawaited(SessionCacheStore.saveNodes(nodes, selectedNodeId: targetNodeId));
      }

      if (targetNodeId.isNotEmpty && targetNodeId != warmedNodeId && _cacheSnapshot.hasCacheForNode(targetNodeId)) {
        _applyNodeCacheToState(targetNodeId, nodesOverride: nodes);
      } else {
        state = state.copyWith(nodes: nodes, selectedNodeId: targetNodeId);
      }
      state = state.copyWith(isInitializing: false);

      if (targetNodeId.isNotEmpty) {
        await _connectAndLoadNode(targetNodeId);
      }
    } catch (_) {
      if (!_disposed) {
        state = state.copyWith(isInitializing: false);
      }
    }
  }

  /// 向网关拉取最新节点列表与在线状态；并发调用自动合并为同一请求。
  Future<List<HostNode>> refreshNodes() async {
    if (_disposed) return state.nodes;
    final inFlight = _inFlightRefreshNodes;
    if (inFlight != null) return inFlight;

    final future = () async {
      try {
        final (nodes, _) = await _api.getNodes();
        if (!_disposed && nodes.isNotEmpty) {
          state = state.copyWith(nodes: nodes);
          return nodes;
        }
      } catch (_) {}
      return state.nodes;
    }();

    _inFlightRefreshNodes = future;
    try {
      return await future;
    } finally {
      if (identical(_inFlightRefreshNodes, future)) {
        _inFlightRefreshNodes = null;
      }
    }
  }

  Future<void> reset() async {
    _quotaTimer?.cancel();
    _quotaTimer = null;
    _cachePersistTimer?.cancel();
    _cachePersistTimer = null;
    _cacheSnapshot = const CachedHubSnapshot();
    _disposeSocketSync();
    _lastNotifiedRunningTitle = '';
    _lastNotifiedRunningBody = '';
    _lastAskQuestionStep = -1;
    if (AndroidNativeBridge.isAndroidNative) {
      unawaited(AndroidNativeBridge.stopRunningNotification());
    }
    unawaited(OfflineOutboxStore.clear());
    unawaited(SessionCacheStore.clear());
    state = const HubState();
  }

  Future<String?> switchNode(String nodeId) async {
    HostNode? findTarget(List<HostNode> list) {
      for (final n in list) {
        if (n.id == nodeId) return n;
      }
      return null;
    }

    if (nodeId == state.selectedNodeId) {
      final current = findTarget(state.nodes);
      final needsReconnect = current == null ||
          (!current.isOnline && !current.isLocal) ||
          state.wsState != WsConnState.connected;
      if (needsReconnect) {
        await refreshNodes();
        unawaited(_socket?.reconnectNow());
        await Future.wait([
          refreshSessionTree(autoSelectFirst: state.activeSessionId.isEmpty)
              .then((_) => refreshFileRoots()),
          fetchQuota(),
          fetchModels(),
        ]);
      }
      return null;
    }

    var target = findTarget(state.nodes);
    if (target == null || (!target.isOnline && !target.isLocal)) {
      // 缓存显示离线或缺失时向网关实时重探，防止远端重启后前端长期被旧状态锁定
      final latestNodes = await refreshNodes();
      target = findTarget(latestNodes);
    }
    if (target == null) return '未找到目标节点';

    if (!target.isOnline && !target.isLocal) {
      if (_cacheSnapshot.hasCacheForNode(nodeId)) {
        _disposeSocketSync();
        _quotaTimer?.cancel();
        _applyNodeCacheToState(nodeId, nodesOverride: state.nodes);
        try {
          final prefs = await SharedPreferences.getInstance();
          await prefs.setString(_selectedNodePrefKey, nodeId);
        } catch (_) {}
        return null;
      }
      return '【${target.name}】当前处于离线状态';
    }

    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_selectedNodePrefKey, nodeId);
    } catch (_) {}

    if (_cacheSnapshot.hasCacheForNode(nodeId)) {
      _applyNodeCacheToState(nodeId, nodesOverride: state.nodes);
    } else {
      state = state.copyWith(
        selectedNodeId: nodeId,
        projects: const {},
        generalSessions: const [],
        activeSessionId: '',
        activeSessionTitle: '正在接入 ${target.name}...',
        activeRootId: 'scratch',
        messages: const [],
        hasMoreMessages: false,
        clearNextBeforeStep: true,
        clearQuota: true,
        activeSessionModel: '',
        clearPendingSwitchModel: true,
        clearSessionChanges: true,
        clearSessionQueue: true,
        cachedRoots: const [],
        pendingAttachments: const [],
        isShowingCachedData: false,
        clearActiveCacheUpdatedAt: true,
      );
    }

    await _connectAndLoadNode(nodeId);
    return null;
  }

  Future<void> _connectAndLoadNode(String nodeId) async {
    _disposeSocketSync();
    _quotaTimer?.cancel();

    final factory = ref.read(eventSocketFactoryProvider);
    final socket = factory(
      serverConfig: _api.serverConfig,
      nodeId: nodeId,
      tokenStore: _api.tokenStore,
      onRefreshAuth: _api.refreshSessionLocked,
    );
    _socket = socket;

    var hadConnectedOnce = false;
    _wsStateSub = socket.connectionStates.listen((connState) {
      if (_disposed || _socket != socket) return;
      final prevState = state.wsState;
      state = state.copyWith(wsState: connState);
      if (connState == WsConnState.connected) {
        final isReconnect = hadConnectedOnce && prevState != WsConnState.connected;
        hadConnectedOnce = true;
        if (state.offlineOutbox.isNotEmpty) {
          unawaited(flushOfflineOutbox());
        }
        if (isReconnect) {
          unawaited(refreshNodes());
          unawaited(refreshSessionTree());
          if (state.activeSessionId.isNotEmpty) {
            unawaited(_syncActiveSessionSilent());
          }
        }
      } else if (connState == WsConnState.disconnected &&
          prevState == WsConnState.connected) {
        unawaited(refreshNodes());
      }
    });
    _wsEventSub = socket.events.listen(_onWsEvent);

    unawaited(socket.connect());

    _quotaTimer = Timer.periodic(const Duration(seconds: 60), (_) {
      if (!_disposed && state.selectedNodeId == nodeId) {
        unawaited(refreshNodes());
        fetchQuota();
        unawaited(fetchModels());
      }
    });

    await Future.wait([
      refreshSessionTree(autoSelectFirst: true).then((_) => refreshFileRoots()),
      fetchQuota(),
      fetchModels(),
    ]);
  }

  void handleAppPaused() {
    _isAppInBackground = true;
    _pausedAt = DateTime.now();
  }

  Future<void> handleAppResumed() async {
    _isAppInBackground = false;
    if (_disposed || state.selectedNodeId.isEmpty) return;
    final now = DateTime.now();
    if (_lastResumedAt != null && now.difference(_lastResumedAt!) < const Duration(seconds: 2)) {
      return;
    }
    final pausedSeconds = _pausedAt == null ? 0 : now.difference(_pausedAt!).inSeconds;
    _pausedAt = null;
    _lastResumedAt = now;

    final socket = _socket;
    if (socket != null && (socket.currentState != WsConnState.connected || pausedSeconds >= 5)) {
      unawaited(socket.reconnectNow(refreshToken: pausedSeconds >= 60));
    }
    unawaited(refreshNodes().then((_) {
      if (!_disposed && state.offlineOutbox.isNotEmpty) {
        unawaited(flushOfflineOutbox());
      }
    }));
    unawaited(refreshSessionTree());
    unawaited(fetchModels());
    if (state.activeSessionId.isNotEmpty) {
      await _syncActiveSessionSilent();
    }
    _syncRunningNotification();
  }

  void _syncRunningNotification() {
    if (!AndroidNativeBridge.isAndroidNative || _disposed) return;
    if (state.isActiveSessionRunning) {
      if (_isAppInBackground && _lastNotifiedRunningTitle.isEmpty) {
        return;
      }
      final title = state.activeSessionTitle.trim().isNotEmpty
          ? state.activeSessionTitle.trim()
          : 'AGY Remote 任务运行中';
      final focus = state.activeFocusText.trim();
      final body = focus.isNotEmpty ? focus : 'Agent 正在执行指令...';
      if (title == _lastNotifiedRunningTitle && body == _lastNotifiedRunningBody) {
        return;
      }
      _lastNotifiedRunningTitle = title;
      _lastNotifiedRunningBody = body;
      unawaited(AndroidNativeBridge.updateRunningNotification(title: title, body: body));
    } else if (_lastNotifiedRunningTitle.isNotEmpty || _lastNotifiedRunningBody.isNotEmpty) {
      _lastNotifiedRunningTitle = '';
      _lastNotifiedRunningBody = '';
      unawaited(AndroidNativeBridge.stopRunningNotification());
    }
  }

  void _maybeNotifyAskQuestion(AgentMessage step) {
    if (!AndroidNativeBridge.isAndroidNative || !_isAppInBackground) return;
    if (step.stepIndex <= _lastAskQuestionStep) return;
    for (final tool in step.toolCalls) {
      if (tool.name == 'ask_question') {
        final qs = AskQuestionItem.parseFromTool(tool);
        if (qs.isNotEmpty) {
          _lastAskQuestionStep = step.stepIndex;
          unawaited(
            AndroidNativeBridge.showAlertNotification(
              title: 'Agent 等待你的确认',
              body: qs.first.question,
              id: 2002,
            ),
          );
          return;
        }
      }
    }
  }

  String _extractLatestModel(List<AgentMessage> messages, [String fallback = '']) {
    for (var i = messages.length - 1; i >= 0; i--) {
      final m = messages[i].model.trim();
      if (m.isNotEmpty) return m;
    }
    return fallback;
  }

  Future<void> _syncActiveSessionSilent({bool ensureSubscribed = false}) async {
    final nodeId = state.selectedNodeId;
    final sid = state.activeSessionId;
    if (_disposed || nodeId.isEmpty || sid.isEmpty) return;
    try {
      final page = await _api.getSessionMessages(nodeId, sid);
      if (_disposed || state.selectedNodeId != nodeId || state.activeSessionId != sid) {
        return;
      }
      final byKey = <String, AgentMessage>{};
      for (final m in state.messages) {
        if (m.stepIndex >= 0) {
          byKey['${m.stepIndex}_${m.msgType}'] = m;
        }
      }
      final serverUserTexts = page.messages.where((m) => m.isUser).map((m) => m.content).toSet();
      for (final m in page.messages) {
        byKey['${m.stepIndex}_${m.msgType}'] = m;
      }
      final merged = byKey.values.toList()..sort((a, b) => a.stepIndex.compareTo(b.stepIndex));
      for (final m in state.messages) {
        if (m.stepIndex < 0 && !(m.isUser && serverUserTexts.contains(m.content))) {
          merged.add(m);
        }
      }
      final nextRunning = Set<String>.from(state.runningSessionIds);
      if (page.isRunning) {
        nextRunning.add(sid);
      } else {
        nextRunning.remove(sid);
      }
      final detectedModel = page.activeModel.isNotEmpty
          ? page.activeModel
          : _extractLatestModel(merged, state.activeSessionModel);
      state = state.copyWith(
        messages: merged,
        hasMoreMessages: page.hasMore || state.hasMoreMessages,
        nextBeforeStep: page.nextBeforeStep ?? state.nextBeforeStep,
        runningSessionIds: nextRunning,
        activeSessionModel: detectedModel,
        clearPendingSwitchModel:
            detectedModel.isNotEmpty && state.pendingSwitchModel == detectedModel,
        isShowingCachedData: false,
        clearActiveCacheUpdatedAt: true,
      );
      _schedulePersistActiveSessionCache(immediate: true);
      if (ensureSubscribed || _subscribedSessionId != sid) {
        final lastStep = merged.isNotEmpty ? merged.last.stepIndex : null;
        _subscribeSession(sid, sinceStep: lastStep);
      }
    } catch (_) {}
    unawaited(refreshSessionQueue());
    unawaited(refreshSessionChanges());
  }

  Future<void> refreshSessionTree({bool autoSelectFirst = false}) async {
    final nodeId = state.selectedNodeId;
    if (nodeId.isEmpty) return;
    try {
      final tree = await _api.getSessionTree(nodeId);
      if (_disposed || state.selectedNodeId != nodeId) return;

      final mergedRunning = Set<String>.from(tree.runningSessionIds);
      final updatedNodes = state.nodes
          .map((n) => n.id == nodeId
              ? HostNode(
                  id: n.id,
                  name: n.name,
                  isOnline: true,
                  engineAlive: tree.engineAlive,
                  isLocal: n.isLocal,
                  lastSeen: n.lastSeen,
                  version: n.version,
                  canWrite: n.canWrite,
                  canDelete: n.canDelete,
                )
              : n)
          .toList();

      state = state.copyWith(
        nodes: updatedNodes,
        projects: tree.projects,
        generalSessions: tree.generalSessions,
        runningSessionIds: mergedRunning,
      );
      final nextTrees = Map<String, CachedNodeTree>.from(_cacheSnapshot.treesByNode);
      nextTrees[nodeId] = CachedNodeTree(
        nodeId: nodeId,
        projects: tree.projects,
        generalSessions: tree.generalSessions,
        updatedAtMs: DateTime.now().millisecondsSinceEpoch,
      );
      _cacheSnapshot = CachedHubSnapshot(
        nodes: updatedNodes,
        lastNodeId: _cacheSnapshot.lastNodeId,
        lastSessionIdByNode: _cacheSnapshot.lastSessionIdByNode,
        treesByNode: nextTrees,
        sessionsByKey: _cacheSnapshot.sessionsByKey,
      );
      unawaited(SessionCacheStore.saveNodes(updatedNodes, selectedNodeId: nodeId));
      unawaited(SessionCacheStore.saveSessionTree(nodeId, tree.projects, tree.generalSessions));

      if (autoSelectFirst) {
        final preferred = _findFirstSession(
          tree.projects,
          tree.generalSessions,
          runningIds: mergedRunning,
        );
        final matched = state.activeSessionId.isNotEmpty
            ? _findSessionById(state.activeSessionId, tree.projects, tree.generalSessions)
            : null;
        final shouldSwitchToRunning = state.isShowingCachedData &&
            preferred != null &&
            preferred.id != state.activeSessionId &&
            (preferred.isRunning || mergedRunning.contains(preferred.id));

        if (state.activeSessionId.isEmpty || matched == null || shouldSwitchToRunning) {
          if (preferred != null) {
            await selectSession(preferred);
          } else if (state.activeSessionId.isEmpty) {
            state = state.copyWith(activeSessionTitle: '暂无会话');
          }
        } else {
          if (matched.title != state.activeSessionTitle) {
            state = state.copyWith(activeSessionTitle: matched.title);
          }
          if (state.isShowingCachedData || _subscribedSessionId != state.activeSessionId) {
            await _syncActiveSessionSilent(ensureSubscribed: true);
          }
        }
      } else if (state.activeSessionId.isNotEmpty) {
        final matched = _findSessionById(state.activeSessionId, tree.projects, tree.generalSessions);
        if (matched != null && matched.title != state.activeSessionTitle) {
          state = state.copyWith(activeSessionTitle: matched.title);
        }
      }
    } catch (_) {}
  }

  SessionItem? _findFirstSession(
    Map<String, List<SessionItem>> projects,
    List<SessionItem> general, {
    Set<String> runningIds = const {},
  }) {
    final allSessions = <SessionItem>[
      for (final list in projects.values) ...list,
      ...general,
    ];
    if (allSessions.isEmpty) return null;

    String sortKeyOf(SessionItem s) =>
        s.lastModified.isNotEmpty ? s.lastModified : s.updatedAt;

    SessionItem pickMostRecent(List<SessionItem> candidates) {
      var best = candidates.first;
      var bestKey = sortKeyOf(best);
      for (var i = 1; i < candidates.length; i++) {
        final cur = candidates[i];
        final curKey = sortKeyOf(cur);
        if (curKey.compareTo(bestKey) > 0) {
          best = cur;
          bestKey = curKey;
        }
      }
      return best;
    }

    // Priority 1: Any currently running session (most recently modified first)
    final running = allSessions
        .where((s) => s.isRunning || runningIds.contains(s.id))
        .toList();
    if (running.isNotEmpty) {
      return pickMostRecent(running);
    }

    // Priority 2: Most recently modified active session across all projects & general
    return pickMostRecent(allSessions);
  }

  SessionItem? _findSessionById(
    String sid,
    Map<String, List<SessionItem>> projects,
    List<SessionItem> general,
  ) {
    for (final list in projects.values) {
      for (final s in list) {
        if (s.id == sid) return s;
      }
    }
    for (final s in general) {
      if (s.id == sid) return s;
    }
    return null;
  }

  Future<void> selectSession(SessionItem session) async {
    final nodeId = state.selectedNodeId;
    if (nodeId.isEmpty || session.id.isEmpty) return;

    _lastAskQuestionStep = -1;
    final prevSid = state.activeSessionId;
    if (prevSid.isNotEmpty && prevSid != session.id) {
      _socket?.unsubscribe(prevSid);
    }

    final cached = _cacheSnapshot.getSession(nodeId, session.id);
    final hasCached = cached != null && cached.messages.isNotEmpty;

    state = state.copyWith(
      activeSessionId: session.id,
      activeSessionTitle: session.title,
      activeRootId: session.rootId.isNotEmpty ? session.rootId : 'scratch',
      messages: hasCached ? cached.messages : const [],
      hasMoreMessages: false,
      clearNextBeforeStep: true,
      activeSessionModel: hasCached ? cached.activeModel : '',
      clearPendingSwitchModel: true,
      clearSessionChanges: true,
      clearSessionQueue: true,
      isLoadingMessages: !hasCached,
      isShowingCachedData: hasCached,
      activeCacheUpdatedAt: hasCached ? cached.updatedAt : null,
      clearActiveCacheUpdatedAt: !hasCached,
    );

    try {
      final page = await _api.getSessionMessages(nodeId, session.id);
      if (_disposed || state.selectedNodeId != nodeId || state.activeSessionId != session.id) {
        return;
      }

      final nextRunning = Set<String>.from(state.runningSessionIds);
      if (page.isRunning) {
        nextRunning.add(session.id);
      } else {
        nextRunning.remove(session.id);
      }
      final detectedModel = page.activeModel.isNotEmpty
          ? page.activeModel
          : _extractLatestModel(page.messages);

      state = state.copyWith(
        messages: page.messages,
        hasMoreMessages: page.hasMore,
        nextBeforeStep: page.nextBeforeStep,
        clearNextBeforeStep: page.nextBeforeStep == null,
        isLoadingMessages: false,
        runningSessionIds: nextRunning,
        activeSessionModel: detectedModel,
        isShowingCachedData: false,
        clearActiveCacheUpdatedAt: true,
      );

      _schedulePersistActiveSessionCache(immediate: true);
      final lastStep = page.messages.isNotEmpty ? page.messages.last.stepIndex : null;
      _subscribeSession(session.id, sinceStep: lastStep);
      _syncRunningNotification();
      unawaited(refreshSessionChanges());
      unawaited(refreshSessionQueue());
    } catch (_) {
      if (_disposed) return;
      state = state.copyWith(isLoadingMessages: false);
    }
  }

  Future<void> loadEarlierMessages() async {
    final nodeId = state.selectedNodeId;
    final sid = state.activeSessionId;
    final before = state.nextBeforeStep;
    if (nodeId.isEmpty || sid.isEmpty || before == null || !state.hasMoreMessages || state.isLoadingMore) {
      return;
    }
    state = state.copyWith(isLoadingMore: true);
    try {
      final page = await _api.getSessionMessages(nodeId, sid, beforeStep: before);
      if (_disposed || state.activeSessionId != sid) return;

      final existingKeys = state.messages.map((m) => '${m.stepIndex}_${m.msgType}').toSet();
      final older = page.messages
          .where((m) => !existingKeys.contains('${m.stepIndex}_${m.msgType}'))
          .toList()
        ..sort((a, b) => a.stepIndex.compareTo(b.stepIndex));
      final merged = [...older, ...state.messages];

      state = state.copyWith(
        messages: merged,
        hasMoreMessages: page.hasMore,
        nextBeforeStep: page.nextBeforeStep,
        clearNextBeforeStep: page.nextBeforeStep == null,
        isLoadingMore: false,
      );
    } catch (_) {
      if (_disposed) return;
      state = state.copyWith(isLoadingMore: false);
    }
  }

  void _onWsEvent(WsServerEvent event) {
    if (_disposed) return;
    switch (event) {
      case WsStepUpsertEvent():
        final nextRunning = Set<String>.from(state.runningSessionIds);
        if (event.isRunning) {
          nextRunning.add(event.sessionId);
        } else {
          nextRunning.remove(event.sessionId);
        }

        if (event.sessionId != state.activeSessionId) {
          state = state.copyWith(runningSessionIds: nextRunning);
          return;
        }

        final updated = List<AgentMessage>.from(state.messages);
        if (event.step.isUser) {
          updated.removeWhere(
            (m) => m.stepIndex < 0 && m.isUser && m.content == event.step.content,
          );
        }
        final existingIdx = updated.indexWhere(
          (m) => m.stepIndex > 0 && m.stepIndex == event.step.stepIndex && m.msgType == event.step.msgType,
        );
        if (existingIdx >= 0) {
          updated[existingIdx] = event.step;
        } else {
          // Insert in step order before trailing newer messages, while keeping
          // newly arrived Agent steps AFTER any unconfirmed optimistic user bubble.
          final lastConfirmedIdx = updated.lastIndexWhere((m) => m.stepIndex >= 0);
          if (lastConfirmedIdx == -1 || event.step.stepIndex > updated[lastConfirmedIdx].stepIndex) {
            updated.add(event.step);
          } else {
            final insertAt = updated.indexWhere(
              (m) => m.stepIndex >= 0 && m.stepIndex > event.step.stepIndex,
            );
            if (insertAt >= 0) {
              updated.insert(insertAt, event.step);
            } else {
              updated.add(event.step);
            }
          }
        }
        final stepModel = event.step.model.trim();
        final preserveOrchestrator = state.activeSessionModel.toLowerCase().contains('orchestrator') &&
            state.pendingSwitchModel.isEmpty &&
            stepModel.isNotEmpty &&
            !stepModel.toLowerCase().contains('orchestrator');
        final nextActiveModel = (stepModel.isNotEmpty && !preserveOrchestrator)
            ? stepModel
            : state.activeSessionModel;
        final clearPending = stepModel.isNotEmpty &&
            (state.pendingSwitchModel == stepModel ||
                state.pendingSwitchModel.toLowerCase().contains('orchestrator'));
        state = state.copyWith(
          messages: updated,
          runningSessionIds: nextRunning,
          activeSessionModel: nextActiveModel,
          clearPendingSwitchModel: clearPending,
          isShowingCachedData: false,
          clearActiveCacheUpdatedAt: true,
        );
        _schedulePersistActiveSessionCache();
        _syncRunningNotification();
        _maybeNotifyAskQuestion(event.step);
        if (event.step.toolCalls.any((t) => _editToolNames.contains(t.name))) {
          unawaited(refreshSessionChanges());
        }
        if (event.sessionId == state.activeSessionId && state.sessionQueue.items.isNotEmpty) {
          unawaited(refreshSessionQueue());
        }
        break;

      case WsSessionStatusEvent():
        final wasRunning = state.runningSessionIds.contains(event.sessionId);
        final nextRunning = Set<String>.from(state.runningSessionIds);
        if (event.isRunning) {
          nextRunning.add(event.sessionId);
        } else {
          nextRunning.remove(event.sessionId);
        }
        state = state.copyWith(runningSessionIds: nextRunning);
        _syncRunningNotification();
        if (wasRunning && !event.isRunning) {
          if (AndroidNativeBridge.isAndroidNative &&
              _isAppInBackground &&
              event.sessionId == state.activeSessionId) {
            unawaited(
              AndroidNativeBridge.showAlertNotification(
                title: '任务已完成',
                body: state.activeSessionTitle,
                id: 2001,
              ),
            );
          }
          unawaited(refreshSessionTree());
          if (event.sessionId == state.activeSessionId) {
            unawaited(refreshSessionChanges());
            unawaited(refreshSessionQueue());
          }
        }
        break;

      case WsSessionTreeChangedEvent():
        unawaited(refreshSessionTree());
        break;

      case WsNodeStatusEvent():
        state = state.copyWith(nodes: event.nodes);
        break;

      case WsPongEvent():
      case WsErrorEvent():
        break;
    }
  }

  bool _isTransientNetworkError(Object err) {
    if (err is ApiException) {
      if (err.statusCode == 0 || err.statusCode == 502 || err.statusCode == 503 || err.statusCode == 504) {
        return true;
      }
      final lower = err.message.toLowerCase();
      return lower.contains('node unavailable') ||
          lower.contains('timeout') ||
          lower.contains('timed out') ||
          lower.contains('connection') ||
          lower.contains('socket') ||
          err.message.contains('网络') ||
          err.message.contains('超时') ||
          err.message.contains('连接');
    }
    final text = err.toString().toLowerCase();
    return text.contains('socketexception') ||
        text.contains('timeout') ||
        text.contains('connection') ||
        text.contains('network');
  }

  Future<void> _enqueueOfflineOutbox({
    required String nodeId,
    required String sessionId,
    required String content,
    required String deliveryMode,
    String lastError = '',
  }) async {
    final item = OfflineOutboxItem(
      id: 'out_${DateTime.now().microsecondsSinceEpoch}',
      nodeId: nodeId,
      sessionId: sessionId,
      content: content,
      deliveryMode: deliveryMode,
      createdAt: DateTime.now().toIso8601String(),
      lastError: lastError,
    );
    final next = [...state.offlineOutbox, item];
    state = state.copyWith(offlineOutbox: next);
    await OfflineOutboxStore.save(next);
  }

  Future<String?> sendMessage(
    String rawText, {
    String deliveryMode = 'queue',
    bool interrupt = false,
  }) async {
    final nodeId = state.selectedNodeId;
    final sid = state.activeSessionId;
    if (nodeId.isEmpty || sid.isEmpty) return '请先选择或新建一个会话';
    if (!state.canWrite) return '当前节点为只读权限';

    final text = rawText.trim();
    if (text.isEmpty && state.pendingAttachments.isEmpty) return null;

    final toSend = List<UploadedAttachment>.from(state.pendingAttachments);
    var finalText = text;
    if (toSend.isNotEmpty) {
      final refs = toSend.map((a) {
        final p = a.absPath ?? a.serverPath ?? a.filename;
        return a.isImage ? '[用户上传图片: $p]' : '[用户上传文件: $p]';
      }).join('\n');
      finalText = finalText.isEmpty ? refs : '$refs\n\n$finalText';
    }

    final current = state.currentNode;
    final canStageOffline = toSend.isEmpty && !interrupt;
    if (canStageOffline &&
        state.wsState != WsConnState.connected &&
        current != null &&
        !current.isOnline &&
        !current.isLocal) {
      await _enqueueOfflineOutbox(
        nodeId: nodeId,
        sessionId: sid,
        content: finalText,
        deliveryMode: deliveryMode,
        lastError: '当前节点离线，已暂存等待恢复发送',
      );
      return null;
    }

    final String? modelToSend =
        state.pendingSwitchModel.isNotEmpty ? state.pendingSwitchModel : null;

    final shouldQueue =
        !interrupt &&
        deliveryMode == 'queue' &&
        (state.isActiveSessionRunning || state.sessionQueue.items.isNotEmpty);

    if (shouldQueue) {
      state = state.copyWith(pendingAttachments: const []);
      try {
        final res = await _api.sendMessageWithMode(
          nodeId,
          sid,
          content: finalText,
          model: modelToSend,
          deliveryMode: 'queue',
        );
        if (!res.ok) {
          if (toSend.isNotEmpty) {
            state = state.copyWith(pendingAttachments: toSend);
          }
          return res.message.isNotEmpty ? res.message : '加入队列失败';
        }
        if (res.queued) {
          unawaited(refreshSessionQueue());
          return null;
        }
        final optimisticMsg = AgentMessage(
          stepIndex: -1,
          source: 'USER_EXPLICIT',
          msgType: 'USER_INPUT',
          status: 'SENT',
          content: finalText,
          thinking: '',
          toolCalls: const [],
          timestamp: DateTime.now().toIso8601String(),
        );
        final nextRunning = Set<String>.from(state.runningSessionIds)..add(sid);
        state = state.copyWith(
          messages: [...state.messages, optimisticMsg],
          runningSessionIds: nextRunning,
        );
        return null;
      } catch (e) {
        if (canStageOffline && _isTransientNetworkError(e)) {
          await _enqueueOfflineOutbox(
            nodeId: nodeId,
            sessionId: sid,
            content: finalText,
            deliveryMode: deliveryMode,
            lastError: e is ApiException ? e.message : '网络异常，等待重连发送',
          );
          return null;
        }
        if (toSend.isNotEmpty) {
          state = state.copyWith(pendingAttachments: toSend);
        }
        return e is ApiException ? e.message : '加入队列失败: $e';
      }
    }

    final optimisticMsg = AgentMessage(
      stepIndex: -1,
      source: 'USER_EXPLICIT',
      msgType: 'USER_INPUT',
      status: 'SENT',
      content: finalText,
      thinking: '',
      toolCalls: const [],
      timestamp: DateTime.now().toIso8601String(),
    );

    final hadRunning = state.runningSessionIds.contains(sid);
    final nextRunning = Set<String>.from(state.runningSessionIds)..add(sid);
    state = state.copyWith(
      pendingAttachments: const [],
      messages: [...state.messages, optimisticMsg],
      runningSessionIds: nextRunning,
    );
    _syncRunningNotification();

    void rollbackOptimistic() {
      final rolledRunning = Set<String>.from(state.runningSessionIds);
      if (!hadRunning) {
        rolledRunning.remove(sid);
      }
      final cleanedMessages =
          state.messages.where((m) => !identical(m, optimisticMsg)).toList();
      state = state.copyWith(
        messages: cleanedMessages,
        runningSessionIds: rolledRunning,
        pendingAttachments: toSend.isNotEmpty ? toSend : state.pendingAttachments,
      );
      _syncRunningNotification();
    }

    try {
      final (bool ok, String msg) = (deliveryMode == 'immediate' || interrupt)
          ? await (() async {
              final res = await _api.sendMessageWithMode(
                nodeId,
                sid,
                content: finalText,
                model: modelToSend,
                deliveryMode: 'immediate',
                interrupt: interrupt,
              );
              return (res.ok, res.message);
            })()
          : await _api.sendMessage(
              nodeId,
              sid,
              content: finalText,
              model: modelToSend,
            );
      if (!ok) {
        rollbackOptimistic();
        return msg.isNotEmpty ? msg : '发送失败';
      }
      return null;
    } catch (e) {
      rollbackOptimistic();
      if (canStageOffline && _isTransientNetworkError(e)) {
        await _enqueueOfflineOutbox(
          nodeId: nodeId,
          sessionId: sid,
          content: finalText,
          deliveryMode: deliveryMode,
          lastError: e is ApiException ? e.message : '网络异常，等待重连发送',
        );
        return null;
      }
      return e is ApiException ? e.message : '发送失败: $e';
    }
  }

  Future<String?> stopActiveSession() async {
    final nodeId = state.selectedNodeId;
    final sid = state.activeSessionId;
    if (nodeId.isEmpty || sid.isEmpty) return null;
    try {
      final (ok, msg) = await _api.stopSession(nodeId, sid);
      if (ok) {
        final next = Set<String>.from(state.runningSessionIds)..remove(sid);
        state = state.copyWith(runningSessionIds: next);
        _syncRunningNotification();
        if (state.sessionQueue.items.isNotEmpty) {
          unawaited(refreshSessionQueue());
        }
        return null;
      }
      return msg.isNotEmpty ? msg : '停止指令执行失败';
    } on ApiException catch (e) {
      return e.message;
    } catch (e) {
      return '停止失败: $e';
    }
  }

  Future<void> refreshSessionQueue() async {
    final nodeId = state.selectedNodeId;
    final sid = state.activeSessionId;
    if (nodeId.isEmpty || sid.isEmpty) return;
    try {
      final queue = await _api.getSessionQueue(nodeId, sid);
      if (_disposed || state.selectedNodeId != nodeId || state.activeSessionId != sid) return;
      state = state.copyWith(sessionQueue: queue);
    } catch (_) {}
  }

  Future<String?> updateQueuedMessage(String itemId, String content) async {
    final nodeId = state.selectedNodeId;
    final sid = state.activeSessionId;
    if (nodeId.isEmpty || sid.isEmpty) return '未选中会话';
    try {
      final queue = await _api.updateQueuedMessage(nodeId, sid, itemId, content);
      if (!_disposed && state.selectedNodeId == nodeId && state.activeSessionId == sid) {
        state = state.copyWith(sessionQueue: queue);
      }
      return null;
    } on ApiException catch (e) {
      return e.message;
    } catch (e) {
      return '更新队列失败: $e';
    }
  }

  Future<String?> deleteQueuedMessage(String itemId) async {
    final nodeId = state.selectedNodeId;
    final sid = state.activeSessionId;
    if (nodeId.isEmpty || sid.isEmpty) return '未选中会话';
    try {
      final queue = await _api.deleteQueuedMessage(nodeId, sid, itemId);
      if (!_disposed && state.selectedNodeId == nodeId && state.activeSessionId == sid) {
        state = state.copyWith(sessionQueue: queue);
      }
      return null;
    } on ApiException catch (e) {
      return e.message;
    } catch (e) {
      return '删除队列项失败: $e';
    }
  }

  Future<String?> clearSessionQueue() async {
    final nodeId = state.selectedNodeId;
    final sid = state.activeSessionId;
    if (nodeId.isEmpty || sid.isEmpty) return '未选中会话';
    try {
      final queue = await _api.clearSessionQueue(nodeId, sid);
      if (!_disposed && state.selectedNodeId == nodeId && state.activeSessionId == sid) {
        state = state.copyWith(sessionQueue: queue);
      }
      return null;
    } on ApiException catch (e) {
      return e.message;
    } catch (e) {
      return '清空队列失败: $e';
    }
  }

  Future<String?> setSessionQueuePaused(bool paused) async {
    final nodeId = state.selectedNodeId;
    final sid = state.activeSessionId;
    if (nodeId.isEmpty || sid.isEmpty) return '未选中会话';
    try {
      final queue = await _api.setSessionQueuePaused(nodeId, sid, paused: paused);
      if (!_disposed && state.selectedNodeId == nodeId && state.activeSessionId == sid) {
        state = state.copyWith(sessionQueue: queue);
      }
      return null;
    } on ApiException catch (e) {
      return e.message;
    } catch (e) {
      return '切换队列状态失败: $e';
    }
  }

  Future<String?> sendQueuedMessageNow(String itemId) async {
    final nodeId = state.selectedNodeId;
    final sid = state.activeSessionId;
    if (nodeId.isEmpty || sid.isEmpty) return '未选中会话';
    try {
      final (ok, msg) = await _api.sendQueuedMessageNow(nodeId, sid, itemId);
      await refreshSessionQueue();
      if (!ok) {
        return msg.isNotEmpty ? msg : '立即发送失败';
      }
      final nextRunning = Set<String>.from(state.runningSessionIds)..add(sid);
      state = state.copyWith(runningSessionIds: nextRunning);
      return null;
    } on ApiException catch (e) {
      return e.message;
    } catch (e) {
      return '立即发送失败: $e';
    }
  }

  Future<String?> flushOfflineOutbox({bool manual = false, String? onlyItemId}) async {
    if (_disposed || _isFlushingOutbox || state.offlineOutbox.isEmpty) return null;
    final activeNodeId = state.selectedNodeId;
    if (activeNodeId.isEmpty) return null;

    _isFlushingOutbox = true;
    state = state.copyWith(isFlushingOutbox: true);
    String? firstError;

    try {
      final targets = state.offlineOutbox.where((e) {
        if (onlyItemId != null) return e.id == onlyItemId;
        return e.nodeId == activeNodeId;
      }).toList();

      for (final item in targets) {
        if (_disposed) break;
        try {
          final res = await _api.sendMessageWithMode(
            item.nodeId,
            item.sessionId,
            content: item.content,
            model: (item.nodeId == state.selectedNodeId &&
                    item.sessionId == state.activeSessionId &&
                    state.pendingSwitchModel.isNotEmpty)
                ? state.pendingSwitchModel
                : null,
            deliveryMode: item.deliveryMode,
          );
          if (_disposed) break;
          if (!res.ok) {
            final errMsg = res.message.isNotEmpty ? res.message : '补发失败';
            firstError ??= errMsg;
            final updated = state.offlineOutbox
                .map((e) => e.id == item.id ? e.copyWith(lastError: errMsg) : e)
                .toList();
            state = state.copyWith(offlineOutbox: updated);
            await OfflineOutboxStore.save(updated);
            continue;
          }

          final remaining = state.offlineOutbox.where((e) => e.id != item.id).toList();
          state = state.copyWith(offlineOutbox: remaining);
          await OfflineOutboxStore.save(remaining);

          if (item.nodeId == state.selectedNodeId && item.sessionId == state.activeSessionId) {
            if (res.queued) {
              unawaited(refreshSessionQueue());
            } else {
              final optimistic = AgentMessage(
                stepIndex: -1,
                source: 'USER_EXPLICIT',
                msgType: 'USER_INPUT',
                status: 'SENT',
                content: item.content,
                thinking: '',
                toolCalls: const [],
                timestamp: DateTime.now().toIso8601String(),
              );
              final nextRunning = Set<String>.from(state.runningSessionIds)..add(item.sessionId);
              state = state.copyWith(
                messages: [...state.messages, optimistic],
                runningSessionIds: nextRunning,
              );
              unawaited(_syncActiveSessionSilent());
            }
          }
        } catch (e) {
          final errMsg = e is ApiException ? e.message : '补发失败: $e';
          firstError ??= errMsg;
          final updated = state.offlineOutbox
              .map((it) => it.id == item.id ? it.copyWith(lastError: errMsg) : it)
              .toList();
          state = state.copyWith(offlineOutbox: updated);
          await OfflineOutboxStore.save(updated);
          if (_isTransientNetworkError(e)) {
            if (!manual) break;
          }
        }
      }
    } finally {
      _isFlushingOutbox = false;
      if (!_disposed) {
        state = state.copyWith(isFlushingOutbox: false);
      }
    }
    return firstError;
  }

  Future<void> editOfflineOutboxItem(String itemId, String newContent) async {
    final cleaned = newContent.trim();
    if (cleaned.isEmpty) return;
    final next = state.offlineOutbox
        .map((e) => e.id == itemId ? e.copyWith(content: cleaned, lastError: '') : e)
        .toList();
    state = state.copyWith(offlineOutbox: next);
    await OfflineOutboxStore.save(next);
  }

  Future<void> removeOfflineOutboxItem(String itemId) async {
    final next = state.offlineOutbox.where((e) => e.id != itemId).toList();
    state = state.copyWith(offlineOutbox: next);
    await OfflineOutboxStore.save(next);
  }

  Future<void> clearActiveOfflineOutbox() async {
    final nodeId = state.selectedNodeId;
    final sid = state.activeSessionId;
    final next = state.offlineOutbox
        .where((e) => !(e.nodeId == nodeId && e.sessionId == sid))
        .toList();
    state = state.copyWith(offlineOutbox: next);
    await OfflineOutboxStore.save(next);
  }

  Future<String?> createNewSession({
    required String content,
    required String mode,
    required String model,
    String? workspacePath,
    String? rootId,
  }) async {
    final nodeId = state.selectedNodeId;
    if (nodeId.isEmpty) return '未选中节点';
    if (!state.canWrite) return '当前节点为只读权限';

    state = state.copyWith(selectedMode: mode, selectedModel: model);
    try {
      final (ok, newSid, msg) = await _api.createSession(
        nodeId,
        content: content,
        model: model,
        mode: mode,
        workspacePath: workspacePath,
        rootId: rootId,
      );
      if (!ok) return msg.isNotEmpty ? msg : '创建新会话失败';

      await refreshSessionTree();
      if (newSid.isNotEmpty) {
        final matched = _findSessionById(newSid, state.projects, state.generalSessions);
        final nextRunning = Set<String>.from(state.runningSessionIds)..add(newSid);
        state = state.copyWith(runningSessionIds: nextRunning);
        await selectSession(
          matched ??
              SessionItem(
                id: newSid,
                title: content.length > 28 ? '${content.substring(0, 28)}...' : content,
                rootId: rootId ?? 'scratch',
                workspacePath: workspacePath ?? '',
              ),
        );
        if (!_disposed && state.activeSessionId == newSid && state.activeSessionModel.isEmpty) {
          state = state.copyWith(activeSessionModel: model);
        }
      }
      return null;
    } on ApiException catch (e) {
      return e.message;
    } catch (e) {
      return '创建会话异常: $e';
    }
  }

  Future<String?> deleteSession(String sessionId) async {
    final nodeId = state.selectedNodeId;
    if (nodeId.isEmpty) return null;
    if (!state.canDelete) return '当前账户无删除权限';

    try {
      final (ok, msg) = await _api.deleteSession(nodeId, sessionId);
      if (!ok) return msg;

      final nextSessions = Map<String, CachedSessionMessages>.from(_cacheSnapshot.sessionsByKey);
      nextSessions.remove(CachedHubSnapshot.sessionKey(nodeId, sessionId));
      _cacheSnapshot = CachedHubSnapshot(
        nodes: _cacheSnapshot.nodes,
        lastNodeId: _cacheSnapshot.lastNodeId,
        lastSessionIdByNode: _cacheSnapshot.lastSessionIdByNode,
        treesByNode: _cacheSnapshot.treesByNode,
        sessionsByKey: nextSessions,
      );
      unawaited(SessionCacheStore.removeSession(nodeId, sessionId));

      if (state.activeSessionId == sessionId) {
        _socket?.unsubscribe(sessionId);
        state = state.copyWith(
          activeSessionId: '',
          activeSessionTitle: '请选择会话或新建',
          messages: const [],
          hasMoreMessages: false,
          clearNextBeforeStep: true,
          activeSessionModel: '',
          clearPendingSwitchModel: true,
          isShowingCachedData: false,
          clearActiveCacheUpdatedAt: true,
        );
      }
      await refreshSessionTree(autoSelectFirst: state.activeSessionId.isEmpty);
      return null;
    } on ApiException catch (e) {
      return e.message;
    } catch (e) {
      return '删除失败: $e';
    }
  }

  Future<String?> uploadAttachment({
    required String filename,
    required Uint8List bytes,
    required bool isImage,
  }) async {
    final nodeId = state.selectedNodeId;
    final sid = state.activeSessionId;
    if (nodeId.isEmpty || sid.isEmpty) return '请先选择会话后再上传附件';
    if (!state.canWrite) return '当前节点为只读权限';

    final att = UploadedAttachment(
      filename: filename,
      isImage: isImage,
      isUploading: true,
      imageBytes: isImage ? bytes : null,
    );
    state = state.copyWith(pendingAttachments: [...state.pendingAttachments, att]);

    try {
      final res = await _api.uploadFile(nodeId, sid, filename: filename, bytes: bytes);
      att.serverPath = res.path;
      att.absPath = res.absPath;
      att.rootId = res.rootId;
      att.size = res.size;
      att.isUploading = false;
      state = state.copyWith(pendingAttachments: [...state.pendingAttachments]);
      return null;
    } catch (e) {
      att.isUploading = false;
      att.hasError = true;
      state = state.copyWith(pendingAttachments: [...state.pendingAttachments]);
      return '上传失败: $e';
    }
  }

  void removePendingAttachment(int index) {
    final next = List<UploadedAttachment>.from(state.pendingAttachments);
    if (index >= 0 && index < next.length) {
      next.removeAt(index);
      state = state.copyWith(pendingAttachments: next);
    }
  }

  Future<void> fetchQuota() async {
    final nodeId = state.selectedNodeId;
    if (nodeId.isEmpty) return;
    state = state.copyWith(isLoadingQuota: true);
    try {
      final quota = await _api.getQuota(nodeId);
      if (_disposed || state.selectedNodeId != nodeId) return;
      state = state.copyWith(quota: quota, isLoadingQuota: false);
    } catch (_) {
      if (_disposed) return;
      state = state.copyWith(isLoadingQuota: false);
    }
  }

  Future<void> fetchModels() async {
    final nodeId = state.selectedNodeId;
    if (nodeId.isEmpty) return;
    try {
      final res = await _api.getModels(nodeId);
      if (_disposed || state.selectedNodeId != nodeId) return;
      if (res.models.isEmpty) return;
      var nextSelected = state.selectedModel;
      if (!res.models.any((m) => m.id == nextSelected)) {
        nextSelected = res.defaultModel.isNotEmpty ? res.defaultModel : res.models.first.id;
      }
      state = state.copyWith(
        availableModels: res.models,
        selectedModel: nextSelected,
      );
    } catch (_) {
      // Fallback gracefully to cached / built-in models on older nodes
    }
  }

  void setSessionPendingModel(String? modelId) {
    final clean = (modelId ?? '').trim();
    if (clean.isEmpty || clean == state.activeSessionModel) {
      state = state.copyWith(clearPendingSwitchModel: true);
    } else {
      state = state.copyWith(pendingSwitchModel: clean);
    }
  }

  Future<List<FileRootItem>> refreshFileRoots() async {
    final nodeId = state.selectedNodeId;
    if (nodeId.isEmpty) return const [];
    try {
      final roots = await _api.getFileRoots(nodeId);
      if (!_disposed && state.selectedNodeId == nodeId) {
        state = state.copyWith(cachedRoots: roots);
      }
      return roots;
    } catch (_) {
      return state.cachedRoots;
    }
  }

  Future<FileTreeData> browseFiles(String rootId, {String subPath = ''}) async {
    return _api.getFileTree(state.selectedNodeId, rootId, path: subPath);
  }

  Future<FileContentData> readFileContent(String rootId, String relPath) async {
    return _api.getFileContent(state.selectedNodeId, rootId, relPath);
  }

  Future<FileSaveResult> saveFileContent(
    String rootId,
    String relPath,
    String content, {
    double? expectedMtime,
  }) async {
    return _api.saveFileContent(
      nodeId: state.selectedNodeId,
      rootId: rootId,
      path: relPath,
      content: content,
      expectedMtime: expectedMtime,
    );
  }

  Future<ToolCallOutputData> fetchStepToolOutput(int stepIndex) async {
    final nodeId = state.selectedNodeId;
    final sid = state.activeSessionId;
    if (nodeId.isEmpty || sid.isEmpty) {
      return ToolCallOutputData(sessionId: sid, stepIndex: stepIndex);
    }
    return _api.getStepToolOutput(nodeId: nodeId, sessionId: sid, stepIndex: stepIndex);
  }

  Future<List<SessionArtifactItem>> fetchSessionArtifacts() async {
    final nodeId = state.selectedNodeId;
    final sid = state.activeSessionId;
    if (nodeId.isEmpty || sid.isEmpty) {
      return const [];
    }
    return _api.getSessionArtifacts(nodeId: nodeId, sessionId: sid);
  }

  Future<void> refreshSessionChanges() async {
    final nodeId = state.selectedNodeId;
    final sid = state.activeSessionId;
    if (nodeId.isEmpty || sid.isEmpty) return;
    try {
      final summary = await _api.getSessionChanges(
        nodeId,
        sid,
        includeHunks: false,
        scope: 'latest_turn',
      );
      if (_disposed || state.selectedNodeId != nodeId || state.activeSessionId != sid) return;
      state = state.copyWith(sessionChanges: summary);
    } catch (_) {}
  }

  Future<SessionChangesData> fetchSessionChangesDetail({
    String? filePath,
    String scope = 'all',
    int? stepIndex,
    int? turnId,
  }) async {
    final nodeId = state.selectedNodeId;
    final sid = state.activeSessionId;
    if (nodeId.isEmpty || sid.isEmpty) {
      return const SessionChangesData();
    }
    return _api.getSessionChanges(
      nodeId,
      sid,
      includeHunks: true,
      filePath: filePath,
      scope: scope,
      stepIndex: stepIndex,
      turnId: turnId,
    );
  }

  Future<List<GitRepoItem>> fetchGitRepos() async {
    final nodeId = state.selectedNodeId;
    if (nodeId.isEmpty) return const [];
    return _api.getGitRepos(nodeId);
  }

  Future<GitDiffData> fetchGitDiff({
    String? rootId,
    String subPath = '',
    String scope = 'uncommitted',
  }) async {
    final roots = state.cachedRoots.isNotEmpty ? state.cachedRoots : await refreshFileRoots();
    final targetRootId = (rootId != null && rootId.isNotEmpty)
        ? rootId
        : (state.activeRootId.isNotEmpty
            ? state.activeRootId
            : (roots.isNotEmpty ? roots.first.id : 'scratch'));
    return _api.getGitDiff(
      state.selectedNodeId,
      targetRootId,
      subPath: subPath,
      scope: scope,
    );
  }

  static final RegExp _lineAnchorRe = RegExp(r'#L\d+(?:-L?\d+)?$', caseSensitive: false);

  ({String rootId, String relPath})? resolveRootAndRelPath(String rawPath, {String? rootId}) {
    var cleaned = rawPath.trim();
    if (cleaned.isEmpty) return null;

    final isFileUri = cleaned.toLowerCase().startsWith('file://');
    if (isFileUri) {
      final hashIdx = cleaned.indexOf('#');
      if (hashIdx >= 0) cleaned = cleaned.substring(0, hashIdx);
      final queryIdx = cleaned.indexOf('?');
      if (queryIdx >= 0) cleaned = cleaned.substring(0, queryIdx);

      final hasTripleSlash = cleaned.toLowerCase().startsWith('file:///');
      var rest = hasTripleSlash ? cleaned.substring(8) : cleaned.substring(7);
      try {
        rest = Uri.decodeFull(rest);
      } catch (_) {}
      if (hasTripleSlash) {
        cleaned = (rest.length >= 2 && rest[1] == ':') ? rest : '/$rest';
      } else {
        cleaned = rest;
      }
    } else {
      cleaned = cleaned.replaceFirst(_lineAnchorRe, '');
    }

    // Normalize stray leading slash before a Windows drive letter (e.g. /C:/foo -> C:/foo)
    if (cleaned.length >= 3 && cleaned[0] == '/' && cleaned[2] == ':') {
      cleaned = cleaned.substring(1);
    }

    final isAbsolute = cleaned.startsWith('/') ||
        cleaned.startsWith('\\') ||
        (cleaned.length >= 2 && cleaned[1] == ':');

    if (!isAbsolute) {
      final effectiveRootId = (rootId != null && rootId.isNotEmpty)
          ? rootId
          : (state.activeRootId.isNotEmpty ? state.activeRootId : '');
      if (effectiveRootId.isNotEmpty) {
        var rel = cleaned.replaceAll('\\', '/');
        while (rel.startsWith('./')) {
          rel = rel.substring(2);
        }
        if (rel.isNotEmpty) {
          return (rootId: effectiveRootId, relPath: rel);
        }
      }
      return null;
    }

    final normTarget = cleaned.replaceAll('\\', '/');
    final normTargetLower = normTarget.toLowerCase();
    final sortedRoots = List<FileRootItem>.from(state.cachedRoots)
      ..sort((a, b) => b.path.length.compareTo(a.path.length));

    for (final root in sortedRoots) {
      var normRoot = root.path.replaceAll('\\', '/');
      while (normRoot.length > 1 && normRoot.endsWith('/') && !(normRoot.length == 3 && normRoot[1] == ':')) {
        normRoot = normRoot.substring(0, normRoot.length - 1);
      }
      final normRootLower = normRoot.toLowerCase();
      if (normTargetLower == normRootLower) {
        return (rootId: root.id, relPath: '');
      }
      final prefix = normRootLower.endsWith('/') ? normRootLower : '$normRootLower/';
      if (normTargetLower.startsWith(prefix)) {
        return (rootId: root.id, relPath: normTarget.substring(prefix.length));
      }
    }
    return null;
  }

  Future<({String rootId, String relPath})?> _resolveFileTargetWithRefresh(
    String pathOrUri, {
    String? rootId,
  }) async {
    if (state.cachedRoots.isEmpty) {
      await refreshFileRoots();
    }
    var resolved = resolveRootAndRelPath(pathOrUri, rootId: rootId);
    if (resolved == null || resolved.relPath.isEmpty) {
      await refreshFileRoots();
      resolved = resolveRootAndRelPath(pathOrUri, rootId: rootId);
    }
    return resolved;
  }

  String resolveMediaUrl(String rawPath, {String? rootId}) {
    if (state.selectedNodeId.isEmpty) return rawPath;
    return _api.buildMediaUrl(state.selectedNodeId, rawPath, rootId: rootId);
  }

  String? buildDirectMediaUrlForRoot(String rootId, String relPath) {
    if (state.selectedNodeId.isEmpty || rootId.isEmpty || relPath.isEmpty) return null;
    return _api.buildMediaUrl(state.selectedNodeId, relPath, rootId: rootId);
  }

  Map<String, String>? get mediaHeaders => _api.authHeadersForMedia();

  Future<String?> downloadFile(String pathOrUri, {String? rootId, String? filename}) async {
    try {
      final nodeId = state.selectedNodeId;
      if (nodeId.isEmpty) return '未选中节点';
      final resolved = await _resolveFileTargetWithRefresh(pathOrUri, rootId: rootId);
      if (resolved == null || resolved.relPath.isEmpty) {
        return '该文件不在当前受控工作区根目录内，无法下载';
      }
      final ticket = await _api.createDownloadTicket(nodeId, resolved.rootId, resolved.relPath);
      final dlUrl = _api.buildDownloadUrl(nodeId, ticket.ticket);
      await PlatformBridge.triggerDownload(dlUrl, filename ?? ticket.filename);
      return null;
    } on ApiException catch (e) {
      return e.message;
    } catch (e) {
      return '下载失败: $e';
    }
  }

  Future<({String? url, String? filename, String? error})> createSignedMediaUrl(
    String rawPath, {
    String? rootId,
  }) async {
    try {
      final nodeId = state.selectedNodeId;
      if (nodeId.isEmpty) return (url: null, filename: null, error: '未选中节点');
      final resolved = await _resolveFileTargetWithRefresh(rawPath, rootId: rootId);
      if (resolved == null || resolved.relPath.isEmpty) {
        return (url: null, filename: null, error: '无法为该路径签发外链票据');
      }
      final ticket = await _api.createDownloadTicket(nodeId, resolved.rootId, resolved.relPath);
      final mediaUrl = _api.buildMediaTicketUrl(nodeId, ticket.ticket);
      return (url: mediaUrl, filename: ticket.filename, error: null);
    } on ApiException catch (e) {
      return (url: null, filename: null, error: e.message);
    } catch (e) {
      return (url: null, filename: null, error: '打开媒体失败: $e');
    }
  }

  Future<String?> openMediaExternal(String rawPath, {String? rootId}) async {
    try {
      final nodeId = state.selectedNodeId;
      if (nodeId.isEmpty) return '未选中节点';
      if (_api.isWebPlatform) {
        final syncResolved = resolveRootAndRelPath(rawPath, rootId: rootId);
        if (syncResolved != null && syncResolved.relPath.isNotEmpty) {
          final directUrl = _api.buildMediaUrl(
            nodeId,
            syncResolved.relPath,
            rootId: syncResolved.rootId,
          );
          await PlatformBridge.openExternalUrl(directUrl);
          return null;
        }
      }
      final resolved = await _resolveFileTargetWithRefresh(rawPath, rootId: rootId);
      if (resolved == null || resolved.relPath.isEmpty) {
        return '无法为该路径签发外链票据';
      }
      final ticket = await _api.createDownloadTicket(nodeId, resolved.rootId, resolved.relPath);
      final mediaUrl = _api.buildMediaTicketUrl(nodeId, ticket.ticket);
      await PlatformBridge.openExternalUrl(mediaUrl);
      return null;
    } on ApiException catch (e) {
      return e.message;
    } catch (e) {
      return '打开媒体失败: $e';
    }
  }

  Future<({String? filename, String? error})> enqueueAndroidSystemDownload(
    String pathOrUri, {
    String? rootId,
    String? filename,
  }) async {
    try {
      final nodeId = state.selectedNodeId;
      if (nodeId.isEmpty) return (filename: null, error: '未选中节点');
      final resolved = await _resolveFileTargetWithRefresh(pathOrUri, rootId: rootId);
      if (resolved == null || resolved.relPath.isEmpty) {
        return (filename: null, error: '该文件不在当前受控工作区根目录内，无法下载');
      }
      final ticket = await _api.createDownloadTicket(nodeId, resolved.rootId, resolved.relPath);
      final dlUrl = _api.buildDownloadUrl(nodeId, ticket.ticket);
      final rawName = (filename != null && filename.trim().isNotEmpty)
          ? filename.trim()
          : (ticket.filename.isNotEmpty ? ticket.filename : 'download.bin');
      final mimeType = AndroidNativeBridge.inferMimeType(rawName);
      final res = await AndroidNativeBridge.enqueueSystemDownload(
        url: dlUrl,
        filename: rawName,
        mimeType: mimeType,
      );
      if (res.ok) {
        return (filename: rawName, error: null);
      }
      return (filename: null, error: res.error ?? '无法拉起系统下载器');
    } on ApiException catch (e) {
      return (filename: null, error: e.message);
    } catch (e) {
      return (filename: null, error: '下载失败: $e');
    }
  }

  Future<({DownloadedLocalFile? file, String? error, bool cancelled})> downloadFileToLocal(
    String pathOrUri, {
    String? rootId,
    String? filename,
    void Function(int received, int total)? onProgress,
    CancelToken? cancelToken,
  }) async {
    String? createdSavePath;
    try {
      final nodeId = state.selectedNodeId;
      if (nodeId.isEmpty) return (file: null, error: '未选中节点', cancelled: false);
      final resolved = await _resolveFileTargetWithRefresh(pathOrUri, rootId: rootId);
      if (cancelToken?.isCancelled == true) {
        return (file: null, error: null, cancelled: true);
      }
      if (resolved == null || resolved.relPath.isEmpty) {
        return (file: null, error: '该文件不在当前受控工作区根目录内，无法下载', cancelled: false);
      }
      final dir = await AndroidNativeBridge.getDownloadsDir();
      if (cancelToken?.isCancelled == true) {
        return (file: null, error: null, cancelled: true);
      }
      if (dir == null || dir.isEmpty) {
        return (file: null, error: '无法访问本地缓存下载目录', cancelled: false);
      }
      final ticket = await _api.createDownloadTicket(nodeId, resolved.rootId, resolved.relPath);
      if (cancelToken?.isCancelled == true) {
        return (file: null, error: null, cancelled: true);
      }
      final dlUrl = _api.buildDownloadUrl(nodeId, ticket.ticket);
      final rawName = (filename != null && filename.trim().isNotEmpty)
          ? filename.trim()
          : (ticket.filename.isNotEmpty ? ticket.filename : 'download.bin');
      final safeName = rawName.replaceAll(RegExp(r'[^a-zA-Z0-9._\-\u4e00-\u9fff]+'), '_');
      final sep = dir.endsWith('/') || dir.endsWith('\\') ? '' : '/';
      final savePath = '$dir$sep${DateTime.now().millisecondsSinceEpoch}_$safeName';
      createdSavePath = savePath;
      final bytesCount = await _api.downloadUrlToPath(
        dlUrl,
        savePath,
        onProgress: onProgress,
        cancelToken: cancelToken,
      );
      return (
        file: DownloadedLocalFile(
          path: savePath,
          filename: rawName,
          sizeBytes: bytesCount,
          mimeType: AndroidNativeBridge.inferMimeType(rawName),
        ),
        error: null,
        cancelled: false,
      );
    } on DownloadCancelledException {
      if (createdSavePath != null) {
        unawaited(PlatformBridge.deleteLocalFile(createdSavePath));
      }
      return (file: null, error: null, cancelled: true);
    } on ApiException catch (e) {
      if (createdSavePath != null) {
        unawaited(PlatformBridge.deleteLocalFile(createdSavePath));
      }
      return (file: null, error: e.message, cancelled: false);
    } catch (e) {
      if (createdSavePath != null) {
        unawaited(PlatformBridge.deleteLocalFile(createdSavePath));
      }
      if (cancelToken?.isCancelled == true) {
        return (file: null, error: null, cancelled: true);
      }
      return (file: null, error: '下载失败: $e', cancelled: false);
    }
  }
}

final hubControllerProvider = NotifierProvider<HubController, HubState>(HubController.new);

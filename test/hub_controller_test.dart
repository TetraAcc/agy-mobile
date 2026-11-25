import 'dart:async';

import 'package:agy_remote/core/config/server_config.dart';
import 'package:agy_remote/core/config/session_cache_store.dart';
import 'package:agy_remote/core/network/api_client.dart';
import 'package:agy_remote/core/network/token_store.dart';
import 'package:agy_remote/core/realtime/node_event_socket.dart';
import 'package:agy_remote/features/auth/auth_controller.dart';
import 'package:agy_remote/features/hub/hub_controller.dart';
import 'package:agy_remote/models/models.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

class FakeEventSocket implements EventSocketClient {
  final String nodeId;
  final StreamController<WsServerEvent> _events = StreamController<WsServerEvent>.broadcast();
  final StreamController<WsConnState> _states = StreamController<WsConnState>.broadcast();
  WsConnState _current = WsConnState.disconnected;
  final List<String> subscribedIds = [];
  final List<String> unsubscribedIds = [];
  int reconnectCount = 0;
  bool lastReconnectRefreshed = false;
  bool disposed = false;

  FakeEventSocket(this.nodeId);

  @override
  Stream<WsServerEvent> get events => _events.stream;

  @override
  Stream<WsConnState> get connectionStates => _states.stream;

  @override
  WsConnState get currentState => _current;

  @override
  Future<void> connect() async {
    _current = WsConnState.connected;
    _states.add(_current);
  }

  void simulateDisconnect() {
    _current = WsConnState.disconnected;
    _states.add(_current);
  }

  @override
  Future<void> reconnectNow({bool refreshToken = false}) async {
    reconnectCount += 1;
    lastReconnectRefreshed = refreshToken;
    await connect();
  }

  @override
  void subscribe(String sessionId, {int? sinceStep}) {
    subscribedIds.add(sessionId);
  }

  @override
  void unsubscribe(String sessionId) {
    unsubscribedIds.add(sessionId);
  }

  void emitEvent(WsServerEvent evt) {
    _events.add(evt);
  }

  @override
  Future<void> dispose() async {
    disposed = true;
    await _events.close();
    await _states.close();
  }
}

class FakeApiClient extends ApiClient {
  final List<String> stoppedSessions = [];
  final List<String> sentMessages = [];
  bool returnCreatedSessionId = true;
  bool appendResumeReply = false;
  int getFileRootsCalls = 0;
  List<FileRootItem> fileRoots = const [
    FileRootItem(id: 'scratch', name: 'scratch', path: r'C:\scratch'),
  ];
  List<FileRootItem>? refreshedFileRoots;
  final List<(String, String)> ticketRequests = [];
  SessionTreeData? customWinTree;
  List<HostNode>? customNodes;
  int getNodesCalls = 0;
  final List<({String nodeId, String sessionId, String content, String deliveryMode, bool interrupt})>
      modeMessages = [];
  final List<String?> sentModels = [];
  String pageActiveModel = '';
  Map<String, List<OfficialModelOption>>? fakeModelsByNode;
  List<OfficialModelOption> fakeModels = const [
    OfficialModelOption(
      id: 'gemini-4-neon-high',
      displayName: 'Gemini 4 Neon (High)',
      group: 'Gemini',
      remainingFraction: 0.82,
      isDefault: true,
    ),
    OfficialModelOption(
      id: 'claude-sonnet-5-5-medium',
      displayName: 'Claude Sonnet 5.5 (Medium)',
      group: 'Claude',
      remainingFraction: 0.48,
    ),
  ];
  bool throwNetworkErrorOnSend = false;
  bool throwGetNodesError = false;
  bool messagesIsRunning = false;
  bool failPinSession = false;
  final List<(String sessionId, bool pinned)> pinCalls = [];
  Completer<(bool, String, String)>? pendingCreateSessionCompleter;
  bool returnEmptyMessagesForNewSession = false;

  FakeApiClient()
      : super(
          serverConfig: const ServerConfig('http://127.0.0.1:8768'),
          tokenStore: MemoryTokenStore(initialAccess: 'tok'),
          isWebOverride: false,
        );

  @override
  Future<(List<HostNode>, String)> getNodes() async {
    getNodesCalls += 1;
    if (throwGetNodesError) {
      throw const ApiException(502, 'Gateway unreachable');
    }
    if (customNodes != null) {
      return (customNodes!, customNodes!.first.id);
    }
    return (
      [
        const HostNode(id: 'win', name: 'Windows PC', isOnline: true, engineAlive: true, canWrite: true, canDelete: true),
        const HostNode(id: 'deck', name: 'Steam Deck', isOnline: true, engineAlive: true, isLocal: true, canWrite: true),
      ],
      'win',
    );
  }

  @override
  Future<SessionTreeData> getSessionTree(String nodeId) async {
    if (nodeId == 'deck') {
      return const SessionTreeData(
        generalSessions: [SessionItem(id: 'deck-s1', title: 'Deck 会话', rootId: 'scratch')],
        engineAlive: true,
      );
    }
    if (customWinTree != null) {
      return customWinTree!;
    }
    return const SessionTreeData(
      projects: {
        'Demo': [SessionItem(id: 's1', title: '主会话', rootId: 'ws_1')],
      },
      generalSessions: [SessionItem(id: 's2', title: '通用会话', rootId: 'scratch')],
      engineAlive: true,
    );
  }

  @override
  Future<({bool ok, bool isPinned, String message})> setSessionPinned(
    String nodeId,
    String sessionId, {
    required bool pinned,
  }) async {
    pinCalls.add((sessionId, pinned));
    if (failPinSession) {
      throw const ApiException(500, 'Pin RPC error');
    }
    return (
      ok: true,
      isPinned: pinned,
      message: pinned ? '已置顶并同步至桌面端' : '已取消置顶并同步至桌面端',
    );
  }

  @override
  Future<SessionMessagesPage> getSessionMessages(
    String nodeId,
    String sessionId, {
    int? beforeStep,
    int limit = 60,
  }) async {
    if (beforeStep == 10) {
      return const SessionMessagesPage(
        sessionId: 's1',
        messages: [
          AgentMessage(
            stepIndex: 5,
            source: 'MODEL',
            msgType: 'PLANNER_RESPONSE',
            status: 'DONE',
            content: '历史步骤 5',
            thinking: '',
            toolCalls: [],
            timestamp: '',
          ),
        ],
        hasMore: false,
        nextBeforeStep: null,
        isRunning: false,
      );
    }
    return SessionMessagesPage(
      sessionId: sessionId,
      messages: (returnEmptyMessagesForNewSession && sessionId == 's-new')
          ? const []
          : [
              const AgentMessage(
                stepIndex: 10,
                source: 'USER_EXPLICIT',
                msgType: 'USER_INPUT',
                status: 'DONE',
                content: '第一条提问',
                thinking: '',
                toolCalls: [],
                timestamp: '',
              ),
              if (appendResumeReply)
                const AgentMessage(
                  stepIndex: 12,
                  source: 'MODEL',
                  msgType: 'PLANNER_RESPONSE',
                  status: 'DONE',
                  content: '后台期间新增回复',
                  thinking: '',
                  toolCalls: [],
                  timestamp: '',
                ),
            ],
      hasMore: sessionId == 's1',
      nextBeforeStep: sessionId == 's1' ? 10 : null,
      isRunning: messagesIsRunning,
      activeModel: pageActiveModel,
    );
  }

  @override
  Future<(bool, String, String)> createSession(
    String nodeId, {
    required String content,
    String? model,
    String mode = 'auto',
    String? workspacePath,
    String? rootId,
  }) async {
    if (pendingCreateSessionCompleter != null) {
      return pendingCreateSessionCompleter!.future;
    }
    return (true, returnCreatedSessionId ? 's-new' : '', 'created');
  }

  @override
  Future<({List<OfficialModelOption> models, String defaultModel})> getModels(String nodeId) async {
    final list = fakeModelsByNode?[nodeId] ?? fakeModels;
    final def = list.where((m) => m.isDefault).firstOrNull ?? (list.isNotEmpty ? list.first : null);
    return (
      models: list,
      defaultModel: def?.id ?? '',
    );
  }

  @override
  Future<(bool, String)> sendMessage(String nodeId, String sessionId, {required String content, String? model}) async {
    if (throwNetworkErrorOnSend) {
      throw const ApiException(502, 'Node unavailable: connection timed out');
    }
    sentMessages.add('$nodeId/$sessionId:$content');
    sentModels.add(model);
    return (true, 'ok');
  }

  @override
  Future<({bool ok, String message, bool queued, int queuePosition})> sendMessageWithMode(
    String nodeId,
    String sessionId, {
    required String content,
    String? model,
    String deliveryMode = 'queue',
    bool interrupt = false,
  }) async {
    if (throwNetworkErrorOnSend) {
      throw const ApiException(502, 'Node unavailable: connection timed out');
    }
    sentModels.add(model);
    modeMessages.add((
      nodeId: nodeId,
      sessionId: sessionId,
      content: content,
      deliveryMode: deliveryMode,
      interrupt: interrupt,
    ));
    return (ok: true, message: 'ok', queued: false, queuePosition: 0);
  }

  @override
  Future<(bool, String)> stopSession(String nodeId, String sessionId) async {
    stoppedSessions.add('$nodeId/$sessionId');
    return (true, 'stopped');
  }

  @override
  Future<QuotaData> getQuota(String nodeId) async {
    return const QuotaData(
      groups: [
        QuotaGroup(
          displayName: 'Gemini',
          buckets: [QuotaBucket(bucketId: '5h', displayName: '5h', window: '5h', remainingFraction: 0.9)],
        ),
      ],
    );
  }

  @override
  Future<List<FileRootItem>> getFileRoots(String nodeId) async {
    getFileRootsCalls += 1;
    if (getFileRootsCalls >= 2 && refreshedFileRoots != null) {
      return refreshedFileRoots!;
    }
    return fileRoots;
  }

  @override
  Future<DownloadTicket> createDownloadTicket(String nodeId, String rootId, String path) async {
    ticketRequests.add((rootId, path));
    return DownloadTicket(ticket: 't-1', expiresIn: 60, filename: path.split('/').last);
  }

  @override
  Future<SessionChangesData> getSessionChanges(
    String nodeId,
    String sessionId, {
    bool includeHunks = false,
    String? filePath,
    String scope = 'all',
    int? stepIndex,
    int? turnId,
  }) async {
    if (nodeId == 'win' && sessionId == 's1') {
      return const SessionChangesData(
        sessionId: 's1',
        totalFiles: 1,
        totalAdded: 3,
        totalRemoved: 1,
        files: [
          SessionFileChange(
            filePath: 'C:/proj/ch1.md',
            fileName: 'ch1.md',
            directory: 'C:/proj',
            addedLines: 3,
            removedLines: 1,
            editCount: 1,
            lastStepIndex: 10,
          ),
        ],
      );
    }
    return SessionChangesData(sessionId: sessionId);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/url_launcher'),
      (call) async => true,
    );
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/url_launcher'),
      null,
    );
  });

  test('HubController 初始化、WS 会话隔离、分页、停止与切节点', () async {
    final fakeApi = FakeApiClient();
    final createdSockets = <String, FakeEventSocket>{};

    final container = ProviderContainer(
      overrides: [
        apiClientProvider.overrideWithValue(fakeApi),
        tokenStoreProvider.overrideWithValue(MemoryTokenStore(initialAccess: 'tok')),
        eventSocketFactoryProvider.overrideWithValue(({
          required ServerConfig serverConfig,
          required String nodeId,
          required TokenStore tokenStore,
          Future<bool> Function()? onRefreshAuth,
        }) {
          final sock = FakeEventSocket(nodeId);
          createdSockets[nodeId] = sock;
          return sock;
        }),
      ],
    );
    addTearDown(container.dispose);

    final user = const UserProfile(
      id: 1,
      username: 'tetra',
      displayName: 'Tetra',
      role: 'admin',
      defaultNode: 'win',
      allowedNodes: ['win', 'deck'],
      nodePermissions: {
        'win': UserPermissionGrant(nodeId: 'win', canWrite: true, canDelete: true),
        'deck': UserPermissionGrant(nodeId: 'deck', canWrite: true, canDelete: false),
      },
    );

    final hub = container.read(hubControllerProvider.notifier);
    await hub.initializeForUser(user);
    await Future<void>.delayed(Duration.zero);

    var state = container.read(hubControllerProvider);
    expect(state.selectedNodeId, 'win');
    expect(state.activeSessionId, 's1');
    expect(state.messages.length, 1);
    expect(state.sessionChanges.totalFiles, 1);
    expect(createdSockets['win']?.subscribedIds, contains('s1'));

    // 发消息触发乐观更新并标记运行态
    await hub.sendMessage('新问题');
    state = container.read(hubControllerProvider);
    expect(state.messages.length, 2);
    expect(state.isActiveSessionRunning, true);

    // 收到另一会话 s2 的事件时，绝不污染 s1 的 messages
    createdSockets['win']!.emitEvent(
      const WsStepUpsertEvent(
        sessionId: 's2',
        step: AgentMessage(
          stepIndex: 99,
          source: 'MODEL',
          msgType: 'PLANNER_RESPONSE',
          status: 'DONE',
          content: '串屏消息',
          thinking: '',
          toolCalls: [],
          timestamp: '',
        ),
        isRunning: true,
      ),
    );
    await Future<void>.delayed(Duration.zero);
    state = container.read(hubControllerProvider);
    expect(state.messages.any((m) => m.content == '串屏消息'), false);
    expect(state.runningSessionIds.contains('s2'), true);

    // 收到当前会话 s1 的回复事件
    createdSockets['win']!.emitEvent(
      const WsStepUpsertEvent(
        sessionId: 's1',
        step: AgentMessage(
          stepIndex: 11,
          source: 'MODEL',
          msgType: 'PLANNER_RESPONSE',
          status: 'DONE',
          content: '当前会话新回复',
          thinking: '',
          toolCalls: [],
          timestamp: '',
        ),
        isRunning: true,
      ),
    );
    await Future<void>.delayed(Duration.zero);
    state = container.read(hubControllerProvider);
    expect(state.messages.last.content, '当前会话新回复');

    // 真实停止当前任务
    await hub.stopActiveSession();
    state = container.read(hubControllerProvider);
    expect(fakeApi.stoppedSessions, contains('win/s1'));
    expect(state.isActiveSessionRunning, false);

    // 加载更早分页消息
    await hub.loadEarlierMessages();
    state = container.read(hubControllerProvider);
    expect(state.messages.first.stepIndex, 5);
    expect(state.hasMoreMessages, false);

    // 含 % 的相对路径及绝对 URI 路径解析不会抛出 FormatException/ArgumentError
    final relWithPercent = hub.resolveRootAndRelPath(
      '微处理器讲义/讲义_100%_笔记.pdf',
      rootId: 'ws_1',
    );
    expect(relWithPercent?.rootId, 'ws_1');
    expect(relWithPercent?.relPath, '微处理器讲义/讲义_100%_笔记.pdf');

    // URL 编码冒号 + 行号锚点（如 file:///c%3A/scratch/AGENTS.md#L1-L20）应正确解析
    final encodedDriveUri = hub.resolveRootAndRelPath(
      'file:///c%3A/scratch/AGENTS.md#L1-L20',
    );
    expect(encodedDriveUri?.rootId, 'scratch');
    expect(encodedDriveUri?.relPath, 'AGENTS.md');

    // 裸相对路径与 ./ 前缀在未显式传 rootId 时应回退到当前会话的 activeRootId (ws_1)
    final bareRel = hub.resolveRootAndRelPath('AGENTS.md');
    expect(bareRel?.rootId, 'ws_1');
    expect(bareRel?.relPath, 'AGENTS.md');
    final dotRel = hub.resolveRootAndRelPath('./docs/AGENTS.md#L10');
    expect(dotRel?.rootId, 'ws_1');
    expect(dotRel?.relPath, 'docs/AGENTS.md');

    // 当 cachedRoots 过期缺少新工作区时，downloadFile 应自动刷新 roots 并重试成功
    fakeApi.refreshedFileRoots = const [
      FileRootItem(id: 'scratch', name: 'scratch', path: r'C:\scratch'),
      FileRootItem(id: 'ws_novel', name: 'novel', path: r'D:\Writing\Novel'),
    ];
    final dlErr = await hub.downloadFile('file:///D:/Writing/Novel/AGENTS.md#L1-L30');
    expect(dlErr, isNull);
    expect(fakeApi.ticketRequests.last, ('ws_novel', 'AGENTS.md'));

    // 切换节点释放旧 WS 并接入 deck
    await hub.switchNode('deck');
    state = container.read(hubControllerProvider);
    expect(createdSockets['win']!.disposed, true);
    expect(state.selectedNodeId, 'deck');
    expect(state.activeSessionId, 'deck-s1');

    // 模拟切后台断线后恢复前台：立即重连 WS 并静默合入新消息
    fakeApi.appendResumeReply = true;
    createdSockets['deck']!.simulateDisconnect();
    hub.handleAppPaused();
    await hub.handleAppResumed();
    state = container.read(hubControllerProvider);
    expect(createdSockets['deck']!.reconnectCount, 1);
    expect(createdSockets['deck']!.currentState, WsConnState.connected);
    expect(state.messages.any((m) => m.content == '后台期间新增回复'), true);

    // 模拟后台期间任务执行中 -> 完成的状态流转安全触发
    hub.handleAppPaused();
    createdSockets['deck']!.emitEvent(
      const WsSessionStatusEvent(sessionId: 'deck-s1', isRunning: true),
    );
    await Future<void>.delayed(Duration.zero);
    createdSockets['deck']!.emitEvent(
      const WsSessionStatusEvent(sessionId: 'deck-s1', isRunning: false),
    );
    await Future<void>.delayed(Duration.zero);
    expect(container.read(hubControllerProvider).isActiveSessionRunning, false);
    await hub.handleAppResumed();
  });

  test('HubController.enqueueAndroidSystemDownload 刷新根目录并拉起系统下载器', () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    addTearDown(() => debugDefaultTargetPlatformOverride = null);

    final nativeCalls = <MethodCall>[];
    const nativeChannel = MethodChannel('com.tetra.agyremote/android_native');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
      nativeChannel,
      (call) async {
        nativeCalls.add(call);
        if (call.method == 'enqueueSystemDownload') {
          return <String, Object?>{'ok': true, 'id': 101, 'filename': 'AGENTS.md'};
        }
        return null;
      },
    );
    addTearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
        nativeChannel,
        null,
      );
    });

    final fakeApi = FakeApiClient();
    fakeApi.refreshedFileRoots = const [
      FileRootItem(id: 'scratch', name: 'scratch', path: r'C:\scratch'),
      FileRootItem(id: 'ws_novel', name: 'novel', path: r'D:\Writing\Novel'),
    ];

    final container = ProviderContainer(
      overrides: [
        apiClientProvider.overrideWithValue(fakeApi),
        tokenStoreProvider.overrideWithValue(MemoryTokenStore(initialAccess: 'tok')),
        eventSocketFactoryProvider.overrideWithValue(({
          required ServerConfig serverConfig,
          required String nodeId,
          required TokenStore tokenStore,
          Future<bool> Function()? onRefreshAuth,
        }) {
          return FakeEventSocket(nodeId);
        }),
      ],
    );
    addTearDown(container.dispose);

    const user = UserProfile(
      id: 1,
      username: 'tetra',
      displayName: 'Tetra',
      role: 'admin',
      defaultNode: 'win',
      allowedNodes: ['win'],
      nodePermissions: {
        'win': UserPermissionGrant(nodeId: 'win', canWrite: true, canDelete: true),
      },
    );

    final hub = container.read(hubControllerProvider.notifier);
    await hub.initializeForUser(user);
    await Future<void>.delayed(Duration.zero);

    final res = await hub.enqueueAndroidSystemDownload('file:///D:/Writing/Novel/AGENTS.md#L1-L20');
    expect(res.error, isNull);
    expect(res.filename, 'AGENTS.md');
    expect(fakeApi.getFileRootsCalls, greaterThanOrEqualTo(2));
    expect(fakeApi.ticketRequests.last, ('ws_novel', 'AGENTS.md'));

    final dlCall = nativeCalls.lastWhere((c) => c.method == 'enqueueSystemDownload');
    final args = Map<Object?, Object?>.from(dlCall.arguments as Map);
    expect(
      args['url'].toString(),
      contains('/api/v2/nodes/win/files/download?ticket='),
    );
    expect(args['filename'], 'AGENTS.md');
    expect(args['mimeType'], 'text/markdown');
  });

  test('HubController 进入应用优先打开正在运行的对话，无运行中则打开最近修改的活跃对话', () async {
    const user = UserProfile(
      id: 1,
      username: 'tetra',
      displayName: 'Tetra',
      role: 'admin',
      defaultNode: 'win',
      allowedNodes: ['win'],
      nodePermissions: {
        'win': UserPermissionGrant(nodeId: 'win', canWrite: true, canDelete: true),
      },
    );

    // 场景 1：通用会话里有一条正在运行的任务，即使项目列表排在前面也优先打开运行中对话
    final fakeApi1 = FakeApiClient()
      ..customWinTree = const SessionTreeData(
        projects: {
          'Novel': [
            SessionItem(
              id: 'p-pinned',
              title: '置顶旧章节',
              isPinned: true,
              lastModified: '2026-11-23T22:50:00Z',
            ),
          ],
        },
        generalSessions: [
          SessionItem(
            id: 'g-running',
            title: '后台正在生成的章节',
            isRunning: true,
            lastModified: '2026-11-23T21:00:00Z',
          ),
        ],
        runningSessionIds: {'g-running'},
        engineAlive: true,
      );

    final c1 = ProviderContainer(
      overrides: [
        apiClientProvider.overrideWithValue(fakeApi1),
        tokenStoreProvider.overrideWithValue(MemoryTokenStore(initialAccess: 'tok')),
        eventSocketFactoryProvider.overrideWithValue(({
          required ServerConfig serverConfig,
          required String nodeId,
          required TokenStore tokenStore,
          Future<bool> Function()? onRefreshAuth,
        }) =>
            FakeEventSocket(nodeId)),
      ],
    );
    addTearDown(c1.dispose);

    await c1.read(hubControllerProvider.notifier).initializeForUser(user);
    await Future<void>.delayed(Duration.zero);
    expect(c1.read(hubControllerProvider).activeSessionId, 'g-running');

    // 场景 2：无运行中任务时，跨项目与置顶顺序，优先打开 lastModified 最新的活跃对话
    final fakeApi2 = FakeApiClient()
      ..customWinTree = const SessionTreeData(
        projects: {
          'Novel': [
            SessionItem(
              id: 'p-old-pinned',
              title: '十天前置顶的大纲',
              isPinned: true,
              lastModified: '2026-11-10T08:00:00Z',
            ),
            SessionItem(
              id: 'p-recent',
              title: '五分钟前修改的第五章',
              isPinned: false,
              lastModified: '2026-11-23T23:05:00Z',
            ),
          ],
        },
        generalSessions: [
          SessionItem(
            id: 'g-latest',
            title: '刚刚在聊的通用会话',
            isPinned: false,
            lastModified: '2026-11-23T23:10:00Z',
          ),
        ],
        engineAlive: true,
      );

    final c2 = ProviderContainer(
      overrides: [
        apiClientProvider.overrideWithValue(fakeApi2),
        tokenStoreProvider.overrideWithValue(MemoryTokenStore(initialAccess: 'tok')),
        eventSocketFactoryProvider.overrideWithValue(({
          required ServerConfig serverConfig,
          required String nodeId,
          required TokenStore tokenStore,
          Future<bool> Function()? onRefreshAuth,
        }) =>
            FakeEventSocket(nodeId)),
      ],
    );
    addTearDown(c2.dispose);

    await c2.read(hubControllerProvider.notifier).initializeForUser(user);
    await Future<void>.delayed(Duration.zero);
    expect(c2.read(hubControllerProvider).activeSessionId, 'g-latest');
  });

  test('HubController 切换缓存离线节点前自动实时重探，上线后直接放行无需重登', () async {
    SharedPreferences.setMockInitialValues({'v2_selected_node': 'deck'});
    final createdSockets = <String, FakeEventSocket>{};
    final fakeApi = FakeApiClient()
      ..customNodes = const [
        HostNode(id: 'win', name: 'Windows PC', isOnline: false, engineAlive: false, canWrite: true),
        HostNode(id: 'deck', name: 'Steam Deck', isOnline: true, engineAlive: true, isLocal: true, canWrite: true),
      ];

    final container = ProviderContainer(
      overrides: [
        apiClientProvider.overrideWithValue(fakeApi),
        tokenStoreProvider.overrideWithValue(MemoryTokenStore(initialAccess: 'tok')),
        eventSocketFactoryProvider.overrideWithValue(({
          required ServerConfig serverConfig,
          required String nodeId,
          required TokenStore tokenStore,
          Future<bool> Function()? onRefreshAuth,
        }) {
          final sock = FakeEventSocket(nodeId);
          createdSockets[nodeId] = sock;
          return sock;
        }),
      ],
    );
    addTearDown(container.dispose);

    const user = UserProfile(
      id: 1,
      username: 'tetra',
      displayName: 'Tetra',
      role: 'admin',
      defaultNode: 'win',
      allowedNodes: ['win', 'deck'],
      nodePermissions: {
        'win': UserPermissionGrant(nodeId: 'win', canWrite: true, canDelete: true),
        'deck': UserPermissionGrant(nodeId: 'deck', canWrite: true, canDelete: true),
      },
    );

    final hub = container.read(hubControllerProvider.notifier);
    await hub.initializeForUser(user);
    await Future<void>.delayed(Duration.zero);

    expect(container.read(hubControllerProvider).selectedNodeId, 'deck');
    expect(
      container.read(hubControllerProvider).nodes.firstWhere((n) => n.id == 'win').isOnline,
      false,
    );
    final initialCalls = fakeApi.getNodesCalls;

    // 远端尚未重启完成时，会先实时重探后再提示离线
    final stillOfflineErr = await hub.switchNode('win');
    expect(stillOfflineErr, contains('离线'));
    expect(fakeApi.getNodesCalls, initialCalls + 1);

    // 模拟 Windows 重启后重新连上网关，此时前端 state.nodes 仍缓存着旧的 isOnline=false
    fakeApi.customNodes = const [
      HostNode(id: 'win', name: 'Windows PC', isOnline: true, engineAlive: true, canWrite: true),
      HostNode(id: 'deck', name: 'Steam Deck', isOnline: true, engineAlive: true, isLocal: true, canWrite: true),
    ];

    // 直接切换节点应自动重探并放行，无需退出重新登录
    final switchErr = await hub.switchNode('win');
    expect(switchErr, isNull);
    final stateAfterSwitch = container.read(hubControllerProvider);
    expect(stateAfterSwitch.selectedNodeId, 'win');
    expect(stateAfterSwitch.nodes.firstWhere((n) => n.id == 'win').isOnline, true);
    expect(fakeApi.getNodesCalls, greaterThanOrEqualTo(initialCalls + 2));

    // 模拟 WS 断线后自动重连，节点状态应自动刷新（如 deck 下线）
    fakeApi.customNodes = const [
      HostNode(id: 'win', name: 'Windows PC', isOnline: true, engineAlive: true, canWrite: true),
      HostNode(id: 'deck', name: 'Steam Deck', isOnline: false, engineAlive: false, isLocal: true, canWrite: true),
    ];
    final callsBeforeReconnect = fakeApi.getNodesCalls;
    createdSockets['win']!.simulateDisconnect();
    await Future<void>.delayed(Duration.zero);
    await createdSockets['win']!.connect();
    await Future<void>.delayed(Duration.zero);

    expect(fakeApi.getNodesCalls, greaterThan(callsBeforeReconnect));
    expect(
      container.read(hubControllerProvider).nodes.firstWhere((n) => n.id == 'deck').isOnline,
      false,
    );
  });

  test('HubController ask_question 交互回复走 immediate+interrupt 直发，不进队列', () async {
    final createdSockets = <String, FakeEventSocket>{};
    final fakeApi = FakeApiClient()
      ..messagesIsRunning = true
      ..customWinTree = const SessionTreeData(
        generalSessions: [
          SessionItem(id: 's-run', title: '交互等待会话', isRunning: true),
        ],
        runningSessionIds: {'s-run'},
        engineAlive: true,
      );

    final container = ProviderContainer(
      overrides: [
        apiClientProvider.overrideWithValue(fakeApi),
        tokenStoreProvider.overrideWithValue(MemoryTokenStore(initialAccess: 'tok')),
        eventSocketFactoryProvider.overrideWithValue(({
          required ServerConfig serverConfig,
          required String nodeId,
          required TokenStore tokenStore,
          Future<bool> Function()? onRefreshAuth,
        }) {
          final sock = FakeEventSocket(nodeId);
          createdSockets[nodeId] = sock;
          return sock;
        }),
      ],
    );
    addTearDown(container.dispose);

    const user = UserProfile(
      id: 1,
      username: 'tetra',
      displayName: 'Tetra',
      role: 'admin',
      defaultNode: 'win',
      allowedNodes: ['win'],
      nodePermissions: {
        'win': UserPermissionGrant(nodeId: 'win', canWrite: true, canDelete: true),
      },
    );

    final hub = container.read(hubControllerProvider.notifier);
    await hub.initializeForUser(user);
    await Future<void>.delayed(Duration.zero);

    expect(container.read(hubControllerProvider).isActiveSessionRunning, true);

    final err = await hub.sendMessage(
      '[选择回复]\n1. 测试方案\n   选择: 方案 A',
      deliveryMode: 'immediate',
      interrupt: true,
    );
    expect(err, isNull);
    expect(fakeApi.modeMessages.length, 1);
    expect(fakeApi.modeMessages.first.deliveryMode, 'immediate');
    expect(fakeApi.modeMessages.first.interrupt, true);
    expect(fakeApi.modeMessages.first.content, contains('[选择回复]'));
  });

  test('HubController 弱网发送纯文本自动离线暂存并在 WS 重连后按序补发清空', () async {
    final createdSockets = <String, FakeEventSocket>{};
    final fakeApi = FakeApiClient();

    final container = ProviderContainer(
      overrides: [
        apiClientProvider.overrideWithValue(fakeApi),
        tokenStoreProvider.overrideWithValue(MemoryTokenStore(initialAccess: 'tok')),
        eventSocketFactoryProvider.overrideWithValue(({
          required ServerConfig serverConfig,
          required String nodeId,
          required TokenStore tokenStore,
          Future<bool> Function()? onRefreshAuth,
        }) {
          final sock = FakeEventSocket(nodeId);
          createdSockets[nodeId] = sock;
          return sock;
        }),
      ],
    );
    addTearDown(container.dispose);

    const user = UserProfile(
      id: 1,
      username: 'tetra',
      displayName: 'Tetra',
      role: 'admin',
      defaultNode: 'win',
      allowedNodes: ['win'],
      nodePermissions: {
        'win': UserPermissionGrant(nodeId: 'win', canWrite: true, canDelete: true),
      },
    );

    final hub = container.read(hubControllerProvider.notifier);
    await hub.initializeForUser(user);
    await Future<void>.delayed(Duration.zero);

    // 1. 断网 / 502 发送纯文本消息，不丢失、不阻塞且不留下假已发用户气泡
    fakeApi.throwNetworkErrorOnSend = true;
    final sendErr = await hub.sendMessage('地铁里发的第一条离线指令');
    expect(sendErr, isNull);

    var curState = container.read(hubControllerProvider);
    expect(curState.activeSessionOutbox.length, 1);
    expect(curState.activeSessionOutbox.first.content, '地铁里发的第一条离线指令');
    expect(curState.messages.any((m) => m.content == '地铁里发的第一条离线指令'), false);

    // 2. 支持编辑离线暂存条目
    final outboxId = curState.activeSessionOutbox.first.id;
    await hub.editOfflineOutboxItem(outboxId, '改好的离线补发指令');
    expect(container.read(hubControllerProvider).activeSessionOutbox.first.content, '改好的离线补发指令');

    // 3. 恢复网络并触发 WS 重连，自动补发并清空待发区
    fakeApi.throwNetworkErrorOnSend = false;
    createdSockets['win']!.simulateDisconnect();
    await Future<void>.delayed(Duration.zero);
    await createdSockets['win']!.connect();
    await Future<void>.delayed(Duration.zero);

    curState = container.read(hubControllerProvider);
    expect(curState.activeSessionOutbox, isEmpty);
    expect(fakeApi.modeMessages.any((m) => m.content == '改好的离线补发指令'), true);
  });

  test('HubController 自动识别会话当前模型、默认不覆写，手动切换后透传模型并在新回复同步清空', () async {
    final fakeApi = FakeApiClient()..pageActiveModel = 'gemini-4-neon-high';
    final createdSockets = <String, FakeEventSocket>{};

    final container = ProviderContainer(
      overrides: [
        apiClientProvider.overrideWithValue(fakeApi),
        tokenStoreProvider.overrideWithValue(MemoryTokenStore(initialAccess: 'tok')),
        eventSocketFactoryProvider.overrideWithValue(({
          required ServerConfig serverConfig,
          required String nodeId,
          required TokenStore tokenStore,
          Future<bool> Function()? onRefreshAuth,
        }) {
          final sock = FakeEventSocket(nodeId);
          createdSockets[nodeId] = sock;
          return sock;
        }),
      ],
    );
    addTearDown(container.dispose);

    const user = UserProfile(
      id: 1,
      username: 'tetra',
      displayName: 'Tetra',
      role: 'admin',
      defaultNode: 'win',
      allowedNodes: ['win'],
      nodePermissions: {
        'win': UserPermissionGrant(nodeId: 'win', canWrite: true, canDelete: true),
      },
    );

    final hub = container.read(hubControllerProvider.notifier);
    await hub.initializeForUser(user);
    await Future<void>.delayed(Duration.zero);

    var state = container.read(hubControllerProvider);
    expect(state.availableModels.length, 2);
    expect(state.activeSessionModel, 'gemini-4-neon-high');
    expect(state.hasPendingModelSwitch, false);

    // 1. 未手动切换时发送消息，model 为 null（保持会话原模型，不误覆盖）
    final err1 = await hub.sendMessage('继续沿用原模型', deliveryMode: 'immediate');
    expect(err1, isNull);
    expect(fakeApi.sentModels.last, isNull);

    // 2. 手动选择切换为 claude-sonnet-5-5-medium，下一条发送携带该 model
    hub.setSessionPendingModel('claude-sonnet-5-5-medium');
    state = container.read(hubControllerProvider);
    expect(state.hasPendingModelSwitch, true);
    expect(state.effectiveSessionModel, 'claude-sonnet-5-5-medium');

    final err2 = await hub.sendMessage('切到 Claude 回复', deliveryMode: 'immediate');
    expect(err2, isNull);
    expect(fakeApi.sentModels.last, 'claude-sonnet-5-5-medium');

    // 3. 收到新模型回复的 WS 事件后，activeSessionModel 更新为新模型并清空待切换标记
    createdSockets['win']!.emitEvent(
      const WsStepUpsertEvent(
        sessionId: 's1',
        isRunning: false,
        step: AgentMessage(
          stepIndex: 11,
          source: 'MODEL',
          msgType: 'PLANNER_RESPONSE',
          status: 'DONE',
          content: '已用 Claude 回复',
          thinking: '',
          toolCalls: [],
          timestamp: '2026-11-25T04:00:00Z',
          model: 'claude-sonnet-5-5-medium',
        ),
      ),
    );
    await Future<void>.delayed(Duration.zero);

    state = container.read(hubControllerProvider);
    expect(state.activeSessionModel, 'claude-sonnet-5-5-medium');
    expect(state.pendingSwitchModel, isEmpty);
    expect(state.hasPendingModelSwitch, false);
  });

  test('HubController 冷启动秒开本地缓存对话并在断联时支持离线只读浏览', () async {
    // 1. 预先写入缓存（模拟上次正常使用后退出）
    await SessionCacheStore.saveNodes(
      const [HostNode(id: 'win', name: 'Windows PC', isOnline: true, engineAlive: true, canWrite: true)],
      selectedNodeId: 'win',
    );
    await SessionCacheStore.saveSessionTree(
      'win',
      {
        'Demo': const [
          SessionItem(id: 's1', title: '缓存主会话', rootId: 'ws_1'),
          SessionItem(id: 's2', title: '缓存次会话', rootId: 'scratch'),
        ],
      },
      const [],
    );
    await SessionCacheStore.saveSessionMessages(
      nodeId: 'win',
      sessionId: 's1',
      title: '缓存主会话',
      rootId: 'ws_1',
      activeModel: 'gemini-4-neon-high',
      messages: const [
        AgentMessage(
          stepIndex: 10,
          source: 'USER_EXPLICIT',
          msgType: 'USER_INPUT',
          status: 'DONE',
          content: '上次断联前的缓存提问',
          thinking: '',
          toolCalls: [],
          timestamp: '',
        ),
        AgentMessage(
          stepIndex: 11,
          source: 'MODEL',
          msgType: 'PLANNER_RESPONSE',
          status: 'DONE',
          content: '上次断联前的缓存回答',
          thinking: '',
          toolCalls: [],
          timestamp: '',
          model: 'gemini-4-neon-high',
        ),
      ],
    );

    // 2. 断网冷启动（getNodes 直接抛错）
    final offlineApi = FakeApiClient()..throwGetNodesError = true;
    final containerOffline = ProviderContainer(
      overrides: [
        apiClientProvider.overrideWithValue(offlineApi),
        tokenStoreProvider.overrideWithValue(MemoryTokenStore(initialAccess: 'tok')),
        eventSocketFactoryProvider.overrideWithValue(({
          required ServerConfig serverConfig,
          required String nodeId,
          required TokenStore tokenStore,
          Future<bool> Function()? onRefreshAuth,
        }) => FakeEventSocket(nodeId)),
      ],
    );
    addTearDown(containerOffline.dispose);

    const user = UserProfile(
      id: 1,
      username: 'tetra',
      displayName: 'Tetra',
      role: 'admin',
      defaultNode: 'win',
      allowedNodes: ['win'],
      nodePermissions: {
        'win': UserPermissionGrant(nodeId: 'win', canWrite: true, canDelete: true),
      },
    );

    await containerOffline.read(hubControllerProvider.notifier).initializeForUser(user);
    final offlineState = containerOffline.read(hubControllerProvider);
    expect(offlineState.isInitializing, false);
    expect(offlineState.selectedNodeId, 'win');
    expect(offlineState.activeSessionId, 's1');
    expect(offlineState.activeSessionTitle, '缓存主会话');
    expect(offlineState.isShowingCachedData, true);
    expect(offlineState.activeSessionModel, 'gemini-4-neon-high');
    expect(offlineState.messages.any((m) => m.content == '上次断联前的缓存回答'), true);
    expect(offlineState.projects['Demo']?.length, 2);

    // 3. 恢复联网后启动：冷启动命中缓存，随即无感刷新为在线最新数据并清除缓存横幅
    final onlineApi = FakeApiClient()..appendResumeReply = true;
    final containerOnline = ProviderContainer(
      overrides: [
        apiClientProvider.overrideWithValue(onlineApi),
        tokenStoreProvider.overrideWithValue(MemoryTokenStore(initialAccess: 'tok')),
        eventSocketFactoryProvider.overrideWithValue(({
          required ServerConfig serverConfig,
          required String nodeId,
          required TokenStore tokenStore,
          Future<bool> Function()? onRefreshAuth,
        }) => FakeEventSocket(nodeId)),
      ],
    );
    addTearDown(containerOnline.dispose);

    await containerOnline.read(hubControllerProvider.notifier).initializeForUser(user);
    await Future<void>.delayed(Duration.zero);
    final onlineState = containerOnline.read(hubControllerProvider);
    expect(onlineState.isInitializing, false);
    expect(onlineState.isShowingCachedData, false);
    expect(onlineState.messages.any((m) => m.content == '后台期间新增回复'), true);
  });

  test('HubController.toggleSessionPin 支持乐观置顶、排序并在失败时回滚', () async {
    final fakeApi = FakeApiClient()
      ..customWinTree = const SessionTreeData(
        projects: {
          'Demo': [
            SessionItem(id: 's1', title: '普通会话1', isPinned: false),
            SessionItem(id: 's2', title: '普通会话2', isPinned: false),
          ],
        },
        generalSessions: [SessionItem(id: 'g1', title: '通用会话', isPinned: false)],
        engineAlive: true,
      );

    final container = ProviderContainer(
      overrides: [
        apiClientProvider.overrideWithValue(fakeApi),
        tokenStoreProvider.overrideWithValue(MemoryTokenStore(initialAccess: 'tok')),
        eventSocketFactoryProvider.overrideWithValue(({
          required ServerConfig serverConfig,
          required String nodeId,
          required TokenStore tokenStore,
          Future<bool> Function()? onRefreshAuth,
        }) => FakeEventSocket(nodeId)),
      ],
    );
    addTearDown(container.dispose);

    const user = UserProfile(
      id: 1,
      username: 'tetra',
      displayName: 'Tetra',
      role: 'admin',
      defaultNode: 'win',
      allowedNodes: ['win'],
      nodePermissions: {
        'win': UserPermissionGrant(nodeId: 'win', canWrite: true, canDelete: true),
      },
    );

    final hub = container.read(hubControllerProvider.notifier);
    await hub.initializeForUser(user);
    await Future<void>.delayed(Duration.zero);

    // 1. 置顶项目下第二个会话 s2，应变为 isPinned=true 且自动排到 Demo 第一位
    final resOk = await hub.toggleSessionPin(
      const SessionItem(id: 's2', title: '普通会话2', isPinned: false),
    );
    expect(resOk.error, isNull);
    expect(resOk.isPinned, true);
    expect(fakeApi.pinCalls.last, ('s2', true));

    // refreshSessionTree 异步对齐前检查缓存树和状态（或自定义 tree 对齐）
    final curItems = container.read(hubControllerProvider).projects['Demo']!;
    expect(curItems.first.id, 's2');
    expect(curItems.first.isPinned, true);

    // 2. 接口失败时应回滚状态
    fakeApi.failPinSession = true;
    final resFail = await hub.toggleSessionPin(
      const SessionItem(id: 's1', title: '普通会话1', isPinned: false),
    );
    expect(resFail.error, isNotNull);
    final afterRollback = container.read(hubControllerProvider).projects['Demo']!;
    expect(afterRollback.firstWhere((e) => e.id == 's1').isPinned, false);
  });

  test('HubController.createNewSession 0ms 乐观切入新对话并保活用户提问与侧边栏占位，失败自动回滚', () async {
    final completer1 = Completer<(bool, String, String)>();
    final fakeApi = FakeApiClient()
      ..pendingCreateSessionCompleter = completer1
      ..returnEmptyMessagesForNewSession = true;
    final createdSockets = <String, FakeEventSocket>{};

    final container = ProviderContainer(
      overrides: [
        apiClientProvider.overrideWithValue(fakeApi),
        tokenStoreProvider.overrideWithValue(MemoryTokenStore(initialAccess: 'tok')),
        eventSocketFactoryProvider.overrideWithValue(({
          required ServerConfig serverConfig,
          required String nodeId,
          required TokenStore tokenStore,
          Future<bool> Function()? onRefreshAuth,
        }) {
          final sock = FakeEventSocket(nodeId);
          createdSockets[nodeId] = sock;
          return sock;
        }),
      ],
    );
    addTearDown(container.dispose);

    const user = UserProfile(
      id: 1,
      username: 'tetra',
      displayName: 'Tetra',
      role: 'admin',
      defaultNode: 'win',
      allowedNodes: ['win'],
      nodePermissions: {
        'win': UserPermissionGrant(nodeId: 'win', canWrite: true, canDelete: true),
      },
    );

    final hub = container.read(hubControllerProvider.notifier);
    await hub.initializeForUser(user);
    await Future<void>.delayed(Duration.zero);
    expect(container.read(hubControllerProvider).activeSessionId, 's1');

    // 1. 发起新建会话：即使后端请求仍在飞，界面已经 0ms 切入新会话视图并显示提问气泡与思考中状态
    final createFuture = hub.createNewSession(
      content: '这是一个很长很需要立即给出创建反馈的新问题',
      mode: 'auto',
      model: 'gemini-4-neon-high',
    );

    var cur = container.read(hubControllerProvider);
    expect(cur.isCreatingSession, true);
    expect(cur.isActiveSessionRunning, true);
    expect(cur.activeSessionTitle, '这是一个很长很需要立即给出创建反馈的新问题');
    expect(cur.messages.length, 1);
    expect(cur.messages.first.isUser, true);
    expect(cur.messages.first.content, '这是一个很长很需要立即给出创建反馈的新问题');

    // 2. 后端返回 s-new，此时 getSessionMessages 仍返回空列表 []：
    //    必须保留乐观用户提问气泡与 running 状态，立即订阅 WS，并在侧边栏可见 s-new
    completer1.complete((true, 's-new', 'created'));
    final err1 = await createFuture;
    expect(err1, isNull);
    await Future<void>.delayed(Duration.zero);

    cur = container.read(hubControllerProvider);
    expect(cur.isCreatingSession, false);
    expect(cur.activeSessionId, 's-new');
    expect(cur.isActiveSessionRunning, true);
    expect(cur.messages.length, 1);
    expect(cur.messages.first.content, '这是一个很长很需要立即给出创建反馈的新问题');
    expect(cur.generalSessions.any((s) => s.id == 's-new'), true);
    expect(createdSockets['win']!.subscribedIds.contains('s-new'), true);

    // 3. 当后端创建失败时，干净回滚到创建前会话 s-new
    final completer2 = Completer<(bool, String, String)>();
    fakeApi.pendingCreateSessionCompleter = completer2;
    final failFuture = hub.createNewSession(
      content: '失败测试问题',
      mode: 'auto',
      model: 'gemini-4-neon-high',
    );
    expect(container.read(hubControllerProvider).isCreatingSession, true);
    completer2.complete((false, '', 'Antigravity 未运行'));
    final err2 = await failFuture;
    expect(err2, 'Antigravity 未运行');

    cur = container.read(hubControllerProvider);
    expect(cur.isCreatingSession, false);
    expect(cur.activeSessionId, 's-new');
  });

  test('HubController 切换节点时按节点隔离模型目录且不残留前序节点独占模型', () async {
    final winModels = [
      const OfficialModelOption(
        id: 'gemini-4-neon-high',
        displayName: 'Gemini 4 Neon (High)',
        group: 'Gemini',
        isDefault: true,
      ),
      const OfficialModelOption(
        id: 'claude-sonnet-5-5-medium',
        displayName: 'Claude Sonnet 5.5 (Medium)',
        group: 'Claude',
      ),
    ];
    final deckModels = [
      const OfficialModelOption(
        id: 'gemini-4-hydrogen-high',
        displayName: 'Gemini 4 Hydrogen (High)',
        group: 'Gemini',
        isDefault: true,
      ),
      const OfficialModelOption(
        id: 'gemini-3.8-flash-medium',
        displayName: 'Gemini 3.8 Flash (Medium)',
        group: 'Gemini',
      ),
      const OfficialModelOption(
        id: 'claude-sonnet-4-6',
        displayName: 'Claude Sonnet 4.6 (Thinking)',
        group: 'Claude',
      ),
    ];

    final fakeApi = FakeApiClient()
      ..fakeModelsByNode = {
        'win': winModels,
        'deck': deckModels,
      };

    final container = ProviderContainer(
      overrides: [
        apiClientProvider.overrideWithValue(fakeApi),
        tokenStoreProvider.overrideWithValue(MemoryTokenStore(initialAccess: 'tok')),
        eventSocketFactoryProvider.overrideWithValue(({
          required ServerConfig serverConfig,
          required String nodeId,
          required TokenStore tokenStore,
          Future<bool> Function()? onRefreshAuth,
        }) => FakeEventSocket(nodeId)),
      ],
    );
    addTearDown(container.dispose);

    const user = UserProfile(
      id: 1,
      username: 'tetra',
      displayName: 'Tetra',
      role: 'admin',
      defaultNode: 'win',
      allowedNodes: ['win', 'deck'],
      nodePermissions: {
        'win': UserPermissionGrant(nodeId: 'win', canWrite: true, canDelete: true),
        'deck': UserPermissionGrant(nodeId: 'deck', canWrite: true, canDelete: true),
      },
    );

    final hub = container.read(hubControllerProvider.notifier);
    await hub.initializeForUser(user);
    await Future<void>.delayed(Duration.zero);

    var cur = container.read(hubControllerProvider);
    expect(cur.selectedNodeId, 'win');
    expect(cur.availableModels.map((m) => m.id).toList(), ['gemini-4-neon-high', 'claude-sonnet-5-5-medium']);
    expect(cur.selectedModel, 'gemini-4-neon-high');

    // 切换到 Steam Deck 节点：必须完全替换为 Deck 模型，不能残留 Windows 的 gemini-4-neon-high
    final switchErr = await hub.switchNode('deck');
    expect(switchErr, isNull);
    await Future<void>.delayed(Duration.zero);

    cur = container.read(hubControllerProvider);
    expect(cur.selectedNodeId, 'deck');
    expect(
      cur.availableModels.map((m) => m.id).toList(),
      ['gemini-4-hydrogen-high', 'gemini-3.8-flash-medium', 'claude-sonnet-4-6'],
    );
    expect(cur.availableModels.any((m) => m.id == 'gemini-4-neon-high'), false);
    expect(cur.selectedModel, 'gemini-4-hydrogen-high');

    // 切回 Windows 节点：立即并准确恢复 Windows 模型目录
    final backErr = await hub.switchNode('win');
    expect(backErr, isNull);
    await Future<void>.delayed(Duration.zero);

    cur = container.read(hubControllerProvider);
    expect(cur.selectedNodeId, 'win');
    expect(cur.availableModels.map((m) => m.id).toList(), ['gemini-4-neon-high', 'claude-sonnet-5-5-medium']);
    expect(cur.selectedModel, 'gemini-4-neon-high');
  });
}

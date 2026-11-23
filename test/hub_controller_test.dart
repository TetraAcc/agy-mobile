import 'dart:async';

import 'package:agy_remote/core/config/server_config.dart';
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

  FakeApiClient()
      : super(
          serverConfig: const ServerConfig('http://127.0.0.1:8768'),
          tokenStore: MemoryTokenStore(initialAccess: 'tok'),
          isWebOverride: false,
        );

  @override
  Future<(List<HostNode>, String)> getNodes() async {
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
      messages: [
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
      isRunning: false,
    );
  }

  @override
  Future<(bool, String)> sendMessage(String nodeId, String sessionId, {required String content, String? model}) async {
    sentMessages.add('$nodeId/$sessionId:$content');
    return (true, 'ok');
  }

  @override
  Future<(bool, String)> stopSession(String nodeId, String sessionId) async {
    stoppedSessions.add('$nodeId/$sessionId');
    return (true, 'stopped');
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
    return (true, returnCreatedSessionId ? 's-new' : '', 'created');
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
}

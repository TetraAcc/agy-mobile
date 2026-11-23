import 'dart:async';

import 'package:agy_remote/core/config/server_config.dart';
import 'package:agy_remote/core/network/api_client.dart';
import 'package:agy_remote/core/network/token_store.dart';
import 'package:agy_remote/core/realtime/node_event_socket.dart';
import 'package:agy_remote/features/auth/auth_controller.dart';
import 'package:agy_remote/features/hub/hub_controller.dart';
import 'package:agy_remote/models/models.dart';
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
    return const [FileRootItem(id: 'scratch', name: 'scratch', path: r'C:\scratch')];
  }

  @override
  Future<SessionChangesData> getSessionChanges(
    String nodeId,
    String sessionId, {
    bool includeHunks = false,
    String? filePath,
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
  setUp(() {
    SharedPreferences.setMockInitialValues({});
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
}

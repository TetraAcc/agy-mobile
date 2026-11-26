import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import '../../models/models.dart';
import '../config/server_config.dart';
import '../network/token_store.dart';
import 'ws_connector.dart';

enum WsConnState { disconnected, connecting, connected }

sealed class WsServerEvent {
  const WsServerEvent();
}

class WsStepUpsertEvent extends WsServerEvent {
  final String sessionId;
  final AgentMessage step;
  final bool isRunning;

  const WsStepUpsertEvent({
    required this.sessionId,
    required this.step,
    required this.isRunning,
  });
}

class WsSessionStatusEvent extends WsServerEvent {
  final String sessionId;
  final bool isRunning;

  const WsSessionStatusEvent({
    required this.sessionId,
    required this.isRunning,
  });
}

class WsSessionTreeChangedEvent extends WsServerEvent {
  const WsSessionTreeChangedEvent();
}

class WsNodeStatusEvent extends WsServerEvent {
  final List<HostNode> nodes;

  const WsNodeStatusEvent(this.nodes);
}

class WsPongEvent extends WsServerEvent {
  const WsPongEvent();
}

class WsApprovalsChangedEvent extends WsServerEvent {
  final String sessionId;
  final List<ToolApprovalItem> approvals;
  final bool isRunning;

  const WsApprovalsChangedEvent({
    required this.sessionId,
    required this.approvals,
    required this.isRunning,
  });
}

class WsErrorEvent extends WsServerEvent {
  final String code;
  final String message;

  const WsErrorEvent({required this.code, required this.message});
}

abstract class EventSocketClient {
  Stream<WsServerEvent> get events;
  Stream<WsConnState> get connectionStates;
  WsConnState get currentState;

  Future<void> connect();
  Future<void> reconnectNow({bool refreshToken = false});
  void subscribe(String sessionId, {int? sinceStep});
  void unsubscribe(String sessionId);
  Future<void> dispose();
}

class NodeEventSocket implements EventSocketClient {
  final ServerConfig serverConfig;
  final String nodeId;
  final TokenStore tokenStore;
  final WebSocketConnectFn _connector;
  final Future<bool> Function()? onRefreshAuth;
  final bool isWebPlatform;

  final StreamController<WsServerEvent> _eventController = StreamController<WsServerEvent>.broadcast();
  final StreamController<WsConnState> _stateController = StreamController<WsConnState>.broadcast();

  WebSocketChannel? _channel;
  StreamSubscription<dynamic>? _channelSub;
  Timer? _heartbeatTimer;
  Timer? _reconnectTimer;

  WsConnState _state = WsConnState.disconnected;
  int _reconnectAttempts = 0;
  bool _disposed = false;
  bool _manualClose = false;
  bool _isConnectingNow = false;
  bool _needsTokenRefreshOnNextConnect = false;

  String? _subscribedSessionId;
  final Map<String, int> _lastStepBySession = {};

  NodeEventSocket({
    required this.serverConfig,
    required this.nodeId,
    required this.tokenStore,
    WebSocketConnectFn? connector,
    this.onRefreshAuth,
    bool? isWebOverride,
  })  : _connector = connector ?? connectWebSocket,
        isWebPlatform = isWebOverride ?? kIsWeb;

  @override
  Stream<WsServerEvent> get events => _eventController.stream;

  @override
  Stream<WsConnState> get connectionStates => _stateController.stream;

  @override
  WsConnState get currentState => _state;

  void _setState(WsConnState next) {
    if (_state != next && !_stateController.isClosed) {
      _state = next;
      _stateController.add(next);
    }
  }

  @override
  Future<void> connect() async {
    if (_disposed || _isConnectingNow) return;
    _isConnectingNow = true;
    _manualClose = false;
    _reconnectTimer?.cancel();
    _setState(WsConnState.connecting);

    try {
      if (!isWebPlatform &&
          onRefreshAuth != null &&
          (_needsTokenRefreshOnNextConnect || (tokenStore.accessToken?.isEmpty ?? true))) {
        _needsTokenRefreshOnNextConnect = false;
        try {
          await onRefreshAuth!();
        } catch (_) {}
      }
      if (_disposed || _manualClose) return;

      final uri = Uri.parse('${serverConfig.wsBaseUrl}/ws/v2/nodes/$nodeId/events');
      Map<String, dynamic>? headers;
      if (!isWebPlatform) {
        final tok = tokenStore.accessToken;
        if (tok != null && tok.isNotEmpty) {
          headers = {'Authorization': 'Bearer $tok'};
        }
      }

      final ch = _connector(uri, headers: headers);
      _channel = ch;
      await ch.ready;
      if (_disposed || _manualClose || _channel != ch) {
        await ch.sink.close();
        return;
      }

      _reconnectAttempts = 0;
      _needsTokenRefreshOnNextConnect = false;
      _setState(WsConnState.connected);
      _startHeartbeat();

      _channelSub = ch.stream.listen(
        _onRawMessage,
        onError: (_) => _handleDisconnect(),
        onDone: _handleDisconnect,
        cancelOnError: true,
      );

      final sid = _subscribedSessionId;
      if (sid != null && sid.isNotEmpty) {
        _sendJson({
          'type': 'subscribe',
          'session_id': sid,
          if (_lastStepBySession[sid] != null) 'since_step': _lastStepBySession[sid],
        });
      }
    } catch (_) {
      if (!isWebPlatform) {
        _needsTokenRefreshOnNextConnect = true;
      }
      _handleDisconnect();
    } finally {
      _isConnectingNow = false;
    }
  }

  @override
  Future<void> reconnectNow({bool refreshToken = false}) async {
    if (_disposed) return;
    _manualClose = true;
    _reconnectTimer?.cancel();
    _heartbeatTimer?.cancel();
    _reconnectAttempts = 0;
    if (refreshToken && !isWebPlatform) {
      _needsTokenRefreshOnNextConnect = true;
    }
    final oldSub = _channelSub;
    _channelSub = null;
    final oldCh = _channel;
    _channel = null;
    _isConnectingNow = false;
    await oldSub?.cancel();
    try {
      await oldCh?.sink.close();
    } catch (_) {}
    if (_disposed) return;
    await connect();
  }

  void _onRawMessage(dynamic raw) {
    try {
      final decoded = jsonDecode(raw.toString());
      if (decoded is! Map) return;
      final data = Map<String, dynamic>.from(decoded);
      final type = data['type']?.toString() ?? '';
      switch (type) {
        case 'step_upsert':
          final sid = data['session_id']?.toString() ?? '';
          final stepMap = Map<String, dynamic>.from(data['step'] as Map);
          final step = AgentMessage.fromJson(stepMap);
          final prev = _lastStepBySession[sid];
          if (prev == null || step.stepIndex > prev) {
            _lastStepBySession[sid] = step.stepIndex;
          }
          _eventController.add(
            WsStepUpsertEvent(
              sessionId: sid,
              step: step,
              isRunning: data['is_running'] == true,
            ),
          );
          break;
        case 'session_status':
          _eventController.add(
            WsSessionStatusEvent(
              sessionId: data['session_id']?.toString() ?? '',
              isRunning: data['is_running'] == true,
            ),
          );
          break;
        case 'session_tree_changed':
          _eventController.add(const WsSessionTreeChangedEvent());
          break;
        case 'node_status':
          final rawNodes = data['nodes'] as List<dynamic>? ?? const [];
          final nodes = rawNodes
              .whereType<Map>()
              .map((e) => HostNode.fromJson(Map<String, dynamic>.from(e)))
              .toList();
          _eventController.add(WsNodeStatusEvent(nodes));
          break;
        case 'pong':
          _eventController.add(const WsPongEvent());
          break;
        case 'approvals_changed':
          final rawApprovals = data['approvals'] as List<dynamic>? ?? const [];
          final approvals = rawApprovals
              .whereType<Map>()
              .map((e) => ToolApprovalItem.fromJson(Map<String, dynamic>.from(e)))
              .toList();
          _eventController.add(
            WsApprovalsChangedEvent(
              sessionId: data['session_id']?.toString() ?? '',
              approvals: approvals,
              isRunning: data['is_running'] == true,
            ),
          );
          break;
        case 'error':
          final errCode = data['code']?.toString() ?? 'unknown';
          _eventController.add(
            WsErrorEvent(
              code: errCode,
              message: data['message']?.toString() ?? '',
            ),
          );
          if (errCode == 'unauthorized' || errCode == 'token_expired' || errCode == '401') {
            _needsTokenRefreshOnNextConnect = true;
            unawaited(reconnectNow(refreshToken: true));
          }
          break;
      }
    } catch (_) {}
  }

  void _sendJson(Map<String, dynamic> payload) {
    final ch = _channel;
    if (ch == null || _state != WsConnState.connected) return;
    try {
      ch.sink.add(jsonEncode(payload));
    } catch (_) {}
  }

  @override
  void subscribe(String sessionId, {int? sinceStep}) {
    if (sessionId.isEmpty) return;
    _subscribedSessionId = sessionId;
    if (sinceStep != null) {
      _lastStepBySession[sessionId] = sinceStep;
    }
    _sendJson({
      'type': 'subscribe',
      'session_id': sessionId,
      if (sinceStep != null) 'since_step': sinceStep,
    });
  }

  @override
  void unsubscribe(String sessionId) {
    if (sessionId.isEmpty) return;
    if (_subscribedSessionId == sessionId) {
      _subscribedSessionId = null;
    }
    _sendJson({
      'type': 'unsubscribe',
      'session_id': sessionId,
    });
  }

  void _startHeartbeat() {
    _heartbeatTimer?.cancel();
    _heartbeatTimer = Timer.periodic(const Duration(seconds: 20), (_) {
      _sendJson({'type': 'ping'});
    });
  }

  void _handleDisconnect() {
    _heartbeatTimer?.cancel();
    _channelSub?.cancel();
    _channelSub = null;
    _channel = null;
    _setState(WsConnState.disconnected);
    if (_disposed || _manualClose) return;

    _reconnectTimer?.cancel();
    final delaySec = min(15, 1 << min(_reconnectAttempts, 4));
    _reconnectAttempts += 1;
    _reconnectTimer = Timer(Duration(seconds: delaySec), () {
      if (!_disposed && !_manualClose) {
        connect();
      }
    });
  }

  @override
  Future<void> dispose() async {
    _disposed = true;
    _manualClose = true;
    _heartbeatTimer?.cancel();
    _reconnectTimer?.cancel();
    await _channelSub?.cancel();
    _channelSub = null;
    try {
      await _channel?.sink.close();
    } catch (_) {}
    _channel = null;
    await _eventController.close();
    await _stateController.close();
  }
}

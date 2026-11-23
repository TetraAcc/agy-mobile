import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:agy_remote/core/config/server_config.dart';
import 'package:agy_remote/core/network/api_client.dart';
import 'package:agy_remote/core/network/token_store.dart';
import 'package:agy_remote/core/realtime/node_event_socket.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

typedef MockHandler = Future<ResponseBody> Function(RequestOptions options);

class MockHttpAdapter implements HttpClientAdapter {
  final MockHandler handler;

  MockHttpAdapter(this.handler);

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) {
    return handler(options);
  }

  @override
  void close({bool force = false}) {}
}

ResponseBody _jsonResp(int status, Object body) {
  return ResponseBody.fromString(
    jsonEncode(body),
    status,
    headers: {
      Headers.contentTypeHeader: ['application/json'],
    },
  );
}

void main() {
  test('ServerConfig 规范化 URL 与推导 WebSocket 地址', () {
    expect(ServerConfig.defaultBaseUrl(), ServerConfig.defaultNativeUrl);
    expect(ServerConfig.normalizeBaseUrl('agy.example.com/'), 'https://agy.example.com');
    expect(ServerConfig.normalizeBaseUrl('127.0.0.1:8768/'), 'http://127.0.0.1:8768');
    expect(const ServerConfig('https://agy.example.com').wsBaseUrl, 'wss://agy.example.com');
    expect(const ServerConfig('http://127.0.0.1:8768').wsBaseUrl, 'ws://127.0.0.1:8768');
  });

  test('ApiClient 401 自动刷新 Token 并重放原请求', () async {
    var sessionCalls = 0;
    var refreshCalls = 0;
    final dio = Dio();
    dio.httpClientAdapter = MockHttpAdapter((opts) async {
      if (opts.path == '/api/v2/auth/refresh') {
        refreshCalls += 1;
        return _jsonResp(200, {
          'ok': true,
          'user': {
            'id': 1,
            'username': 'tetra',
            'display_name': 'Tetra',
            'role': 'admin',
            'allowed_nodes': ['win'],
            'node_permissions': {'win': {'node_id': 'win', 'can_write': true, 'can_delete': true}},
          },
          'tokens': {
            'access_token': 'new_access_tok',
            'refresh_token': 'new_refresh_tok',
            'expires_in': 1800,
          },
        });
      }
      if (opts.path == '/api/v2/nodes/win/sessions') {
        sessionCalls += 1;
        if (sessionCalls == 1) {
          expect(opts.headers['Authorization'], 'Bearer old_access_tok');
          return _jsonResp(401, {'detail': 'expired'});
        }
        expect(opts.headers['Authorization'], 'Bearer new_access_tok');
        return _jsonResp(200, {
          'projects': {},
          'general_sessions': [],
          'engine_alive': true,
          'running_session_ids': [],
        });
      }
      return _jsonResp(404, {'detail': 'not found'});
    });

    final store = MemoryTokenStore(initialAccess: 'old_access_tok', initialRefresh: 'old_refresh_tok');
    final client = ApiClient(
      serverConfig: const ServerConfig('https://agy.example.com'),
      tokenStore: store,
      dio: dio,
      isWebOverride: false,
    );

    final tree = await client.getSessionTree('win');
    expect(tree.engineAlive, true);
    expect(refreshCalls, 1);
    expect(sessionCalls, 2);
    expect(store.accessToken, 'new_access_tok');
    expect(await store.readRefreshToken(), 'new_refresh_tok');
  });

  test('ApiClient 刷新失败触发 onSessionExpired 并清空凭证', () async {
    var expiredTriggered = false;
    final dio = Dio();
    dio.httpClientAdapter = MockHttpAdapter((opts) async {
      if (opts.path == '/api/v2/auth/refresh') {
        return _jsonResp(401, {'detail': 'refresh expired'});
      }
      return _jsonResp(401, {'detail': 'unauthorized'});
    });

    final store = MemoryTokenStore(initialAccess: 'bad_access', initialRefresh: 'bad_refresh');
    final client = ApiClient(
      serverConfig: const ServerConfig('https://agy.example.com'),
      tokenStore: store,
      dio: dio,
      isWebOverride: false,
      onSessionExpired: () => expiredTriggered = true,
    );

    await expectLater(() => client.getSessionTree('win'), throwsA(isA<UnauthorizedException>()));
    expect(expiredTriggered, true);
    expect(store.accessToken, isNull);
    expect(await store.readRefreshToken(), isNull);
  });

  test('ApiClient 读取二进制文件 415 抛出 BinaryFileApiException', () async {
    final dio = Dio();
    dio.httpClientAdapter = MockHttpAdapter((opts) async {
      return _jsonResp(415, {'detail': 'Binary file cannot be rendered as text'});
    });

    final client = ApiClient(
      serverConfig: const ServerConfig('https://agy.example.com'),
      tokenStore: MemoryTokenStore(initialAccess: 'tok'),
      dio: dio,
      isWebOverride: false,
    );

    await expectLater(
      () => client.getFileContent('win', 'scratch', 'archive.zip'),
      throwsA(isA<BinaryFileApiException>()),
    );
  });

  test('NodeEventSocket 在令牌失效重连时刷新 Token 并携带新 Authorization 头', () async {
    final store = MemoryTokenStore(initialAccess: 'expired_tok', initialRefresh: 'rt_1');
    final recordedHeaders = <Map<String, dynamic>?>[];
    var refreshCalls = 0;

    final socket = NodeEventSocket(
      serverConfig: const ServerConfig('https://agy.example.com'),
      nodeId: 'win',
      tokenStore: store,
      isWebOverride: false,
      onRefreshAuth: () async {
        refreshCalls += 1;
        await store.saveTokens(
          accessToken: 'fresh_tok_$refreshCalls',
          refreshToken: 'rt_${refreshCalls + 1}',
        );
        return true;
      },
      connector: (uri, {headers}) {
        recordedHeaders.add(headers == null ? null : Map<String, dynamic>.from(headers));
        return _FakeWsChannel();
      },
    );
    addTearDown(socket.dispose);

    await socket.connect();
    expect(recordedHeaders.last?['Authorization'], 'Bearer expired_tok');

    await socket.reconnectNow(refreshToken: true);
    expect(refreshCalls, 1);
    expect(recordedHeaders.last?['Authorization'], 'Bearer fresh_tok_1');
  });
}

class _FakeWsSink implements WebSocketSink {
  final List<dynamic> sent = [];
  bool closed = false;

  @override
  void add(dynamic data) => sent.add(data);

  @override
  void addError(Object error, [StackTrace? stackTrace]) {}

  @override
  Future addStream(Stream stream) async {
    await for (final item in stream) {
      sent.add(item);
    }
  }

  @override
  Future close([int? closeCode, String? closeReason]) async {
    closed = true;
  }

  @override
  Future get done => Future.value();
}

class _FakeWsChannel implements WebSocketChannel {
  final StreamController<dynamic> _incoming = StreamController<dynamic>.broadcast();
  final _FakeWsSink _sink = _FakeWsSink();

  @override
  int? get closeCode => null;

  @override
  String? get closeReason => null;

  @override
  String? get protocol => null;

  @override
  Future<void> get ready => Future.value();

  @override
  WebSocketSink get sink => _sink;

  @override
  Stream<dynamic> get stream => _incoming.stream;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

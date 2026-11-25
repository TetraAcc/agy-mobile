import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';

import '../../models/models.dart';
import '../config/server_config.dart';
import 'http_adapter.dart';
import 'token_store.dart';

class ApiException implements Exception {
  final int statusCode;
  final String message;

  const ApiException(this.statusCode, this.message);

  @override
  String toString() => 'ApiException($statusCode): $message';
}

class UnauthorizedException extends ApiException {
  const UnauthorizedException([String message = '未授权或登录已过期']) : super(401, message);
}

class BinaryFileApiException extends ApiException {
  const BinaryFileApiException([String message = '二进制文件不支持文本查看']) : super(415, message);
}

class DownloadCancelledException implements Exception {
  const DownloadCancelledException();
}

class ApiClient {
  final Dio _dio;
  final Dio _refreshDio;
  final TokenStore tokenStore;
  final bool isWebPlatform;
  ServerConfig _serverConfig;
  VoidCallback? onSessionExpired;
  Completer<bool>? _refreshCompleter;

  ApiClient({
    required ServerConfig serverConfig,
    required this.tokenStore,
    Dio? dio,
    bool? isWebOverride,
    this.onSessionExpired,
  })  : _serverConfig = serverConfig,
        isWebPlatform = isWebOverride ?? kIsWeb,
        _dio = dio ?? Dio(),
        _refreshDio = Dio() {
    _dio.options = _dio.options.copyWith(
      baseUrl: _serverConfig.baseUrl,
      connectTimeout: const Duration(seconds: 15),
      receiveTimeout: const Duration(seconds: 60),
    );
    if (dio == null) {
      configureDioAdapter(_dio);
    }
    _refreshDio.options = _dio.options;
    _refreshDio.httpClientAdapter = _dio.httpClientAdapter;
    _installInterceptors();
  }

  ServerConfig get serverConfig => _serverConfig;

  void updateServerConfig(ServerConfig config) {
    _serverConfig = config;
    _dio.options = _dio.options.copyWith(baseUrl: config.baseUrl);
    _refreshDio.options = _dio.options;
  }

  void _installInterceptors() {
    _dio.interceptors.add(
      InterceptorsWrapper(
        onRequest: (options, handler) {
          if (!isWebPlatform) {
            final tok = tokenStore.accessToken;
            if (tok != null && tok.isNotEmpty && !options.headers.containsKey('Authorization')) {
              options.headers['Authorization'] = 'Bearer $tok';
            }
          }
          handler.next(options);
        },
        onError: (err, handler) async {
          final status = err.response?.statusCode ?? 0;
          final path = err.requestOptions.path;
          final alreadyRetried = err.requestOptions.extra['_retried'] == true;
          final isAuthEndpoint = path.contains('/api/v2/auth/login') || path.contains('/api/v2/auth/refresh');

          if (status == 401 && !isAuthEndpoint && !alreadyRetried) {
            final refreshed = await _tryRefreshLocked();
            if (refreshed) {
              final retryOpts = err.requestOptions;
              retryOpts.extra['_retried'] = true;
              if (!isWebPlatform && tokenStore.accessToken != null) {
                retryOpts.headers['Authorization'] = 'Bearer ${tokenStore.accessToken}';
              }
              try {
                final resp = await _refreshDio.fetch(retryOpts);
                handler.resolve(resp);
                return;
              } catch (retryErr) {
                if (retryErr is DioException) {
                  handler.next(retryErr);
                  return;
                }
              }
            }
            await tokenStore.clear();
            onSessionExpired?.call();
          }
          handler.next(err);
        },
      ),
    );
  }

  Future<bool> refreshSessionLocked() => _tryRefreshLocked();

  Future<bool> _tryRefreshLocked() async {
    if (_refreshCompleter != null) {
      return _refreshCompleter!.future;
    }
    final completer = Completer<bool>();
    _refreshCompleter = completer;
    try {
      final result = await tryRefreshSession();
      completer.complete(result);
      return result;
    } catch (_) {
      completer.complete(false);
      return false;
    } finally {
      _refreshCompleter = null;
    }
  }

  Future<bool> tryRefreshSession() async {
    final storedRefresh = isWebPlatform ? null : await tokenStore.readRefreshToken();
    if (!isWebPlatform && (storedRefresh == null || storedRefresh.isEmpty)) {
      return false;
    }
    try {
      final resp = await _refreshDio.post<Map<String, dynamic>>(
        '/api/v2/auth/refresh',
        data: storedRefresh != null ? {'refresh_token': storedRefresh} : const <String, dynamic>{},
      );
      final data = resp.data;
      if (resp.statusCode == 200 && data != null) {
        final loginRes = LoginResult.fromJson(data);
        await tokenStore.saveTokens(
          accessToken: loginRes.tokens.accessToken,
          refreshToken: loginRes.tokens.refreshToken,
        );
        return true;
      }
    } catch (_) {}
    return false;
  }

  Never _throwDioError(DioException err) {
    final code = err.response?.statusCode ?? 0;
    String msg = err.message ?? '网络请求失败';
    final data = err.response?.data;
    if (data is Map && data['detail'] != null) {
      msg = data['detail'].toString();
    } else if (data is String && data.isNotEmpty) {
      msg = data;
    }
    if (code == 401) throw UnauthorizedException(msg);
    if (code == 415) throw BinaryFileApiException(msg);
    throw ApiException(code, msg);
  }

  Future<T> _exec<T>(Future<Response<dynamic>> Function() call, T Function(dynamic data) mapper) async {
    try {
      final resp = await call();
      return mapper(resp.data);
    } on DioException catch (e) {
      _throwDioError(e);
    }
  }

  // ---------------------------------------------------------------------------
  // Auth
  // ---------------------------------------------------------------------------
  Future<LoginResult> login({
    required String username,
    required String password,
    String deviceInfo = '',
  }) async {
    final res = await _exec(
      () => _dio.post<dynamic>(
        '/api/v2/auth/login',
        data: {
          'username': username,
          'password': password,
          'device_info': deviceInfo,
        },
      ),
      (data) => LoginResult.fromJson(Map<String, dynamic>.from(data as Map)),
    );
    await tokenStore.saveTokens(
      accessToken: res.tokens.accessToken,
      refreshToken: res.tokens.refreshToken,
    );
    return res;
  }

  Future<void> logout() async {
    final rt = isWebPlatform ? null : await tokenStore.readRefreshToken();
    try {
      await _dio.post<dynamic>(
        '/api/v2/auth/logout',
        data: rt != null ? {'refresh_token': rt} : const <String, dynamic>{},
      );
    } catch (_) {}
    await tokenStore.clear();
  }

  Future<UserProfile> getMe() async {
    return _exec(
      () => _dio.get<dynamic>('/api/v2/auth/me'),
      (data) => UserProfile.fromJson(Map<String, dynamic>.from(data as Map)),
    );
  }

  Future<({bool discordConfigured, double minRunSeconds, double askQuestionDelaySeconds})>
      getNotificationStatus() async {
    return _exec(
      () => _dio.get<dynamic>('/api/v2/notifications/status'),
      (data) {
        final map = Map<String, dynamic>.from(data as Map);
        return (
          discordConfigured: map['discord_configured'] == true,
          minRunSeconds: (map['min_run_seconds'] as num?)?.toDouble() ?? 15.0,
          askQuestionDelaySeconds:
              (map['ask_question_delay_seconds'] as num?)?.toDouble() ?? 10.0,
        );
      },
    );
  }

  Future<(bool ok, String message)> sendTestNotification() async {
    return _exec(
      () => _dio.post<dynamic>('/api/v2/notifications/test'),
      (data) {
        final map = Map<String, dynamic>.from(data as Map);
        return (map['ok'] == true, map['message']?.toString() ?? '');
      },
    );
  }

  // ---------------------------------------------------------------------------
  // Nodes
  // ---------------------------------------------------------------------------
  Future<(List<HostNode>, String)> getNodes() async {
    return _exec(
      () => _dio.get<dynamic>('/api/v2/nodes'),
      (data) {
        final map = Map<String, dynamic>.from(data as Map);
        final rawNodes = map['nodes'] as List<dynamic>? ?? const [];
        final nodes = rawNodes
            .whereType<Map>()
            .map((e) => HostNode.fromJson(Map<String, dynamic>.from(e)))
            .toList();
        return (nodes, map['default_node']?.toString() ?? '');
      },
    );
  }

  Future<List<HostNode>> getAdminNodes() async {
    return _exec(
      () => _dio.get<dynamic>('/api/v2/admin/nodes'),
      (data) {
        final map = Map<String, dynamic>.from(data as Map);
        final rawNodes = map['nodes'] as List<dynamic>? ?? const [];
        return rawNodes
            .whereType<Map>()
            .map((e) => HostNode.fromJson(Map<String, dynamic>.from(e)))
            .toList();
      },
    );
  }

  Future<NodeUpdateStatus> getNodeUpdateStatus(String nodeId, {bool fetch = true}) async {
    return _exec(
      () => _dio.get<dynamic>(
        '/api/v2/nodes/$nodeId/update/status',
        queryParameters: {'fetch': fetch},
      ),
      (data) => NodeUpdateStatus.fromJson(Map<String, dynamic>.from(data as Map)),
    );
  }

  Future<NodeUpdateApplyResult> applyNodeUpdate(String nodeId, {bool force = false}) async {
    return _exec(
      () => _dio.post<dynamic>(
        '/api/v2/nodes/$nodeId/update/apply',
        data: {'force': force},
      ),
      (data) => NodeUpdateApplyResult.fromJson(Map<String, dynamic>.from(data as Map)),
    );
  }

  // ---------------------------------------------------------------------------
  // Sessions & Messages
  // ---------------------------------------------------------------------------
  Future<SessionTreeData> getSessionTree(String nodeId) async {
    return _exec(
      () => _dio.get<dynamic>('/api/v2/nodes/$nodeId/sessions'),
      (data) => SessionTreeData.fromJson(Map<String, dynamic>.from(data as Map)),
    );
  }

  Future<(bool ok, String sessionId, String message)> createSession(
    String nodeId, {
    required String content,
    String? model,
    String mode = 'auto',
    String? workspacePath,
    String? rootId,
  }) async {
    return _exec(
      () => _dio.post<dynamic>(
        '/api/v2/nodes/$nodeId/sessions',
        data: {
          'content': content,
          if (model != null && model.isNotEmpty) 'model': model,
          'mode': mode,
          if (workspacePath != null && workspacePath.isNotEmpty) 'workspace_path': workspacePath,
          if (rootId != null && rootId.isNotEmpty) 'root_id': rootId,
        },
      ),
      (data) {
        final map = Map<String, dynamic>.from(data as Map);
        return (
          map['ok'] == true,
          map['session_id']?.toString() ?? '',
          map['message']?.toString() ?? '',
        );
      },
    );
  }

  Future<SessionMessagesPage> getSessionMessages(
    String nodeId,
    String sessionId, {
    int? beforeStep,
    int limit = 60,
  }) async {
    return _exec(
      () => _dio.get<dynamic>(
        '/api/v2/nodes/$nodeId/sessions/$sessionId/messages',
        queryParameters: {
          if (beforeStep != null) 'before_step': beforeStep,
          'limit': limit,
        },
      ),
      (data) => SessionMessagesPage.fromJson(Map<String, dynamic>.from(data as Map)),
    );
  }

  Future<(bool ok, String message)> sendMessage(
    String nodeId,
    String sessionId, {
    required String content,
    String? model,
  }) async {
    return _exec(
      () => _dio.post<dynamic>(
        '/api/v2/nodes/$nodeId/sessions/$sessionId/messages',
        data: {
          'content': content,
          if (model != null && model.isNotEmpty) 'model': model,
        },
      ),
      (data) {
        final map = Map<String, dynamic>.from(data as Map);
        return (map['ok'] == true, map['message']?.toString() ?? '');
      },
    );
  }

  Future<({bool ok, String message, bool queued, int queuePosition})> sendMessageWithMode(
    String nodeId,
    String sessionId, {
    required String content,
    String? model,
    String deliveryMode = 'queue',
    bool interrupt = false,
  }) async {
    return _exec(
      () => _dio.post<dynamic>(
        '/api/v2/nodes/$nodeId/sessions/$sessionId/messages',
        data: {
          'content': content,
          if (model != null && model.isNotEmpty) 'model': model,
          'delivery_mode': deliveryMode,
          if (interrupt) 'interrupt': true,
        },
      ),
      (data) {
        final map = Map<String, dynamic>.from(data as Map);
        return (
          ok: map['ok'] == true,
          message: map['message']?.toString() ?? '',
          queued: map['queued'] == true,
          queuePosition: (map['queue_position'] as num?)?.toInt() ?? 0,
        );
      },
    );
  }

  Future<SessionQueueData> getSessionQueue(String nodeId, String sessionId) async {
    return _exec(
      () => _dio.get<dynamic>('/api/v2/nodes/$nodeId/sessions/$sessionId/queue'),
      (data) => SessionQueueData.fromJson(Map<String, dynamic>.from(data as Map)),
    );
  }

  Future<SessionQueueData> updateQueuedMessage(
    String nodeId,
    String sessionId,
    String itemId,
    String content,
  ) async {
    return _exec(
      () => _dio.put<dynamic>(
        '/api/v2/nodes/$nodeId/sessions/$sessionId/queue/$itemId',
        data: {'content': content},
      ),
      (data) => SessionQueueData.fromJson(Map<String, dynamic>.from(data as Map)),
    );
  }

  Future<SessionQueueData> deleteQueuedMessage(String nodeId, String sessionId, String itemId) async {
    return _exec(
      () => _dio.delete<dynamic>('/api/v2/nodes/$nodeId/sessions/$sessionId/queue/$itemId'),
      (data) => SessionQueueData.fromJson(Map<String, dynamic>.from(data as Map)),
    );
  }

  Future<SessionQueueData> clearSessionQueue(String nodeId, String sessionId) async {
    return _exec(
      () => _dio.delete<dynamic>('/api/v2/nodes/$nodeId/sessions/$sessionId/queue'),
      (data) => SessionQueueData.fromJson(Map<String, dynamic>.from(data as Map)),
    );
  }

  Future<SessionQueueData> setSessionQueuePaused(
    String nodeId,
    String sessionId, {
    required bool paused,
  }) async {
    return _exec(
      () => _dio.post<dynamic>(
        '/api/v2/nodes/$nodeId/sessions/$sessionId/queue/pause',
        data: {'paused': paused},
      ),
      (data) => SessionQueueData.fromJson(Map<String, dynamic>.from(data as Map)),
    );
  }

  Future<(bool ok, String message)> sendQueuedMessageNow(
    String nodeId,
    String sessionId,
    String itemId,
  ) async {
    return _exec(
      () => _dio.post<dynamic>('/api/v2/nodes/$nodeId/sessions/$sessionId/queue/$itemId/send-now'),
      (data) {
        final map = Map<String, dynamic>.from(data as Map);
        return (map['ok'] == true, map['message']?.toString() ?? '');
      },
    );
  }

  Future<(bool ok, String message)> stopSession(String nodeId, String sessionId) async {
    return _exec(
      () => _dio.post<dynamic>('/api/v2/nodes/$nodeId/sessions/$sessionId/stop'),
      (data) {
        final map = Map<String, dynamic>.from(data as Map);
        return (map['ok'] == true, map['message']?.toString() ?? '');
      },
    );
  }

  Future<(bool ok, String message)> deleteSession(
    String nodeId,
    String sessionId, {
    bool purgeDisk = false,
  }) async {
    return _exec(
      () => _dio.delete<dynamic>(
        '/api/v2/nodes/$nodeId/sessions/$sessionId',
        queryParameters: {'purge_disk': purgeDisk},
      ),
      (data) {
        final map = Map<String, dynamic>.from(data as Map);
        return (map['ok'] == true, map['message']?.toString() ?? '');
      },
    );
  }

  // ---------------------------------------------------------------------------
  // Uploads, Files, Media, Git, Quota
  // ---------------------------------------------------------------------------
  Future<UploadResult> uploadFile(
    String nodeId,
    String sessionId, {
    required String filename,
    required Uint8List bytes,
  }) async {
    final formData = FormData.fromMap({
      'file': MultipartFile.fromBytes(bytes, filename: filename),
    });
    return _exec(
      () => _dio.post<dynamic>(
        '/api/v2/nodes/$nodeId/sessions/$sessionId/uploads',
        data: formData,
      ),
      (data) => UploadResult.fromJson(Map<String, dynamic>.from(data as Map)),
    );
  }

  Future<List<FileRootItem>> getFileRoots(String nodeId) async {
    return _exec(
      () => _dio.get<dynamic>('/api/v2/nodes/$nodeId/files/roots'),
      (data) => (data as List<dynamic>)
          .whereType<Map>()
          .map((e) => FileRootItem.fromJson(Map<String, dynamic>.from(e)))
          .toList(),
    );
  }

  Future<FileTreeData> getFileTree(String nodeId, String rootId, {String path = ''}) async {
    return _exec(
      () => _dio.get<dynamic>(
        '/api/v2/nodes/$nodeId/files/tree',
        queryParameters: {'root_id': rootId, 'path': path},
      ),
      (data) => FileTreeData.fromJson(Map<String, dynamic>.from(data as Map)),
    );
  }

  Future<FileContentData> getFileContent(String nodeId, String rootId, String path) async {
    return _exec(
      () => _dio.get<dynamic>(
        '/api/v2/nodes/$nodeId/files/content',
        queryParameters: {'root_id': rootId, 'path': path},
      ),
      (data) => FileContentData.fromJson(Map<String, dynamic>.from(data as Map)),
    );
  }

  Future<FileSaveResult> saveFileContent({
    required String nodeId,
    required String rootId,
    required String path,
    required String content,
    double? expectedMtime,
  }) async {
    return _exec(
      () => _dio.put<dynamic>(
        '/api/v2/nodes/$nodeId/files/content',
        data: {
          'root_id': rootId,
          'path': path,
          'content': content,
          if (expectedMtime != null) 'expected_mtime': expectedMtime,
        },
      ),
      (data) => FileSaveResult.fromJson(Map<String, dynamic>.from(data as Map)),
    );
  }

  Future<ToolCallOutputData> getStepToolOutput({
    required String nodeId,
    required String sessionId,
    required int stepIndex,
  }) async {
    return _exec(
      () => _dio.get<dynamic>('/api/v2/nodes/$nodeId/sessions/$sessionId/steps/$stepIndex/tool-output'),
      (data) => ToolCallOutputData.fromJson(Map<String, dynamic>.from(data as Map)),
    );
  }

  Future<List<SessionArtifactItem>> getSessionArtifacts({
    required String nodeId,
    required String sessionId,
  }) async {
    return _exec(
      () => _dio.get<dynamic>('/api/v2/nodes/$nodeId/sessions/$sessionId/artifacts'),
      (data) {
        final map = Map<String, dynamic>.from(data as Map);
        final raw = map['items'] as List<dynamic>? ?? const [];
        return raw
            .whereType<Map>()
            .map((e) => SessionArtifactItem.fromJson(Map<String, dynamic>.from(e)))
            .toList();
      },
    );
  }

  Future<DownloadTicket> createDownloadTicket(String nodeId, String rootId, String path) async {
    return _exec(
      () => _dio.post<dynamic>(
        '/api/v2/nodes/$nodeId/files/ticket',
        data: {'root_id': rootId, 'path': path},
      ),
      (data) => DownloadTicket.fromJson(Map<String, dynamic>.from(data as Map)),
    );
  }

  String buildDownloadUrl(String nodeId, String ticket) {
    final base = _serverConfig.baseUrl;
    return '$base/api/v2/nodes/$nodeId/files/download?ticket=${Uri.encodeQueryComponent(ticket)}';
  }

  String buildMediaTicketUrl(String nodeId, String ticket) {
    final base = _serverConfig.baseUrl;
    return '$base/api/v2/nodes/$nodeId/media?ticket=${Uri.encodeQueryComponent(ticket)}';
  }

  String buildMediaUrl(String nodeId, String rawPath, {String? rootId}) {
    final base = _serverConfig.baseUrl;
    final qp = StringBuffer('path=${Uri.encodeQueryComponent(rawPath)}');
    if (rootId != null && rootId.isNotEmpty) {
      qp.write('&root_id=${Uri.encodeQueryComponent(rootId)}');
    }
    return '$base/api/v2/nodes/$nodeId/media?$qp';
  }

  Map<String, String>? authHeadersForMedia() {
    if (isWebPlatform) return null;
    final tok = tokenStore.accessToken;
    if (tok == null || tok.isEmpty) return null;
    return {'Authorization': 'Bearer $tok'};
  }

  Future<SessionChangesData> getSessionChanges(
    String nodeId,
    String sessionId, {
    bool includeHunks = false,
    String? filePath,
    String scope = 'all',
    int? stepIndex,
    int? turnId,
  }) async {
    return _exec(
      () => _dio.get<dynamic>(
        '/api/v2/nodes/$nodeId/sessions/$sessionId/changes',
        queryParameters: {
          'include_hunks': includeHunks,
          if (filePath != null && filePath.isNotEmpty) 'file_path': filePath,
          if (scope != 'all') 'scope': scope,
          if (stepIndex != null) 'step_index': stepIndex,
          if (turnId != null) 'turn_id': turnId,
        },
      ),
      (data) => SessionChangesData.fromJson(Map<String, dynamic>.from(data as Map)),
    );
  }

  Future<List<GitRepoItem>> getGitRepos(String nodeId) async {
    return _exec(
      () => _dio.get<dynamic>('/api/v2/nodes/$nodeId/git/repos'),
      (data) {
        final map = Map<String, dynamic>.from(data as Map);
        final raw = map['repos'] as List<dynamic>? ?? const [];
        return raw
            .whereType<Map>()
            .map((e) => GitRepoItem.fromJson(Map<String, dynamic>.from(e)))
            .toList();
      },
    );
  }

  Future<GitDiffData> getGitDiff(
    String nodeId,
    String rootId, {
    String subPath = '',
    String scope = 'uncommitted',
  }) async {
    return _exec(
      () => _dio.get<dynamic>(
        '/api/v2/nodes/$nodeId/git/diff',
        queryParameters: {
          'root_id': rootId,
          if (subPath.isNotEmpty) 'sub_path': subPath,
          'scope': scope,
        },
      ),
      (data) => GitDiffData.fromJson(Map<String, dynamic>.from(data as Map)),
    );
  }

  Future<QuotaData> getQuota(String nodeId) async {
    return _exec(
      () => _dio.get<dynamic>('/api/v2/nodes/$nodeId/quota'),
      (data) => QuotaData.fromJson(Map<String, dynamic>.from(data as Map)),
    );
  }

  Future<({List<OfficialModelOption> models, String defaultModel})> getModels(String nodeId) async {
    return _exec(
      () => _dio.get<dynamic>('/api/v2/nodes/$nodeId/models'),
      (data) {
        final map = Map<String, dynamic>.from(data as Map);
        final raw = map['models'] as List<dynamic>? ?? const [];
        final models = raw
            .whereType<Map>()
            .map((e) => OfficialModelOption.fromJson(Map<String, dynamic>.from(e)))
            .where((m) => m.id.isNotEmpty)
            .toList();
        return (
          models: models,
          defaultModel: map['default_model']?.toString() ?? '',
        );
      },
    );
  }

  Future<int> downloadUrlToPath(
    String fullUrl,
    String savePath, {
    void Function(int received, int total)? onProgress,
    CancelToken? cancelToken,
  }) async {
    var lastReceived = 0;
    try {
      await _dio.download(
        fullUrl,
        savePath,
        cancelToken: cancelToken,
        onReceiveProgress: (received, total) {
          lastReceived = received;
          onProgress?.call(received, total);
        },
      );
      return lastReceived;
    } on DioException catch (e) {
      if (e.type == DioExceptionType.cancel) {
        throw const DownloadCancelledException();
      }
      final code = e.response?.statusCode ?? 0;
      if (code == 403) {
        throw const ApiException(403, '无权限下载该文件');
      }
      if (code == 404) {
        throw const ApiException(404, '目标文件不存在或已被移动');
      }
      _throwDioError(e);
    }
  }
}

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/config/server_config.dart';
import '../../core/network/api_client.dart';
import '../../core/network/token_store.dart';
import '../../models/models.dart';

enum AuthStatus { checking, unauthenticated, authenticated }

class AuthState {
  final AuthStatus status;
  final UserProfile? user;
  final ServerConfig serverConfig;
  final bool isLoading;
  final String errorMessage;

  const AuthState({
    required this.status,
    this.user,
    required this.serverConfig,
    this.isLoading = false,
    this.errorMessage = '',
  });

  AuthState copyWith({
    AuthStatus? status,
    UserProfile? user,
    bool clearUser = false,
    ServerConfig? serverConfig,
    bool? isLoading,
    String? errorMessage,
  }) {
    return AuthState(
      status: status ?? this.status,
      user: clearUser ? null : (user ?? this.user),
      serverConfig: serverConfig ?? this.serverConfig,
      isLoading: isLoading ?? this.isLoading,
      errorMessage: errorMessage ?? this.errorMessage,
    );
  }
}

final tokenStoreProvider = Provider<TokenStore>((ref) => PlatformTokenStore());

final apiClientProvider = Provider<ApiClient>((ref) {
  final store = ref.watch(tokenStoreProvider);
  final client = ApiClient(
    serverConfig: ServerConfig(ServerConfig.defaultBaseUrl()),
    tokenStore: store,
  );
  client.onSessionExpired = () {
    ref.read(authControllerProvider.notifier).handleSessionExpired();
  };
  return client;
});

class AuthController extends Notifier<AuthState> {
  @override
  AuthState build() {
    Future.microtask(restoreSession);
    return AuthState(
      status: AuthStatus.checking,
      serverConfig: ServerConfig(ServerConfig.defaultBaseUrl()),
    );
  }

  ApiClient get _api => ref.read(apiClientProvider);

  Future<void> restoreSession() async {
    final cfg = await ServerConfig.load();
    _api.updateServerConfig(cfg);
    state = state.copyWith(serverConfig: cfg, status: AuthStatus.checking, errorMessage: '');

    try {
      if (kIsWeb) {
        try {
          final me = await _api.getMe();
          state = state.copyWith(status: AuthStatus.authenticated, user: me, errorMessage: '');
          return;
        } on UnauthorizedException {
          final refreshed = await _api.tryRefreshSession();
          if (refreshed) {
            final me = await _api.getMe();
            state = state.copyWith(status: AuthStatus.authenticated, user: me, errorMessage: '');
            return;
          }
        }
      } else {
        final refreshed = await _api.tryRefreshSession();
        if (refreshed) {
          final me = await _api.getMe();
          state = state.copyWith(status: AuthStatus.authenticated, user: me, errorMessage: '');
          return;
        }
      }
    } catch (_) {}

    state = state.copyWith(status: AuthStatus.unauthenticated, clearUser: true);
  }

  Future<void> updateServerUrl(String rawUrl) async {
    final cfg = await ServerConfig.save(rawUrl);
    _api.updateServerConfig(cfg);
    state = state.copyWith(serverConfig: cfg, errorMessage: '');
  }

  Future<bool> login({required String username, required String password}) async {
    final cleanUser = username.trim().toLowerCase();
    final cleanPass = password.trim();
    if (cleanUser.isEmpty || cleanPass.isEmpty) {
      state = state.copyWith(errorMessage: '请输入账号和密码');
      return false;
    }

    state = state.copyWith(isLoading: true, errorMessage: '');
    try {
      final res = await _api.login(
        username: cleanUser,
        password: cleanPass,
        deviceInfo: kIsWeb ? 'flutter-web' : 'flutter-native',
      );
      state = state.copyWith(
        status: AuthStatus.authenticated,
        user: res.user,
        isLoading: false,
        errorMessage: '',
      );
      return true;
    } on ApiException catch (e) {
      state = state.copyWith(
        status: AuthStatus.unauthenticated,
        isLoading: false,
        errorMessage: e.message.isNotEmpty ? e.message : '登录失败 (${e.statusCode})',
      );
      return false;
    } catch (e) {
      state = state.copyWith(
        status: AuthStatus.unauthenticated,
        isLoading: false,
        errorMessage: '无法连接服务器，请检查地址与网络',
      );
      return false;
    }
  }

  Future<void> logout() async {
    await _api.logout();
    state = state.copyWith(
      status: AuthStatus.unauthenticated,
      clearUser: true,
      isLoading: false,
      errorMessage: '',
    );
  }

  void handleSessionExpired() {
    if (state.status == AuthStatus.authenticated) {
      state = state.copyWith(
        status: AuthStatus.unauthenticated,
        clearUser: true,
        isLoading: false,
        errorMessage: '登录会话已过期，请重新登录',
      );
    }
  }
}

final authControllerProvider = NotifierProvider<AuthController, AuthState>(AuthController.new);

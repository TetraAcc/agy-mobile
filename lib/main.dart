import 'dart:convert';
import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:web_socket_channel/web_socket_channel.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'bridge/js_bridge.dart';
import 'constants/app_colors.dart';
import 'models/models.dart';
import 'widgets/widgets.dart';

// 全局明暗主题监听器
final ValueNotifier<ThemeMode> themeNotifier = ValueNotifier(ThemeMode.dark);
// 全局强调色主题监听器（默认使用护眼翡翠绿）
final ValueNotifier<AccentThemeOption> accentThemeNotifier =
    ValueNotifier(AppColors.accentThemes.first);

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const AgyRemoteApp());
}

class AgyRemoteApp extends StatefulWidget {
  const AgyRemoteApp({super.key});

  @override
  State<AgyRemoteApp> createState() => _AgyRemoteAppState();
}

class _AgyRemoteAppState extends State<AgyRemoteApp> {
  @override
  void initState() {
    super.initState();
    _loadThemePref();
  }

  Future<void> _loadThemePref() async {
    final prefs = await SharedPreferences.getInstance();
    final isDark = prefs.getBool('is_dark_mode') ?? true;
    themeNotifier.value = isDark ? ThemeMode.dark : ThemeMode.light;
    final accentId = prefs.getString('accent_theme') ?? 'emerald';
    accentThemeNotifier.value = AppColors.getThemeById(accentId);
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: Listenable.merge([themeNotifier, accentThemeNotifier]),
      builder: (ctx, _) {
        final currentThemeMode = themeNotifier.value;
        final currentAccent = accentThemeNotifier.value;

        return MaterialApp(
          title: 'AGY Remote',
          debugShowCheckedModeBanner: false,
          themeMode: currentThemeMode,
          // 优雅日间模式
          theme: ThemeData(
            useMaterial3: true,
            brightness: Brightness.light,
            scaffoldBackgroundColor: AppColors.lightBg,
            colorScheme: ColorScheme.light(
              primary: currentAccent.primary,
              secondary: currentAccent.secondary,
              surface: AppColors.lightBg,
            ),
          ),
          // 深度暗夜模式（护眼柔和）
          darkTheme: ThemeData(
            useMaterial3: true,
            brightness: Brightness.dark,
            scaffoldBackgroundColor: AppColors.darkBg,
            colorScheme: ColorScheme.dark(
              primary: currentAccent.primary,
              secondary: currentAccent.secondary,
              surface: AppColors.darkBg,
            ),
          ),
          home: const MainRemoteScreen(),
        );
      },
    );
  }
}

class MainRemoteScreen extends StatefulWidget {
  const MainRemoteScreen({super.key});

  @override
  State<MainRemoteScreen> createState() => _MainRemoteScreenState();
}

class _MainRemoteScreenState extends State<MainRemoteScreen> {
  // 账号密码认证状态与控制器
  bool _isLoggedIn = false;
  bool _isCheckingAuth = true;
  String _currentUsername = "";
  String _currentDisplayName = "";
  final TextEditingController _loginUsernameController = TextEditingController();
  final TextEditingController _loginPasswordController = TextEditingController();
  bool _loginObscurePassword = true;
  bool _isLoggingIn = false;
  String _loginErrorMessage = "";

  final TextEditingController _ipController = TextEditingController();
  final TextEditingController _inputController = TextEditingController();
  final TextEditingController _tokenController = TextEditingController();
  final List<AgentMessage> _messages = [];
  final Map<String, List<SessionItem>> _projects = {};
  final List<SessionItem> _generalSessions = [];
  final ScrollController _scrollController = ScrollController();
  bool _showScrollToBottom = false;
  Timer? _quotaPollingTimer;
  late final Map<String, void Function(Map<String, dynamic>)> _messageHandlers;

  String _selectedNode = "windows";
  String _selectedMode = "auto";
  String _selectedModel = "gemini-3.8-flash-high";
  List<HostNode> _nodes = [
    HostNode(id: "deck", name: "Steam Deck", isOnline: true),
    HostNode(id: "windows", name: "Windows PC", isOnline: false),
  ];

  WebSocketChannel? _channel;
  bool _isConnected = false;
  bool _isConnecting = false;
  final Set<String> _runningSessionIds = {};
  bool get _isThinking => _runningSessionIds.contains(_activeSessionId);
  String _currentIp = "127.0.0.1";
  String _authToken = "";
  String _activeSessionId = "";
  String _activeSessionTitle = "当前会话";

  Timer? _heartbeatTimer;
  Timer? _reconnectTimer;
  bool _manualDisconnect = false;

  List<FileItem> _currentFiles = [];
  String _currentSubPath = "";
  String _baseDirName = "";
  StateSetter? _fileModalSetState;

  final List<UploadedAttachment> _pendingAttachments = [];

  bool _showSlashMenu = false;
  List<SlashCommandOption> _filteredSlashCommands = kOfficialSlashCommands;

  Map<String, dynamic>? _quotaData;
  bool _isLoadingQuota = false;

  @override
  void initState() {
    super.initState();
    _initMessageHandlers();
    _scrollController.addListener(_onScrollChanged);
    _inputController.addListener(_onInputChanged);
    _initWebPasteListener();
    _loadSavedIp();
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

  void _updateAccentTheme(AccentThemeOption option) async {
    accentThemeNotifier.value = option;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('accent_theme', option.id);
  }

  void _startQuotaPolling() {
    _quotaPollingTimer?.cancel();
    _quotaPollingTimer = Timer.periodic(const Duration(seconds: 60), (_) {
      if (_isConnected) {
        _requestQuota();
      }
    });
  }

  void _requestQuota() {
    if (_channel != null && _isConnected) {
      setState(() {
        _isLoadingQuota = true;
      });
      _channel!.sink.add(jsonEncode({"action": "get_quota"}));
    }
  }

  void _onInputChanged() {
    final text = _inputController.text;
    if (text.startsWith("/")) {
      final query = text.toLowerCase().trim();
      final filtered = kOfficialSlashCommands.where((c) {
        return c.command.toLowerCase().startsWith(query);
      }).toList();

      setState(() {
        _showSlashMenu = filtered.isNotEmpty;
        _filteredSlashCommands = filtered;
      });
    } else {
      if (_showSlashMenu) {
        setState(() {
          _showSlashMenu = false;
        });
      }
    }
  }

  void _applySlashCommand(String cmd) {
    HapticFeedback.selectionClick();
    setState(() {
      _inputController.text = "$cmd ";
      _inputController.selection = TextSelection.fromPosition(
        TextPosition(offset: _inputController.text.length),
      );
      _showSlashMenu = false;
    });
  }

  void _stopCurrentTask() {
    if (!_isConnected) return;
    HapticFeedback.heavyImpact();
    setState(() {
      _runningSessionIds.remove(_activeSessionId);
    });
    final payload = jsonEncode({
      "action": "stop",
      "session_id": _activeSessionId,
    });
    _channel?.sink.add(payload);
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text("已向 Agent 发送停止指令"),
        behavior: SnackBarBehavior.floating,
        duration: Duration(seconds: 1),
      ),
    );
  }

  void _initWebPasteListener() {
    if (kIsWeb) {
      try {
        JsBridge.initBridge((name, base64, isImg) {
          _handleIncomingUpload(name, base64, isImg);
        });
      } catch (e) {
        debugPrint("Failed to init agyBridge: $e");
      }
    }
  }

  void _handleIncomingUpload(String filename, String dataUrl, bool isImage) {
    Uint8List? bytes;
    try {
      String clean = dataUrl;
      if (clean.contains(',')) {
        clean = clean.split(',')[1];
      }
      bytes = base64Decode(clean);
    } catch (_) {}

    final item = UploadedAttachment(
      filename: filename,
      dataUrl: dataUrl,
      isImage: isImage,
      isUploading: true,
      imageBytes: bytes,
    );

    setState(() {
      _pendingAttachments.add(item);
    });

    HapticFeedback.mediumImpact();

    if (_isConnected && _channel != null) {
      final payload = jsonEncode({
        "action": "upload_file",
        "filename": filename,
        "data": dataUrl,
        "session_id": _activeSessionId,
      });
      _channel?.sink.add(payload);
    } else {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text("请先连接到主机，文件将在连接后自动上传"),
          duration: Duration(seconds: 2),
        ),
      );
    }
  }

  Future<void> _loadSavedIp() async {
    final prefs = await SharedPreferences.getInstance();
    final savedIp = prefs.getString('saved_ip');

    if (savedIp != null && savedIp.isNotEmpty) {
      _currentIp = savedIp;
    } else if (kIsWeb) {
      final base = Uri.base;
      final scheme = base.scheme == 'https' ? 'wss' : 'ws';
      final portStr = base.hasPort ? ':${base.port}' : '';
      _currentIp = '$scheme://${base.host}$portStr/ws';
    } else {
      _currentIp = "127.0.0.1:8765";
    }
    _ipController.text = _currentIp;

    await _checkAuthAndConnect();
  }

  Future<void> _checkAuthAndConnect() async {
    final prefs = await SharedPreferences.getInstance();
    final savedToken = prefs.getString('auth_token') ?? '';
    final urlToken = kIsWeb ? Uri.base.queryParameters['token'] : null;

    if (urlToken != null && urlToken.isNotEmpty) {
      _authToken = urlToken;
      await prefs.setString('auth_token', urlToken);
    } else if (savedToken.isNotEmpty) {
      _authToken = savedToken;
    }
    _tokenController.text = _authToken;

    // 向 /api/me 探测当前登录状态
    try {
      final base = kIsWeb ? Uri.base : Uri.parse('http://${_currentIp.replaceAll('ws://', '').replaceAll('wss://', '').split('/').first}');
      final portStr = base.hasPort ? ':${base.port}' : '';
      final meUrl = "${base.scheme}://${base.host}$portStr/api/me";

      final headers = <String, String>{};
      if (_authToken.isNotEmpty) {
        headers['X-Auth-Token'] = _authToken;
      }
      final resp = await http.get(Uri.parse(meUrl), headers: headers).timeout(const Duration(seconds: 4));
      if (resp.statusCode == 200) {
        final data = jsonDecode(resp.body);
        if (data['logged_in'] == true) {
          final defaultNode = data['default_node'] ?? 'windows';
          final savedNode = prefs.getString('selected_node');
          final allowedNodes = (data['allowed_nodes'] as List<dynamic>?)?.map((e) => e.toString()).toList() ?? [];

          String actualNode = savedNode ?? defaultNode;
          if (allowedNodes.isNotEmpty && !allowedNodes.contains(actualNode)) {
            actualNode = defaultNode;
            await prefs.setString('selected_node', actualNode);
          }

          setState(() {
            _isLoggedIn = true;
            _isCheckingAuth = false;
            _selectedNode = actualNode;
            _currentUsername = data['username'] ?? '';
            _currentDisplayName = data['display_name'] ?? data['username'] ?? 'User';
            if (data['token'] != null && data['token'].toString().isNotEmpty) {
              _authToken = data['token'];
              prefs.setString('auth_token', _authToken);
            }
          });
          _connect();
          return;
        }
      }
    } catch (_) {}

    setState(() {
      _isLoggedIn = false;
      _isCheckingAuth = false;
    });
  }

  Future<void> _handleLogin() async {
    final username = _loginUsernameController.text.trim().toLowerCase();
    final password = _loginPasswordController.text.trim();
    if (username.isEmpty || password.isEmpty) {
      setState(() {
        _loginErrorMessage = "请输入账号和密码";
      });
      return;
    }

    setState(() {
      _isLoggingIn = true;
      _loginErrorMessage = "";
    });

    try {
      final base = kIsWeb ? Uri.base : Uri.parse('http://${_currentIp.replaceAll('ws://', '').replaceAll('wss://', '').split('/').first}');
      final portStr = base.hasPort ? ':${base.port}' : '';
      final loginUrl = "${base.scheme}://${base.host}$portStr/api/login";

      final resp = await http.post(
        Uri.parse(loginUrl),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({'username': username, 'password': password}),
      ).timeout(const Duration(seconds: 6));

      final data = jsonDecode(resp.body);
      if (resp.statusCode == 200 && data['success'] == true) {
        final user = data['user'] ?? {};
        final token = data['token'] ?? '';
        final prefs = await SharedPreferences.getInstance();
        if (token.isNotEmpty) {
          await prefs.setString('auth_token', token);
        }
        final defaultNode = user['default_node'] ?? 'windows';
        await prefs.setString('selected_node', defaultNode);

        setState(() {
          _isLoggedIn = true;
          _isLoggingIn = false;
          _authToken = token;
          _selectedNode = defaultNode;
          _currentUsername = user['username'] ?? username;
          _currentDisplayName = user['display_name'] ?? username;
        });

        _connect();
      } else {
        setState(() {
          _isLoggingIn = false;
          _loginErrorMessage = data['error'] ?? '用户名或密码错误';
        });
      }
    } catch (e) {
      setState(() {
        _isLoggingIn = false;
        _loginErrorMessage = "连接认证服务器失败，请检查网络";
      });
    }
  }

  Future<void> _handleLogout() async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text("退出登录"),
        content: const Text("确定要退出当前账号吗？"),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text("取消")),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: FilledButton.styleFrom(backgroundColor: Colors.redAccent),
            child: const Text("退出"),
          ),
        ],
      ),
    );
    if (confirm != true) return;

    try {
      final base = kIsWeb ? Uri.base : Uri.parse('http://${_currentIp.replaceAll('ws://', '').replaceAll('wss://', '').split('/').first}');
      final portStr = base.hasPort ? ':${base.port}' : '';
      final logoutUrl = "${base.scheme}://${base.host}$portStr/api/logout";
      await http.post(
        Uri.parse(logoutUrl),
        headers: {
          'Content-Type': 'application/json',
          if (_authToken.isNotEmpty) 'X-Auth-Token': _authToken,
        },
        body: jsonEncode({'token': _authToken}),
      );
    } catch (_) {}

    final prefs = await SharedPreferences.getInstance();
    await prefs.remove('auth_token');
    await prefs.remove('selected_node');

    _manualDisconnect = true;
    _channel?.sink.close();
    _heartbeatTimer?.cancel();
    _quotaPollingTimer?.cancel();

    setState(() {
      _isLoggedIn = false;
      _isConnected = false;
      _isConnecting = false;
      _authToken = "";
      _selectedNode = "windows";
      _currentUsername = "";
      _currentDisplayName = "";
      _messages.clear();
      _projects.clear();
      _generalSessions.clear();
      _loginPasswordController.clear();
      _loginErrorMessage = "";
    });
  }

  void _switchNode(String nodeId) async {
    if (_selectedNode == nodeId) return;

    final target = _nodes.firstWhere((n) => n.id == nodeId, orElse: () => HostNode(id: nodeId, name: nodeId));
    if (!target.isOnline && nodeId != "deck") {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text("【${target.name}】当前处于关机或离线状态"),
          behavior: SnackBarBehavior.floating,
          backgroundColor: Colors.redAccent.shade700,
        ),
      );
      return;
    }

    setState(() {
      _selectedNode = nodeId;
      _messages.clear();
      _projects.clear();
      _generalSessions.clear();
      _activeSessionTitle = "正在接入 ${target.name}...";
      _activeSessionId = "";
    });

    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('selected_node', nodeId);

    _manualDisconnect = false;
    _heartbeatTimer?.cancel();
    _reconnectTimer?.cancel();
    _channel?.sink.close();
    _channel = null;
    _isConnected = false;
    _isConnecting = false;

    Future.delayed(const Duration(milliseconds: 200), () {
      if (mounted) {
        _connect();
      }
    });
  }

  Future<void> _saveIp(String ip) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('saved_ip', ip);
  }

  Future<void> _toggleTheme(bool isDark) async {
    themeNotifier.value = isDark ? ThemeMode.dark : ThemeMode.light;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('is_dark_mode', isDark);
    HapticFeedback.lightImpact();
  }

  void _startHeartbeat() {
    _heartbeatTimer?.cancel();
    _heartbeatTimer = Timer.periodic(const Duration(seconds: 15), (t) {
      if (_isConnected && _channel != null) {
        try {
          _channel?.sink.add(jsonEncode({"action": "ping"}));
        } catch (_) {}
      }
    });
  }

  void _scheduleReconnect() {
    _reconnectTimer?.cancel();
    _reconnectTimer = Timer(const Duration(seconds: 3), () {
      if (!_isConnected && !_isConnecting && mounted && !_manualDisconnect) {
        _connect();
      }
    });
  }


  void _initMessageHandlers() {
    _messageHandlers = {
      'nodes_status': _handleNodesStatus,
      'node_offline': _handleNodeOffline,
      'auth_error': _handleAuthError,
      'connected': _handleConnected,
      'pong': (_) {},
      'session_tree': _handleSessionTree,
      'session_history': _handleSessionHistory,
      'quota_update': _handleQuotaUpdate,
      'file_browser_result': _handleFileBrowserResult,
      'file_content': _handleFileContent,
      'file_content_error': _handleFileContentError,
      'git_diff_result': _handleGitDiffResult,
      'file_uploaded': _handleFileUploaded,
      'file_upload_error': _handleFileUploadError,
      'prompt_ack': _handlePromptAck,
      'status_change': _handleStatusChange,
      'stopped': _handleStopped,
      'agent_update': _handleAgentUpdate,
      'delete_ack': (_) {},
      'new_session_ack': (_) {},
    };
  }

  void _handleNodesStatus(Map<String, dynamic> data) {
    final rawNodes = data['nodes'] as List<dynamic>?;
    if (rawNodes != null) {
      setState(() {
        _nodes = rawNodes.map((n) => HostNode.fromJson(n)).toList();
      });
    }
  }

  void _handleNodeOffline(Map<String, dynamic> data) {
    final offlineMsg = data['msg'] ?? '目标电脑当前已离线或未开机';
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(offlineMsg),
        backgroundColor: Colors.redAccent.shade700,
        behavior: SnackBarBehavior.floating,
      ),
    );
  }

  void _handleAuthError(Map<String, dynamic> data) {
    setState(() {
      _isLoggedIn = false;
      _isConnected = false;
      _isConnecting = false;
      _loginErrorMessage = data['msg'] ?? '访问口令 (Token) 错误或已过期，请重新登录';
    });
  }

  void _handleConnected(Map<String, dynamic> data) {
    setState(() {
      _isConnected = true;
      _isConnecting = false;
      _activeSessionId = data['active_session'] ?? "";
    });
    _startHeartbeat();
    _startQuotaPolling();
    _requestQuota();
    HapticFeedback.lightImpact();
  }

  void _handleSessionTree(Map<String, dynamic> data) {
    final rawProjects = data['projects'] as Map<String, dynamic>? ?? {};
    final rawGeneral = data['general_sessions'] as List? ?? [];

    setState(() {
      _projects.clear();
      rawProjects.forEach((projName, list) {
        _projects[projName] = (list as List).map((e) => SessionItem.fromJson(e)).toList();
      });

      _generalSessions.clear();
      _generalSessions.addAll(rawGeneral.map((e) => SessionItem.fromJson(e)).toList());

      if (data['current'] != null) {
        _activeSessionId = data['current'];
        for (var list in _projects.values) {
          for (var s in list) {
            if (s.id == _activeSessionId) _activeSessionTitle = s.title;
          }
        }
        for (var s in _generalSessions) {
          if (s.id == _activeSessionId) _activeSessionTitle = s.title;
        }
      }
    });
  }

  void _handleSessionHistory(Map<String, dynamic> data) {
    // 历史消息加载：全部预置为已完成，绝对禁止历史旧消息触发打字机动画
    final rawList = data['history'] as List? ?? data['messages'] as List? ?? [];
    final hist = rawList.map((e) {
      final msg = AgentMessage.fromJson(e);
      msg.isLiveStream = false;
      StreamingMarkdownBody.markFinished(msg.messageKey);
      return msg;
    }).toList();
    final sid = data['session_id']?.toString() ?? _activeSessionId;

    if (data['is_running'] != null) {
      if (data['is_running'] == true) {
        _runningSessionIds.add(sid);
      } else {
        _runningSessionIds.remove(sid);
      }
    } else if (hist.isNotEmpty) {
      final latest = hist.last;
      if (!latest.isUser && (latest.status == 'DONE' || latest.status == 'ERROR')) {
        _runningSessionIds.remove(sid);
      } else {
        // 最后一条为用户发出的提问，或 Agent 响应尚未标记为 DONE/ERROR，保持运行中状态
        _runningSessionIds.add(sid);
      }
    } else {
      _runningSessionIds.remove(sid);
    }

    setState(() {
      _messages.clear();
      _messages.addAll(hist.reversed);
    });
  }

  void _handleQuotaUpdate(Map<String, dynamic> data) {
    if (data['quota'] != null && data['quota'] is Map) {
      setState(() {
        _quotaData = Map<String, dynamic>.from(data['quota']);
        _isLoadingQuota = false;
      });
    } else {
      setState(() {
        _isLoadingQuota = false;
      });
    }
  }

  void _handleFileBrowserResult(Map<String, dynamic> data) {
    final items = (data['items'] as List).map((e) => FileItem.fromJson(e)).toList();
    if (_fileModalSetState != null) {
      _fileModalSetState!(() {
        _currentFiles = items;
        _currentSubPath = data['current_path'] ?? "";
        _baseDirName = data['base_dir_name'] ?? "工程根目录";
      });
    }
  }

  void _handleFileContent(Map<String, dynamic> data) {
    final path = data['path'] ?? '';
    final name = data['name'] ?? '文件';
    final content = data['content'] ?? '';
    final totalLines = data['total_lines'] ?? 0;
    final truncated = data['truncated'] ?? false;
    final size = data['size'] ?? 0;
    _showFileContentViewer(name, path, content, totalLines, truncated, size);
  }

  void _handleFileContentError(Map<String, dynamic> data) {
    final err = data['error'] ?? '读取失败';
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('文件读取失败: $err'), backgroundColor: Colors.redAccent),
    );
  }

  void _handleGitDiffResult(Map<String, dynamic> data) {
    final ws = data['workspace'] ?? '';
    final st = data['status'] ?? '';
    final df = data['diff'] ?? '';
    _showGitDiffViewer(ws, st, df);
  }

  void _handleFileUploaded(Map<String, dynamic> data) {
    final p = data['path'] ?? '';
    final fname = data['filename'] ?? '';
    final sz = data['size'] ?? 0;
    setState(() {
      for (var att in _pendingAttachments) {
        if (att.isUploading) {
          att.serverPath = p;
          att.isUploading = false;
          att.size = sz;
          break;
        }
      }
    });
    HapticFeedback.lightImpact();
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text("📎 附件已就绪: $fname"),
        behavior: SnackBarBehavior.floating,
        duration: const Duration(seconds: 2),
      ),
    );
  }

  void _handleFileUploadError(Map<String, dynamic> data) {
    final err = data['error'] ?? '上传失败';
    setState(() {
      _pendingAttachments.removeWhere((a) => a.isUploading);
    });
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text("附件上传失败: $err"), backgroundColor: Colors.redAccent),
    );
  }

  void _handlePromptAck(Map<String, dynamic> data) {
    final status = data['status'];
    final sid = data['session_id']?.toString() ?? _activeSessionId;
    if (status == 'error') {
      setState(() {
        _runningSessionIds.remove(sid);
      });
      final err = data['error'] ?? '未知错误';
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('发送失败: $err'),
          backgroundColor: Colors.redAccent.shade700,
          behavior: SnackBarBehavior.floating,
        ),
      );
    } else {
      HapticFeedback.lightImpact();
    }
  }

  void _handleStatusChange(Map<String, dynamic> data) {
    final sid = data['session_id']?.toString() ?? _activeSessionId;
    final isRunning = data['is_running'] == true;
    setState(() {
      if (isRunning) {
        _runningSessionIds.add(sid);
      } else {
        _runningSessionIds.remove(sid);
      }
    });
  }

  void _handleStopped(Map<String, dynamic> data) {
    final sid = data['session_id']?.toString() ?? _activeSessionId;
    setState(() {
      _runningSessionIds.remove(sid);
    });
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text("任务已停止"),
        behavior: SnackBarBehavior.floating,
        duration: Duration(seconds: 1),
      ),
    );
  }

  void _handleAgentUpdate(Map<String, dynamic> data) {
    final sid = data['session_id']?.toString() ?? _activeSessionId;
    final Map<String, dynamic> mutableData = Map<String, dynamic>.from(data);
    mutableData['is_live_stream'] = true; // 标记为当前实时动态流，触发打字机流式逐字渲染
    final newMsg = AgentMessage.fromJson(mutableData);
    if (newMsg.content.isEmpty && newMsg.thinking.isEmpty && newMsg.toolCalls.isEmpty) {
      return;
    }

    setState(() {
      if (newMsg.isUser) {
        _runningSessionIds.add(sid);
      } else {
        final backendRunning = data['is_running'];
        if (backendRunning != null) {
          if (backendRunning == true) {
            _runningSessionIds.add(sid);
          } else {
            _runningSessionIds.remove(sid);
          }
        } else if (newMsg.status == 'DONE' || newMsg.status == 'ERROR') {
          _runningSessionIds.remove(sid);
        } else {
          _runningSessionIds.add(sid);
        }
      }

      if (sid == _activeSessionId || _activeSessionId.isEmpty) {
        if (newMsg.isUser && _messages.isNotEmpty && _messages.first.isUser && _messages.first.content == newMsg.content) {
          return;
        }

        // 核心锁定防线：在推入新消息前，将现有历史消息的打字机状态全部永久锁定
        for (var m in _messages) {
          m.isLiveStream = false;
          StreamingMarkdownBody.markFinished(m.messageKey);
        }

        // 如果是同一步骤的 Agent 回复增量更新，原地替换以支持无缝打字机追赶
        if (!newMsg.isUser && _messages.isNotEmpty && !_messages.first.isUser &&
            newMsg.stepIndex > 0 && newMsg.stepIndex == _messages.first.stepIndex) {
          _messages[0] = newMsg;
        } else {
          _messages.insert(0, newMsg);
        }
      }
    });

    if (newMsg.status == 'WAITING_APPROVAL' || newMsg.status == 'WAITING_INPUT') {
      HapticFeedback.mediumImpact();
    } else if (newMsg.status == 'DONE' && newMsg.content.isNotEmpty) {
      HapticFeedback.lightImpact();
    }
  }

  void _connect() {
    if (!_isLoggedIn) return;
    if (_isConnected) return;

    final rawIp = _ipController.text.trim();
    if (rawIp.isEmpty) return;

    _manualDisconnect = false;
    _saveIp(rawIp);
    setState(() {
      _isConnecting = true;
      _currentIp = rawIp;
    });

    String wsUrl = rawIp;
    if (!wsUrl.startsWith('ws://') && !wsUrl.startsWith('wss://')) {
      final scheme = (kIsWeb && Uri.base.scheme == 'https') ? 'wss://' : 'ws://';
      wsUrl = '$scheme$rawIp';
    }

    // 携带安全访问口令 Token
    if (!wsUrl.contains('token=') && _authToken.isNotEmpty) {
      final sep = wsUrl.contains('?') ? '&' : '?';
      wsUrl = '$wsUrl${sep}token=$_authToken';
    }

    // 携带当前选中的控制节点
    if (!wsUrl.contains('node=')) {
      final sep = wsUrl.contains('?') ? '&' : '?';
      wsUrl = '$wsUrl${sep}node=$_selectedNode';
    }

    try {
      _channel = WebSocketChannel.connect(Uri.parse(wsUrl));

      _channel!.stream.listen(
        (message) {
          try {
            final data = jsonDecode(message);
            final type = data['type']?.toString() ?? '';
            final handler = _messageHandlers[type];
            if (handler != null) {
              handler(data);
            } else {
              debugPrint("未处理协议: $type");
            }
          } catch (e) {
            debugPrint("Parse error: $e");
          }
        },
        onError: (error) => _disconnect(isManual: false),
        onDone: () => _disconnect(isManual: false),
      );
    } catch (e) {
      _disconnect(isManual: false);
    }
  }

  void _disconnect({bool isManual = false}) {
    _manualDisconnect = isManual;
    _heartbeatTimer?.cancel();
    _channel?.sink.close();
    _channel = null;
    if (mounted) {
      setState(() {
        _isConnected = false;
        _isConnecting = false;
      });
    }
    if (!isManual) {
      _scheduleReconnect();
    }
  }

  void _switchSession(SessionItem session) {
    if (!_isConnected) return;
    setState(() {
      _activeSessionId = session.id;
      _activeSessionTitle = session.title;
      _messages.clear();
      StreamingMarkdownBody.clearCache();
    });
    final payload = jsonEncode({"action": "switch_session", "session_id": session.id});
    _channel?.sink.add(payload);
    HapticFeedback.selectionClick();
  }

  void _deleteSession(String sessionId) {
    if (!_isConnected) return;
    _channel?.sink.add(jsonEncode({"action": "delete_session", "session_id": sessionId}));

    setState(() {
      for (var list in _projects.values) {
        list.removeWhere((item) => item.id == sessionId);
      }
      _generalSessions.removeWhere((item) => item.id == sessionId);
      if (_activeSessionId == sessionId) {
        _activeSessionId = "";
        _activeSessionTitle = "请选择会话或新建";
        _messages.clear();
      }
    });

    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text("已从当前主机中删除该会话"),
        behavior: SnackBarBehavior.floating,
        duration: Duration(seconds: 2),
      ),
    );
    HapticFeedback.mediumImpact();
  }

  void _sendMessage([String? customText]) {
    final text = (customText ?? _inputController.text).trim();
    if (text.isEmpty && _pendingAttachments.isEmpty) return;

    if (!_isConnected) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text("正在连接到主机，请稍候重试..."),
          duration: Duration(seconds: 2),
          behavior: SnackBarBehavior.floating,
        ),
      );
      _connect();
      return;
    }

    // 处理待发送的附件
    String finalText = text;
    final toSendAttachments = List<UploadedAttachment>.from(_pendingAttachments);
    if (toSendAttachments.isNotEmpty) {
      final refs = toSendAttachments.map((a) {
        if (a.serverPath != null && a.serverPath!.isNotEmpty) {
          return a.isImage ? "[用户上传图片: ${a.serverPath}]" : "[用户上传文件: ${a.serverPath}]";
        } else {
          return "[附加文件: ${a.filename}]";
        }
      }).join("\n");

      if (finalText.isEmpty) {
        finalText = refs;
      } else {
        finalText = "$refs\n\n$finalText";
      }

      setState(() {
        _pendingAttachments.clear();
      });
    }

    // 立即清空输入框，消除输入延迟感
    if (customText == null) {
      _inputController.clear();
    }

    // 乐观更新：立刻在界面上展示用户的提问气泡
    final optimisticMsg = AgentMessage(
      stepIndex: -1,
      source: 'USER_EXPLICIT',
      msgType: 'USER_INPUT',
      status: 'SENT',
      content: finalText,
      thinking: '',
      toolCalls: [],
      timestamp: DateTime.now().toIso8601String(),
    );

    setState(() {
      _messages.insert(0, optimisticMsg);
      _runningSessionIds.add(_activeSessionId);
    });

    if (_scrollController.hasClients) {
      _scrollController.animateTo(
        0,
        duration: const Duration(milliseconds: 250),
        curve: Curves.easeOut,
      );
    }

    final payload = jsonEncode({
      "action": "prompt",
      "content": finalText,
      "session_id": _activeSessionId,
    });
    _channel?.sink.add(payload);
    HapticFeedback.lightImpact();
  }

  void _requestReadFile(String filePath) {
    if (!_isConnected) return;
    _channel?.sink.add(jsonEncode({"action": "read_file", "path": filePath}));
    HapticFeedback.selectionClick();
  }

  void _requestGitDiff() {
    if (!_isConnected) return;
    _channel?.sink.add(jsonEncode({"action": "get_git_diff"}));
    HapticFeedback.selectionClick();
  }

  void _downloadFile(String filePath, {String? filename}) {
    String cleanPath = filePath.trim();
    if (cleanPath.startsWith("file:///")) {
      cleanPath = cleanPath.replaceFirst("file:///", "");
    } else if (cleanPath.startsWith("file://")) {
      cleanPath = cleanPath.replaceFirst("file://", "");
    }

    final name = filename ?? cleanPath.split(RegExp(r'[\\/]')).last;
    final encodedPath = Uri.encodeComponent(cleanPath);

    final baseUri = Uri.base;
    final portStr = baseUri.hasPort ? ':${baseUri.port}' : '';
    final downloadUrl = "${baseUri.scheme}://${baseUri.host}$portStr/api/download?path=$encodedPath&token=$_authToken&node=$_selectedNode";

    try {
      JsBridge.downloadFile(downloadUrl, name);
    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text("触发下载失败: $e")),
      );
      return;
    }

    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text("已触发下载: $name"),
        behavior: SnackBarBehavior.floating,
        duration: const Duration(seconds: 2),
      ),
    );
  }

  void _showFileContentViewer(String name, String path, String content, int totalLines, bool truncated, int size) {
    FileViewerSheet.show(
      context,
      name: name,
      path: path,
      content: content,
      totalLines: totalLines,
      truncated: truncated,
      size: size,
      onDownloadFallback: (p) => _downloadFile(p),
    );
  }

  void _showGitDiffViewer(String workspace, String status, String diff) {
    GitDiffViewerSheet.show(
      context,
      workspace: workspace,
      status: status,
      diff: diff,
    );
  }

  void _openWorkspaceFilePicker() {
    if (!_isConnected) return;
    _channel?.sink.add(jsonEncode({"action": "browse_files", "sub_path": ""}));

    final isDark = Theme.of(context).brightness == Brightness.dark;

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: isDark ? const Color(0xFF161F30) : Colors.white,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(16))),
      builder: (ctx) {
        return StatefulBuilder(
          builder: (modalCtx, setModalState) {
            _fileModalSetState = setModalState;

            return WorkspaceFilePickerDialog(
              baseDirName: _baseDirName,
              currentSubPath: _currentSubPath,
              files: _currentFiles,
              isDark: isDark,
              onNavigate: (path) {
                _channel?.sink.add(jsonEncode({"action": "browse_files", "sub_path": path}));
              },
              onDownload: (path) => _downloadFile(path),
              onReadFile: (path) => _requestReadFile(path),
              onInsertRef: (ref) => _insertText(ref),
            );
          },
        );
      },
    ).whenComplete(() {
      _fileModalSetState = null;
    });
  }

  void _showAddContextSheet() {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    ContextMenuSheet.show(
      context,
      isDark: isDark,
      onRequestGitDiff: _requestGitDiff,
      onOpenWorkspaceFiles: _openWorkspaceFilePicker,
      onInsertText: (txt) => _insertText(txt),
      onShowPromptDialog: (title, hint, onConfirm) => _showPromptDialog(title, hint, onConfirm),
    );
  }

  void _showPromptDialog(String title, String hint, Function(String) onConfirm) {
    final tc = TextEditingController();
    final isDark = Theme.of(context).brightness == Brightness.dark;

    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: isDark ? const Color(0xFF1E293B) : Colors.white,
        title: Text(title, style: TextStyle(color: isDark ? Colors.white : Colors.black87, fontSize: 16)),
        content: TextField(
          controller: tc,
          autofocus: true,
          style: TextStyle(color: isDark ? Colors.white : Colors.black87),
          decoration: InputDecoration(
            hintText: hint,
            hintStyle: TextStyle(color: isDark ? Colors.white24 : Colors.black26, fontSize: 13),
            filled: true,
            fillColor: isDark ? const Color(0xFF0F172A) : const Color(0xFFF8FAFC),
            border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text("取消")),
          ElevatedButton(
            onPressed: () {
              Navigator.pop(ctx);
              if (tc.text.trim().isNotEmpty) {
                onConfirm(tc.text.trim());
              }
            },
            style: ElevatedButton.styleFrom(
              backgroundColor: Theme.of(context).colorScheme.primary,
              foregroundColor: Colors.white,
            ),
            child: const Text("确定"),
          ),
        ],
      ),
    );
  }

  void _insertText(String text) {
    setState(() {
      _inputController.text = text + _inputController.text;
      _inputController.selection = TextSelection.fromPosition(
        TextPosition(offset: _inputController.text.length),
      );
    });
  }

  void _showSettingsDialog() {
    final isDark = Theme.of(context).brightness == Brightness.dark;

    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: isDark ? const Color(0xFF1E293B) : Colors.white,
        title: Text("连接设置", style: TextStyle(color: isDark ? Colors.white : Colors.black87)),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text("电脑连接地址 (IP / 域名):", style: TextStyle(color: isDark ? Colors.grey : Colors.black54, fontSize: 13)),
            const SizedBox(height: 8),
            TextField(
              controller: _ipController,
              style: TextStyle(color: isDark ? Colors.white : Colors.black87),
              decoration: InputDecoration(
                hintText: "192.168.1.100:8765 / 域名",
                hintStyle: TextStyle(color: isDark ? Colors.white24 : Colors.black26),
                filled: true,
                fillColor: isDark ? const Color(0xFF0B0F19) : const Color(0xFFF1F5F9),
                border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
              ),
            ),
            const SizedBox(height: 14),
            Text("访问安全口令 (Token):", style: TextStyle(color: isDark ? Colors.grey : Colors.black54, fontSize: 13)),
            const SizedBox(height: 8),
            TextField(
              controller: _tokenController,
              obscureText: true,
              style: TextStyle(color: isDark ? Colors.white : Colors.black87),
              decoration: InputDecoration(
                hintText: "防公网扫描暗号 (例如 your_secret_token)",
                hintStyle: TextStyle(color: isDark ? Colors.white24 : Colors.black26),
                filled: true,
                fillColor: isDark ? const Color(0xFF0B0F19) : const Color(0xFFF1F5F9),
                border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
              ),
            ),
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text("取消")),
          ElevatedButton(
            onPressed: () async {
              Navigator.pop(ctx);
              final prefs = await SharedPreferences.getInstance();
              _authToken = _tokenController.text.trim();
              await prefs.setString('auth_token', _authToken);
              _disconnect(isManual: true);
              _connect();
            },
            style: ElevatedButton.styleFrom(
              backgroundColor: Theme.of(context).colorScheme.primary,
              foregroundColor: Colors.white,
            ),
            child: const Text("保存并连接"),
          ),
        ],
      ),
    );
  }

  void _showNewSessionDialog({String? initialProjectName, String? initialWorkspacePath}) {
    // 收集所有项目的本地工作区路径
    final projectPaths = <String, String>{};
    for (var entry in _projects.entries) {
      final validPath = entry.value.firstWhere(
        (s) => s.workspacePath.isNotEmpty,
        orElse: () => entry.value.first,
      ).workspacePath;
      if (validPath.isNotEmpty) {
        projectPaths[entry.key] = validPath;
      }
    }

    showDialog(
      context: context,
      builder: (ctx) => NewSessionDialog(
        initialMode: _selectedMode,
        initialModel: _selectedModel,
        models: kAllOfficialModels,
        availableProjects: projectPaths,
        initialProjectName: initialProjectName,
        onStart: (prompt, mode, model, workspacePath) {
          setState(() {
            _selectedMode = mode;
            _selectedModel = model;
          });
          _startNewSession(prompt, workspacePath: workspacePath);
        },
      ),
    );
  }

  void _startNewSession(String initialPrompt, {String? workspacePath}) {
    if (!_isConnected) return;
    setState(() {
      _messages.clear();
      _activeSessionTitle = "新任务 (启动中...)";
      _runningSessionIds.add(_activeSessionId);
    });

    final payload = jsonEncode({
      "action": "new_session",
      "content": initialPrompt,
      "model": _selectedModel,
      "mode": _selectedMode,
      "workspace_path": workspacePath ?? "",
    });
    _channel?.sink.add(payload);
    HapticFeedback.mediumImpact();
  }

  Widget _buildNodeSwitchButton(bool isDark) {
    final currentNode = _nodes.firstWhere((n) => n.id == _selectedNode, orElse: () => _nodes.first);
    final isWin = _selectedNode == "windows";

    return PopupMenuButton<String>(
      tooltip: "切换目标电脑",
      offset: const Offset(0, 45),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      color: isDark ? const Color(0xFF1E293B) : Colors.white,
      onSelected: _switchNode,
      itemBuilder: (context) {
        return _nodes.map((node) {
          final isSelected = node.id == _selectedNode;
          final isDeck = node.id == "deck";
          return PopupMenuItem<String>(
            value: node.id,
            child: Row(
              children: [
                Icon(
                  isDeck ? Icons.videogame_asset_rounded : Icons.desktop_windows_rounded,
                  size: 18,
                  color: isSelected ? Theme.of(context).colorScheme.primary : (isDark ? Colors.white70 : Colors.black87),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    node.name,
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight: isSelected ? FontWeight.bold : FontWeight.normal,
                      color: isDark ? Colors.white : Colors.black87,
                    ),
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
                        : (node.engineAlive ? Colors.greenAccent : Colors.amberAccent),
                  ),
                ),
                const SizedBox(width: 4),
                Text(
                  !node.isOnline ? "离线" : (node.engineAlive ? "在线" : "未启动"),
                  style: TextStyle(
                    fontSize: 10,
                    color: !node.isOnline
                        ? (isDark ? Colors.white38 : Colors.black38)
                        : (node.engineAlive ? Colors.greenAccent : Colors.amberAccent),
                  ),
                ),
              ],
            ),
          );
        }).toList();
      },
      child: Container(
        margin: const EdgeInsets.symmetric(vertical: 10, horizontal: 4),
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
        decoration: BoxDecoration(
          color: isDark
              ? (isWin ? const Color(0xFF1E3A8A).withOpacity(0.4) : const Color(0xFF334155).withOpacity(0.5))
              : (isWin ? const Color(0xFFE0F2FE) : const Color(0xFFF1F5F9)),
          borderRadius: BorderRadius.circular(16),
          border: Border.all(
            color: isWin ? const Color(0xFF38BDF8).withOpacity(0.6) : (isDark ? Colors.white12 : Colors.black12),
            width: 1,
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              isWin ? Icons.desktop_windows_rounded : Icons.videogame_asset_rounded,
              size: 14,
              color: isWin ? const Color(0xFF38BDF8) : (isDark ? Colors.white70 : Colors.black87),
            ),
            const SizedBox(width: 5),
            Text(
              currentNode.name,
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w600,
                color: isDark ? Colors.white : Colors.black87,
              ),
            ),
            const SizedBox(width: 3),
            Icon(Icons.arrow_drop_down_rounded, size: 16, color: isDark ? Colors.white38 : Colors.black38),
          ],
        ),
      ),
    );
  }

  Widget _buildThinkingIndicator(bool isDark) {
    return Container(
      margin: const EdgeInsets.only(bottom: 12, top: 4),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(
        color: isDark ? const Color(0xFF161F30) : Colors.white,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(
          color: Theme.of(context).colorScheme.primary.withOpacity(0.4),
          width: 1,
        ),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(isDark ? 0.2 : 0.05),
            blurRadius: 8,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          SizedBox(
            width: 14,
            height: 14,
            child: CircularProgressIndicator(
              strokeWidth: 2,
              valueColor: AlwaysStoppedAnimation<Color>(Theme.of(context).colorScheme.primary),
            ),
          ),
          const SizedBox(width: 10),
          Text(
            "Agent 正在思考并执行指令...",
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w500,
              color: isDark ? Colors.white70 : Colors.black87,
            ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;

    if (_isCheckingAuth) {
      return Scaffold(
        backgroundColor: isDark ? const Color(0xFF0F172A) : const Color(0xFFF8FAFC),
        body: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              CircularProgressIndicator(color: Theme.of(context).colorScheme.primary),
              const SizedBox(height: 16),
              Text(
                "正在验证连接凭证...",
                style: TextStyle(
                  fontSize: 13,
                  color: isDark ? Colors.white54 : Colors.black54,
                ),
              ),
            ],
          ),
        ),
      );
    }

    if (!_isLoggedIn) {
      return _buildLoginScreen(context, isDark);
    }

    return Scaffold(
      drawer: QuotaDrawer(
        nodes: _nodes,
        selectedNode: _selectedNode,
        onSwitchNode: _switchNode,
        quotaData: _quotaData,
        isLoadingQuota: _isLoadingQuota,
        onRequestQuota: _requestQuota,
        onNewSession: _showNewSessionDialog,
        onNewSessionInProject: (projectName, wsPath) => _showNewSessionDialog(
          initialProjectName: projectName,
          initialWorkspacePath: wsPath,
        ),
        projects: _projects,
        generalSessions: _generalSessions,
        activeSessionId: _activeSessionId,
        runningSessionIds: _runningSessionIds,
        onSwitchSession: _switchSession,
        onDeleteSession: _deleteSession,
        isDark: isDark,
        onToggleTheme: _toggleTheme,
        currentAccentThemeId: accentThemeNotifier.value.id,
        onSelectAccentTheme: _updateAccentTheme,
        currentDisplayName: _currentDisplayName.isNotEmpty ? _currentDisplayName : (_currentUsername.isNotEmpty ? _currentUsername : "User"),
        onLogout: _handleLogout,
      ),
      onDrawerChanged: (isOpen) {
        if (isOpen) _requestQuota();
      },
      appBar: AppBar(
        backgroundColor: isDark ? const Color(0xFF161F30) : Colors.white,
        elevation: isDark ? 0 : 1,
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              _activeSessionTitle,
              style: TextStyle(fontSize: 14, fontWeight: FontWeight.bold, color: isDark ? Colors.white : Colors.black87),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            Row(
              children: [
                Container(
                  width: 7,
                  height: 7,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: _isConnected ? Colors.greenAccent : (_isConnecting ? Colors.orangeAccent : Colors.redAccent),
                  ),
                ),
                const SizedBox(width: 5),
                Text(
                  _isConnected ? "在线 ($_currentIp)" : (_isConnecting ? "连接中..." : "未连接"),
                  style: TextStyle(fontSize: 10, color: isDark ? Colors.white54 : Colors.black45),
                ),
              ],
            ),
          ],
        ),
        actions: [
          _buildNodeSwitchButton(isDark),
          IconButton(
            icon: Icon(isDark ? Icons.light_mode_rounded : Icons.dark_mode_rounded, size: 20),
            tooltip: isDark ? "切换为日间模式" : "切换为夜间模式",
            onPressed: () => _toggleTheme(!isDark),
          ),
          IconButton(icon: const Icon(Icons.settings_outlined), onPressed: _showSettingsDialog),
        ],
      ),
      body: Column(
        children: [
          Expanded(
            child: _messages.isEmpty
                ? Center(
                    child: Text(
                      _isConnected ? "等待 Agent 动态...\n点击左上角 [≡] 可切换项目与会话" : "尚未连接到电脑端\n请在右上角设置中检查 IP",
                      textAlign: TextAlign.center,
                      style: TextStyle(color: isDark ? Colors.white38 : Colors.black38, fontSize: 13, height: 1.5),
                    ),
                  )
                : Stack(
                    children: [
                      ListView.builder(
                        controller: _scrollController,
                        reverse: true,
                        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                        itemCount: _messages.length + (_isThinking ? 1 : 0),
                        itemBuilder: (ctx, idx) {
                          if (_isThinking && idx == 0) {
                            return _buildThinkingIndicator(isDark);
                          }
                          final msgIdx = _isThinking ? idx - 1 : idx;
                          final msg = _messages[msgIdx];
                          return MessageCard(
                            key: ValueKey(msg.messageKey),
                            msg: msg,
                            isLatest: (msgIdx == 0),
                            isDark: isDark,
                            authToken: _authToken,
                            selectedNode: _selectedNode,
                            onDownloadFile: (p, {filename}) => _downloadFile(p, filename: filename),
                            onReadFile: (p) => _requestReadFile(p),
                            onOpenUrl: (url) => JsBridge.openUrl(url),
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
                                    color: Colors.black.withOpacity(0.3),
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
                                    "回到底部",
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
          BottomInputBar(
            inputController: _inputController,
            isConnected: _isConnected,
            isThinking: _isThinking,
            isDark: isDark,
            showSlashMenu: _showSlashMenu,
            filteredSlashCommands: _filteredSlashCommands,
            onSelectSlashCommand: _applySlashCommand,
            pendingAttachments: _pendingAttachments,
            onRemoveAttachment: (idx) {
              setState(() {
                _pendingAttachments.removeAt(idx);
              });
            },
            onShowAddContext: _showAddContextSheet,
            onSendMessage: _sendMessage,
            onStopTask: _stopCurrentTask,
          ),
        ],
      ),
    );
  }

  Widget _buildLoginScreen(BuildContext context, bool isDark) {
    return Scaffold(
      backgroundColor: isDark ? const Color(0xFF0F172A) : const Color(0xFFF8FAFC),
      body: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: Container(
            constraints: const BoxConstraints(maxWidth: 400),
            padding: const EdgeInsets.all(32),
            decoration: BoxDecoration(
              color: isDark ? const Color(0xFF1E293B) : Colors.white,
              borderRadius: BorderRadius.circular(20),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withValues(alpha: isDark ? 0.4 : 0.08),
                  blurRadius: 24,
                  offset: const Offset(0, 8),
                ),
              ],
              border: Border.all(
                color: isDark ? Colors.white12 : Colors.black12,
              ),
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                // Logo & 标题
                Center(
                  child: Container(
                    width: 56,
                    height: 56,
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        colors: [Theme.of(context).colorScheme.primary, Colors.blueAccent],
                        begin: Alignment.topLeft,
                        end: Alignment.bottomRight,
                      ),
                      borderRadius: BorderRadius.circular(16),
                    ),
                    child: const Icon(Icons.hub_rounded, color: Colors.white, size: 32),
                  ),
                ),
                const SizedBox(height: 18),
                Center(
                  child: Text(
                    "AGY Remote Hub",
                    style: TextStyle(
                      fontSize: 22,
                      fontWeight: FontWeight.bold,
                      color: isDark ? Colors.white : Colors.black87,
                      letterSpacing: 0.5,
                    ),
                  ),
                ),
                const SizedBox(height: 6),
                Center(
                  child: Text(
                    "请输入您的账号与密码登录控制台",
                    style: TextStyle(
                      fontSize: 12,
                      color: isDark ? Colors.white54 : Colors.black54,
                    ),
                  ),
                ),
                const SizedBox(height: 28),

                // 错误提示
                if (_loginErrorMessage.isNotEmpty) ...[
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                    decoration: BoxDecoration(
                      color: Colors.redAccent.withValues(alpha: 0.15),
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(color: Colors.redAccent.withValues(alpha: 0.4)),
                    ),
                    child: Row(
                      children: [
                        const Icon(Icons.error_outline_rounded, color: Colors.redAccent, size: 16),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            _loginErrorMessage,
                            style: const TextStyle(color: Colors.redAccent, fontSize: 12),
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 16),
                ],

                // 账号输入框
                TextField(
                  controller: _loginUsernameController,
                  textInputAction: TextInputAction.next,
                  style: TextStyle(color: isDark ? Colors.white : Colors.black87, fontSize: 14),
                  decoration: InputDecoration(
                    labelText: "账号 (Username)",
                    hintText: "请输入用户名",
                    prefixIcon: const Icon(Icons.person_outline_rounded, size: 20),
                    filled: true,
                    fillColor: isDark ? const Color(0xFF0F172A) : const Color(0xFFF1F5F9),
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(12),
                      borderSide: BorderSide.none,
                    ),
                    contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
                  ),
                ),
                const SizedBox(height: 16),

                // 密码输入框
                TextField(
                  controller: _loginPasswordController,
                  obscureText: _loginObscurePassword,
                  textInputAction: TextInputAction.done,
                  onSubmitted: (_) => _handleLogin(),
                  style: TextStyle(color: isDark ? Colors.white : Colors.black87, fontSize: 14),
                  decoration: InputDecoration(
                    labelText: "密码 (Password)",
                    hintText: "请输入密码",
                    prefixIcon: const Icon(Icons.lock_outline_rounded, size: 20),
                    suffixIcon: IconButton(
                      icon: Icon(
                        _loginObscurePassword ? Icons.visibility_off_outlined : Icons.visibility_outlined,
                        size: 20,
                      ),
                      onPressed: () {
                        setState(() {
                          _loginObscurePassword = !_loginObscurePassword;
                        });
                      },
                    ),
                    filled: true,
                    fillColor: isDark ? const Color(0xFF0F172A) : const Color(0xFFF1F5F9),
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(12),
                      borderSide: BorderSide.none,
                    ),
                    contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
                  ),
                ),
                const SizedBox(height: 24),

                // 登录按钮
                FilledButton(
                  onPressed: _isLoggingIn ? null : _handleLogin,
                  style: FilledButton.styleFrom(
                    padding: const EdgeInsets.symmetric(vertical: 14),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                  ),
                  child: _isLoggingIn
                      ? const SizedBox(
                          width: 20,
                          height: 20,
                          child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                        )
                      : const Text(
                          "立即登录",
                          style: TextStyle(fontSize: 15, fontWeight: FontWeight.bold),
                        ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  @override
  void dispose() {
    _loginUsernameController.dispose();
    _loginPasswordController.dispose();
    _quotaPollingTimer?.cancel();
    _heartbeatTimer?.cancel();
    _reconnectTimer?.cancel();
    _channel?.sink.close();
    _scrollController.removeListener(_onScrollChanged);
    _inputController.removeListener(_onInputChanged);
    _scrollController.dispose();
    _ipController.dispose();
    _inputController.dispose();
    _tokenController.dispose();
    super.dispose();
  }
}

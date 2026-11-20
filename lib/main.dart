import 'dart:convert';
import 'dart:async';
import 'bridge/js_bridge.dart';
import 'constants/app_colors.dart';
import 'models/models.dart';
import 'widgets/widgets.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_markdown/flutter_markdown.dart';
import 'package:web_socket_channel/web_socket_channel.dart';
import 'package:shared_preferences/shared_preferences.dart';

// 全局主题监听器
final ValueNotifier<ThemeMode> themeNotifier = ValueNotifier(ThemeMode.dark);

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
  }

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<ThemeMode>(
      valueListenable: themeNotifier,
      builder: (ctx, currentThemeMode, _) {
        return MaterialApp(
          title: 'AGY Remote',
          debugShowCheckedModeBanner: false,
          themeMode: currentThemeMode,
          // 优雅日间模式
          theme: ThemeData(
            useMaterial3: true,
            brightness: Brightness.light,
            scaffoldBackgroundColor: AppColors.lightBg,
            colorScheme: const ColorScheme.light(
              primary: AppColors.primaryBlue,
              surface: AppColors.lightSurface,
              background: AppColors.lightBg,
            ),
          ),
          // 深度暗夜模式
          darkTheme: ThemeData(
            useMaterial3: true,
            brightness: Brightness.dark,
            scaffoldBackgroundColor: AppColors.darkBg,
            colorScheme: const ColorScheme.dark(
              primary: AppColors.primarySky,
              surface: AppColors.darkSurface,
              background: AppColors.darkBg,
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
  final TextEditingController _ipController = TextEditingController();
  final TextEditingController _inputController = TextEditingController();
  final TextEditingController _tokenController = TextEditingController();
  final List<AgentMessage> _messages = [];
  final Map<String, List<SessionItem>> _projects = {};
  final List<SessionItem> _generalSessions = [];
  final ScrollController _scrollController = ScrollController();

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
  bool _isThinking = false;
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
      _isThinking = false;
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


  @override
  void initState() {
    super.initState();
    _inputController.addListener(_onInputChanged);
    _initWebPasteListener();
    _loadSavedIp();
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
    final savedToken = prefs.getString('auth_token');
    final savedNode = prefs.getString('selected_node');

    if (savedNode != null && savedNode.isNotEmpty) {
      _selectedNode = savedNode;
    }

    if (kIsWeb) {
      final urlToken = Uri.base.queryParameters['token'];
      if (urlToken != null && urlToken.isNotEmpty) {
        _authToken = urlToken;
        await prefs.setString('auth_token', urlToken);
      } else if (savedToken != null && savedToken.isNotEmpty) {
        _authToken = savedToken;
      }
      final urlNode = Uri.base.queryParameters['node'];
      if (urlNode != null && urlNode.isNotEmpty) {
        _selectedNode = urlNode;
        await prefs.setString('selected_node', urlNode);
      }
    } else if (savedToken != null && savedToken.isNotEmpty) {
      _authToken = savedToken;
    }
    _tokenController.text = _authToken;

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
    _connect();
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

  void _connect() {
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
            final type = data['type'];

            if (type == 'nodes_status') {
              final rawNodes = data['nodes'] as List<dynamic>?;
              if (rawNodes != null) {
                setState(() {
                  _nodes = rawNodes.map((n) => HostNode.fromJson(n)).toList();
                });
              }
            } else if (type == 'node_offline') {
              final offlineMsg = data['msg'] ?? '目标电脑当前已离线或未开机';
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(
                  content: Text(offlineMsg),
                  backgroundColor: Colors.redAccent.shade700,
                  behavior: SnackBarBehavior.floating,
                ),
              );
            } else if (type == 'auth_error') {
              final msg = data['msg'] ?? '访问口令 (Token) 错误';
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(content: Text(msg), backgroundColor: Colors.redAccent),
              );
              _showSettingsDialog();
              return;
            } else if (type == 'connected') {
              setState(() {
                _isConnected = true;
                _isConnecting = false;
                _activeSessionId = data['active_session'] ?? "";
              });
              _startHeartbeat();
              HapticFeedback.lightImpact();
            } else if (type == 'pong') {
              // 收到心跳响应，维持长连接活跃
            } else if (type == 'session_tree') {
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
            } else if (type == 'session_history') {
              final hist = (data['history'] as List).map((e) => AgentMessage.fromJson(e)).toList();
              setState(() {
                _messages.clear();
                _messages.addAll(hist.reversed);
              });
            } else if (type == 'quota_update') {
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
            } else if (type == 'file_browser_result') {
              final items = (data['items'] as List).map((e) => FileItem.fromJson(e)).toList();
              if (_fileModalSetState != null) {
                _fileModalSetState!(() {
                  _currentFiles = items;
                  _currentSubPath = data['current_path'] ?? "";
                  _baseDirName = data['base_dir_name'] ?? "工程根目录";
                });
              }
            } else if (type == 'file_content') {
              final path = data['path'] ?? '';
              final name = data['name'] ?? '文件';
              final content = data['content'] ?? '';
              final totalLines = data['total_lines'] ?? 0;
              final truncated = data['truncated'] ?? false;
              final size = data['size'] ?? 0;
              _showFileContentViewer(name, path, content, totalLines, truncated, size);
            } else if (type == 'file_content_error') {
              final err = data['error'] ?? '读取失败';
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(content: Text('文件读取失败: $err'), backgroundColor: Colors.redAccent),
              );
            } else if (type == 'git_diff_result') {
              final ws = data['workspace'] ?? '';
              final st = data['status'] ?? '';
              final df = data['diff'] ?? '';
              _showGitDiffViewer(ws, st, df);
            } else if (type == 'file_uploaded') {
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
            } else if (type == 'file_upload_error') {
              final err = data['error'] ?? '上传失败';
              setState(() {
                _pendingAttachments.removeWhere((a) => a.isUploading);
              });
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(content: Text("附件上传失败: $err"), backgroundColor: Colors.redAccent),
              );
            } else if (type == 'prompt_ack') {
              final status = data['status'];
              if (status == 'error') {
                setState(() {
                  _isThinking = false;
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
            } else if (type == 'status_change') {
              final isRunning = data['is_running'] == true;
              setState(() {
                _isThinking = isRunning;
              });
            } else if (type == 'stopped') {
              setState(() {
                _isThinking = false;
              });
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(
                  content: Text("任务已停止"),
                  behavior: SnackBarBehavior.floating,
                  duration: Duration(seconds: 1),
                ),
              );
            } else if (type == 'agent_update') {
              final newMsg = AgentMessage.fromJson(data);
              if (newMsg.content.isEmpty && newMsg.thinking.isEmpty && newMsg.toolCalls.isEmpty) {
                return;
              }
              // 关键：电脑端输入或模型仍在执行时，网页端必须保持红色停止按钮
              if (newMsg.isUser) {
                setState(() {
                  _isThinking = true;
                });
              } else {
                final backendRunning = data['is_running'];
                if (backendRunning != null) {
                  setState(() {
                    _isThinking = backendRunning == true;
                  });
                } else if (newMsg.status == 'DONE' && newMsg.toolCalls.isEmpty) {
                  setState(() {
                    _isThinking = false;
                  });
                } else {
                  setState(() {
                    _isThinking = true;
                  });
                }
              }

              // 避免乐观插入和广播重复
              if (newMsg.isUser && _messages.isNotEmpty && _messages.first.isUser && _messages.first.content == newMsg.content) {
                return;
              }
              setState(() {
                _messages.insert(0, newMsg);
              });

              if (newMsg.status == 'WAITING_APPROVAL' || newMsg.status == 'WAITING_INPUT') {
                HapticFeedback.mediumImpact();
              } else if (newMsg.status == 'DONE' && newMsg.content.isNotEmpty) {
                HapticFeedback.lightImpact();
              }
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
    });
    final payload = jsonEncode({"action": "switch_session", "session_id": session.id});
    _channel?.sink.add(payload);
    Navigator.pop(context);
    HapticFeedback.selectionClick();
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
      _isThinking = true;
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

  void _showFileContentViewer(String name, String path, String content, int totalLines, bool truncated, int size) {
    final isDark = Theme.of(context).brightness == Brightness.dark;

    // 🛡️ 防御：如果检测到 NUL 字节或二进制后缀，坚决拒绝纯文本排版，防止 CanvasKit 死锁
    if (content.contains('\x00') || _isBinaryFile(name)) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text("📦 文件 [$name] 为二进制文件，已自动转为下载通道"),
          behavior: SnackBarBehavior.floating,
          duration: const Duration(seconds: 3),
          action: SnackBarAction(
            label: "立即下载",
            textColor: Colors.cyanAccent,
            onPressed: () => _downloadFile(path),
          ),
        ),
      );
      _downloadFile(path);
      return;
    }

    final lines = content.split('\n');

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: isDark ? const Color(0xFF0F172A) : Colors.white,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(16))),
      builder: (ctx) {
        return Container(
          height: MediaQuery.of(context).size.height * 0.88,
          padding: const EdgeInsets.all(14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Icon(Icons.description_outlined, color: Theme.of(context).colorScheme.primary, size: 20),
                            const SizedBox(width: 8),
                            Expanded(
                              child: Text(
                                name,
                                style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: isDark ? Colors.white : Colors.black87),
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 2),
                        Text(
                          path,
                          style: TextStyle(fontSize: 10, color: isDark ? Colors.white38 : Colors.black38, fontFamily: 'monospace'),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ],
                    ),
                  ),
                  Row(
                    children: [
                      IconButton(
                        icon: const Icon(Icons.copy_rounded, size: 18),
                        tooltip: "复制全文",
                        onPressed: () {
                          Clipboard.setData(ClipboardData(text: content));
                          ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text("已复制到剪贴板")));
                        },
                      ),
                      IconButton(
                        icon: const Icon(Icons.close_rounded, size: 20),
                        onPressed: () => Navigator.pop(ctx),
                      ),
                    ],
                  ),
                ],
              ),
              Container(
                margin: const EdgeInsets.symmetric(vertical: 8),
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                decoration: BoxDecoration(
                  color: isDark ? Colors.white.withOpacity(0.05) : Colors.black.withOpacity(0.04),
                  borderRadius: BorderRadius.circular(6),
                ),
                child: Row(
                  children: [
                    Text(
                      truncated ? "共 $totalLines 行 (已显示前 2000 行)" : "共 $totalLines 行",
                      style: TextStyle(fontSize: 11, color: isDark ? Colors.white60 : Colors.black54),
                    ),
                    const Spacer(),
                    Text("${(size / 1024).toStringAsFixed(1)} KB", style: TextStyle(fontSize: 11, color: isDark ? Colors.white38 : Colors.black38)),
                  ],
                ),
              ),
              Expanded(
                child: Container(
                  decoration: BoxDecoration(
                    color: isDark ? const Color(0xFF090D16) : const Color(0xFFF8FAFC),
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(color: isDark ? const Color(0xFF23324A) : const Color(0xFFE2E8F0)),
                  ),
                  child: SingleChildScrollView(
                    scrollDirection: Axis.horizontal,
                    child: SingleChildScrollView(
                      child: Padding(
                        padding: const EdgeInsets.all(10),
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Column(
                              crossAxisAlignment: CrossAxisAlignment.end,
                              children: [
                                for (int i = 1; i <= lines.length; i++)
                                  Text(
                                    "$i  ",
                                    style: TextStyle(
                                      fontFamily: 'monospace',
                                      fontSize: 12,
                                      color: isDark ? Colors.white24 : Colors.black26,
                                      height: 1.45,
                                    ),
                                  ),
                              ],
                            ),
                            SelectableText(
                              content,
                              style: TextStyle(
                                fontFamily: 'monospace',
                                fontSize: 12,
                                color: isDark ? const Color(0xFFE2E8F0) : const Color(0xFF1E293B),
                                height: 1.45,
                              ),
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
        );
      },
    );
  }

  void _showGitDiffViewer(String workspace, String status, String diff) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final diffLines = diff.isEmpty ? <String>[] : diff.split('\n');
    final statusLines = status.isEmpty ? <String>[] : status.split('\n');

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: isDark ? const Color(0xFF0F172A) : Colors.white,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(16))),
      builder: (ctx) {
        return Container(
          height: MediaQuery.of(context).size.height * 0.88,
          padding: const EdgeInsets.all(14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Row(
                    children: [
                      const Icon(Icons.difference_rounded, color: Color(0xFF38BDF8), size: 22),
                      const SizedBox(width: 8),
                      Text(
                        "Git 变更审查 (Diff)",
                        style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: isDark ? Colors.white : Colors.black87),
                      ),
                    ],
                  ),
                  IconButton(
                    icon: const Icon(Icons.close_rounded, size: 20),
                    onPressed: () => Navigator.pop(ctx),
                  ),
                ],
              ),
              Text(
                "工作区: ${workspace.split(RegExp(r'[\\/]')).last}",
                style: TextStyle(fontSize: 11, color: isDark ? Colors.white38 : Colors.black38, fontFamily: 'monospace'),
              ),
              const SizedBox(height: 10),

              if (statusLines.isNotEmpty && status.trim().isNotEmpty) ...[
                Wrap(
                  spacing: 6,
                  runSpacing: 6,
                  children: statusLines.map((s) {
                    final isModified = s.contains('M');
                    final isAdded = s.contains('A') || s.contains('?');
                    final isDeleted = s.contains('D');
                    final color = isModified
                        ? const Color(0xFFF59E0B)
                        : (isAdded ? const Color(0xFF10B981) : (isDeleted ? const Color(0xFFEF4444) : Colors.blueGrey));
                    return Container(
                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                      decoration: BoxDecoration(
                        color: color.withOpacity(0.15),
                        borderRadius: BorderRadius.circular(6),
                        border: Border.all(color: color.withOpacity(0.3)),
                      ),
                      child: Text(
                        s.trim(),
                        style: TextStyle(fontSize: 11, fontFamily: 'monospace', color: color, fontWeight: FontWeight.bold),
                      ),
                    );
                  }).toList(),
                ),
                const SizedBox(height: 10),
              ],

              Expanded(
                child: diff.trim().isEmpty
                    ? Center(
                        child: Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            const Icon(Icons.check_circle_outline_rounded, color: Colors.greenAccent, size: 48),
                            const SizedBox(height: 12),
                            Text("工作区干净 (Clean)", style: TextStyle(color: isDark ? Colors.white70 : Colors.black87, fontWeight: FontWeight.bold)),
                            const SizedBox(height: 4),
                            Text("当前没有未提交的代码修改", style: TextStyle(color: isDark ? Colors.white38 : Colors.black38, fontSize: 12)),
                          ],
                        ),
                      )
                    : Container(
                        decoration: BoxDecoration(
                          color: isDark ? const Color(0xFF090D16) : const Color(0xFFF8FAFC),
                          borderRadius: BorderRadius.circular(10),
                          border: Border.all(color: isDark ? const Color(0xFF23324A) : const Color(0xFFE2E8F0)),
                        ),
                        child: SingleChildScrollView(
                          scrollDirection: Axis.horizontal,
                          child: SingleChildScrollView(
                            padding: const EdgeInsets.all(8),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: diffLines.map((line) {
                                Color? bgColor;
                                Color textColor = isDark ? const Color(0xFFE2E8F0) : const Color(0xFF1E293B);
                                FontWeight fontWeight = FontWeight.normal;

                                if (line.startsWith('+') && !line.startsWith('+++')) {
                                  bgColor = const Color(0x2822C55E);
                                  textColor = const Color(0xFF4ADE80);
                                } else if (line.startsWith('-') && !line.startsWith('---')) {
                                  bgColor = const Color(0x28EF4444);
                                  textColor = const Color(0xFFF87171);
                                } else if (line.startsWith('@@')) {
                                  bgColor = const Color(0x1F38BDF8);
                                  textColor = const Color(0xFF38BDF8);
                                  fontWeight = FontWeight.bold;
                                } else if (line.startsWith('diff --git')) {
                                  textColor = Theme.of(context).colorScheme.primary;
                                  fontWeight = FontWeight.bold;
                                }

                                return Container(
                                  color: bgColor,
                                  padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
                                  child: Text(
                                    line,
                                    style: TextStyle(
                                      fontFamily: 'monospace',
                                      fontSize: 11.5,
                                      color: textColor,
                                      fontWeight: fontWeight,
                                      height: 1.4,
                                    ),
                                  ),
                                );
                              }).toList(),
                            ),
                          ),
                        ),
                      ),
              ),
            ],
          ),
        );
      },
    );
  }


  bool _isBinaryFile(String path) {
    final lower = path.toLowerCase();
    final ext = lower.contains('.') ? lower.split('.').last : '';
    const binaryExts = {
      'zip', 'rar', '7z', 'tar', 'gz', 'bz2', 'xz', 'tgz',
      'exe', 'dll', 'so', 'dylib', 'bin', 'iso', 'apk', 'msi',
      'pdf', 'docx', 'xlsx', 'pptx', 'doc', 'xls', 'ppt',
      'png', 'jpg', 'jpeg', 'gif', 'webp', 'ico', 'bmp', 'svg',
      'mp3', 'wav', 'ogg', 'm4a', 'flac',
      'mp4', 'mkv', 'avi', 'mov', 'webm',
      'wasm', 'pyc', 'class', 'o', 'a', 'lib', 'db', 'sqlite'
    };
    return binaryExts.contains(ext);
  }

  IconData _getFileIconData(String name, bool isDir) {
    if (isDir) return Icons.folder_rounded;
    final lower = name.toLowerCase();
    final ext = lower.contains('.') ? lower.split('.').last : '';
    if (const {'zip', 'rar', '7z', 'tar', 'gz', 'bz2', 'xz', 'tgz'}.contains(ext)) {
      return Icons.folder_zip_rounded;
    }
    if (const {'png', 'jpg', 'jpeg', 'gif', 'webp', 'ico', 'bmp', 'svg'}.contains(ext)) {
      return Icons.image_rounded;
    }
    if (const {'pdf', 'docx', 'xlsx', 'pptx', 'doc', 'xls', 'ppt'}.contains(ext)) {
      return Icons.description_rounded;
    }
    if (const {'exe', 'msi', 'apk', 'bin', 'iso'}.contains(ext)) {
      return Icons.extension_rounded;
    }
    if (const {'dart', 'py', 'js', 'ts', 'html', 'css', 'json', 'yaml', 'yml', 'sh', 'bat', 'c', 'cpp', 'h', 'java', 'go', 'rs', 'sql'}.contains(ext)) {
      return Icons.code_rounded;
    }
    return Icons.insert_drive_file_outlined;
  }

  Color _getFileIconColor(String name, bool isDir, BuildContext context) {
    if (isDir) return const Color(0xFFFBBF24);
    final lower = name.toLowerCase();
    final ext = lower.contains('.') ? lower.split('.').last : '';
    if (const {'zip', 'rar', '7z', 'tar', 'gz', 'bz2', 'xz', 'tgz'}.contains(ext)) {
      return const Color(0xFFF97316);
    }
    if (const {'png', 'jpg', 'jpeg', 'gif', 'webp', 'ico', 'bmp', 'svg'}.contains(ext)) {
      return const Color(0xFF10B981);
    }
    if (const {'pdf', 'docx', 'xlsx', 'pptx', 'doc', 'xls', 'ppt'}.contains(ext)) {
      return const Color(0xFFEF4444);
    }
    if (const {'exe', 'msi', 'apk', 'bin', 'iso'}.contains(ext)) {
      return const Color(0xFF8B5CF6);
    }
    return Theme.of(context).colorScheme.primary;
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

            return Container(
              height: MediaQuery.of(context).size.height * 0.75,
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Row(
                        children: [
                          Icon(Icons.folder_special_rounded, color: Theme.of(context).colorScheme.primary, size: 20),
                          const SizedBox(width: 8),
                          Text(
                            _currentSubPath.isEmpty ? "工作区: $_baseDirName" : ".../$_currentSubPath",
                            style: TextStyle(fontWeight: FontWeight.bold, fontSize: 14, color: isDark ? Colors.white : Colors.black87),
                            overflow: TextOverflow.ellipsis,
                          ),
                        ],
                      ),
                      IconButton(
                        icon: Icon(Icons.close, color: isDark ? Colors.white54 : Colors.black54, size: 20),
                        onPressed: () => Navigator.pop(ctx),
                      ),
                    ],
                  ),
                  Divider(color: isDark ? Colors.white12 : Colors.black12),

                  if (_currentSubPath.isNotEmpty)
                    InkWell(
                      onTap: () {
                        final parts = _currentSubPath.split('/');
                        parts.removeLast();
                        final parentPath = parts.join('/');
                        _channel?.sink.add(jsonEncode({"action": "browse_files", "sub_path": parentPath}));
                      },
                      child: Container(
                        padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 10),
                        margin: const EdgeInsets.only(bottom: 6),
                        decoration: BoxDecoration(
                          color: isDark ? Colors.white.withOpacity(0.04) : Colors.black.withOpacity(0.04),
                          borderRadius: BorderRadius.circular(6),
                        ),
                        child: Row(
                          children: [
                            Icon(Icons.arrow_upward_rounded, size: 16, color: Theme.of(context).colorScheme.primary),
                            const SizedBox(width: 8),
                            Text("返回上一层目录 (..)", style: TextStyle(color: Theme.of(context).colorScheme.primary, fontSize: 12)),
                          ],
                        ),
                      ),
                    ),

                  Expanded(
                    child: _currentFiles.isEmpty
                        ? const Center(child: CircularProgressIndicator())
                        : ListView.builder(
                            itemCount: _currentFiles.length,
                            itemBuilder: (c, idx) {
                              final item = _currentFiles[idx];
                              final isBin = _isBinaryFile(item.path);
                              return ListTile(
                                dense: true,
                                visualDensity: const VisualDensity(vertical: -2),
                                leading: Icon(
                                  _getFileIconData(item.name, item.isDir),
                                  color: _getFileIconColor(item.name, item.isDir, context),
                                  size: 18,
                                ),
                                title: Text(
                                  item.name,
                                  style: TextStyle(
                                    color: isDark ? (item.isDir ? Colors.white : const Color(0xFFE2E8F0)) : (item.isDir ? Colors.black87 : Colors.black54),
                                    fontSize: 13,
                                    fontWeight: item.isDir ? FontWeight.bold : FontWeight.normal,
                                  ),
                                ),
                                trailing: item.isDir
                                    ? Icon(Icons.chevron_right, size: 16, color: isDark ? Colors.white24 : Colors.black26)
                                    : Row(
                                        mainAxisSize: MainAxisSize.min,
                                        children: [
                                          IconButton(
                                            icon: const Icon(Icons.download_rounded, size: 18),
                                            tooltip: "下载到本地",
                                            color: Colors.greenAccent.shade400,
                                            onPressed: () => _downloadFile(item.path),
                                          ),
                                          if (!isBin)
                                            IconButton(
                                              icon: const Icon(Icons.visibility_outlined, size: 18),
                                              tooltip: "查看内容",
                                              color: Theme.of(context).colorScheme.primary,
                                              onPressed: () => _requestReadFile(item.path),
                                            ),
                                          IconButton(
                                            icon: const Icon(Icons.add_comment_outlined, size: 18),
                                            tooltip: "引用到输入框",
                                            color: isDark ? Colors.white54 : Colors.black45,
                                            onPressed: () {
                                              Navigator.pop(ctx);
                                              _insertText("@file:${item.path} ");
                                              HapticFeedback.lightImpact();
                                            },
                                          ),
                                        ],
                                      ),
                                onTap: () {
                                  if (item.isDir) {
                                    _channel?.sink.add(jsonEncode({"action": "browse_files", "sub_path": item.path}));
                                  } else if (isBin) {
                                    _downloadFile(item.path);
                                    ScaffoldMessenger.of(context).showSnackBar(
                                      SnackBar(
                                        content: Text("📦 检测到文档/二进制文件 [${item.name}]，已为您触发直接下载"),
                                        behavior: SnackBarBehavior.floating,
                                        duration: const Duration(seconds: 2),
                                      ),
                                    );
                                  } else {
                                    _requestReadFile(item.path);
                                  }
                                },
                              );
                            },
                          ),
                  ),
                ],
              ),
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

    showModalBottomSheet(
      context: context,
      backgroundColor: isDark ? const Color(0xFF161F30) : Colors.white,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(16))),
      builder: (ctx) {
        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 8),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
                  child: Text(
                    "添加上下文",
                    style: TextStyle(color: isDark ? Colors.white54 : Colors.black45, fontSize: 12, fontWeight: FontWeight.bold),
                  ),
                ),
                Divider(color: isDark ? Colors.white12 : Colors.black12, height: 1),
                _buildContextMenuItem(Icons.upload_file_rounded, "添加本地文件", "从电脑/手机选择并上传本地代码、文档或配置", () {
                  if (kIsWeb) {
                    try {
                      JsBridge.pickFile('*/*', false);
                    } catch (e) {
                      debugPrint("pickFile error: $e");
                    }
                  }
                }),
                _buildContextMenuItem(Icons.image_outlined, "上传图片", "选择本地图片上传 (也可直接按 Ctrl+V 粘贴)", () {
                  if (kIsWeb) {
                    try {
                      JsBridge.pickFile('image/*', true);
                    } catch (e) {
                      debugPrint("pickFile error: $e");
                    }
                  }
                }),
                _buildContextMenuItem(Icons.difference_rounded, "Git 变更 Diff", "查看当前项目所有未提交修改对比", () {
                  _requestGitDiff();
                }),
                _buildContextMenuItem(Icons.folder_open_rounded, "工作区文件", "点选浏览工程文件并可直接查看代码", () {
                  _openWorkspaceFilePicker();
                }),
                _buildContextMenuItem(Icons.alternate_email, "提及", "快捷引用规则与技能", () {
                  _showMentionOptionsSheet();
                }),
                _buildContextMenuItem(Icons.check_box_outlined, "快捷操作", "一键执行测试或 Git 状态", () {
                  _showQuickActionsSheet();
                }),
                _buildContextMenuItem(Icons.language, "浏览器", "调度浏览器子代理交互", () {
                  _showPromptDialog("浏览器操作", "输入要测试或访问的网址:", (val) {
                    _insertText("请使用 browser 代理打开 $val 进行测试");
                  });
                }),
              ],
            ),
          ),
        );
      },
    );
  }

  void _showQuickActionsSheet() {
    final isDark = Theme.of(context).brightness == Brightness.dark;

    showModalBottomSheet(
      context: context,
      backgroundColor: isDark ? const Color(0xFF1E293B) : Colors.white,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(16))),
      builder: (ctx) {
        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text("常用快捷操作", style: TextStyle(fontWeight: FontWeight.bold, fontSize: 14, color: isDark ? Colors.white : Colors.black87)),
                const SizedBox(height: 12),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    _buildActionChip("🚀 运行测试", "/test"),
                    _buildActionChip("📊 Git 状态", "运行 git status 查看当前工作区修改"),
                    _buildActionChip("🧹 紧凑上下文", "/compact"),
                    _buildActionChip("🔍 检查报错", "分析刚才命令执行中的所有报错并给出修复方案"),
                    _buildActionChip("📖 查看帮助", "/help"),
                  ],
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  void _showMentionOptionsSheet() {
    final isDark = Theme.of(context).brightness == Brightness.dark;

    showModalBottomSheet(
      context: context,
      backgroundColor: isDark ? const Color(0xFF1E293B) : Colors.white,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(16))),
      builder: (ctx) {
        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text("快速提及", style: TextStyle(fontWeight: FontWeight.bold, fontSize: 14, color: isDark ? Colors.white : Colors.black87)),
                const SizedBox(height: 12),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    _buildActionChip("📜 全局协作约定", "@rules "),
                    _buildActionChip("💻 终端会话", "@terminal "),
                    _buildActionChip("🧩 故障排查技能", "@engineering-debugging "),
                    _buildActionChip("🐍 Python辅导", "@python-coaching "),
                  ],
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _buildActionChip(String label, String command) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return ActionChip(
      backgroundColor: isDark ? const Color(0xFF0F172A) : const Color(0xFFF1F5F9),
      side: BorderSide(color: isDark ? const Color(0xFF334155) : const Color(0xFFCBD5E1)),
      label: Text(label, style: TextStyle(color: isDark ? Colors.white : Colors.black87, fontSize: 12)),
      onPressed: () {
        Navigator.pop(context);
        _inputController.text = command;
      },
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

  Widget _buildContextMenuItem(IconData icon, String title, String subtitle, VoidCallback onTap) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return ListTile(
      dense: true,
      visualDensity: const VisualDensity(vertical: -2),
      leading: Icon(icon, color: Theme.of(context).colorScheme.primary, size: 20),
      title: Text(title, style: TextStyle(color: isDark ? Colors.white : Colors.black87, fontSize: 14)),
      trailing: Text(subtitle, style: TextStyle(color: isDark ? Colors.white30 : Colors.black26, fontSize: 11)),
      onTap: () {
        Navigator.pop(context);
        onTap();
      },
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

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return Scaffold(
      drawer: _buildAppDrawer(),
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
                : ListView.builder(
                    controller: _scrollController,
                    reverse: true,
                    padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                    itemCount: _messages.length + (_isThinking ? 1 : 0),
                    itemBuilder: (ctx, idx) {
                      if (_isThinking && idx == 0) {
                        return _buildThinkingIndicator(isDark);
                      }
                      final msgIdx = _isThinking ? idx - 1 : idx;
                      return _buildMessageCard(_messages[msgIdx]);
                    },
                  ),
          ),
          _buildBottomInputBar(),
        ],
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
                    color: node.isOnline ? Colors.greenAccent : (isDark ? Colors.white24 : Colors.black26),
                  ),
                ),
                const SizedBox(width: 4),
                Text(
                  node.isOnline ? "在线" : "离线",
                  style: TextStyle(
                    fontSize: 10,
                    color: node.isOnline ? Colors.greenAccent : (isDark ? Colors.white38 : Colors.black38),
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

  // 完美复刻抽屉侧边栏，底部带有【日间 / 夜间】切换开关
  Widget _buildAppDrawer() {
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return Drawer(
      backgroundColor: isDark ? const Color(0xFF0F172A) : Colors.white,
      child: SafeArea(
        child: Column(
          children: [
            // 设备切换指示器卡片
            Container(
              margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: isDark ? const Color(0xFF1E293B) : const Color(0xFFF8FAFC),
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: isDark ? Colors.white10 : Colors.black12),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Icon(Icons.hub_rounded, size: 14, color: isDark ? Colors.white54 : Colors.black45),
                      const SizedBox(width: 6),
                      Text("目标控制主机", style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold, color: isDark ? Colors.white54 : Colors.black45)),
                    ],
                  ),
                  const SizedBox(height: 6),
                  Row(
                    children: _nodes.map((node) {
                      final isSelected = node.id == _selectedNode;
                      final isDeck = node.id == "deck";
                      return Expanded(
                        child: InkWell(
                          onTap: () => _switchNode(node.id),
                          borderRadius: BorderRadius.circular(8),
                          child: Container(
                            padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 4),
                            margin: const EdgeInsets.symmetric(horizontal: 2),
                            decoration: BoxDecoration(
                              color: isSelected
                                  ? (isDark ? const Color(0xFF0284C7).withOpacity(0.3) : const Color(0xFFE0F2FE))
                                  : Colors.transparent,
                              borderRadius: BorderRadius.circular(8),
                              border: Border.all(
                                color: isSelected ? const Color(0xFF38BDF8) : Colors.transparent,
                                width: 1,
                              ),
                            ),
                            child: Row(
                              mainAxisAlignment: MainAxisAlignment.center,
                              children: [
                                Icon(
                                  isDeck ? Icons.videogame_asset_rounded : Icons.desktop_windows_rounded,
                                  size: 13,
                                  color: isSelected ? const Color(0xFF38BDF8) : (isDark ? Colors.white60 : Colors.black54),
                                ),
                                const SizedBox(width: 4),
                                Flexible(
                                  child: Text(
                                    node.name,
                                    style: TextStyle(
                                      fontSize: 11,
                                      fontWeight: isSelected ? FontWeight.bold : FontWeight.normal,
                                      color: isSelected
                                          ? (isDark ? Colors.white : const Color(0xFF0284C7))
                                          : (isDark ? Colors.white70 : Colors.black87),
                                    ),
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                ),
                                const SizedBox(width: 4),
                                Container(
                                  width: 6,
                                  height: 6,
                                  decoration: BoxDecoration(
                                    shape: BoxShape.circle,
                                    color: node.isOnline ? Colors.greenAccent : (isDark ? Colors.white24 : Colors.black26),
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      );
                    }).toList(),
                  ),
                ],
              ),
            ),

            // 实时模型额度展示卡片（官方底座真实配额）
            _buildQuotaCard(isDark),

            // 顶部操作栏: + 新建会话
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(border: Border(bottom: BorderSide(color: isDark ? Colors.white10 : Colors.black12))),
              child: ElevatedButton.icon(
                onPressed: () {
                  Navigator.pop(context);
                  _showNewSessionDialog();
                },
                style: ElevatedButton.styleFrom(
                  backgroundColor: isDark ? const Color(0xFF1E293B) : const Color(0xFFF1F5F9),
                  foregroundColor: isDark ? Colors.white : Colors.black87,
                  elevation: 0,
                  minimumSize: const Size(double.infinity, 40),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                ),
                icon: const Icon(Icons.add, size: 18),
                label: const Text("新建会话", style: TextStyle(fontSize: 13)),
              ),
            ),

            // 项目与会话列表
            Expanded(
              child: ListView(
                padding: const EdgeInsets.symmetric(vertical: 8),
                children: [
                  if (_projects.isNotEmpty) ...[
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
                      child: Text("项目列表", style: TextStyle(color: isDark ? Colors.white38 : Colors.black38, fontSize: 11, fontWeight: FontWeight.bold)),
                    ),
                    for (var entry in _projects.entries)
                      Theme(
                        data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
                        child: ExpansionTile(
                          initiallyExpanded: entry.value.any((s) => s.id == _activeSessionId),
                          tilePadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 0),
                          leading: Icon(Icons.folder_outlined, color: Theme.of(context).colorScheme.primary, size: 18),
                          title: Text(
                            entry.key,
                            style: TextStyle(color: isDark ? Colors.white : Colors.black87, fontSize: 13, fontWeight: FontWeight.bold),
                          ),
                          children: entry.value.map((s) => _buildSessionTile(s, isIndented: true)).toList(),
                        ),
                      ),
                    Divider(color: isDark ? Colors.white10 : Colors.black12, height: 16),
                  ],

                  if (_generalSessions.isNotEmpty) ...[
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
                      child: Text("会话列表", style: TextStyle(color: isDark ? Colors.white38 : Colors.black38, fontSize: 11, fontWeight: FontWeight.bold)),
                    ),
                    for (var s in _generalSessions) _buildSessionTile(s, isIndented: false),
                  ],
                ],
              ),
            ),

            // 抽屉底部：日间 / 夜间模式一键切换
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
              decoration: BoxDecoration(border: Border(top: BorderSide(color: isDark ? Colors.white10 : Colors.black12))),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Row(
                    children: [
                      Icon(isDark ? Icons.dark_mode_outlined : Icons.light_mode_outlined, size: 18, color: Theme.of(context).colorScheme.primary),
                      const SizedBox(width: 8),
                      Text(isDark ? "夜间模式" : "日间模式", style: TextStyle(fontSize: 13, color: isDark ? Colors.white70 : Colors.black87)),
                    ],
                  ),
                  Switch(
                    value: isDark,
                    activeColor: Theme.of(context).colorScheme.primary,
                    onChanged: (val) => _toggleTheme(val),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  // 官方底座模型实时配额卡片（周额度与 5 小时滑动额度）
  Widget _buildQuotaCard(bool isDark) {
    final groups = (_quotaData != null && _quotaData!['groups'] is List)
        ? (_quotaData!['groups'] as List)
        : [];

    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: isDark ? const Color(0xFF161F30) : const Color(0xFFF8FAFC),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: isDark ? const Color(0xFF23324A) : const Color(0xFFE2E8F0)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Row(
                children: [
                  Icon(
                    Icons.speed_rounded,
                    size: 14,
                    color: isDark ? const Color(0xFF38BDF8) : const Color(0xFF0284C7),
                  ),
                  const SizedBox(width: 5),
                  Text(
                    "模型实时额度",
                    style: TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.bold,
                      color: isDark ? Colors.white70 : Colors.black87,
                    ),
                  ),
                ],
              ),
              InkWell(
                onTap: _isLoadingQuota ? null : _requestQuota,
                borderRadius: BorderRadius.circular(12),
                child: Padding(
                  padding: const EdgeInsets.all(2),
                  child: _isLoadingQuota
                      ? SizedBox(
                          width: 11,
                          height: 11,
                          child: CircularProgressIndicator(
                            strokeWidth: 1.5,
                            color: Theme.of(context).colorScheme.primary,
                          ),
                        )
                      : Icon(
                          Icons.refresh_rounded,
                          size: 14,
                          color: isDark ? Colors.white54 : Colors.black45,
                        ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          if (groups.isEmpty)
            Center(
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 4),
                child: InkWell(
                  onTap: _requestQuota,
                  child: Text(
                    _isLoadingQuota ? "正在拉取配额..." : "点击同步官方实时配额",
                    style: TextStyle(
                      fontSize: 11,
                      color: isDark ? Colors.white38 : Colors.black38,
                    ),
                  ),
                ),
              ),
            )
          else
            Column(
              children: [
                for (int i = 0; i < groups.length; i++) ...[
                  if (i > 0)
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 5),
                      child: Divider(
                        color: isDark ? Colors.white10 : Colors.black12,
                        height: 1,
                      ),
                    ),
                  _buildQuotaGroup(groups[i], isDark),
                ],
              ],
            ),
        ],
      ),
    );
  }

  Widget _buildQuotaGroup(dynamic groupData, bool isDark) {
    if (groupData is! Map) return const SizedBox.shrink();
    final group = Map<String, dynamic>.from(groupData);
    final rawName = group['displayName']?.toString() ?? "";
    String groupTitle = rawName;
    if (rawName.toLowerCase().contains("gemini")) {
      groupTitle = "Gemini 系列";
    } else if (rawName.toLowerCase().contains("claude")) {
      groupTitle = "Claude & GPT";
    }

    final buckets = (group['buckets'] is List) ? (group['buckets'] as List) : [];

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          groupTitle,
          style: TextStyle(
            fontSize: 10.5,
            fontWeight: FontWeight.bold,
            color: isDark ? const Color(0xFF94A3B8) : const Color(0xFF475569),
          ),
        ),
        const SizedBox(height: 3),
        for (var bData in buckets)
          if (bData is Map) _buildBucketProgress(Map<String, dynamic>.from(bData), isDark),
      ],
    );
  }

  Widget _buildBucketProgress(Map<String, dynamic> bucket, bool isDark) {
    final rawId = bucket['bucketId']?.toString().toLowerCase() ?? "";
    final rawName = bucket['displayName']?.toString().toLowerCase() ?? "";
    final window = bucket['window']?.toString().toLowerCase() ?? "";

    String bucketLabel = "额度";
    if (rawId.contains("weekly") || rawName.contains("weekly") || window == "weekly") {
      bucketLabel = "周额度";
    } else if (rawId.contains("5h") || rawName.contains("5h") || window == "5h") {
      bucketLabel = "5小时滑动";
    }

    final double fraction = ((bucket['remainingFraction'] as num?)?.toDouble() ?? 1.0).clamp(0.0, 1.0);
    final pctText = "${(fraction * 100).toStringAsFixed(1)}%";
    final resetText = _formatResetTime(bucket['resetTime']?.toString());

    Color barColor;
    if (fraction >= 0.5) {
      barColor = isDark ? const Color(0xFF38BDF8) : const Color(0xFF0284C7);
    } else if (fraction >= 0.2) {
      barColor = const Color(0xFFFBBF24);
    } else {
      barColor = const Color(0xFFF87171);
    }

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2.5),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                bucketLabel,
                style: TextStyle(
                  fontSize: 10,
                  color: isDark ? Colors.white60 : Colors.black54,
                ),
              ),
              Row(
                children: [
                  if (resetText.isNotEmpty) ...[
                    Text(
                      resetText,
                      style: TextStyle(
                        fontSize: 9,
                        color: isDark ? Colors.white30 : Colors.black26,
                      ),
                    ),
                    const SizedBox(width: 5),
                  ],
                  Text(
                    pctText,
                    style: TextStyle(
                      fontSize: 10,
                      fontWeight: FontWeight.bold,
                      color: barColor,
                    ),
                  ),
                ],
              ),
            ],
          ),
          const SizedBox(height: 2),
          ClipRRect(
            borderRadius: BorderRadius.circular(2.5),
            child: LinearProgressIndicator(
              value: fraction,
              minHeight: 4,
              backgroundColor: isDark ? const Color(0xFF0B0F19) : const Color(0xFFE2E8F0),
              valueColor: AlwaysStoppedAnimation<Color>(barColor),
            ),
          ),
        ],
      ),
    );
  }

  String _formatResetTime(String? resetTimeStr) {
    if (resetTimeStr == null || resetTimeStr.isEmpty) return "";
    try {
      final resetTime = DateTime.parse(resetTimeStr).toLocal();
      final now = DateTime.now();
      final diff = resetTime.difference(now);
      if (diff.isNegative) return "已刷新";
      final days = diff.inDays;
      final hours = diff.inHours % 24;
      final minutes = diff.inMinutes % 60;
      if (days > 0) {
        return "$days天$hours时重置";
      } else if (hours > 0) {
        return "$hours时$minutes分重置";
      } else {
        return "$minutes分重置";
      }
    } catch (_) {
      return "";
    }
  }

  Map<String, dynamic> _parseToolArgs(dynamic rawArgs) {
    if (rawArgs == null) return {};
    if (rawArgs is Map<String, dynamic>) return rawArgs;
    if (rawArgs is Map) return Map<String, dynamic>.from(rawArgs);
    if (rawArgs is String) {
      try {
        final decoded = jsonDecode(rawArgs);
        if (decoded is Map) return Map<String, dynamic>.from(decoded);
      } catch (_) {}
    }
    return {};
  }

  String _cleanPath(dynamic p) {
    if (p == null) return "";
    return p.toString().replaceAll('"', '').trim();
  }

  String _cleanCodeString(dynamic val) {
    if (val == null) return "";
    String s = val.toString();
    if (s.startsWith('"') && s.endsWith('"') && s.length >= 2) {
      s = s.substring(1, s.length - 1);
    }
    return s.replaceAll(r'\n', '\n').replaceAll(r'\"', '"').replaceAll(r'\\', '\\');
  }

  Widget _buildDiffView(String targetCode, String replacementCode, String filePath) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final targetLines = targetCode.isEmpty ? <String>[] : targetCode.split('\n');
    final repLines = replacementCode.isEmpty ? <String>[] : replacementCode.split('\n');

    return Container(
      margin: const EdgeInsets.only(top: 6),
      decoration: BoxDecoration(
        color: isDark ? const Color(0xFF090D16) : const Color(0xFFF8FAFC),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: isDark ? const Color(0xFF23324A) : const Color(0xFFE2E8F0)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (filePath.isNotEmpty)
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
              decoration: BoxDecoration(
                color: isDark ? Colors.white.withOpacity(0.04) : Colors.black.withOpacity(0.03),
                borderRadius: const BorderRadius.vertical(top: Radius.circular(8)),
              ),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Expanded(
                    child: Text(
                      filePath.split(RegExp(r'[\\/]')).last,
                      style: TextStyle(
                        fontFamily: 'monospace',
                        fontSize: 11,
                        fontWeight: FontWeight.bold,
                        color: Theme.of(context).colorScheme.primary,
                      ),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  InkWell(
                    onTap: () => _requestReadFile(filePath),
                    child: Row(
                      children: [
                        Icon(Icons.visibility_outlined, size: 13, color: Theme.of(context).colorScheme.primary),
                        const SizedBox(width: 4),
                        Text("查看全文", style: TextStyle(fontSize: 11, color: Theme.of(context).colorScheme.primary)),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Padding(
              padding: const EdgeInsets.all(8),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  for (var line in targetLines)
                    Container(
                      color: const Color(0x28EF4444),
                      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
                      child: Text(
                        "- $line",
                        style: const TextStyle(
                          fontFamily: 'monospace',
                          fontSize: 11.5,
                          color: Color(0xFFF87171),
                          height: 1.4,
                        ),
                      ),
                    ),
                  for (var line in repLines)
                    Container(
                      color: const Color(0x2822C55E),
                      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
                      child: Text(
                        "+ $line",
                        style: const TextStyle(
                          fontFamily: 'monospace',
                          fontSize: 11.5,
                          color: Color(0xFF4ADE80),
                          height: 1.4,
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildToolCallWidget(dynamic rawTool, {required bool isStandalone}) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final tool = rawTool is Map ? rawTool : {};
    final name = (tool['name'] ?? 'tool').toString();
    final args = _parseToolArgs(tool['args']);

    if (name == 'edit_file') {
      final filePath = _cleanPath(args['Path'] ?? args['path']);
      final fileName = filePath.isEmpty ? '文件' : filePath.split(RegExp(r'[\\/]')).last;
      final target = _cleanCodeString(args['Target'] ?? args['target']);
      final replacement = _cleanCodeString(args['Replacement'] ?? args['replacement']);

      return Container(
        margin: const EdgeInsets.symmetric(vertical: 2),
        decoration: BoxDecoration(
          color: isDark ? const Color(0xFF0D1525) : const Color(0xFFF1F5F9),
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: const Color(0xFF0284C7).withOpacity(0.3)),
        ),
        child: Theme(
          data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
          child: ExpansionTile(
            initiallyExpanded: false,
            tilePadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 0),
            childrenPadding: const EdgeInsets.only(left: 10, right: 10, bottom: 10),
            leading: const Icon(Icons.edit_note_rounded, color: Color(0xFF38BDF8), size: 18),
            title: Text(
              "edit_file: $fileName",
              style: const TextStyle(color: Color(0xFF38BDF8), fontSize: 12, fontWeight: FontWeight.bold, fontFamily: 'monospace'),
              overflow: TextOverflow.ellipsis,
            ),
            trailing: Container(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
              decoration: BoxDecoration(
                color: const Color(0xFF0284C7).withOpacity(0.2),
                borderRadius: BorderRadius.circular(4),
              ),
              child: const Text("Diff 对比", style: TextStyle(color: Color(0xFF38BDF8), fontSize: 10)),
            ),
            children: [
              _buildDiffView(target, replacement, filePath),
            ],
          ),
        ),
      );
    }

    if (name == 'write_file') {
      final filePath = _cleanPath(args['Path'] ?? args['path']);
      final fileName = filePath.isEmpty ? '文件' : filePath.split(RegExp(r'[\\/]')).last;
      final content = _cleanCodeString(args['Content'] ?? args['content']);

      return Container(
        margin: const EdgeInsets.symmetric(vertical: 2),
        decoration: BoxDecoration(
          color: isDark ? const Color(0xFF0D1525) : const Color(0xFFF1F5F9),
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: const Color(0xFF10B981).withOpacity(0.3)),
        ),
        child: Theme(
          data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
          child: ExpansionTile(
            initiallyExpanded: false,
            tilePadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 0),
            childrenPadding: const EdgeInsets.only(left: 10, right: 10, bottom: 10),
            leading: const Icon(Icons.post_add_rounded, color: Color(0xFF34D399), size: 18),
            title: Text(
              "write_file: $fileName",
              style: const TextStyle(color: Color(0xFF34D399), fontSize: 12, fontWeight: FontWeight.bold, fontFamily: 'monospace'),
              overflow: TextOverflow.ellipsis,
            ),
            trailing: InkWell(
              onTap: filePath.isNotEmpty ? () => _requestReadFile(filePath) : null,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                decoration: BoxDecoration(
                  color: const Color(0xFF10B981).withOpacity(0.2),
                  borderRadius: BorderRadius.circular(4),
                ),
                child: const Text("查看文件", style: TextStyle(color: Color(0xFF34D399), fontSize: 10)),
              ),
            ),
            children: [
              Container(
                margin: const EdgeInsets.only(top: 6),
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: isDark ? const Color(0xFF090D16) : Colors.white,
                  borderRadius: BorderRadius.circular(6),
                ),
                child: SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: SelectableText(
                    content,
                    style: TextStyle(
                      fontFamily: 'monospace',
                      fontSize: 11.5,
                      color: isDark ? const Color(0xFFE2E8F0) : const Color(0xFF1E293B),
                      height: 1.4,
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      );
    }

    if (name == 'read_file') {
      final filePath = _cleanPath(args['Path'] ?? args['path']);
      final fileName = filePath.isEmpty ? '文件' : filePath.split(RegExp(r'[\\/]')).last;

      return Container(
        margin: const EdgeInsets.symmetric(vertical: 2),
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        decoration: BoxDecoration(
          color: isDark ? Colors.white.withOpacity(0.04) : Colors.black.withOpacity(0.04),
          borderRadius: BorderRadius.circular(6),
        ),
        child: Row(
          children: [
            const Icon(Icons.menu_book_rounded, color: Color(0xFFFBBF24), size: 15),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                "read_file: $fileName",
                style: TextStyle(fontFamily: 'monospace', fontSize: 11.5, color: isDark ? Colors.white70 : Colors.black87),
                overflow: TextOverflow.ellipsis,
              ),
            ),
            if (filePath.isNotEmpty)
              InkWell(
                onTap: () => _requestReadFile(filePath),
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                  decoration: BoxDecoration(
                    color: const Color(0xFFFBBF24).withOpacity(0.15),
                    borderRadius: BorderRadius.circular(4),
                  ),
                  child: const Text("点此预览", style: TextStyle(color: Color(0xFFFBBF24), fontSize: 10, fontWeight: FontWeight.bold)),
                ),
              ),
          ],
        ),
      );
    }

    if (name == 'run_command') {
      final cmd = (args['CommandLine'] ?? args['command'] ?? '').toString();
      final summary = (args['toolSummary'] ?? '').toString();

      return Container(
        margin: const EdgeInsets.symmetric(vertical: 2),
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        decoration: BoxDecoration(
          color: isDark ? Colors.white.withOpacity(0.04) : Colors.black.withOpacity(0.04),
          borderRadius: BorderRadius.circular(6),
        ),
        child: Row(
          children: [
            Icon(Icons.terminal_rounded, color: isDark ? Colors.white38 : Colors.black38, size: 15),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                summary.isNotEmpty ? "$summary ($cmd)" : cmd,
                style: TextStyle(fontFamily: 'monospace', fontSize: 11, color: isDark ? Colors.white60 : Colors.black54),
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
        ),
      );
    }

    return Container(
      margin: const EdgeInsets.symmetric(vertical: 2),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: isDark ? Colors.white.withOpacity(0.03) : Colors.black.withOpacity(0.03),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.settings_suggest_rounded, color: isDark ? Colors.white38 : Colors.black38, size: 13),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              "工具: $name",
              style: TextStyle(color: isDark ? Colors.white54 : Colors.black54, fontSize: 11, fontFamily: 'monospace'),
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSessionTile(SessionItem s, {required bool isIndented}) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final isCurrent = s.id == _activeSessionId;

    return Container(
      margin: EdgeInsets.only(left: isIndented ? 28 : 10, right: 10, bottom: 2),
      decoration: BoxDecoration(
        color: isCurrent ? (isDark ? const Color(0xFF1E293B) : const Color(0xFFE2E8F0)) : Colors.transparent,
        borderRadius: BorderRadius.circular(6),
      ),
      child: ListTile(
        dense: true,
        visualDensity: const VisualDensity(vertical: -3),
        leading: Icon(
          Icons.chat_bubble_outline_rounded,
          size: 14,
          color: isCurrent ? Theme.of(context).colorScheme.primary : (isDark ? Colors.white38 : Colors.black38),
        ),
        title: Text(
          s.title,
          style: TextStyle(
            color: isCurrent ? Theme.of(context).colorScheme.primary : (isDark ? Colors.white70 : Colors.black87),
            fontSize: 12,
            fontWeight: isCurrent ? FontWeight.bold : FontWeight.normal,
          ),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (s.time.isNotEmpty)
              Text(
                s.time,
                style: TextStyle(color: isDark ? Colors.white24 : Colors.black26, fontSize: 9),
              ),
            const SizedBox(width: 4),
            InkWell(
              onTap: () => _confirmDeleteSession(s),
              borderRadius: BorderRadius.circular(12),
              child: Padding(
                padding: const EdgeInsets.all(4),
                child: Icon(
                  Icons.delete_outline_rounded,
                  size: 15,
                  color: isDark ? Colors.white30 : Colors.black38,
                ),
              ),
            ),
          ],
        ),
        onTap: () => _switchSession(s),
      ),
    );
  }

  void _confirmDeleteSession(SessionItem s) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    showDialog(
      context: context,
      builder: (ctx) {
        return AlertDialog(
          backgroundColor: isDark ? const Color(0xFF1E293B) : Colors.white,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
          title: const Text("删除此会话？", style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
          content: Text(
            "确定要删除「${s.title}」吗？\n删除后会话记录与本地上下文将被永久移除。",
            style: TextStyle(fontSize: 13, color: isDark ? Colors.white70 : Colors.black87),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: Text("取消", style: TextStyle(color: isDark ? Colors.white60 : Colors.black54)),
            ),
            ElevatedButton(
              onPressed: () {
                Navigator.pop(ctx);
                _deleteSession(s.id);
              },
              style: ElevatedButton.styleFrom(
                backgroundColor: Colors.redAccent.shade700,
                foregroundColor: Colors.white,
                elevation: 0,
              ),
              child: const Text("确认删除"),
            ),
          ],
        );
      },
    );
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

  List<String> _extractImagePaths(String text) {
    final List<String> paths = [];
    final reg = RegExp(r'\[用户上传图片:\s*(.*?)\]');
    for (final m in reg.allMatches(text)) {
      final p = m.group(1)?.trim();
      if (p != null && p.isNotEmpty && !paths.contains(p)) paths.add(p);
    }
    final reg2 = RegExp(r'([A-Za-z]:[\\/][^\s\n\r"\[\]]+\.(?:png|jpg|jpeg|webp)|/(?:home|tmp)[^\s\n\r"\[\]]+\.(?:png|jpg|jpeg|webp))');
    for (final m in reg2.allMatches(text)) {
      final p = m.group(1)?.trim();
      if (p != null && p.isNotEmpty && !paths.contains(p)) paths.add(p);
    }
    return paths;
  }

  List<String> _extractDownloadableFiles(String text) {
    final List<String> files = [];
    final reg = RegExp(
      r'(?:file:///)?([A-Za-z]:[\\/][^\s\n\r"\[\]<>]+\.(?:zip|tar\.gz|tgz|rar|7z|pdf|txt|py|json|bat|sh|csv|docx|xlsx|pptx)|/(?:home|tmp|root)[^\s\n\r"\[\]<>]+\.(?:zip|tar\.gz|tgz|rar|7z|pdf|txt|py|json|bat|sh|csv|docx|xlsx|pptx))',
      caseSensitive: false,
    );
    for (final m in reg.allMatches(text)) {
      final p = m.group(1)?.trim();
      if (p != null && p.isNotEmpty && !files.contains(p)) {
        files.add(p);
      }
    }
    return files;
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

  Widget _buildDownloadCard(String filePath, bool isDark) {
    final cleanPath = filePath.replaceAll('file:///', '').replaceAll('file://', '').trim();
    final fileName = cleanPath.split(RegExp(r'[\\/]')).last;

    return Container(
      margin: const EdgeInsets.only(top: 8),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: isDark ? const Color(0xFF1E293B) : const Color(0xFFF1F5F9),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: isDark ? const Color(0xFF334155) : const Color(0xFFCBD5E1)),
      ),
      child: Row(
        children: [
          Icon(
            Icons.inventory_2_outlined,
            size: 20,
            color: Theme.of(context).colorScheme.primary,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  fileName,
                  style: TextStyle(
                    fontSize: 12.5,
                    fontWeight: FontWeight.bold,
                    color: isDark ? Colors.white : Colors.black87,
                  ),
                  overflow: TextOverflow.ellipsis,
                ),
                Text(
                  cleanPath,
                  style: TextStyle(
                    fontSize: 10,
                    color: isDark ? Colors.white38 : Colors.black38,
                  ),
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          ElevatedButton.icon(
            onPressed: () => _downloadFile(cleanPath, filename: fileName),
            style: ElevatedButton.styleFrom(
              backgroundColor: Theme.of(context).colorScheme.primary,
              foregroundColor: Colors.white,
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
              minimumSize: const Size(0, 32),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(6)),
              elevation: 0,
            ),
            icon: const Icon(Icons.download_rounded, size: 14),
            label: const Text("下载", style: TextStyle(fontSize: 12)),
          ),
        ],
      ),
    );
  }

  Widget _buildImagePreviewWidget(String path, bool isDark) {
    final url = "/api/media?path=${Uri.encodeComponent(path)}&token=$_authToken";
    return Container(
      margin: const EdgeInsets.only(top: 8),
      constraints: const BoxConstraints(maxHeight: 240, maxWidth: 320),
      decoration: BoxDecoration(
        color: Colors.black26,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: isDark ? Colors.white24 : Colors.black12),
      ),
      clipBehavior: Clip.antiAlias,
      child: Image.network(
        url,
        fit: BoxFit.contain,
        errorBuilder: (ctx, err, stack) => Padding(
          padding: const EdgeInsets.all(8.0),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.image_outlined, size: 16, color: Colors.white70),
              const SizedBox(width: 6),
              Flexible(
                child: Text(
                  "图片已上传: ${path.split(RegExp(r'[\\/]')).last}",
                  style: const TextStyle(fontSize: 10, color: Colors.white70),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

    Widget _buildCompactToolCallsBar(List<dynamic> toolCalls, bool isDark) {
    if (toolCalls.isEmpty) return const SizedBox.shrink();

    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Wrap(
        spacing: 6,
        runSpacing: 4,
        children: toolCalls.map((rawTool) {
          final tool = rawTool is Map ? rawTool : {};
          final name = (tool['name'] ?? 'tool').toString();
          final args = _parseToolArgs(tool['args']);
          String label = name;
          IconData icon = Icons.settings_suggest_rounded;

          if (name == 'edit_file') {
            final p = _cleanPath(args['Path'] ?? args['path']);
            final f = p.isEmpty ? '文件' : p.split(RegExp(r'[\\/]')).last;
            label = "edit: $f";
            icon = Icons.edit_note_rounded;
          } else if (name == 'write_file') {
            final p = _cleanPath(args['Path'] ?? args['path']);
            final f = p.isEmpty ? '文件' : p.split(RegExp(r'[\\/]')).last;
            label = "write: $f";
            icon = Icons.post_add_rounded;
          } else if (name == 'read_file') {
            final p = _cleanPath(args['Path'] ?? args['path']);
            final f = p.isEmpty ? '文件' : p.split(RegExp(r'[\\/]')).last;
            label = "read: $f";
            icon = Icons.menu_book_rounded;
          } else if (name == 'run_command') {
            final s = (args['toolSummary'] ?? '').toString();
            label = s.isNotEmpty ? s : "run_command";
            icon = Icons.terminal_rounded;
          }

          return Container(
            padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2.5),
            decoration: BoxDecoration(
              color: isDark ? Colors.white.withOpacity(0.04) : Colors.black.withOpacity(0.04),
              borderRadius: BorderRadius.circular(4),
              border: Border.all(color: isDark ? Colors.white10 : Colors.black12),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(icon, size: 11, color: isDark ? Colors.white38 : Colors.black38),
                const SizedBox(width: 4),
                ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 220),
                  child: Text(
                    label,
                    style: TextStyle(
                      fontSize: 10.5,
                      fontFamily: 'monospace',
                      color: isDark ? Colors.white60 : Colors.black54,
                    ),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
            ),
          );
        }).toList(),
      ),
    );
  }

Widget _buildMessageCard(AgentMessage msg) {
    final isDark = Theme.of(context).brightness == Brightness.dark;

    // 1. 用户消息气泡
    if (msg.isUser) {
      final imgPaths = _extractImagePaths(msg.content);
      var displayContent = msg.content.replaceAll(RegExp(r'\[用户上传图片:\s*.*?\]\n?'), '').trim();
      displayContent = displayContent.replaceAll(RegExp(r'\[用户上传文件:\s*.*?\]\n?'), '').trim();

      return Align(
        alignment: Alignment.centerRight,
        child: Container(
          margin: const EdgeInsets.only(bottom: 12, left: 40),
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
          decoration: BoxDecoration(
            color: const Color(0xFF0284C7),
            borderRadius: BorderRadius.circular(16).copyWith(bottomRight: const Radius.circular(2)),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.end,
            mainAxisSize: MainAxisSize.min,
            children: [
              if (displayContent.isNotEmpty)
                SelectableText(
                  displayContent,
                  style: const TextStyle(color: Colors.white, fontSize: 14, height: 1.4),
                ),
              for (var imgPath in imgPaths)
                _buildImagePreviewWidget(imgPath, isDark),
            ],
          ),
        ),
      );
    }

    // 2. 纯工具执行或空内容步骤：彻底隐藏，不占任何空间！
    if (msg.content.trim().isEmpty && msg.status != 'WAITING_APPROVAL' && msg.status != 'WAITING_INPUT') {
      return const SizedBox.shrink();
    }

    // 3. Agent 回复内容卡片（极简现代化卡片）
    return Container(
      margin: const EdgeInsets.only(bottom: 14),
      decoration: BoxDecoration(
        color: isDark ? const Color(0xFF161F30) : Colors.white,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: isDark ? const Color(0xFF23324A) : const Color(0xFFE2E8F0)),
        boxShadow: isDark ? null : [BoxShadow(color: Colors.black.withOpacity(0.04), blurRadius: 4, offset: const Offset(0, 2))],
      ),
      padding: const EdgeInsets.all(14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // 极简微型工具标签栏（单行 18px 标签）
          if (msg.toolCalls.isNotEmpty)
            _buildCompactToolCallsBar(msg.toolCalls, isDark),

          // 思考过程折叠栏
          if (msg.thinking.isNotEmpty) ...[
            _buildThinkingFold(msg.thinking),
            const SizedBox(height: 10),
          ],

          // Markdown 回复正文（无任何多余边框）
          if (msg.content.isNotEmpty)
            MarkdownBody(
              data: msg.content,
              selectable: true,
              onTapLink: (text, href, title) {
                if (href != null && href.isNotEmpty) {
                  if (href.startsWith("http://") || href.startsWith("https://")) {
                    JsBridge.openUrl(href);
                  } else {
                    _downloadFile(href);
                  }
                }
              },
              styleSheet: MarkdownStyleSheet.fromTheme(Theme.of(context)).copyWith(
                p: TextStyle(color: isDark ? const Color(0xFFE2E8F0) : const Color(0xFF1E293B), fontSize: 14, height: 1.6),
                h1: TextStyle(color: isDark ? Colors.white : Colors.black87, fontSize: 18, fontWeight: FontWeight.bold),
                h2: TextStyle(color: isDark ? Colors.white : Colors.black87, fontSize: 16, fontWeight: FontWeight.bold),
                h3: TextStyle(color: Theme.of(context).colorScheme.primary, fontSize: 15, fontWeight: FontWeight.bold),
                strong: TextStyle(color: isDark ? Colors.white : Colors.black87, fontWeight: FontWeight.bold),
                em: TextStyle(color: isDark ? const Color(0xFF94A3B8) : const Color(0xFF64748B), fontStyle: FontStyle.italic),
                a: TextStyle(color: isDark ? const Color(0xFF38BDF8) : const Color(0xFF0284C7), decoration: TextDecoration.underline),
                listBullet: TextStyle(color: Theme.of(context).colorScheme.primary, fontSize: 14),
                blockquote: TextStyle(
                  color: isDark ? const Color(0xFFCBD5E1) : const Color(0xFF334155),
                  fontSize: 13.5,
                  height: 1.6,
                ),
                blockquotePadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                blockquoteDecoration: BoxDecoration(
                  color: isDark ? const Color(0xFF161F30) : const Color(0xFFF1F5F9),
                  borderRadius: BorderRadius.circular(8),
                  border: Border(
                    left: BorderSide(
                      color: isDark ? const Color(0xFF38BDF8) : const Color(0xFF0284C7),
                      width: 3.5,
                    ),
                  ),
                ),
                code: TextStyle(
                  backgroundColor: isDark ? const Color(0xFF0B0F19) : const Color(0xFFF1F5F9),
                  color: Theme.of(context).colorScheme.primary,
                  fontFamily: 'monospace',
                  fontSize: 12,
                ),
                codeblockPadding: const EdgeInsets.all(10),
                codeblockDecoration: BoxDecoration(
                  color: isDark ? const Color(0xFF0B0F19) : const Color(0xFFF8FAFC),
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: isDark ? const Color(0xFF23324A) : const Color(0xFFE2E8F0)),
                ),
                tableHead: TextStyle(
                  color: isDark ? Colors.white : Colors.black87,
                  fontWeight: FontWeight.bold,
                ),
                tableBody: TextStyle(
                  color: isDark ? const Color(0xFFE2E8F0) : const Color(0xFF1E293B),
                ),
                tableBorder: TableBorder.all(
                  color: isDark ? const Color(0xFF23324A) : const Color(0xFFE2E8F0),
                  width: 1,
                ),
                tableCellsDecoration: BoxDecoration(
                  color: isDark ? const Color(0xFF0F172A) : const Color(0xFFF8FAFC),
                ),
                horizontalRuleDecoration: BoxDecoration(
                  border: Border(
                    top: BorderSide(
                      color: isDark ? const Color(0xFF23324A) : const Color(0xFFE2E8F0),
                      width: 1,
                    ),
                  ),
                ),
              ),
            ),

          // 自动检测正文中提及的可下载文件，生成直观显眼的【下载卡片】
          for (final fPath in _extractDownloadableFiles(msg.content))
            _buildDownloadCard(fPath, isDark),
        ],
      ),
    );
  }

  Widget _buildThinkingFold(String thinkingText) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final preview = thinkingText.trim().split('\n').first;
    final cleanPreview = preview.length > 30 ? "${preview.substring(0, 30)}..." : preview;

    return Container(
      decoration: BoxDecoration(
        color: isDark ? const Color(0xFF090D16) : const Color(0xFFF3E8FF).withOpacity(0.4),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: isDark ? const Color(0xFF2E1065) : const Color(0xFFD8B4FE)),
      ),
      child: Theme(
        data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
        child: ExpansionTile(
          initiallyExpanded: false,
          tilePadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 0),
          childrenPadding: const EdgeInsets.only(left: 10, right: 10, bottom: 10),
          leading: const Icon(Icons.psychology_outlined, color: Color(0xFFA855F7), size: 18),
          title: Text(
            "思考过程: $cleanPreview",
            style: const TextStyle(color: Color(0xFFA855F7), fontSize: 12, fontWeight: FontWeight.w500),
            overflow: TextOverflow.ellipsis,
          ),
          children: [
            SelectableText(
              thinkingText,
              style: TextStyle(color: isDark ? const Color(0xFFD8B4FE) : const Color(0xFF6B21A8), fontSize: 12, height: 1.45),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildBottomInputBar() {
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      color: isDark ? const Color(0xFF161F30) : Colors.white,
      child: SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // 斜杠指令悬浮补全卡片
            if (_showSlashMenu)
              SlashCommandMenu(
                commands: _filteredSlashCommands,
                onSelect: _applySlashCommand,
                isDark: isDark,
              ),

            // 待上传附件栏
            if (_pendingAttachments.isNotEmpty)
              AttachmentPreviewBar(
                attachments: _pendingAttachments,
                onRemove: (idx) {
                  setState(() {
                    _pendingAttachments.removeAt(idx);
                  });
                },
                isDark: isDark,
              ),

            // 输入框主行
            Row(
              children: [
                InkWell(
                  borderRadius: BorderRadius.circular(20),
                  onTap: _showAddContextSheet,
                  child: Container(
                    width: 36,
                    height: 36,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: isDark ? Colors.white.withOpacity(0.08) : Colors.black.withOpacity(0.05),
                    ),
                    child: Icon(Icons.add_rounded, color: isDark ? Colors.white70 : Colors.black54, size: 22),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: TextField(
                    controller: _inputController,
                    style: TextStyle(color: isDark ? Colors.white : Colors.black87),
                    decoration: InputDecoration(
                      hintText: _isConnected ? "向 Agent 发送指令或 /斜杠命令..." : "请先连接电脑...",
                      hintStyle: TextStyle(color: isDark ? Colors.white24 : Colors.black26, fontSize: 13),
                      filled: true,
                      fillColor: isDark ? const Color(0xFF0B0F19) : const Color(0xFFF1F5F9),
                      contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                      border: OutlineInputBorder(borderRadius: BorderRadius.circular(24), borderSide: BorderSide.none),
                    ),
                    onSubmitted: (_) {
                      if (_isConnected && !_isThinking) {
                        _sendMessage();
                      }
                    },
                  ),
                ),
                const SizedBox(width: 8),
                IconButton(
                  icon: _isThinking
                      ? Container(
                          width: 32,
                          height: 32,
                          decoration: BoxDecoration(
                            color: Colors.redAccent.withOpacity(0.15),
                            shape: BoxShape.circle,
                            border: Border.all(color: Colors.redAccent, width: 1.5),
                          ),
                          child: const Center(
                            child: Icon(Icons.stop_rounded, color: Colors.redAccent, size: 20),
                          ),
                        )
                      : Icon(Icons.arrow_upward_rounded, color: Theme.of(context).colorScheme.primary),
                  tooltip: _isThinking ? "停止当前任务 (Stop)" : "发送",
                  onPressed: _isConnected
                      ? (_isThinking ? _stopCurrentTask : _sendMessage)
                      : null,
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  void _showNewSessionDialog() {
    showDialog(
      context: context,
      builder: (ctx) => NewSessionDialog(
        initialMode: _selectedMode,
        initialModel: _selectedModel,
        models: kAllOfficialModels,
        onStart: (prompt, mode, model) {
          setState(() {
            _selectedMode = mode;
            _selectedModel = model;
          });
          _startNewSession(prompt);
        },
      ),
    );
  }

  void _startNewSession(String initialPrompt) {
    if (!_isConnected) return;
    setState(() {
      _messages.clear();
      _activeSessionTitle = "新任务 (启动中...)";
      _isThinking = true;
    });

    final payload = jsonEncode({
      "action": "new_session",
      "content": initialPrompt,
      "model": _selectedModel,
      "mode": _selectedMode,
    });
    _channel?.sink.add(payload);
    HapticFeedback.mediumImpact();
  }

  @override
  void dispose() {
    _heartbeatTimer?.cancel();
    _reconnectTimer?.cancel();
    _channel?.sink.close();
    _inputController.removeListener(_onInputChanged);
    _scrollController.dispose();
    _ipController.dispose();
    _inputController.dispose();
    super.dispose();
  }
}

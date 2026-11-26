import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:web_socket_channel/web_socket_channel.dart';
import 'package:xterm/xterm.dart';

import '../../core/config/server_config.dart';
import '../../core/network/token_store.dart';
import '../../core/realtime/ws_connector.dart';
import '../../core/theme/app_colors.dart';

class TerminalPanel extends StatefulWidget {
  final ServerConfig serverConfig;
  final TokenStore tokenStore;
  final Future<bool> Function()? onRefreshAuth;
  final String nodeId;
  final String nodeName;
  final String initialCwd;
  final String activeSessionId;
  final bool isEmbedded;
  final VoidCallback? onClose;
  final WebSocketConnectFn? wsConnectOverride;

  const TerminalPanel({
    super.key,
    required this.serverConfig,
    required this.tokenStore,
    this.onRefreshAuth,
    required this.nodeId,
    required this.nodeName,
    this.initialCwd = '',
    this.activeSessionId = '',
    this.isEmbedded = false,
    this.onClose,
    this.wsConnectOverride,
  });

  static void showSheet(
    BuildContext context, {
    required ServerConfig serverConfig,
    required TokenStore tokenStore,
    Future<bool> Function()? onRefreshAuth,
    required String nodeId,
    required String nodeName,
    String initialCwd = '',
    String activeSessionId = '',
  }) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      constraints: const BoxConstraints(maxWidth: 1080.0),
      backgroundColor: isDark ? const Color(0xFF0E1016) : Colors.white,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (ctx) => SizedBox(
        height: MediaQuery.of(ctx).size.height * 0.88,
        child: TerminalPanel(
          serverConfig: serverConfig,
          tokenStore: tokenStore,
          onRefreshAuth: onRefreshAuth,
          nodeId: nodeId,
          nodeName: nodeName,
          initialCwd: initialCwd,
          activeSessionId: activeSessionId,
          isEmbedded: false,
          onClose: () => Navigator.of(ctx).pop(),
        ),
      ),
    );
  }

  @override
  State<TerminalPanel> createState() => _TerminalPanelState();
}

class _TerminalPanelState extends State<TerminalPanel> {
  late final Terminal _terminal;
  late final TerminalController _termController;
  final FocusNode _termFocusNode = FocusNode();

  WebSocketChannel? _channel;
  StreamSubscription? _wsSub;
  Timer? _pingTimer;
  bool _connecting = false;
  bool _connected = false;
  bool _disposed = false;
  String _shellName = '';
  String _platformName = '';
  String _cwdDisplay = '';
  String _statusError = '';
  int _cols = 90;
  int _rows = 28;
  bool _retriedAuthOnce = false;

  @override
  void initState() {
    super.initState();
    _termController = TerminalController();
    _terminal = Terminal(
      maxLines: 5000,
      onOutput: _handleTerminalOutput,
      onResize: _handleTerminalResize,
    );
    unawaited(_connect());
  }

  @override
  void didUpdateWidget(covariant TerminalPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.nodeId != widget.nodeId) {
      _terminal.write('\r\n\x1b[90m--- 已切换节点至 ${widget.nodeName} ---\x1b[0m\r\n');
      unawaited(_reconnect());
    }
  }

  @override
  void dispose() {
    _disposed = true;
    _disconnectSync();
    _termController.dispose();
    _termFocusNode.dispose();
    super.dispose();
  }

  void _disconnectSync() {
    _pingTimer?.cancel();
    _pingTimer = null;
    _wsSub?.cancel();
    _wsSub = null;
    try {
      _channel?.sink.close();
    } catch (_) {}
    _channel = null;
  }

  Uri _buildTerminalWsUri(String? token) {
    final httpBase = widget.serverConfig.baseUrl.replaceAll(RegExp(r'/+$'), '');
    final wsBase = httpBase.startsWith('https://')
        ? 'wss://${httpBase.substring(8)}'
        : (httpBase.startsWith('http://') ? 'ws://${httpBase.substring(7)}' : 'ws://$httpBase');
    final query = <String, String>{
      'cols': '$_cols',
      'rows': '$_rows',
      if (widget.initialCwd.trim().isNotEmpty) 'cwd': widget.initialCwd.trim(),
      if (!kIsWeb && token != null && token.isNotEmpty) 'token': token,
    };
    return Uri.parse('$wsBase/ws/v2/nodes/${widget.nodeId}/terminal').replace(queryParameters: query);
  }

  Future<void> _connect() async {
    if (_disposed || widget.nodeId.isEmpty) return;
    _disconnectSync();
    if (mounted) {
      setState(() {
        _connecting = true;
        _connected = false;
        _statusError = '';
      });
    }

    try {
      final token = kIsWeb ? null : widget.tokenStore.accessToken;
      if (_disposed) return;
      final uri = _buildTerminalWsUri(token);
      final headers = (!kIsWeb && token != null && token.isNotEmpty)
          ? <String, dynamic>{'Authorization': 'Bearer $token'}
          : null;
      final connector = widget.wsConnectOverride ?? connectWebSocket;
      final channel = connector(uri, headers: headers);
      _channel = channel;

      _wsSub = channel.stream.listen(
        _onWsFrame,
        onError: (Object err) {
          if (_disposed) return;
          if (mounted) {
            setState(() {
              _connecting = false;
              _connected = false;
              _statusError = '终端连接异常: $err';
            });
          }
        },
        onDone: () {
          if (_disposed) return;
          final closeCode = channel.closeCode;
          final closeReason = channel.closeReason ?? '';
          if (closeCode == 4401 && !_retriedAuthOnce && widget.onRefreshAuth != null) {
            _retriedAuthOnce = true;
            unawaited(_refreshAndReconnect());
            return;
          }
          if (mounted) {
            setState(() {
              _connecting = false;
              _connected = false;
              if (closeCode == 4403) {
                _statusError = closeReason.isNotEmpty ? closeReason : '无权限访问远程终端（需管理员及写权限）';
              } else if (closeCode == 4429) {
                _statusError = '当前节点终端会话数已达上限';
              } else if (closeCode == 4502) {
                _statusError = '目标节点不可达，请确认 Node Agent 在线';
              } else if (_statusError.isEmpty && closeReason.isNotEmpty) {
                _statusError = closeReason;
              }
            });
          }
        },
      );

      _pingTimer = Timer.periodic(const Duration(seconds: 25), (_) {
        _sendJson({'type': 'ping'});
      });
    } catch (e) {
      if (_disposed) return;
      if (mounted) {
        setState(() {
          _connecting = false;
          _connected = false;
          _statusError = '无法连接终端: $e';
        });
      }
    }
  }

  Future<void> _refreshAndReconnect() async {
    final ok = await widget.onRefreshAuth?.call() ?? false;
    if (_disposed) return;
    if (ok) {
      await _connect();
    } else if (mounted) {
      setState(() {
        _connecting = false;
        _connected = false;
        _statusError = '登录态已过期，请重新登录';
      });
    }
  }

  Future<void> _reconnect() async {
    _retriedAuthOnce = false;
    await _connect();
  }

  void _onWsFrame(dynamic raw) {
    if (_disposed) return;
    if (raw is! String) return;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map<String, dynamic>) return;
      final type = decoded['type']?.toString() ?? '';
      if (type == 'ready') {
        _retriedAuthOnce = false;
        if (mounted) {
          setState(() {
            _connecting = false;
            _connected = true;
            _statusError = '';
            _shellName = decoded['shell']?.toString() ?? '';
            _platformName = decoded['platform']?.toString() ?? '';
            _cwdDisplay = decoded['cwd']?.toString() ?? '';
          });
        }
        // Sync actual xterm grid dimensions once ready
        _sendJson({'type': 'resize', 'cols': _cols, 'rows': _rows});
      } else if (type == 'output') {
        final data = decoded['data']?.toString() ?? '';
        if (data.isNotEmpty) {
          _terminal.write(data);
        }
      } else if (type == 'exit') {
        final code = decoded['code'] ?? 0;
        _terminal.write('\r\n\x1b[90m[终端进程已退出，exit code: $code]\x1b[0m\r\n');
        if (mounted) {
          setState(() {
            _connecting = false;
            _connected = false;
          });
        }
      } else if (type == 'error') {
        final msg = decoded['message']?.toString() ?? '终端运行出错';
        _terminal.write('\r\n\x1b[31m$msg\x1b[0m\r\n');
        if (mounted) {
          setState(() {
            _connecting = false;
            _connected = false;
            _statusError = msg;
          });
        }
      }
    } catch (_) {}
  }

  void _sendJson(Map<String, dynamic> payload) {
    final ch = _channel;
    if (ch == null) return;
    try {
      ch.sink.add(jsonEncode(payload));
    } catch (_) {}
  }

  void _handleTerminalOutput(String data) {
    if (!_connected || data.isEmpty) return;
    _sendJson({'type': 'input', 'data': data});
  }

  void _handleTerminalResize(int width, int height, int pixelWidth, int pixelHeight) {
    _cols = width.clamp(20, 300);
    _rows = height.clamp(8, 120);
    if (_connected) {
      _sendJson({'type': 'resize', 'cols': _cols, 'rows': _rows});
    }
  }

  void _sendQuickBytes(String raw) {
    if (!_connected) return;
    _sendJson({'type': 'input', 'data': raw});
    _termFocusNode.requestFocus();
  }

  void _attachCurrentAgyConversation() {
    final sid = widget.activeSessionId.trim();
    if (!_connected || sid.isEmpty) return;
    // Open the active conversation directly inside interactive agy TUI so user can run /rewind or /undo
    _sendQuickBytes('agy --conversation=$sid\r');
  }

  Future<void> _pasteFromClipboard() async {
    final clip = await Clipboard.getData(Clipboard.kTextPlain);
    final text = clip?.text ?? '';
    if (text.isNotEmpty) {
      _sendQuickBytes(text);
    }
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final primary = Theme.of(context).colorScheme.primary;
    final borderColor = isDark ? const Color(0xFF26262C) : const Color(0xFFE4E4E7);
    final bottomInset = widget.isEmbedded ? 0.0 : MediaQuery.of(context).viewInsets.bottom;
    final canAttachAgyCli = _connected &&
        widget.activeSessionId.isNotEmpty &&
        !widget.activeSessionId.startsWith('__creating_') &&
        _platformName == 'deck';

    return Padding(
      padding: EdgeInsets.only(bottom: bottomInset),
      child: Column(
        children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
            decoration: BoxDecoration(
              color: isDark ? const Color(0xFF15161B) : const Color(0xFFF4F4F5),
              border: Border(bottom: BorderSide(color: borderColor)),
            ),
            child: Row(
              children: [
                Container(
                  width: 8,
                  height: 8,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: _connected
                        ? AppColors.statusGreen(isDark)
                        : (_connecting ? AppColors.statusAmber(isDark) : AppColors.statusRed(isDark)),
                  ),
                ),
                const SizedBox(width: 7),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        _shellName.isNotEmpty
                            ? '${widget.nodeName} · $_shellName'
                            : '${widget.nodeName} · 远程终端',
                        style: TextStyle(
                          fontSize: 12.5,
                          fontWeight: FontWeight.w700,
                          color: isDark ? Colors.white : const Color(0xFF18181B),
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      if (_cwdDisplay.isNotEmpty)
                        Text(
                          _cwdDisplay,
                          style: TextStyle(
                            fontSize: 10,
                            fontFamily: 'monospace',
                            color: isDark ? Colors.white38 : Colors.black45,
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                    ],
                  ),
                ),
                if (canAttachAgyCli)
                  Padding(
                    padding: const EdgeInsets.only(right: 4),
                    child: Tooltip(
                      message: '在终端打开当前会话的 agy 交互界面（可执行 /rewind）',
                      child: FilledButton.tonalIcon(
                        onPressed: _attachCurrentAgyConversation,
                        style: FilledButton.styleFrom(
                          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                          minimumSize: Size.zero,
                          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                        ),
                        icon: const Icon(Icons.history_rounded, size: 13),
                        label: const Text('接入当前会话', style: TextStyle(fontSize: 11)),
                      ),
                    ),
                  ),
                IconButton(
                  tooltip: '粘贴剪贴板',
                  visualDensity: VisualDensity.compact,
                  icon: const Icon(Icons.content_paste_rounded, size: 16),
                  onPressed: _connected ? _pasteFromClipboard : null,
                ),
                IconButton(
                  tooltip: '清屏',
                  visualDensity: VisualDensity.compact,
                  icon: const Icon(Icons.cleaning_services_outlined, size: 16),
                  onPressed: () {
                    _terminal.buffer.clear();
                    _terminal.buffer.setCursor(0, 0);
                  },
                ),
                IconButton(
                  tooltip: '重新连接终端',
                  visualDensity: VisualDensity.compact,
                  icon: const Icon(Icons.refresh_rounded, size: 17),
                  onPressed: _connecting ? null : _reconnect,
                ),
                if (widget.onClose != null)
                  IconButton(
                    tooltip: '关闭终端',
                    visualDensity: VisualDensity.compact,
                    icon: const Icon(Icons.close_rounded, size: 18),
                    onPressed: widget.onClose,
                  ),
              ],
            ),
          ),
          if (_statusError.isNotEmpty)
            Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
              color: Colors.redAccent.withValues(alpha: 0.14),
              child: Row(
                children: [
                  Icon(Icons.error_outline_rounded, size: 14, color: AppColors.statusRed(isDark)),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      _statusError,
                      style: TextStyle(fontSize: 11.5, color: AppColors.statusRed(isDark)),
                    ),
                  ),
                  TextButton(
                    onPressed: _reconnect,
                    style: TextButton.styleFrom(
                      visualDensity: VisualDensity.compact,
                      padding: const EdgeInsets.symmetric(horizontal: 8),
                    ),
                    child: const Text('重试', style: TextStyle(fontSize: 11.5)),
                  ),
                ],
              ),
            ),
          Expanded(
            child: Container(
              color: const Color(0xFF0E1016),
              child: TerminalView(
                _terminal,
                controller: _termController,
                focusNode: _termFocusNode,
                autofocus: true,
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
                theme: _agyDarkTerminalTheme,
                textStyle: const TerminalStyle(
                  fontSize: 13,
                  fontFamily: 'monospace',
                ),
                deleteDetection: true,
              ),
            ),
          ),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
            decoration: BoxDecoration(
              color: isDark ? const Color(0xFF15161B) : const Color(0xFFF4F4F5),
              border: Border(top: BorderSide(color: borderColor)),
            ),
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(
                children: [
                  _keyChip('Esc', '\x1b', isDark, primary),
                  _keyChip('Tab', '\t', isDark, primary),
                  _keyChip('Ctrl+C', '\x03', isDark, primary),
                  _keyChip('Ctrl+D', '\x04', isDark, primary),
                  _keyChip('↑', '\x1b[A', isDark, primary),
                  _keyChip('↓', '\x1b[B', isDark, primary),
                  _keyChip('←', '\x1b[D', isDark, primary),
                  _keyChip('→', '\x1b[C', isDark, primary),
                  _keyChip('Enter', '\r', isDark, primary),
                  if (_platformName == 'deck')
                    _keyChip('/rewind', '/rewind\r', isDark, primary, accent: true),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _keyChip(
    String label,
    String seq,
    bool isDark,
    Color primary, {
    bool accent = false,
  }) {
    return Padding(
      padding: const EdgeInsets.only(right: 5),
      child: InkWell(
        borderRadius: BorderRadius.circular(6),
        onTap: _connected ? () => _sendQuickBytes(seq) : null,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
          decoration: BoxDecoration(
            color: accent
                ? primary.withValues(alpha: isDark ? 0.2 : 0.12)
                : (isDark ? const Color(0xFF22242C) : Colors.white),
            borderRadius: BorderRadius.circular(6),
            border: Border.all(
              color: accent
                  ? primary.withValues(alpha: 0.55)
                  : (isDark ? const Color(0xFF323542) : const Color(0xFFD4D4D8)),
            ),
          ),
          child: Text(
            label,
            style: TextStyle(
              fontSize: 11,
              fontFamily: 'monospace',
              fontWeight: accent ? FontWeight.w700 : FontWeight.w500,
              color: accent
                  ? primary
                  : (_connected
                      ? (isDark ? Colors.white70 : Colors.black87)
                      : (isDark ? Colors.white24 : Colors.black26)),
            ),
          ),
        ),
      ),
    );
  }
}

const TerminalTheme _agyDarkTerminalTheme = TerminalTheme(
  cursor: Color(0xFF34D399),
  selection: Color(0x6634D399),
  foreground: Color(0xFFE4E4E7),
  background: Color(0xFF0E1016),
  black: Color(0xFF18181B),
  red: Color(0xFFF87171),
  green: Color(0xFF4ADE80),
  yellow: Color(0xFFFBBF24),
  blue: Color(0xFF60A5FA),
  magenta: Color(0xFFC084FC),
  cyan: Color(0xFF22D3EE),
  white: Color(0xFFE4E4E7),
  brightBlack: Color(0xFF71717A),
  brightRed: Color(0xFFFCA5A5),
  brightGreen: Color(0xFF86EFAC),
  brightYellow: Color(0xFFFDE047),
  brightBlue: Color(0xFF93C5FD),
  brightMagenta: Color(0xFFD8B4FE),
  brightCyan: Color(0xFF67E8F9),
  brightWhite: Color(0xFFFAFAFA),
  searchHitBackground: Color(0x88F59E0B),
  searchHitBackgroundCurrent: Color(0xCCF59E0B),
  searchHitForeground: Color(0xFF09090B),
);

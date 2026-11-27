import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:web_socket_channel/web_socket_channel.dart';
import 'package:xterm/xterm.dart';

import '../../core/config/server_config.dart';
import '../../core/network/token_store.dart';
import '../../core/realtime/ws_connector.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/app_fonts.dart';
import '../../core/theme/font_loader_service.dart';

class TerminalPanel extends StatefulWidget {
  final ServerConfig serverConfig;
  final TokenStore tokenStore;
  final Future<bool> Function()? onRefreshAuth;
  final String nodeId;
  final String nodeName;
  final String initialCwd;
  final String activeSessionId;
  final bool isEmbedded;
  final bool isActive;
  final VoidCallback? onMinimize;
  final VoidCallback? onClose;
  final ValueChanged<bool>? onConnectionChanged;
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
    this.isActive = true,
    this.onMinimize,
    this.onClose,
    this.onConnectionChanged,
    this.wsConnectOverride,
  });

  static const Map<String, String> _shiftSymbolMap = {
    '1': '!',
    '2': '@',
    '3': '#',
    '4': '\$',
    '5': '%',
    '6': '^',
    '7': '&',
    '8': '*',
    '9': '(',
    '0': ')',
    '-': '_',
    '=': '+',
    '[': '{',
    ']': '}',
    '\\': '|',
    ';': ':',
    "'": '"',
    ',': '<',
    '.': '>',
    '/': '?',
    '`': '~',
  };

  static final RegExp _csiKeyRe = RegExp(r'^\x1b\[(\d+)?([A-Za-z~])$');
  static final RegExp _ss3FnRe = RegExp(r'^\x1bO([PQRS])$');

  /// 将终端虚拟键盘的粘滞修饰键应用到普通键值或 ANSI 控制序列上。
  static String applyKeyModifiers(
    String raw, {
    bool ctrl = false,
    bool alt = false,
    bool shift = false,
  }) {
    if (raw.isEmpty || (!ctrl && !alt && !shift)) return raw;

    // Tab / Backtab
    if (raw == '\t') {
      final base = shift ? '\x1b[Z' : '\t';
      return alt ? '\x1b$base' : base;
    }

    // Backspace (\x7f) & Enter (\r) & Esc (\x1b)
    if (raw == '\x7f') {
      final base = ctrl ? '\x08' : '\x7f';
      return alt ? '\x1b$base' : base;
    }
    if (raw == '\r' || raw == '\x1b') {
      return alt ? '\x1b$raw' : raw;
    }

    // xterm CSI sequences (arrows, Home/End, Ins/Del, PgUp/PgDn, F5-F12)
    final csiMatch = _csiKeyRe.firstMatch(raw);
    if (csiMatch != null) {
      final mod = 1 + (shift ? 1 : 0) + (alt ? 2 : 0) + (ctrl ? 4 : 0);
      final numPart = csiMatch.group(1);
      final suffix = csiMatch.group(2)!;
      final prefix = (numPart == null || numPart.isEmpty) ? '1' : numPart;
      return '\x1b[$prefix;$mod$suffix';
    }

    // xterm SS3 sequences (F1-F4: \x1bOP..\x1bOS)
    final ss3Match = _ss3FnRe.firstMatch(raw);
    if (ss3Match != null) {
      final mod = 1 + (shift ? 1 : 0) + (alt ? 2 : 0) + (ctrl ? 4 : 0);
      return '\x1b[1;$mod${ss3Match.group(1)!}';
    }

    var out = raw;
    if (shift) {
      if (_shiftSymbolMap.containsKey(out)) {
        out = _shiftSymbolMap[out]!;
      } else {
        out = out.toUpperCase();
      }
    }
    if (ctrl && out.length == 1) {
      final upper = out.toUpperCase();
      final code = upper.codeUnitAt(0);
      if (code >= 0x40 && code <= 0x5F) {
        // @, A-Z, [, \, ], ^, _ -> 0x00..0x1F
        out = String.fromCharCode(code - 0x40);
      } else if (out == ' ') {
        out = '\x00';
      } else if (out == '?') {
        out = '\x7f';
      } else if (out == '-' || out == '/') {
        out = '\x1f';
      }
    }
    if (alt) {
      out = '\x1b$out';
    }
    return out;
  }

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
      builder: (ctx) {
        final mq = MediaQuery.of(ctx);
        final maxAvailable = math.max(0.0, mq.size.height - mq.padding.top - mq.viewInsets.bottom);
        final targetHeight = math.min(mq.size.height * 0.88, maxAvailable);
        return Padding(
          padding: EdgeInsets.only(bottom: mq.viewInsets.bottom),
          child: MediaQuery.removeViewInsets(
            context: ctx,
            removeBottom: true,
            child: SizedBox(
              height: targetHeight,
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
          ),
        );
      },
    );
  }

  @override
  State<TerminalPanel> createState() => _TerminalPanelState();
}

class _TerminalPanelState extends State<TerminalPanel> {
  static const List<String> _terminalFontFallbacks = [
    'AgyMono',
    'JetBrains Mono',
    'Cascadia Mono',
    'Consolas',
    'Menlo',
    'Monaco',
    'Noto Sans Mono CJK SC',
    'Noto Sans CJK SC',
    'monospace',
  ];

  static const TerminalStyle _monoTerminalStyle = TerminalStyle(
    fontSize: 13,
    height: 1.25,
    fontFamily: 'AgyMono',
    fontFamilyFallback: _terminalFontFallbacks,
  );

  static const TerminalStyle _fallbackTerminalStyle = TerminalStyle(
    fontSize: 13,
    height: 1.25,
    fontFamily: 'monospace',
    fontFamilyFallback: _terminalFontFallbacks,
  );

  late final Terminal _terminal;
  late final TerminalController _termController;
  final FocusNode _termFocusNode = FocusNode(debugLabel: 'agy_terminal_focus');

  WebSocketChannel? _channel;
  StreamSubscription? _wsSub;
  Timer? _pingTimer;
  int _connectSeq = 0;
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
  bool _monoFontLoaded = FontLoaderService.isLoaded(AppFonts.mono);
  bool _showFullKeyboard = false;
  bool _ctrlActive = false;
  bool _altActive = false;
  bool _shiftActive = false;

  bool get _isTouchMobile =>
      !kIsWeb &&
      (defaultTargetPlatform == TargetPlatform.android ||
          defaultTargetPlatform == TargetPlatform.iOS);

  @override
  void initState() {
    super.initState();
    _termController = TerminalController();
    _terminal = Terminal(
      maxLines: 5000,
      onOutput: _handleTerminalOutput,
      onResize: _handleTerminalResize,
    );
    if (!_monoFontLoaded && widget.wsConnectOverride == null) {
      unawaited(_ensureMonoFont());
    }
    if (widget.isActive) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && !_disposed && widget.isActive && !_termFocusNode.hasFocus) {
          _termFocusNode.requestFocus();
        }
      });
    }
    unawaited(_connect());
  }

  Future<void> _ensureMonoFont() async {
    final loaded = await FontLoaderService.ensureLoaded(
      AppFonts.mono,
      baseUrl: widget.serverConfig.baseUrl,
    );
    if (loaded && mounted && !_disposed) {
      setState(() => _monoFontLoaded = true);
    }
  }

  @override
  void didUpdateWidget(covariant TerminalPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.nodeId != widget.nodeId) {
      _terminal.write('\r\n\x1b[90m--- 已切换节点至 ${widget.nodeName} ---\x1b[0m\r\n');
      unawaited(_reconnect());
    }
    if (oldWidget.isActive != widget.isActive) {
      if (widget.isActive) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted && !_disposed && widget.isActive) {
            _termFocusNode.requestFocus();
          }
        });
      } else {
        _termFocusNode.unfocus();
      }
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

  void _notifyConnectionChanged(bool connected) {
    widget.onConnectionChanged?.call(connected);
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

  Uri _buildTerminalWsUri() {
    final httpBase = widget.serverConfig.baseUrl.replaceAll(RegExp(r'/+$'), '');
    final wsBase = httpBase.startsWith('https://')
        ? 'wss://${httpBase.substring(8)}'
        : (httpBase.startsWith('http://') ? 'ws://${httpBase.substring(7)}' : 'ws://$httpBase');
    final query = <String, String>{
      'cols': '$_cols',
      'rows': '$_rows',
      if (widget.initialCwd.trim().isNotEmpty) 'cwd': widget.initialCwd.trim(),
    };
    return Uri.parse('$wsBase/ws/v2/nodes/${widget.nodeId}/terminal').replace(queryParameters: query);
  }

  Future<void> _connect() async {
    if (_disposed || widget.nodeId.isEmpty) return;
    final seq = ++_connectSeq;
    _disconnectSync();
    if (mounted) {
      setState(() {
        _connecting = true;
        _connected = false;
        _statusError = '';
      });
    } else {
      _connecting = true;
      _connected = false;
    }
    _notifyConnectionChanged(false);

    try {
      final token = kIsWeb ? null : widget.tokenStore.accessToken;
      if (_disposed || seq != _connectSeq) return;
      final uri = _buildTerminalWsUri();
      final headers = (!kIsWeb && token != null && token.isNotEmpty)
          ? <String, dynamic>{'Authorization': 'Bearer $token'}
          : null;
      final connector = widget.wsConnectOverride ?? connectWebSocket;
      final channel = connector(uri, headers: headers);
      _channel = channel;

      _wsSub = channel.stream.listen(
        (raw) {
          if (_disposed || seq != _connectSeq) return;
          _onWsFrame(raw);
        },
        onError: (Object err) {
          if (_disposed || seq != _connectSeq) return;
          if (mounted) {
            setState(() {
              _connecting = false;
              _connected = false;
              _statusError = '终端连接异常: $err';
            });
          } else {
            _connecting = false;
            _connected = false;
          }
          _notifyConnectionChanged(false);
        },
        onDone: () {
          if (_disposed || seq != _connectSeq) return;
          final closeCode = channel.closeCode;
          final closeReason = channel.closeReason ?? '';
          if (closeCode == 4401 && !_retriedAuthOnce && widget.onRefreshAuth != null) {
            _retriedAuthOnce = true;
            unawaited(_refreshAndReconnect(seq));
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
          } else {
            _connecting = false;
            _connected = false;
          }
          _notifyConnectionChanged(false);
        },
      );

      _pingTimer = Timer.periodic(const Duration(seconds: 25), (_) {
        if (seq == _connectSeq && !_disposed) {
          _sendJson({'type': 'ping'});
        }
      });
    } catch (e) {
      if (_disposed || seq != _connectSeq) return;
      if (mounted) {
        setState(() {
          _connecting = false;
          _connected = false;
          _statusError = '无法连接终端: $e';
        });
      } else {
        _connecting = false;
        _connected = false;
      }
      _notifyConnectionChanged(false);
    }
  }

  Future<void> _refreshAndReconnect(int seq) async {
    final ok = await widget.onRefreshAuth?.call() ?? false;
    if (_disposed || seq != _connectSeq) return;
    if (ok) {
      await _connect();
    } else if (mounted) {
      setState(() {
        _connecting = false;
        _connected = false;
        _statusError = '登录态已过期，请重新登录';
      });
      _notifyConnectionChanged(false);
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
        } else {
          _connecting = false;
          _connected = true;
        }
        _notifyConnectionChanged(true);
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
        } else {
          _connecting = false;
          _connected = false;
        }
        _notifyConnectionChanged(false);
      } else if (type == 'error') {
        final msg = decoded['message']?.toString() ?? '终端运行出错';
        _terminal.write('\r\n\x1b[31m$msg\x1b[0m\r\n');
        if (mounted) {
          setState(() {
            _connecting = false;
            _connected = false;
            _statusError = msg;
          });
        } else {
          _connecting = false;
          _connected = false;
        }
        _notifyConnectionChanged(false);
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

  void _clearModifiersIfNeeded() {
    if (!_ctrlActive && !_altActive && !_shiftActive) return;
    if (mounted) {
      setState(() {
        _ctrlActive = false;
        _altActive = false;
        _shiftActive = false;
      });
    } else {
      _ctrlActive = false;
      _altActive = false;
      _shiftActive = false;
    }
  }

  void _handleTerminalOutput(String data) {
    if (!_connected || data.isEmpty) return;
    if (_ctrlActive || _altActive || _shiftActive) {
      final transformed = TerminalPanel.applyKeyModifiers(
        data,
        ctrl: _ctrlActive,
        alt: _altActive,
        shift: _shiftActive,
      );
      _sendJson({'type': 'input', 'data': transformed});
      _clearModifiersIfNeeded();
      return;
    }
    _sendJson({'type': 'input', 'data': data});
  }

  KeyEventResult _handleTerminalKeyEvent(FocusNode node, KeyEvent event) {
    if (!_connected || event is! KeyDownEvent) return KeyEventResult.ignored;
    final kb = HardwareKeyboard.instance;
    if (kb.isControlPressed && !kb.isAltPressed && !kb.isMetaPressed) {
      final key = event.logicalKey;
      if (key == LogicalKeyboardKey.minus ||
          key == LogicalKeyboardKey.underscore ||
          key == LogicalKeyboardKey.slash) {
        _sendJson({'type': 'input', 'data': kb.isShiftPressed && key == LogicalKeyboardKey.slash ? '\x7f' : '\x1f'});
        _clearModifiersIfNeeded();
        return KeyEventResult.handled;
      }
    }
    return KeyEventResult.ignored;
  }

  void _handleTerminalResize(int width, int height, int pixelWidth, int pixelHeight) {
    _cols = width.clamp(20, 300);
    _rows = height.clamp(8, 120);
    if (_connected) {
      _sendJson({'type': 'resize', 'cols': _cols, 'rows': _rows});
    }
  }

  void _sendQuickBytes(String raw, {bool applyModifiers = false}) {
    if (!_connected) return;
    var payload = raw;
    if (applyModifiers && (_ctrlActive || _altActive || _shiftActive)) {
      payload = TerminalPanel.applyKeyModifiers(
        raw,
        ctrl: _ctrlActive,
        alt: _altActive,
        shift: _shiftActive,
      );
      _clearModifiersIfNeeded();
    }
    _sendJson({'type': 'input', 'data': payload});
    if (!_isTouchMobile || !_showFullKeyboard) {
      _termFocusNode.requestFocus();
    }
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
      child: LayoutBuilder(
        builder: (context, constraints) {
          final maxKbHeight = constraints.maxHeight.isFinite
              ? math.max(0.0, math.min(248.0, constraints.maxHeight - 120.0))
              : 248.0;
          return Column(
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
                  onPressed: _reconnect,
                ),
                if (widget.onMinimize != null)
                  IconButton(
                    tooltip: '收起终端（后台保持运行）',
                    visualDensity: VisualDensity.compact,
                    icon: const Icon(Icons.keyboard_arrow_down_rounded, size: 20),
                    onPressed: widget.onMinimize,
                  ),
                if (widget.onClose != null)
                  IconButton(
                    tooltip: widget.onMinimize != null ? '结束终端会话' : '关闭终端',
                    visualDensity: VisualDensity.compact,
                    icon: Icon(
                      widget.onMinimize != null
                          ? Icons.power_settings_new_rounded
                          : Icons.close_rounded,
                      size: widget.onMinimize != null ? 17 : 18,
                      color: widget.onMinimize != null ? AppColors.statusRed(isDark) : null,
                    ),
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
                    onPressed: _connecting ? null : _reconnect,
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
                autofocus: widget.isActive,
                onKeyEvent: _handleTerminalKeyEvent,
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
                theme: _agyDarkTerminalTheme,
                textStyle: _monoFontLoaded ? _monoTerminalStyle : _fallbackTerminalStyle,
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
            child: _showFullKeyboard
                ? _buildFullKeyboardPanel(
                    isDark,
                    primary,
                    borderColor,
                    maxHeight: maxKbHeight,
                  )
                : _buildQuickKeyboardBar(isDark, primary),
          ),
            ],
          );
        },
      ),
    );
  }

  Widget _buildQuickKeyboardBar(bool isDark, Color primary) {
    return Row(
      children: [
        _modeToggleButton(
          label: '全键盘',
          icon: Icons.keyboard_alt_outlined,
          isExpanded: false,
          isDark: isDark,
          primary: primary,
        ),
        const SizedBox(width: 6),
        Expanded(
          child: SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(
              children: [
                _keyChip('Esc', '\x1b', isDark, primary),
                _keyChip('Tab', '\t', isDark, primary, applyModifiers: true),
                _modifierChip(
                  'Ctrl',
                  active: _ctrlActive,
                  isDark: isDark,
                  primary: primary,
                  onTap: () => setState(() => _ctrlActive = !_ctrlActive),
                ),
                _modifierChip(
                  'Alt',
                  active: _altActive,
                  isDark: isDark,
                  primary: primary,
                  onTap: () => setState(() => _altActive = !_altActive),
                ),
                _keyChip('Ctrl+C', '\x03', isDark, primary),
                _keyChip('Ctrl+D', '\x04', isDark, primary),
                _keyChip('↑', '\x1b[A', isDark, primary, applyModifiers: true),
                _keyChip('↓', '\x1b[B', isDark, primary, applyModifiers: true),
                _keyChip('←', '\x1b[D', isDark, primary, applyModifiers: true),
                _keyChip('→', '\x1b[C', isDark, primary, applyModifiers: true),
                _keyChip('Enter', '\r', isDark, primary, applyModifiers: true),
                if (_platformName == 'deck')
                  _keyChip('/rewind', '/rewind\r', isDark, primary, accent: true),
              ],
            ),
          ),
        ),
      ],
    );
  }

  static const List<({String label, String seq})> _fnKeysRow1 = [
    (label: 'F1', seq: '\x1bOP'),
    (label: 'F2', seq: '\x1bOQ'),
    (label: 'F3', seq: '\x1bOR'),
    (label: 'F4', seq: '\x1bOS'),
    (label: 'F5', seq: '\x1b[15~'),
    (label: 'F6', seq: '\x1b[17~'),
  ];

  static const List<({String label, String seq})> _fnKeysRow2 = [
    (label: 'F7', seq: '\x1b[18~'),
    (label: 'F8', seq: '\x1b[19~'),
    (label: 'F9', seq: '\x1b[20~'),
    (label: 'F10', seq: '\x1b[21~'),
    (label: 'F11', seq: '\x1b[23~'),
    (label: 'F12', seq: '\x1b[24~'),
  ];

  static const List<String> _numRowKeys = [
    '1', '2', '3', '4', '5', '6', '7', '8', '9', '0', '-', '=', '\\',
  ];
  static const List<String> _qwertyRow1 = [
    'q', 'w', 'e', 'r', 't', 'y', 'u', 'i', 'o', 'p', '[', ']',
  ];
  static const List<String> _qwertyRow2 = [
    'a', 's', 'd', 'f', 'g', 'h', 'j', 'k', 'l', ';', "'",
  ];
  static const List<String> _qwertyRow3 = [
    'z', 'x', 'c', 'v', 'b', 'n', 'm', ',', '.', '/',
  ];

  Widget _buildFullKeyboardPanel(
    bool isDark,
    Color primary,
    Color borderColor, {
    double maxHeight = 248,
  }) {
    return ConstrainedBox(
      constraints: BoxConstraints(maxHeight: maxHeight),
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // 第1行：模式切回 + 常用控制/编辑键 + 粘滞修饰键
            Row(
              children: [
                _modeToggleButton(
                  label: '快捷栏',
                  icon: Icons.keyboard_hide_outlined,
                  isExpanded: true,
                  isDark: isDark,
                  primary: primary,
                ),
                const SizedBox(width: 6),
                Expanded(
                  child: SingleChildScrollView(
                    scrollDirection: Axis.horizontal,
                    child: Row(
                      children: [
                        _keyChip('Esc', '\x1b', isDark, primary, applyModifiers: true),
                        _keyChip('Tab', '\t', isDark, primary, applyModifiers: true),
                        _modifierChip(
                          'Ctrl',
                          active: _ctrlActive,
                          isDark: isDark,
                          primary: primary,
                          onTap: () => setState(() => _ctrlActive = !_ctrlActive),
                        ),
                        _modifierChip(
                          'Alt',
                          active: _altActive,
                          isDark: isDark,
                          primary: primary,
                          onTap: () => setState(() => _altActive = !_altActive),
                        ),
                        _modifierChip(
                          'Shift',
                          active: _shiftActive,
                          isDark: isDark,
                          primary: primary,
                          onTap: () => setState(() => _shiftActive = !_shiftActive),
                        ),
                        _keyChip('Home', '\x1b[H', isDark, primary, applyModifiers: true),
                        _keyChip('End', '\x1b[F', isDark, primary, applyModifiers: true),
                        _keyChip('PgUp', '\x1b[5~', isDark, primary, applyModifiers: true),
                        _keyChip('PgDn', '\x1b[6~', isDark, primary, applyModifiers: true),
                        _keyChip('Ins', '\x1b[2~', isDark, primary, applyModifiers: true),
                        _keyChip('Del', '\x1b[3~', isDark, primary, applyModifiers: true),
                        if (_platformName == 'deck')
                          _keyChip('/rewind', '/rewind\r', isDark, primary, accent: true),
                      ],
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 5),
            // 第2行：F1-F12 功能区（宽屏单行12键，窄屏分两行6+6键确保全部直达）
            LayoutBuilder(
              builder: (ctx, constraints) {
                if (constraints.maxWidth >= 500) {
                  return _buildFnKeyRow([..._fnKeysRow1, ..._fnKeysRow2], isDark, primary);
                }
                return Column(
                  children: [
                    _buildFnKeyRow(_fnKeysRow1, isDark, primary),
                    const SizedBox(height: 3),
                    _buildFnKeyRow(_fnKeysRow2, isDark, primary),
                  ],
                );
              },
            ),
            const SizedBox(height: 4),
            // 第3行：数字与符号 + 退格
            Row(
              children: [
                for (final k in _numRowKeys)
                  Expanded(
                    child: Padding(
                      padding: const EdgeInsets.only(right: 3),
                      child: _gridKeyButton(
                        label: _shiftActive ? TerminalPanel.applyKeyModifiers(k, shift: true) : k,
                        onTap: _connected ? () => _sendQuickBytes(k, applyModifiers: true) : null,
                        isDark: isDark,
                        primary: primary,
                      ),
                    ),
                  ),
                Expanded(
                  flex: 2,
                  child: _gridKeyButton(
                    label: '⌫',
                    onTap: _connected ? () => _sendQuickBytes('\x7f', applyModifiers: true) : null,
                    isDark: isDark,
                    primary: primary,
                    toneMuted: true,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 3),
            // 第4行：QWERTY 上排
            Row(
              children: [
                for (var i = 0; i < _qwertyRow1.length; i++)
                  Expanded(
                    child: Padding(
                      padding: EdgeInsets.only(right: i == _qwertyRow1.length - 1 ? 0 : 3),
                      child: _gridKeyButton(
                        label: _displayCharLabel(_qwertyRow1[i]),
                        onTap: _connected
                            ? () => _sendQuickBytes(_qwertyRow1[i], applyModifiers: true)
                            : null,
                        isDark: isDark,
                        primary: primary,
                      ),
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 3),
            // 第5行：ASDF 中排 + Enter
            Row(
              children: [
                for (final k in _qwertyRow2)
                  Expanded(
                    child: Padding(
                      padding: const EdgeInsets.only(right: 3),
                      child: _gridKeyButton(
                        label: _displayCharLabel(k),
                        onTap: _connected ? () => _sendQuickBytes(k, applyModifiers: true) : null,
                        isDark: isDark,
                        primary: primary,
                      ),
                    ),
                  ),
                Expanded(
                  flex: 2,
                  child: _gridKeyButton(
                    label: 'Enter',
                    onTap: _connected ? () => _sendQuickBytes('\r', applyModifiers: true) : null,
                    isDark: isDark,
                    primary: primary,
                    accent: true,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 3),
            // 第6行：ZXCV 下排 + 方向键 ↑
            Row(
              children: [
                for (final k in _qwertyRow3)
                  Expanded(
                    child: Padding(
                      padding: const EdgeInsets.only(right: 3),
                      child: _gridKeyButton(
                        label: _displayCharLabel(k),
                        onTap: _connected ? () => _sendQuickBytes(k, applyModifiers: true) : null,
                        isDark: isDark,
                        primary: primary,
                      ),
                    ),
                  ),
                Expanded(
                  child: Padding(
                    padding: const EdgeInsets.only(right: 3),
                    child: _gridKeyButton(
                      label: _displayCharLabel('`'),
                      onTap: _connected ? () => _sendQuickBytes('`', applyModifiers: true) : null,
                      isDark: isDark,
                      primary: primary,
                    ),
                  ),
                ),
                Expanded(
                  child: _gridKeyButton(
                    label: '↑',
                    onTap: _connected ? () => _sendQuickBytes('\x1b[A', applyModifiers: true) : null,
                    isDark: isDark,
                    primary: primary,
                    toneMuted: true,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 3),
            // 第7行：高频热键 + 空格 + 方向键 ← ↓ →
            Row(
              children: [
                Expanded(
                  flex: 2,
                  child: Padding(
                    padding: const EdgeInsets.only(right: 3),
                    child: _gridKeyButton(
                      label: '^C',
                      onTap: _connected ? () => _sendQuickBytes('\x03') : null,
                      isDark: isDark,
                      primary: primary,
                      toneMuted: true,
                    ),
                  ),
                ),
                Expanded(
                  flex: 2,
                  child: Padding(
                    padding: const EdgeInsets.only(right: 3),
                    child: _gridKeyButton(
                      label: '^L',
                      onTap: _connected ? () => _sendQuickBytes('\x0c') : null,
                      isDark: isDark,
                      primary: primary,
                      toneMuted: true,
                    ),
                  ),
                ),
                Expanded(
                  flex: 5,
                  child: Padding(
                    padding: const EdgeInsets.only(right: 3),
                    child: _gridKeyButton(
                      label: 'Space',
                      onTap: _connected ? () => _sendQuickBytes(' ', applyModifiers: true) : null,
                      isDark: isDark,
                      primary: primary,
                    ),
                  ),
                ),
                Expanded(
                  child: Padding(
                    padding: const EdgeInsets.only(right: 3),
                    child: _gridKeyButton(
                      label: '←',
                      onTap: _connected ? () => _sendQuickBytes('\x1b[D', applyModifiers: true) : null,
                      isDark: isDark,
                      primary: primary,
                      toneMuted: true,
                    ),
                  ),
                ),
                Expanded(
                  child: Padding(
                    padding: const EdgeInsets.only(right: 3),
                    child: _gridKeyButton(
                      label: '↓',
                      onTap: _connected ? () => _sendQuickBytes('\x1b[B', applyModifiers: true) : null,
                      isDark: isDark,
                      primary: primary,
                      toneMuted: true,
                    ),
                  ),
                ),
                Expanded(
                  child: _gridKeyButton(
                    label: '→',
                    onTap: _connected ? () => _sendQuickBytes('\x1b[C', applyModifiers: true) : null,
                    isDark: isDark,
                    primary: primary,
                    toneMuted: true,
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildFnKeyRow(
    List<({String label, String seq})> keys,
    bool isDark,
    Color primary,
  ) {
    return Row(
      children: [
        for (var i = 0; i < keys.length; i++)
          Expanded(
            child: Padding(
              padding: EdgeInsets.only(right: i == keys.length - 1 ? 0 : 3),
              child: _gridKeyButton(
                label: keys[i].label,
                onTap: _connected ? () => _sendQuickBytes(keys[i].seq, applyModifiers: true) : null,
                isDark: isDark,
                primary: primary,
                toneMuted: true,
              ),
            ),
          ),
      ],
    );
  }

  String _displayCharLabel(String ch) {
    if (_shiftActive) {
      return TerminalPanel.applyKeyModifiers(ch, shift: true);
    }
    if (ch.length == 1 && RegExp(r'^[a-z]$').hasMatch(ch)) {
      return ch.toUpperCase();
    }
    return ch;
  }

  Widget _modeToggleButton({
    required String label,
    required IconData icon,
    required bool isExpanded,
    required bool isDark,
    required Color primary,
  }) {
    return InkWell(
      borderRadius: BorderRadius.circular(6),
      onTap: () {
        final nextShowFull = !isExpanded;
        setState(() {
          _showFullKeyboard = nextShowFull;
          if (!nextShowFull) {
            _shiftActive = false;
          }
        });
        if (!_isTouchMobile || !nextShowFull) {
          _termFocusNode.requestFocus();
        }
      },
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        decoration: BoxDecoration(
          color: isExpanded
              ? primary.withValues(alpha: isDark ? 0.22 : 0.14)
              : (isDark ? const Color(0xFF232630) : Colors.white),
          borderRadius: BorderRadius.circular(6),
          border: Border.all(
            color: isExpanded
                ? primary.withValues(alpha: 0.6)
                : (isDark ? const Color(0xFF3A3E4D) : const Color(0xFFD4D4D8)),
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              icon,
              size: 13,
              color: isExpanded
                  ? primary
                  : (isDark ? Colors.white70 : Colors.black87),
            ),
            const SizedBox(width: 4),
            Text(
              label,
              style: TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.w600,
                color: isExpanded
                    ? primary
                    : (isDark ? Colors.white70 : Colors.black87),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _modifierChip(
    String label, {
    required bool active,
    required bool isDark,
    required Color primary,
    required VoidCallback onTap,
  }) {
    return Padding(
      padding: const EdgeInsets.only(right: 5),
      child: InkWell(
        borderRadius: BorderRadius.circular(6),
        onTap: _connected ? onTap : null,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
          decoration: BoxDecoration(
            color: active
                ? primary.withValues(alpha: isDark ? 0.28 : 0.16)
                : (isDark ? const Color(0xFF22242C) : Colors.white),
            borderRadius: BorderRadius.circular(6),
            border: Border.all(
              color: active
                  ? primary
                  : (isDark ? const Color(0xFF323542) : const Color(0xFFD4D4D8)),
            ),
          ),
          child: Text(
            label,
            style: TextStyle(
              fontSize: 11,
              fontFamily: 'monospace',
              fontWeight: active ? FontWeight.w700 : FontWeight.w500,
              color: active
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

  Widget _gridKeyButton({
    required String label,
    required VoidCallback? onTap,
    required bool isDark,
    required Color primary,
    bool accent = false,
    bool toneMuted = false,
  }) {
    final bgColor = accent
        ? primary.withValues(alpha: isDark ? 0.24 : 0.14)
        : (toneMuted
            ? (isDark ? const Color(0xFF1B1D24) : const Color(0xFFE9EAEE))
            : (isDark ? const Color(0xFF252832) : Colors.white));
    final borderColor = accent
        ? primary.withValues(alpha: 0.6)
        : (isDark ? const Color(0xFF343846) : const Color(0xFFD4D4D8));
    final textColor = accent
        ? primary
        : (_connected
            ? (isDark ? Colors.white.withValues(alpha: 0.88) : Colors.black87)
            : (isDark ? Colors.white24 : Colors.black26));

    return Material(
      color: bgColor,
      borderRadius: BorderRadius.circular(5),
      child: InkWell(
        borderRadius: BorderRadius.circular(5),
        onTap: onTap,
        child: Container(
          height: 27,
          alignment: Alignment.center,
          padding: const EdgeInsets.symmetric(horizontal: 2),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(5),
            border: Border.all(color: borderColor, width: 0.8),
          ),
          child: FittedBox(
            fit: BoxFit.scaleDown,
            child: Text(
              label,
              style: TextStyle(
                fontSize: 11,
                fontFamily: 'monospace',
                fontWeight: accent ? FontWeight.w700 : FontWeight.w500,
                color: textColor,
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _keyChip(
    String label,
    String seq,
    bool isDark,
    Color primary, {
    bool accent = false,
    bool applyModifiers = false,
  }) {
    return Padding(
      padding: const EdgeInsets.only(right: 5),
      child: InkWell(
        borderRadius: BorderRadius.circular(6),
        onTap: _connected ? () => _sendQuickBytes(seq, applyModifiers: applyModifiers) : null,
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

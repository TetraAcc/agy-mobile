import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/config/composer_prefs.dart';
import '../../models/models.dart';
import 'attachment_preview_bar.dart';

class BottomInputBar extends StatefulWidget {
  final TextEditingController inputController;
  final bool isConnected;
  final bool isThinking;
  final bool canWrite;
  final bool isDark;
  final Widget? changesBar;
  final Widget? queueBar;
  final String queueMode;
  final String sendKey;
  final List<UploadedAttachment> pendingAttachments;
  final ValueChanged<int> onRemoveAttachment;
  final VoidCallback onShowAddContext;
  final VoidCallback onSendMessage;
  final VoidCallback onStopTask;

  const BottomInputBar({
    super.key,
    required this.inputController,
    required this.isConnected,
    required this.isThinking,
    this.canWrite = true,
    required this.isDark,
    this.changesBar,
    this.queueBar,
    this.queueMode = ComposerPrefs.queueModeQueue,
    this.sendKey = ComposerPrefs.sendKeyEnter,
    required this.pendingAttachments,
    required this.onRemoveAttachment,
    required this.onShowAddContext,
    required this.onSendMessage,
    required this.onStopTask,
  });

  @override
  State<BottomInputBar> createState() => _BottomInputBarState();
}

class _BottomInputBarState extends State<BottomInputBar> {
  late final FocusNode _focusNode;

  @override
  void initState() {
    super.initState();
    _focusNode = FocusNode(onKeyEvent: _handleKeyEvent);
  }

  @override
  void dispose() {
    _focusNode.dispose();
    super.dispose();
  }

  bool get _hasDraft =>
      widget.inputController.text.trim().isNotEmpty || widget.pendingAttachments.isNotEmpty;

  bool get _isCtrlEnter => widget.sendKey == ComposerPrefs.sendKeyCtrlEnter;

  KeyEventResult _handleKeyEvent(FocusNode node, KeyEvent event) {
    if (!widget.isConnected || !widget.canWrite) return KeyEventResult.ignored;
    if (event is! KeyDownEvent) return KeyEventResult.ignored;
    if (event.logicalKey != LogicalKeyboardKey.enter &&
        event.logicalKey != LogicalKeyboardKey.numpadEnter) {
      return KeyEventResult.ignored;
    }

    final kb = HardwareKeyboard.instance;
    final shift = kb.isShiftPressed;
    final ctrl = kb.isControlPressed || kb.isMetaPressed;
    final alt = kb.isAltPressed;

    final shouldSend = _isCtrlEnter ? (ctrl && !alt) : (!shift && !ctrl && !alt);
    if (shouldSend) {
      if (_hasDraft) {
        widget.onSendMessage();
      }
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  @override
  Widget build(BuildContext context) {
    final isDark = widget.isDark;
    final inputEnabled = widget.isConnected && widget.canWrite;
    final isQueueMode = widget.queueMode != ComposerPrefs.queueModeImmediate;
    final primary = Theme.of(context).colorScheme.primary;

    final String hintText;
    if (!widget.isConnected) {
      hintText = '请先连接到节点...';
    } else if (!widget.canWrite) {
      hintText = '当前节点为只读权限';
    } else if (widget.isThinking) {
      hintText = isQueueMode ? '执行中，输入后将排队入列...' : '执行中，输入后将立即发送...';
    } else if (_isCtrlEnter) {
      hintText = '向 Agent 发送指令... (Ctrl+Enter 发送)';
    } else {
      hintText = '向 Agent 发送指令...';
    }

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      color: isDark ? const Color(0xFF161F30) : Colors.white,
      child: SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (widget.changesBar != null) widget.changesBar!,
            if (widget.queueBar != null) widget.queueBar!,
            if (widget.pendingAttachments.isNotEmpty)
              AttachmentPreviewBar(
                attachments: widget.pendingAttachments,
                onRemove: widget.onRemoveAttachment,
                isDark: isDark,
              ),
            Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Padding(
                  padding: const EdgeInsets.only(bottom: 4),
                  child: InkWell(
                    borderRadius: BorderRadius.circular(20),
                    onTap: widget.isConnected ? widget.onShowAddContext : null,
                    child: Container(
                      width: 36,
                      height: 36,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: isDark
                            ? Colors.white.withValues(alpha: 0.08)
                            : Colors.black.withValues(alpha: 0.05),
                      ),
                      child: Icon(
                        Icons.add_rounded,
                        color: widget.isConnected
                            ? (isDark ? Colors.white70 : Colors.black54)
                            : (isDark ? Colors.white24 : Colors.black26),
                        size: 22,
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: TextField(
                    focusNode: _focusNode,
                    controller: widget.inputController,
                    enabled: inputEnabled,
                    minLines: 1,
                    maxLines: 5,
                    keyboardType: TextInputType.multiline,
                    textInputAction: _isCtrlEnter ? TextInputAction.newline : TextInputAction.send,
                    style: TextStyle(color: isDark ? Colors.white : Colors.black87),
                    decoration: InputDecoration(
                      hintText: hintText,
                      hintStyle: TextStyle(
                        color: isDark ? Colors.white24 : Colors.black26,
                        fontSize: 13,
                      ),
                      filled: true,
                      fillColor: isDark ? const Color(0xFF0B0F19) : const Color(0xFFF1F5F9),
                      contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(24),
                        borderSide: BorderSide.none,
                      ),
                    ),
                    onSubmitted: (_) {
                      if (inputEnabled && !_isCtrlEnter && _hasDraft) {
                        widget.onSendMessage();
                      }
                    },
                  ),
                ),
                const SizedBox(width: 6),
                ValueListenableBuilder<TextEditingValue>(
                  valueListenable: widget.inputController,
                  builder: (_, val, __) {
                    final hasTextOrAttach =
                        val.text.trim().isNotEmpty || widget.pendingAttachments.isNotEmpty;
                    if (!widget.isThinking) {
                      return IconButton(
                        icon: Icon(Icons.arrow_upward_rounded, color: primary),
                        tooltip: _isCtrlEnter ? '发送 (Ctrl+Enter)' : '发送',
                        onPressed: inputEnabled ? widget.onSendMessage : null,
                      );
                    }
                    return Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        if (inputEnabled && hasTextOrAttach)
                          IconButton(
                            icon: Icon(
                              isQueueMode ? Icons.playlist_add_rounded : Icons.send_rounded,
                              color: primary,
                            ),
                            tooltip: isQueueMode ? '排队入列' : '立即发送',
                            onPressed: widget.onSendMessage,
                          ),
                        IconButton(
                          icon: Container(
                            width: 32,
                            height: 32,
                            decoration: BoxDecoration(
                              color: Colors.redAccent.withValues(alpha: 0.15),
                              shape: BoxShape.circle,
                              border: Border.all(color: Colors.redAccent, width: 1.5),
                            ),
                            child: const Center(
                              child: Icon(Icons.stop_rounded, color: Colors.redAccent, size: 20),
                            ),
                          ),
                          tooltip: '停止当前任务 (Stop)',
                          onPressed: inputEnabled ? widget.onStopTask : null,
                        ),
                      ],
                    );
                  },
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/config/composer_prefs.dart';
import '../../core/config/responsive_layout.dart';
import '../../core/platform/platform_bridge.dart';
import '../../core/theme/app_colors.dart';
import '../../models/models.dart';
import 'attachment_preview_bar.dart';

class BottomInputBar extends StatefulWidget {
  final TextEditingController inputController;
  final bool isConnected;
  final bool isThinking;
  final bool canWrite;
  final bool isDark;
  final double maxContentWidth;
  final Widget? changesBar;
  final Widget? queueBar;
  final Widget? outboxBar;
  final String queueMode;
  final String sendKey;
  final List<UploadedAttachment> pendingAttachments;
  final ValueChanged<int> onRemoveAttachment;
  final VoidCallback onShowAddContext;
  final VoidCallback onSendMessage;
  final VoidCallback onStopTask;
  final ValueChanged<PickedLocalFile>? onInsertRichContent;

  const BottomInputBar({
    super.key,
    required this.inputController,
    required this.isConnected,
    required this.isThinking,
    this.canWrite = true,
    required this.isDark,
    this.maxContentWidth = 780.0,
    this.changesBar,
    this.queueBar,
    this.outboxBar,
    this.queueMode = ComposerPrefs.queueModeQueue,
    this.sendKey = ComposerPrefs.sendKeyEnter,
    required this.pendingAttachments,
    required this.onRemoveAttachment,
    required this.onShowAddContext,
    required this.onSendMessage,
    required this.onStopTask,
    this.onInsertRichContent,
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

  bool get _isTouchMobile =>
      !kIsWeb &&
      (defaultTargetPlatform == TargetPlatform.android ||
          defaultTargetPlatform == TargetPlatform.iOS);

  String _extFromMime(String mimeType) {
    final lower = mimeType.toLowerCase();
    if (lower.contains('jpeg') || lower.contains('jpg')) return 'jpg';
    if (lower.contains('webp')) return 'webp';
    if (lower.contains('gif')) return 'gif';
    return 'png';
  }

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
    } else if (_isCtrlEnter && !_isTouchMobile) {
      hintText = '向 Agent 发送指令... (Ctrl+Enter 发送)';
    } else {
      hintText = '向 Agent 发送指令...';
    }

    final composerBg = isDark ? const Color(0xFF1B1B1F) : const Color(0xFFF5F5F7);
    final composerBorder = isDark ? const Color(0xFF2D2D34) : const Color(0xFFE4E4E7);
    final isCompactKeyboard = ResponsiveLayout.isCompactHeightKeyboardOpen(context);

    return Container(
      color: isDark ? AppColors.darkBg : AppColors.lightBg,
      padding: isCompactKeyboard
          ? const EdgeInsets.fromLTRB(12, 2, 12, 4)
          : const EdgeInsets.fromLTRB(12, 4, 12, 8),
      child: SafeArea(
        top: false,
        child: Center(
          child: ConstrainedBox(
            constraints: BoxConstraints(maxWidth: widget.maxContentWidth),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (widget.changesBar != null) widget.changesBar!,
                if (widget.queueBar != null) widget.queueBar!,
                if (widget.outboxBar != null) widget.outboxBar!,
                if (widget.pendingAttachments.isNotEmpty)
                  AttachmentPreviewBar(
                    attachments: widget.pendingAttachments,
                    onRemove: widget.onRemoveAttachment,
                    isDark: isDark,
                  ),
                Container(
                  decoration: BoxDecoration(
                    color: composerBg,
                    borderRadius: BorderRadius.circular(20),
                    border: Border.all(color: composerBorder, width: 1),
                  ),
                  padding: isCompactKeyboard
                      ? const EdgeInsets.fromLTRB(14, 7, 10, 6)
                      : const EdgeInsets.fromLTRB(14, 10, 10, 8),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      TextField(
                        focusNode: _focusNode,
                        controller: widget.inputController,
                        enabled: inputEnabled,
                        minLines: 1,
                        maxLines: isCompactKeyboard ? 3 : 6,
                        keyboardType: TextInputType.multiline,
                        textInputAction: (_isTouchMobile || _isCtrlEnter)
                            ? TextInputAction.newline
                            : TextInputAction.send,
                        contentInsertionConfiguration:
                            (widget.onInsertRichContent != null && inputEnabled)
                                ? ContentInsertionConfiguration(
                                    allowedMimeTypes: const <String>[
                                      'image/png',
                                      'image/jpeg',
                                      'image/webp',
                                      'image/gif',
                                    ],
                                    onContentInserted: (KeyboardInsertedContent content) {
                                      final data = content.data;
                                      if (data == null || data.isEmpty) return;
                                      final ext = _extFromMime(content.mimeType);
                                      widget.onInsertRichContent!(
                                        PickedLocalFile(
                                          filename:
                                              'ime_image_${DateTime.now().millisecondsSinceEpoch}.$ext',
                                          bytes: data,
                                          isImage: true,
                                        ),
                                      );
                                    },
                                  )
                                : null,
                        style: TextStyle(
                          color: isDark ? const Color(0xFFF4F4F5) : const Color(0xFF18181B),
                          fontSize: 14.5,
                          height: 1.45,
                        ),
                        decoration: InputDecoration(
                          isDense: true,
                          hintText: hintText,
                          hintStyle: TextStyle(
                            color: isDark ? const Color(0xFF71717A) : const Color(0xFFA1A1AA),
                            fontSize: 14,
                          ),
                          filled: false,
                          contentPadding: const EdgeInsets.symmetric(horizontal: 2, vertical: 2),
                          border: InputBorder.none,
                          enabledBorder: InputBorder.none,
                          focusedBorder: InputBorder.none,
                          disabledBorder: InputBorder.none,
                        ),
                        onSubmitted: (_) {
                          if (!_isTouchMobile && inputEnabled && !_isCtrlEnter && _hasDraft) {
                            widget.onSendMessage();
                          }
                        },
                      ),
                      const SizedBox(height: 6),
                      Row(
                        children: [
                          InkWell(
                            borderRadius: BorderRadius.circular(16),
                            onTap: widget.isConnected ? widget.onShowAddContext : null,
                            child: Container(
                              width: 32,
                              height: 32,
                              decoration: BoxDecoration(
                                borderRadius: BorderRadius.circular(16),
                                color: isDark
                                    ? Colors.white.withValues(alpha: 0.06)
                                    : Colors.black.withValues(alpha: 0.05),
                              ),
                              child: Icon(
                                Icons.add_rounded,
                                color: widget.isConnected
                                    ? (isDark ? const Color(0xFFD4D4D8) : const Color(0xFF3F3F46))
                                    : (isDark ? Colors.white24 : Colors.black26),
                                size: 20,
                              ),
                            ),
                          ),
                          const Spacer(),
                          ValueListenableBuilder<TextEditingValue>(
                            valueListenable: widget.inputController,
                            builder: (_, val, __) {
                              final hasTextOrAttach =
                                  val.text.trim().isNotEmpty || widget.pendingAttachments.isNotEmpty;
                              final canSendNow = inputEnabled && hasTextOrAttach;
                              if (!widget.isThinking) {
                                return Tooltip(
                                  message: _isCtrlEnter ? '发送 (Ctrl+Enter)' : '发送',
                                  child: InkWell(
                                    borderRadius: BorderRadius.circular(18),
                                    onTap: inputEnabled ? widget.onSendMessage : null,
                                    child: AnimatedContainer(
                                      duration: const Duration(milliseconds: 150),
                                      width: 32,
                                      height: 32,
                                      decoration: BoxDecoration(
                                        shape: BoxShape.circle,
                                        color: canSendNow
                                            ? (isDark
                                                ? const Color(0xFFF4F4F5)
                                                : const Color(0xFF18181B))
                                            : (isDark
                                                ? Colors.white.withValues(alpha: 0.08)
                                                : Colors.black.withValues(alpha: 0.08)),
                                      ),
                                      child: Icon(
                                        Icons.arrow_upward_rounded,
                                        size: 18,
                                        color: canSendNow
                                            ? (isDark ? const Color(0xFF111113) : Colors.white)
                                            : (isDark ? Colors.white30 : Colors.black26),
                                      ),
                                    ),
                                  ),
                                );
                              }
                              return Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  if (inputEnabled && hasTextOrAttach) ...[
                                    Tooltip(
                                      message: isQueueMode ? '排队入列' : '立即发送',
                                      child: InkWell(
                                        borderRadius: BorderRadius.circular(16),
                                        onTap: widget.onSendMessage,
                                        child: Container(
                                          width: 32,
                                          height: 32,
                                          decoration: BoxDecoration(
                                            shape: BoxShape.circle,
                                            color: primary.withValues(alpha: 0.16),
                                          ),
                                          child: Icon(
                                            isQueueMode
                                                ? Icons.playlist_add_rounded
                                                : Icons.send_rounded,
                                            size: 17,
                                            color: primary,
                                          ),
                                        ),
                                      ),
                                    ),
                                    const SizedBox(width: 8),
                                  ],
                                  Tooltip(
                                    message: '停止当前任务',
                                    child: InkWell(
                                      borderRadius: BorderRadius.circular(10),
                                      onTap: inputEnabled ? widget.onStopTask : null,
                                      child: Container(
                                        width: 32,
                                        height: 32,
                                        decoration: BoxDecoration(
                                          color: Colors.redAccent.withValues(alpha: 0.12),
                                          borderRadius: BorderRadius.circular(10),
                                          border: Border.all(
                                            color: Colors.redAccent.withValues(alpha: 0.6),
                                            width: 1.2,
                                          ),
                                        ),
                                        child: const Center(
                                          child: Icon(
                                            Icons.stop_rounded,
                                            color: Colors.redAccent,
                                            size: 18,
                                          ),
                                        ),
                                      ),
                                    ),
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
              ],
            ),
          ),
        ),
      ),
    );
  }
}

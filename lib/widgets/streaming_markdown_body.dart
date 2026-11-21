import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_markdown/flutter_markdown.dart';
import 'code_block_builder.dart';

/// 专用于 Agent 回复的流式打字机 Markdown 渲染器
/// 具有永久完结记忆（Finished Cache）与唯一锁定机制，严禁对任何历史旧消息重放打字机
class StreamingMarkdownBody extends StatefulWidget {
  final String messageKey;
  final String fullText;
  final bool isLiveStream;
  final bool isDark;
  final void Function(String url) onOpenUrl;
  final void Function(String path) onDownloadFile;
  final VoidCallback? onComplete;

  const StreamingMarkdownBody({
    super.key,
    required this.messageKey,
    required this.fullText,
    required this.isLiveStream,
    required this.isDark,
    required this.onOpenUrl,
    required this.onDownloadFile,
    this.onComplete,
  });

  /// 已完成打字机的消息唯一指纹集合，永远不会被二次重放
  static final Set<String> _globallyFinishedKeys = {};

  static void markFinished(String key) {
    if (key.isNotEmpty) _globallyFinishedKeys.add(key);
  }

  static void clearCache() {
    _globallyFinishedKeys.clear();
  }

  @override
  State<StreamingMarkdownBody> createState() => _StreamingMarkdownBodyState();
}

class _StreamingMarkdownBodyState extends State<StreamingMarkdownBody> {
  int _displayedLength = 0;
  Timer? _typewriterTimer;
  bool _isFinished = false;

  @override
  void initState() {
    super.initState();
    // 核心防线 1：如果已经在完结集合中，或者非实时流，或者内容为空，100% 直接展示全文，绝对不启动打字机
    if (widget.messageKey.isNotEmpty && StreamingMarkdownBody._globallyFinishedKeys.contains(widget.messageKey)) {
      _displayedLength = widget.fullText.length;
      _isFinished = true;
      return;
    }

    if (!widget.isLiveStream || widget.fullText.isEmpty) {
      _displayedLength = widget.fullText.length;
      _isFinished = true;
      if (widget.messageKey.isNotEmpty) {
        StreamingMarkdownBody.markFinished(widget.messageKey);
      }
    } else {
      _startTypewriter();
    }
  }

  @override
  void didUpdateWidget(covariant StreamingMarkdownBody oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!widget.isLiveStream ||
        (widget.messageKey.isNotEmpty && StreamingMarkdownBody._globallyFinishedKeys.contains(widget.messageKey))) {
      _displayedLength = widget.fullText.length;
      _isFinished = true;
      _typewriterTimer?.cancel();
    } else if (widget.fullText != oldWidget.fullText) {
      if (_isFinished && _displayedLength < widget.fullText.length) {
        _isFinished = false;
        _startTypewriter();
      }
    }
  }

  @override
  void dispose() {
    _typewriterTimer?.cancel();
    super.dispose();
  }

  void _startTypewriter() {
    _typewriterTimer?.cancel();
    _typewriterTimer = Timer.periodic(const Duration(milliseconds: 20), (timer) {
      if (!mounted) {
        timer.cancel();
        return;
      }
      if (_displayedLength >= widget.fullText.length) {
        timer.cancel();
        _markCompleted();
        return;
      }

      // 动态步长自适应：长消息快速推进，短消息细腻敲击
      final remaining = widget.fullText.length - _displayedLength;
      final step = remaining > 150 ? 8 : (remaining > 50 ? 4 : 2);
      final nextLength = (_displayedLength + step).clamp(0, widget.fullText.length);

      setState(() {
        _displayedLength = nextLength;
        if (_displayedLength >= widget.fullText.length) {
          _markCompleted();
          timer.cancel();
        }
      });
    });
  }

  void _markCompleted() {
    setState(() => _isFinished = true);
    if (widget.messageKey.isNotEmpty) {
      StreamingMarkdownBody.markFinished(widget.messageKey);
    }
    widget.onComplete?.call();
  }

  void _skipToEnd() {
    if (!_isFinished) {
      _typewriterTimer?.cancel();
      _displayedLength = widget.fullText.length;
      _markCompleted();
    }
  }

  /// 智能闭合流式截断的 Markdown 语法（如未闭合的代码块反引号）
  String _safeSubstring(String text, int length) {
    if (length >= text.length) return text;
    final sub = text.substring(0, length);
    final tripleBackticks = RegExp(r'```').allMatches(sub).length;
    if (tripleBackticks % 2 != 0) {
      return '$sub\n```';
    }
    return sub;
  }

  @override
  Widget build(BuildContext context) {
    final currentText = _isFinished ? widget.fullText : _safeSubstring(widget.fullText, _displayedLength);

    return GestureDetector(
      onTap: _skipToEnd, // 点击卡片即可快速跳过打字机动画
      behavior: HitTestBehavior.translucent,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          MarkdownBody(
            data: currentText,
            selectable: true,
            builders: {
              'code': CodeElementBuilder(isDark: widget.isDark),
            },
            onTapLink: (text, href, title) {
              if (href != null && href.isNotEmpty) {
                if (href.startsWith("http://") || href.startsWith("https://")) {
                  widget.onOpenUrl(href);
                } else {
                  widget.onDownloadFile(href);
                }
              }
            },
            styleSheet: MarkdownStyleSheet.fromTheme(Theme.of(context)).copyWith(
              p: TextStyle(
                color: widget.isDark ? const Color(0xFFE2E8F0) : const Color(0xFF1E293B),
                fontSize: 14,
                height: 1.6,
              ),
              h1: TextStyle(
                color: widget.isDark ? Colors.white : Colors.black87,
                fontSize: 18,
                fontWeight: FontWeight.bold,
              ),
              h2: TextStyle(
                color: widget.isDark ? Colors.white : Colors.black87,
                fontSize: 16,
                fontWeight: FontWeight.bold,
              ),
              h3: TextStyle(
                color: Theme.of(context).colorScheme.primary,
                fontSize: 15,
                fontWeight: FontWeight.bold,
              ),
              strong: TextStyle(
                color: widget.isDark ? Colors.white : Colors.black87,
                fontWeight: FontWeight.bold,
              ),
              em: TextStyle(
                color: widget.isDark ? const Color(0xFF94A3B8) : const Color(0xFF64748B),
                fontStyle: FontStyle.italic,
              ),
              a: TextStyle(
                color: Theme.of(context).colorScheme.primary,
                decoration: TextDecoration.underline,
              ),
              listBullet: TextStyle(
                color: Theme.of(context).colorScheme.primary,
                fontSize: 14,
              ),
              blockquote: TextStyle(
                color: widget.isDark ? const Color(0xFFCBD5E1) : const Color(0xFF334155),
                fontSize: 13.5,
                height: 1.6,
              ),
              blockquotePadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
              blockquoteDecoration: BoxDecoration(
                color: widget.isDark ? const Color(0xFF161F30) : const Color(0xFFF1F5F9),
                borderRadius: BorderRadius.circular(8),
                border: Border(
                  left: BorderSide(
                    color: Theme.of(context).colorScheme.primary,
                    width: 3.5,
                  ),
                ),
              ),
              code: TextStyle(
                backgroundColor: widget.isDark ? const Color(0xFF0B0F19) : const Color(0xFFF1F5F9),
                color: Theme.of(context).colorScheme.primary,
                fontFamily: 'monospace',
                fontSize: 12,
              ),
            ),
          ),
          // 流式进行中的微动光标
          if (!_isFinished) ...[
            const SizedBox(height: 6),
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  width: 6,
                  height: 12,
                  decoration: BoxDecoration(
                    color: Theme.of(context).colorScheme.primary,
                    borderRadius: BorderRadius.circular(1.5),
                  ),
                ),
                const SizedBox(width: 6),
                Text(
                  "打字机流式输出中 (点击跳过)",
                  style: TextStyle(
                    fontSize: 10,
                    color: widget.isDark ? Colors.white30 : Colors.black26,
                  ),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }
}

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
  final String authToken;
  final String selectedNode;
  final void Function(String url) onOpenUrl;
  final void Function(String path) onDownloadFile;
  final VoidCallback? onComplete;

  const StreamingMarkdownBody({
    super.key,
    required this.messageKey,
    required this.fullText,
    required this.isLiveStream,
    required this.isDark,
    this.authToken = '',
    this.selectedNode = 'windows',
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
            imageBuilder: (Uri uri, String? title, String? alt) {
              return _buildMarkdownImage(context, uri, title, alt);
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

  /// 自定义 Markdown 图片构建器（完美支持本地图片代理转换与点击全屏大图预览）
  Widget _buildMarkdownImage(BuildContext context, Uri uri, String? title, String? alt) {
    final rawUriStr = uri.toString();
    final isNetwork = rawUriStr.startsWith('http://') || rawUriStr.startsWith('https://');
    final displayCaption = (title != null && title.isNotEmpty)
        ? title
        : ((alt != null && alt.isNotEmpty) ? alt : "");

    String proxyUrl = rawUriStr;
    if (!isNetwork) {
      // 本地 file 协议或系统绝对路径，转为 /api/media 媒体接口代理
      proxyUrl = "/api/media?path=${Uri.encodeComponent(rawUriStr)}&token=${widget.authToken}&node=${widget.selectedNode}";
    }

    final filename = rawUriStr.split(RegExp(r'[\\/]')).last;

    Widget imageWidget = Image.network(
      proxyUrl,
      fit: BoxFit.contain,
      loadingBuilder: (ctx, child, progress) {
        if (progress == null) return child;
        return Container(
          height: 160,
          alignment: Alignment.center,
          child: SizedBox(
            width: 24,
            height: 24,
            child: CircularProgressIndicator(
              strokeWidth: 2,
              value: progress.expectedTotalBytes != null
                  ? progress.cumulativeBytesLoaded / progress.expectedTotalBytes!
                  : null,
              color: Theme.of(context).colorScheme.primary,
            ),
          ),
        );
      },
      errorBuilder: (ctx, err, stack) {
        return Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          decoration: BoxDecoration(
            color: widget.isDark ? const Color(0xFF1E293B) : const Color(0xFFF1F5F9),
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: widget.isDark ? Colors.white12 : Colors.black12),
          ),
          child: Row(
            children: [
              Icon(Icons.broken_image_rounded, size: 20, color: widget.isDark ? Colors.white38 : Colors.black38),
              const SizedBox(width: 8),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      displayCaption.isNotEmpty ? displayCaption : filename,
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.bold,
                        color: widget.isDark ? Colors.white70 : Colors.black87,
                      ),
                      overflow: TextOverflow.ellipsis,
                    ),
                    Text(
                      "未直接加载: $filename",
                      style: TextStyle(
                        fontSize: 10,
                        color: widget.isDark ? Colors.white38 : Colors.black45,
                      ),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                ),
              ),
              if (!isNetwork)
                TextButton.icon(
                  style: TextButton.styleFrom(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                    minimumSize: Size.zero,
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  ),
                  onPressed: () => widget.onDownloadFile(rawUriStr),
                  icon: const Icon(Icons.download_rounded, size: 14),
                  label: const Text("下载查看", style: TextStyle(fontSize: 11)),
                ),
            ],
          ),
        );
      },
    );

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          InkWell(
            borderRadius: BorderRadius.circular(10),
            onTap: () => _openImageLightbox(context, proxyUrl, displayCaption, rawUriStr),
            child: Container(
              constraints: const BoxConstraints(maxHeight: 450),
              decoration: BoxDecoration(
                color: widget.isDark ? const Color(0xFF0F172A) : const Color(0xFFF8FAFC),
                borderRadius: BorderRadius.circular(10),
                border: Border.all(
                  color: widget.isDark ? const Color(0xFF23324A) : const Color(0xFFE2E8F0),
                ),
              ),
              clipBehavior: Clip.antiAlias,
              child: imageWidget,
            ),
          ),
          if (displayCaption.isNotEmpty) ...[
            const SizedBox(height: 4),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 4),
              child: Text(
                displayCaption,
                style: TextStyle(
                  fontSize: 11,
                  color: widget.isDark ? Colors.white54 : Colors.black45,
                  fontStyle: FontStyle.italic,
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }

  /// 点击图片弹出交互式全屏大图预览模态框（支持无级平移缩放与新标签页独立打开）
  void _openImageLightbox(BuildContext context, String imageUrl, String caption, String rawPath) {
    showDialog(
      context: context,
      builder: (ctx) {
        return Dialog(
          backgroundColor: Colors.transparent,
          insetPadding: const EdgeInsets.all(12),
          child: Stack(
            alignment: Alignment.center,
            children: [
              Container(
                constraints: BoxConstraints(
                  maxWidth: MediaQuery.of(ctx).size.width * 0.95,
                  maxHeight: MediaQuery.of(ctx).size.height * 0.85,
                ),
                decoration: BoxDecoration(
                  color: widget.isDark ? const Color(0xFF0F172A) : Colors.white,
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(color: widget.isDark ? const Color(0xFF334155) : const Color(0xFFE2E8F0)),
                  boxShadow: const [
                    BoxShadow(color: Colors.black54, blurRadius: 24, spreadRadius: 4),
                  ],
                ),
                clipBehavior: Clip.antiAlias,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    // 顶部标题与工具栏
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                      color: widget.isDark ? const Color(0xFF1E293B) : const Color(0xFFF8FAFC),
                      child: Row(
                        children: [
                          Icon(Icons.image_outlined, size: 16, color: Theme.of(context).colorScheme.primary),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              caption.isNotEmpty ? caption : rawPath.split(RegExp(r'[\\/]')).last,
                              style: TextStyle(
                                fontSize: 13,
                                fontWeight: FontWeight.bold,
                                color: widget.isDark ? Colors.white : Colors.black87,
                              ),
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                          IconButton(
                            tooltip: "在新标签页打开原图",
                            icon: const Icon(Icons.open_in_new_rounded, size: 18),
                            onPressed: () => widget.onOpenUrl(imageUrl),
                          ),
                          IconButton(
                            tooltip: "关闭",
                            icon: const Icon(Icons.close_rounded, size: 20),
                            onPressed: () => Navigator.of(ctx).pop(),
                          ),
                        ],
                      ),
                    ),
                    // 图片交互缩放区
                    Flexible(
                      child: InteractiveViewer(
                        panEnabled: true,
                        scaleEnabled: true,
                        minScale: 0.8,
                        maxScale: 4.0,
                        child: Center(
                          child: Image.network(
                            imageUrl,
                            fit: BoxFit.contain,
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

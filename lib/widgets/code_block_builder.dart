import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_markdown/flutter_markdown.dart';
import 'package:markdown/markdown.dart' as md;
import 'package:flutter_highlight/flutter_highlight.dart';
import 'package:flutter_highlight/themes/atom-one-dark.dart';
import 'package:flutter_highlight/themes/atom-one-light.dart';

/// 专用于 Markdown 代码块的高性能代码高亮与一键复制组件
class CodeBlockWidget extends StatefulWidget {
  final String code;
  final String language;
  final bool isDark;

  const CodeBlockWidget({
    super.key,
    required this.code,
    required this.language,
    required this.isDark,
  });

  @override
  State<CodeBlockWidget> createState() => _CodeBlockWidgetState();
}

class _CodeBlockWidgetState extends State<CodeBlockWidget> {
  bool _copied = false;

  void _handleCopy() {
    Clipboard.setData(ClipboardData(text: widget.code));
    setState(() => _copied = true);
    HapticFeedback.lightImpact();
    Future.delayed(const Duration(seconds: 2), () {
      if (mounted) setState(() => _copied = false);
    });
  }

  @override
  Widget build(BuildContext context) {
    final displayLang = widget.language.isEmpty ? "CODE" : widget.language.toUpperCase();
    final headerBg = widget.isDark ? const Color(0xFF1E293B) : const Color(0xFFE2E8F0);
    final bodyBg = widget.isDark ? const Color(0xFF0F172A) : const Color(0xFFF8FAFC);
    final borderColor = widget.isDark ? const Color(0xFF334155) : const Color(0xFFCBD5E1);

    return Container(
      margin: const EdgeInsets.symmetric(vertical: 8),
      decoration: BoxDecoration(
        color: bodyBg,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: borderColor, width: 1),
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // 顶部代码块操作栏
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
            color: headerBg,
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                // 语言标签
                Row(
                  children: [
                    Container(
                      width: 8,
                      height: 8,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: widget.isDark ? Colors.white38 : Colors.black38,
                      ),
                    ),
                    const SizedBox(width: 6),
                    Text(
                      displayLang,
                      style: TextStyle(
                        fontFamily: 'monospace',
                        fontSize: 11,
                        fontWeight: FontWeight.bold,
                        letterSpacing: 0.8,
                        color: widget.isDark ? const Color(0xFF94A3B8) : const Color(0xFF64748B),
                      ),
                    ),
                  ],
                ),
                // 一键复制按钮
                InkWell(
                  onTap: _handleCopy,
                  borderRadius: BorderRadius.circular(6),
                  child: AnimatedContainer(
                    duration: const Duration(milliseconds: 200),
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                    decoration: BoxDecoration(
                      color: _copied
                          ? (widget.isDark ? Colors.greenAccent.withOpacity(0.2) : const Color(0xFFDCFCE7))
                          : (widget.isDark ? Colors.white10 : Colors.black.withOpacity(0.06)),
                      borderRadius: BorderRadius.circular(6),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          _copied ? Icons.check_rounded : Icons.copy_rounded,
                          size: 13,
                          color: _copied
                              ? (widget.isDark ? Colors.greenAccent : Colors.green.shade700)
                              : (widget.isDark ? Colors.white70 : Colors.black54),
                        ),
                        const SizedBox(width: 4),
                        Text(
                          _copied ? "已复制" : "复制",
                          style: TextStyle(
                            fontSize: 11,
                            fontWeight: FontWeight.w600,
                            color: _copied
                                ? (widget.isDark ? Colors.greenAccent : Colors.green.shade700)
                                : (widget.isDark ? Colors.white70 : Colors.black54),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
          // 代码语法高亮展示区域
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: HighlightView(
              widget.code,
              language: widget.language.toLowerCase(),
              theme: widget.isDark ? atomOneDarkTheme : atomOneLightTheme,
              padding: const EdgeInsets.all(12),
              textStyle: const TextStyle(
                fontFamily: 'monospace',
                fontSize: 12.5,
                height: 1.5,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// 自定义 MarkdownElementBuilder，仅劫持代码块并赋予高亮与复制功能
class CodeElementBuilder extends MarkdownElementBuilder {
  final bool isDark;

  CodeElementBuilder({required this.isDark});

  @override
  Widget? visitElementAfter(md.Element element, TextStyle? preferredStyle) {
    final textContent = element.textContent;
    final className = element.attributes['class'] ?? '';
    
    // 如果没有换行且没有明确指定语言 class，判定为行内代码，回退给原生 Markdown 处理
    final isBlock = textContent.contains('\n') || className.startsWith('language-');
    if (!isBlock) {
      return null;
    }

    String language = '';
    if (className.startsWith('language-')) {
      language = className.replaceFirst('language-', '').trim();
    }

    // 清理尾部多余的换行
    final cleanCode = textContent.endsWith('\n')
        ? textContent.substring(0, textContent.length - 1)
        : textContent;

    return CodeBlockWidget(
      code: cleanCode,
      language: language,
      isDark: isDark,
    );
  }
}

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_highlight/flutter_highlight.dart';
import 'package:flutter_highlight/themes/atom-one-dark.dart';
import 'package:flutter_highlight/themes/atom-one-light.dart';
import 'package:flutter_markdown/flutter_markdown.dart';
import 'package:markdown/markdown.dart' as md;

import '../../core/utils/search_highlight_utils.dart';

class CodeBlockWidget extends StatefulWidget {
  final String code;
  final String language;
  final bool isDark;
  final String highlightQuery;
  final bool isFocusedMatch;

  const CodeBlockWidget({
    super.key,
    required this.code,
    required this.language,
    required this.isDark,
    this.highlightQuery = '',
    this.isFocusedMatch = false,
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

  Map<String, TextStyle> _buildSeamlessHighlightTheme() {
    final base = widget.isDark ? atomOneDarkTheme : atomOneLightTheme;
    final rootStyle = base['root'];
    return {
      ...base,
      'root': TextStyle(
        color: rootStyle?.color ?? (widget.isDark ? const Color(0xFFE2E8F0) : const Color(0xFF334155)),
        backgroundColor: Colors.transparent,
      ),
    };
  }

  @override
  Widget build(BuildContext context) {
    final displayLang = widget.language.isEmpty ? 'CODE' : widget.language.toUpperCase();
    final headerBg = widget.isDark ? const Color(0xFF1D1D21) : const Color(0xFFF1F1F3);
    final bodyBg = widget.isDark ? const Color(0xFF141417) : const Color(0xFFF8F8F9);
    final borderColor = widget.isDark ? const Color(0xFF2A2A30) : const Color(0xFFE4E4E7);
    final dividerColor = widget.isDark ? const Color(0xFF26262C) : const Color(0xFFE4E4E7);

    return Container(
      margin: const EdgeInsets.symmetric(vertical: 10),
      decoration: BoxDecoration(
        color: bodyBg,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: borderColor, width: 1),
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
            decoration: BoxDecoration(
              color: headerBg,
              border: Border(bottom: BorderSide(color: dividerColor, width: 1)),
            ),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(
                  displayLang,
                  style: TextStyle(
                    fontFamily: 'monospace',
                    fontSize: 11,
                    fontWeight: FontWeight.w600,
                    letterSpacing: 0.6,
                    color: widget.isDark ? const Color(0xFFA1A1AA) : const Color(0xFF71717A),
                  ),
                ),
                InkWell(
                  onTap: _handleCopy,
                  borderRadius: BorderRadius.circular(6),
                  child: AnimatedContainer(
                    duration: const Duration(milliseconds: 200),
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                    decoration: BoxDecoration(
                      color: _copied
                          ? (widget.isDark
                              ? Colors.greenAccent.withValues(alpha: 0.18)
                              : const Color(0xFFDCFCE7))
                          : (widget.isDark
                              ? Colors.white.withValues(alpha: 0.07)
                              : Colors.black.withValues(alpha: 0.05)),
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
                          _copied ? '已复制' : '复制',
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
          LayoutBuilder(
            builder: (context, constraints) {
              final trimmedQuery = widget.highlightQuery.trim();
              final hasCodeMatch = trimmedQuery.isNotEmpty &&
                  widget.code.toLowerCase().contains(trimmedQuery.toLowerCase());
              const codeTextStyle = TextStyle(
                fontFamily: 'monospace',
                fontFamilyFallback: ['Consolas', 'Fira Code', 'JetBrains Mono', 'Courier New', 'monospace'],
                fontSize: 12.5,
                height: 1.55,
              );
              return SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                physics: const BouncingScrollPhysics(),
                child: ConstrainedBox(
                  constraints: BoxConstraints(minWidth: constraints.maxWidth),
                  child: hasCodeMatch
                      ? Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                          child: SelectableText.rich(
                            buildHighlightedTextSpan(
                              text: widget.code,
                              query: trimmedQuery,
                              baseStyle: codeTextStyle.copyWith(
                                color: widget.isDark
                                    ? const Color(0xFFE2E8F0)
                                    : const Color(0xFF334155),
                              ),
                              isDark: widget.isDark,
                              isFocused: widget.isFocusedMatch,
                            ),
                          ),
                        )
                      : HighlightView(
                          widget.code,
                          language: widget.language.toLowerCase(),
                          theme: _buildSeamlessHighlightTheme(),
                          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                          textStyle: codeTextStyle,
                        ),
                ),
              );
            },
          ),
        ],
      ),
    );
  }
}

class CodeElementBuilder extends MarkdownElementBuilder {
  final bool isDark;
  final String highlightQuery;
  final bool isFocusedMatch;

  CodeElementBuilder({
    required this.isDark,
    this.highlightQuery = '',
    this.isFocusedMatch = false,
  });

  @override
  Widget? visitElementAfter(md.Element element, TextStyle? preferredStyle) {
    final textContent = element.textContent;
    final className = element.attributes['class'] ?? '';
    final isBlock = textContent.contains('\n') || className.startsWith('language-');
    if (!isBlock) {
      final trimmedQuery = highlightQuery.trim();
      if (trimmedQuery.isNotEmpty &&
          textContent.toLowerCase().contains(trimmedQuery.toLowerCase())) {
        final baseStyle = preferredStyle ??
            TextStyle(
              backgroundColor: isDark ? const Color(0xFF222226) : const Color(0xFFF1F1F3),
              color: isDark ? const Color(0xFFF4F4F5) : const Color(0xFF18181B),
              fontFamily: 'monospace',
              fontSize: 13,
            );
        return Text.rich(
          buildHighlightedTextSpan(
            text: textContent,
            query: trimmedQuery,
            baseStyle: baseStyle,
            isDark: isDark,
            isFocused: isFocusedMatch,
          ),
        );
      }
      return null;
    }
    var language = '';
    if (className.startsWith('language-')) {
      language = className.replaceFirst('language-', '').trim();
    }
    final cleanCode =
        textContent.endsWith('\n') ? textContent.substring(0, textContent.length - 1) : textContent;
    return CodeBlockWidget(
      code: cleanCode,
      language: language,
      isDark: isDark,
      highlightQuery: highlightQuery,
      isFocusedMatch: isFocusedMatch,
    );
  }
}

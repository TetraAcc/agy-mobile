import 'package:flutter/material.dart';
import 'package:flutter_markdown/flutter_markdown.dart';

import 'code_block_builder.dart';

class MarkdownMessageBody extends StatelessWidget {
  final String text;
  final bool isDark;
  final String Function(String rawPath) resolveMediaUrl;
  final Map<String, String>? mediaHeaders;
  final void Function(String url) onOpenUrl;
  final void Function(String rawPath) onDownloadPath;
  final void Function(String rawPath)? onOpenMediaExternal;

  const MarkdownMessageBody({
    super.key,
    required this.text,
    required this.isDark,
    required this.resolveMediaUrl,
    this.mediaHeaders,
    required this.onOpenUrl,
    required this.onDownloadPath,
    this.onOpenMediaExternal,
  });

  @override
  Widget build(BuildContext context) {
    final primary = Theme.of(context).colorScheme.primary;
    return MarkdownBody(
      data: text,
      selectable: true,
      builders: {
        'code': CodeElementBuilder(isDark: isDark),
      },
      sizedImageBuilder: (MarkdownImageConfig config) {
        return _buildMarkdownImage(context, config.uri, config.title, config.alt);
      },
      onTapLink: (linkText, href, title) {
        if (href == null || href.isEmpty) return;
        if (href.startsWith('http://') || href.startsWith('https://')) {
          onOpenUrl(href);
        } else {
          onDownloadPath(href);
        }
      },
      styleSheet: MarkdownStyleSheet.fromTheme(Theme.of(context)).copyWith(
        p: TextStyle(
          color: isDark ? const Color(0xFFE2E8F0) : const Color(0xFF1E293B),
          fontSize: 14,
          height: 1.6,
        ),
        h1: TextStyle(
          color: isDark ? Colors.white : Colors.black87,
          fontSize: 18,
          fontWeight: FontWeight.bold,
        ),
        h2: TextStyle(
          color: isDark ? Colors.white : Colors.black87,
          fontSize: 16,
          fontWeight: FontWeight.bold,
        ),
        h3: TextStyle(
          color: primary,
          fontSize: 15,
          fontWeight: FontWeight.bold,
        ),
        strong: TextStyle(
          color: isDark ? Colors.white : Colors.black87,
          fontWeight: FontWeight.bold,
        ),
        em: TextStyle(
          color: isDark ? const Color(0xFF94A3B8) : const Color(0xFF64748B),
          fontStyle: FontStyle.italic,
        ),
        a: TextStyle(
          color: primary,
          decoration: TextDecoration.underline,
        ),
        listBullet: TextStyle(
          color: primary,
          fontSize: 14,
        ),
        blockquote: TextStyle(
          color: isDark ? const Color(0xFFCBD5E1) : const Color(0xFF334155),
          fontSize: 13.5,
          height: 1.6,
        ),
        blockquotePadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        blockquoteDecoration: BoxDecoration(
          color: isDark ? const Color(0xFF161F30) : const Color(0xFFF1F5F9),
          borderRadius: BorderRadius.circular(8),
          border: Border(left: BorderSide(color: primary, width: 3.5)),
        ),
        code: TextStyle(
          backgroundColor: isDark ? const Color(0xFF0B0F19) : const Color(0xFFF1F5F9),
          color: primary,
          fontFamily: 'monospace',
          fontSize: 12,
        ),
      ),
    );
  }

  Widget _buildMarkdownImage(BuildContext context, Uri uri, String? title, String? alt) {
    final rawUriStr = uri.toString();
    final isNetwork = rawUriStr.startsWith('http://') || rawUriStr.startsWith('https://');
    final displayCaption = (title != null && title.isNotEmpty)
        ? title
        : ((alt != null && alt.isNotEmpty) ? alt : '');

    final imageUrl = isNetwork ? rawUriStr : resolveMediaUrl(rawUriStr);
    final headers = isNetwork ? null : mediaHeaders;
    final filename = rawUriStr.split(RegExp(r'[\\/]')).last;

    final imageWidget = Image.network(
      imageUrl,
      headers: headers,
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
            color: isDark ? const Color(0xFF1E293B) : const Color(0xFFF1F5F9),
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: isDark ? Colors.white12 : Colors.black12),
          ),
          child: Row(
            children: [
              Icon(Icons.broken_image_rounded, size: 20, color: isDark ? Colors.white38 : Colors.black38),
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
                        color: isDark ? Colors.white70 : Colors.black87,
                      ),
                      overflow: TextOverflow.ellipsis,
                    ),
                    Text(
                      '未直接加载: $filename',
                      style: TextStyle(
                        fontSize: 10,
                        color: isDark ? Colors.white38 : Colors.black45,
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
                  onPressed: () => onDownloadPath(rawUriStr),
                  icon: const Icon(Icons.download_rounded, size: 14),
                  label: const Text('下载查看', style: TextStyle(fontSize: 11)),
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
            onTap: () => _openImageLightbox(context, imageUrl, headers, displayCaption, rawUriStr, isNetwork),
            child: Container(
              constraints: const BoxConstraints(maxHeight: 450),
              decoration: BoxDecoration(
                color: isDark ? const Color(0xFF0F172A) : const Color(0xFFF8FAFC),
                borderRadius: BorderRadius.circular(10),
                border: Border.all(
                  color: isDark ? const Color(0xFF23324A) : const Color(0xFFE2E8F0),
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
                  color: isDark ? Colors.white54 : Colors.black45,
                  fontStyle: FontStyle.italic,
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }

  void _openImageLightbox(
    BuildContext context,
    String imageUrl,
    Map<String, String>? headers,
    String caption,
    String rawPath,
    bool isNetwork,
  ) {
    showDialog(
      context: context,
      builder: (ctx) {
        return Dialog(
          backgroundColor: Colors.transparent,
          insetPadding: const EdgeInsets.all(12),
          child: Container(
            constraints: BoxConstraints(
              maxWidth: MediaQuery.of(ctx).size.width * 0.95,
              maxHeight: MediaQuery.of(ctx).size.height * 0.85,
            ),
            decoration: BoxDecoration(
              color: isDark ? const Color(0xFF0F172A) : Colors.white,
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: isDark ? const Color(0xFF334155) : const Color(0xFFE2E8F0)),
              boxShadow: const [
                BoxShadow(color: Colors.black54, blurRadius: 24, spreadRadius: 4),
              ],
            ),
            clipBehavior: Clip.antiAlias,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                  color: isDark ? const Color(0xFF1E293B) : const Color(0xFFF8FAFC),
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
                            color: isDark ? Colors.white : Colors.black87,
                          ),
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      IconButton(
                        tooltip: '在新标签页打开原图',
                        icon: const Icon(Icons.open_in_new_rounded, size: 18),
                        onPressed: () {
                          if (isNetwork) {
                            onOpenUrl(imageUrl);
                          } else if (onOpenMediaExternal != null) {
                            onOpenMediaExternal!(rawPath);
                          } else {
                            onDownloadPath(rawPath);
                          }
                        },
                      ),
                      IconButton(
                        tooltip: '关闭',
                        icon: const Icon(Icons.close_rounded, size: 20),
                        onPressed: () => Navigator.of(ctx).pop(),
                      ),
                    ],
                  ),
                ),
                Flexible(
                  child: InteractiveViewer(
                    panEnabled: true,
                    scaleEnabled: true,
                    minScale: 0.8,
                    maxScale: 4.0,
                    child: Center(
                      child: Image.network(
                        imageUrl,
                        headers: headers,
                        fit: BoxFit.contain,
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}

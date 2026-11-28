import 'package:flutter/material.dart';

class PlatformWebEmbedFrame extends StatelessWidget {
  final String? htmlContent;
  final String? url;
  final bool isDark;
  final Color primaryColor;
  final int reloadNonce;
  final VoidCallback? onOpenExternal;
  final VoidCallback? onSwitchToSource;
  final VoidCallback? onDownload;

  const PlatformWebEmbedFrame({
    super.key,
    this.htmlContent,
    this.url,
    required this.isDark,
    required this.primaryColor,
    this.reloadNonce = 0,
    this.onOpenExternal,
    this.onSwitchToSource,
    this.onDownload,
  });

  bool get _isHtml => htmlContent != null;

  @override
  Widget build(BuildContext context) {
    final fg = isDark ? const Color(0xFFE4E4E7) : const Color(0xFF18181B);
    final muted = isDark ? Colors.white60 : Colors.black54;

    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 380),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 48,
                height: 48,
                decoration: BoxDecoration(
                  color: primaryColor.withValues(alpha: isDark ? 0.16 : 0.12),
                  borderRadius: BorderRadius.circular(14),
                ),
                child: Icon(
                  _isHtml ? Icons.web_asset_rounded : Icons.picture_as_pdf_rounded,
                  size: 26,
                  color: primaryColor,
                ),
              ),
              const SizedBox(height: 14),
              Text(
                _isHtml ? '交互式 HTML 预览可在浏览器中打开' : 'PDF 文档请使用系统查看器打开',
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 14.5,
                  fontWeight: FontWeight.w700,
                  color: fg,
                ),
              ),
              const SizedBox(height: 6),
              Text(
                _isHtml
                    ? '当前移动端原生容器直接展示源码，也可一键拉起系统浏览器渲染完整交互页面。'
                    : '点击下方按钮调用外部应用查看，或下载原文件到本地。',
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 12, height: 1.5, color: muted),
              ),
              const SizedBox(height: 16),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                alignment: WrapAlignment.center,
                children: [
                  if (onOpenExternal != null)
                    FilledButton.icon(
                      onPressed: onOpenExternal,
                      icon: const Icon(Icons.open_in_new_rounded, size: 15),
                      label: Text(
                        _isHtml ? '在浏览器中打开' : '打开 PDF',
                        style: const TextStyle(fontSize: 12.5),
                      ),
                    ),
                  if (_isHtml && onSwitchToSource != null)
                    OutlinedButton.icon(
                      onPressed: onSwitchToSource,
                      icon: const Icon(Icons.code_rounded, size: 15),
                      label: const Text('查看源码', style: TextStyle(fontSize: 12.5)),
                    ),
                  if (!_isHtml && onDownload != null)
                    OutlinedButton.icon(
                      onPressed: onDownload,
                      icon: const Icon(Icons.download_rounded, size: 15),
                      label: const Text('下载文件', style: TextStyle(fontSize: 12.5)),
                    ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

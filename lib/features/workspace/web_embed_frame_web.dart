import 'dart:ui_web' as ui_web;

import 'package:flutter/material.dart';
import 'package:web/web.dart' as web;

class PlatformWebEmbedFrame extends StatefulWidget {
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

  @override
  State<PlatformWebEmbedFrame> createState() => _PlatformWebEmbedFrameState();
}

class _PlatformWebEmbedFrameState extends State<PlatformWebEmbedFrame> {
  static int _viewCounter = 0;
  late String _viewType;

  @override
  void initState() {
    super.initState();
    _registerFrame();
  }

  @override
  void didUpdateWidget(covariant PlatformWebEmbedFrame oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.htmlContent != widget.htmlContent ||
        oldWidget.url != widget.url ||
        oldWidget.isDark != widget.isDark ||
        oldWidget.primaryColor != widget.primaryColor ||
        oldWidget.reloadNonce != widget.reloadNonce) {
      _registerFrame();
    }
  }

  static String _hexColor(Color c) {
    final rgb = c.toARGB32() & 0xFFFFFF;
    return '#${rgb.toRadixString(16).padLeft(6, '0')}';
  }

  String _injectThemeVariables(String rawHtml) {
    final isDark = widget.isDark;
    final primaryHex = _hexColor(widget.primaryColor);
    final bg = isDark ? '#111113' : '#ffffff';
    final content = isDark ? '#141418' : '#ffffff';
    final card = isDark ? '#18181b' : '#f8f8f9';
    final sidebar = isDark ? '#111113' : '#f4f4f5';
    final border = isDark ? '#2c2c32' : '#e4e4e7';
    final fg = isDark ? '#f4f4f5' : '#18181b';
    final muted = isDark ? '#a1a1aa' : '#71717a';
    final primaryFg = isDark ? '#111113' : '#ffffff';
    final success = isDark ? '#69f0ae' : '#15803d';
    final warning = isDark ? '#ffd740' : '#b45309';
    final error = isDark ? '#ff5252' : '#dc2626';

    final themeStyle = '''
<style id="agy-host-theme">
:root {
  color-scheme: ${isDark ? 'dark' : 'light'};
  --background: $bg;
  --content: $content;
  --card: $card;
  --sidebar: $sidebar;
  --border: $border;
  --card-border: $border;
  --foreground: $fg;
  --muted-foreground: $muted;
  --primary: $primaryHex;
  --primary-foreground: $primaryFg;
  --success: $success;
  --warning: $warning;
  --error: $error;
}
html, body {
  background-color: var(--background);
  color: var(--foreground);
}
</style>''';

    final headRe = RegExp(r'<head\b[^>]*>', caseSensitive: false);
    final m = headRe.firstMatch(rawHtml);
    if (m != null) {
      return '${rawHtml.substring(0, m.end)}\n$themeStyle\n${rawHtml.substring(m.end)}';
    }
    return '$themeStyle\n$rawHtml';
  }

  void _registerFrame() {
    _viewCounter += 1;
    final nextType = 'agy-embed-$_viewCounter';
    _viewType = nextType;
    final html = widget.htmlContent;
    final srcUrl = widget.url;
    final injected = html != null ? _injectThemeVariables(html) : null;

    ui_web.platformViewRegistry.registerViewFactory(nextType, (int _) {
      final iframe = web.HTMLIFrameElement()
        ..style.border = '0'
        ..style.width = '100%'
        ..style.height = '100%'
        ..style.display = 'block';

      if (injected != null) {
        iframe.setAttribute('sandbox', 'allow-scripts');
        iframe.setAttribute('srcdoc', injected);
      } else if (srcUrl != null && srcUrl.isNotEmpty) {
        iframe.src = srcUrl;
      }
      return iframe;
    });
  }

  @override
  Widget build(BuildContext context) {
    return HtmlElementView(
      key: ValueKey(_viewType),
      viewType: _viewType,
    );
  }
}

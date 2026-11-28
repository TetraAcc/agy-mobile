import 'package:flutter/material.dart';

import 'web_embed_frame_io.dart' if (dart.library.js_interop) 'web_embed_frame_web.dart' as impl;

/// Cross-platform sandboxed HTML (`srcdoc`) or inline PDF (`url`) preview frame.
/// On Web, renders an embedded `<iframe>`; on non-Web platforms renders a clean fallback card.
class WebEmbedFrame extends StatelessWidget {
  final String? htmlContent;
  final String? url;
  final bool isDark;
  final Color primaryColor;
  final int reloadNonce;
  final VoidCallback? onOpenExternal;
  final VoidCallback? onSwitchToSource;
  final VoidCallback? onDownload;

  const WebEmbedFrame.html({
    super.key,
    required String this.htmlContent,
    required this.isDark,
    required this.primaryColor,
    this.reloadNonce = 0,
    this.onOpenExternal,
    this.onSwitchToSource,
  })  : url = null,
        onDownload = null;

  const WebEmbedFrame.url({
    super.key,
    required String this.url,
    required this.isDark,
    this.reloadNonce = 0,
    this.onOpenExternal,
    this.onDownload,
  })  : htmlContent = null,
        primaryColor = const Color(0xFF10B981),
        onSwitchToSource = null;

  @override
  Widget build(BuildContext context) {
    return impl.PlatformWebEmbedFrame(
      htmlContent: htmlContent,
      url: url,
      isDark: isDark,
      primaryColor: primaryColor,
      reloadNonce: reloadNonce,
      onOpenExternal: onOpenExternal,
      onSwitchToSource: onSwitchToSource,
      onDownload: onDownload,
    );
  }
}

import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';

Future<T> runWithDownloadProgressDialog<T>({
  required BuildContext context,
  required bool autoOpen,
  String? titleOverride,
  required Future<T> Function(
    void Function(int received, int total) onProgress,
    CancelToken cancelToken,
  ) task,
  required String Function(int bytes) formatBytes,
}) async {
  final progress = ValueNotifier<(int, int)>((0, 0));
  final cancelToken = CancelToken();
  var finished = false;
  var dialogPopped = false;
  BuildContext? dialogCtx;
  Future<void>? dialogFuture;

  void dismissDialogIfMounted() {
    if (dialogPopped) return;
    final ctx = dialogCtx;
    if (ctx != null && ctx.mounted) {
      dialogPopped = true;
      Navigator.of(ctx).pop();
    }
  }

  void cancelDownload() {
    if (!cancelToken.isCancelled) {
      cancelToken.cancel('user_cancelled');
    }
    dismissDialogIfMounted();
  }

  if (context.mounted) {
    dialogFuture = showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) {
        dialogCtx = ctx;
        if (finished || dialogPopped) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            dismissDialogIfMounted();
          });
          return const SizedBox.shrink();
        }
        final isDark = Theme.of(ctx).brightness == Brightness.dark;
        return PopScope(
          canPop: false,
          onPopInvokedWithResult: (didPop, _) {
            if (!didPop) {
              cancelDownload();
            }
          },
          child: AlertDialog(
            backgroundColor: isDark ? const Color(0xFF18181B) : Colors.white,
            content: ValueListenableBuilder<(int, int)>(
              valueListenable: progress,
              builder: (_, val, __) {
                final (received, total) = val;
                final double? pct =
                    total > 0 ? (received / total).clamp(0.0, 1.0) : null;
                final subtitle = total > 0
                    ? '${(pct! * 100).toStringAsFixed(0)}%  (${formatBytes(received)} / ${formatBytes(total)})'
                    : (received > 0 ? '已下载 ${formatBytes(received)}...' : '正在建立安全下载连接...');
                return Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      titleOverride ?? (autoOpen ? '正在获取文件预览...' : '正在下载文件...'),
                      style: TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                        color: isDark ? Colors.white : Colors.black87,
                      ),
                    ),
                    const SizedBox(height: 12),
                    LinearProgressIndicator(value: pct),
                    const SizedBox(height: 8),
                    Text(
                      subtitle,
                      style: TextStyle(
                        fontSize: 12,
                        color: isDark ? Colors.white60 : Colors.black54,
                      ),
                    ),
                  ],
                );
              },
            ),
            actions: [
              TextButton(
                onPressed: cancelDownload,
                child: const Text('取消'),
              ),
            ],
          ),
        );
      },
    );
    unawaited(dialogFuture.whenComplete(progress.dispose));
  }

  try {
    return await task(
      (rec, tot) {
        if (!finished && !cancelToken.isCancelled) {
          progress.value = (rec, tot);
        }
      },
      cancelToken,
    );
  } finally {
    finished = true;
    dismissDialogIfMounted();
    if (dialogFuture == null) {
      progress.dispose();
    } else {
      await dialogFuture.timeout(
        const Duration(milliseconds: 500),
        onTimeout: () {},
      );
    }
  }
}

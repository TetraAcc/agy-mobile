import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/utils/file_utils.dart';
import '../../models/models.dart';

class WorkspaceFilePickerDialog extends StatelessWidget {
  final List<FileRootItem> roots;
  final String activeRootId;
  final String rootName;
  final String currentSubPath;
  final List<FileItem> files;
  final bool isLoading;
  final String? errorMessage;
  final String? statusMessage;
  final bool statusIsError;
  final bool statusIsBusy;
  final VoidCallback? onDismissStatus;
  final bool isDark;
  final ValueChanged<String> onSelectRoot;
  final ValueChanged<String> onNavigate;
  final ValueChanged<String> onDownload;
  final ValueChanged<String> onReadFile;
  final ValueChanged<String>? onPreviewPdf;
  final ValueChanged<String>? onPreviewImage;
  final ValueChanged<String>? onPreviewMedia;
  final ValueChanged<String> onInsertRef;

  const WorkspaceFilePickerDialog({
    super.key,
    required this.roots,
    required this.activeRootId,
    required this.rootName,
    required this.currentSubPath,
    required this.files,
    required this.isLoading,
    this.errorMessage,
    this.statusMessage,
    this.statusIsError = false,
    this.statusIsBusy = false,
    this.onDismissStatus,
    required this.isDark,
    required this.onSelectRoot,
    required this.onNavigate,
    required this.onDownload,
    required this.onReadFile,
    this.onPreviewPdf,
    this.onPreviewImage,
    this.onPreviewMedia,
    required this.onInsertRef,
  });

  Widget _buildStatusBanner(BuildContext context) {
    final Color accent = statusIsError
        ? Colors.redAccent
        : (statusIsBusy ? Theme.of(context).colorScheme.primary : const Color(0xFF10B981));
    final Color bg = accent.withValues(alpha: isDark ? 0.16 : 0.10);

    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: accent.withValues(alpha: 0.45)),
      ),
      child: Row(
        children: [
          if (statusIsBusy)
            SizedBox(
              width: 14,
              height: 14,
              child: CircularProgressIndicator(strokeWidth: 2, color: accent),
            )
          else
            Icon(
              statusIsError ? Icons.error_outline_rounded : Icons.check_circle_outline_rounded,
              size: 16,
              color: accent,
            ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              statusMessage ?? '',
              style: TextStyle(
                fontSize: 12,
                color: isDark ? Colors.white : Colors.black87,
              ),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          if (!statusIsBusy && onDismissStatus != null)
            InkWell(
              onTap: onDismissStatus,
              borderRadius: BorderRadius.circular(12),
              child: Padding(
                padding: const EdgeInsets.all(2),
                child: Icon(
                  Icons.close_rounded,
                  size: 15,
                  color: isDark ? Colors.white54 : Colors.black45,
                ),
              ),
            ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      height: MediaQuery.of(context).size.height * 0.78,
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Expanded(
                child: Row(
                  children: [
                    Icon(
                      Icons.folder_special_rounded,
                      color: Theme.of(context).colorScheme.primary,
                      size: 20,
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        currentSubPath.isEmpty ? '工作区: $rootName' : '$rootName/$currentSubPath',
                        style: TextStyle(
                          fontWeight: FontWeight.bold,
                          fontSize: 14,
                          color: isDark ? Colors.white : Colors.black87,
                        ),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ],
                ),
              ),
              IconButton(
                icon: Icon(Icons.close, color: isDark ? Colors.white54 : Colors.black54, size: 20),
                onPressed: () => Navigator.pop(context),
              ),
            ],
          ),
          if (roots.length > 1) ...[
            const SizedBox(height: 6),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 10),
              decoration: BoxDecoration(
                color: isDark ? const Color(0xFF111113) : const Color(0xFFF4F4F5),
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: isDark ? Colors.white12 : Colors.black12),
              ),
              child: DropdownButtonHideUnderline(
                child: DropdownButton<String>(
                  value: roots.any((r) => r.id == activeRootId) ? activeRootId : roots.first.id,
                  isExpanded: true,
                  isDense: true,
                  dropdownColor: isDark ? const Color(0xFF222226) : Colors.white,
                  items: roots
                      .map(
                        (r) => DropdownMenuItem<String>(
                          value: r.id,
                          child: Text(
                            '${r.name} (${r.id})',
                            style: TextStyle(
                              fontSize: 12,
                              color: isDark ? Colors.white70 : Colors.black87,
                            ),
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                      )
                      .toList(),
                  onChanged: (val) {
                    if (val != null && val != activeRootId) {
                      onSelectRoot(val);
                    }
                  },
                ),
              ),
            ),
          ],
          Divider(color: isDark ? Colors.white12 : Colors.black12),
          if (statusMessage != null && statusMessage!.isNotEmpty) _buildStatusBanner(context),
          if (currentSubPath.isNotEmpty)
            InkWell(
              onTap: () {
                final parts = currentSubPath.split('/');
                parts.removeLast();
                onNavigate(parts.join('/'));
              },
              child: Container(
                padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 10),
                margin: const EdgeInsets.only(bottom: 6),
                decoration: BoxDecoration(
                  color: isDark
                      ? Colors.white.withValues(alpha: 0.04)
                      : Colors.black.withValues(alpha: 0.04),
                  borderRadius: BorderRadius.circular(6),
                ),
                child: Row(
                  children: [
                    Icon(
                      Icons.arrow_upward_rounded,
                      size: 16,
                      color: Theme.of(context).colorScheme.primary,
                    ),
                    const SizedBox(width: 8),
                    Text(
                      '返回上一层目录 (..)',
                      style: TextStyle(color: Theme.of(context).colorScheme.primary, fontSize: 12),
                    ),
                  ],
                ),
              ),
            ),
          Expanded(
            child: isLoading
                ? const Center(child: CircularProgressIndicator())
                : (errorMessage != null && errorMessage!.isNotEmpty)
                    ? Center(
                        child: Text(
                          errorMessage!,
                          style: const TextStyle(color: Colors.redAccent, fontSize: 13),
                          textAlign: TextAlign.center,
                        ),
                      )
                    : files.isEmpty
                        ? Center(
                            child: Column(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Icon(
                                  Icons.folder_open_rounded,
                                  size: 40,
                                  color: isDark ? Colors.white24 : Colors.black26,
                                ),
                                const SizedBox(height: 8),
                                Text(
                                  '当前目录为空',
                                  style: TextStyle(
                                    color: isDark ? Colors.white38 : Colors.black45,
                                    fontSize: 13,
                                  ),
                                ),
                              ],
                            ),
                          )
                        : ListView.builder(
                            itemCount: files.length,
                            itemBuilder: (c, idx) {
                              final item = files[idx];
                              final isPdf = FileUtils.isPdfFile(item.path);
                              final isImg = FileUtils.isImageFile(item.path);
                              final isMedia = FileUtils.isMediaStreamFile(item.path);
                              final isOffice = FileUtils.isOfficePreviewableFile(item.path);
                              final isBin = FileUtils.isBinaryFile(item.path);

                              VoidCallback? previewAction;
                              String previewTooltip = '查看内容';
                              IconData previewIcon = Icons.visibility_outlined;
                              if (isPdf && onPreviewPdf != null) {
                                previewAction = () => onPreviewPdf!(item.path);
                                previewTooltip = '在线预览 PDF';
                              } else if (isImg && onPreviewImage != null) {
                                previewAction = () => onPreviewImage!(item.path);
                                previewTooltip = '预览图片';
                              } else if (isMedia && (onPreviewMedia != null || onPreviewPdf != null)) {
                                final mediaCb = onPreviewMedia ?? onPreviewPdf!;
                                previewAction = () => mediaCb(item.path);
                                previewTooltip = '播放音视频';
                                previewIcon = Icons.play_circle_outline_rounded;
                              } else if (isOffice || !isBin) {
                                previewAction = () => onReadFile(item.path);
                                previewTooltip = isOffice ? '预览文档内容' : '查看内容';
                              }

                              return ListTile(
                                dense: true,
                                visualDensity: const VisualDensity(vertical: -2),
                                leading: Icon(
                                  FileUtils.getFileIconData(item.name, item.isDir),
                                  color: FileUtils.getFileIconColor(item.name, item.isDir, context),
                                  size: 18,
                                ),
                                title: Text(
                                  item.name,
                                  style: TextStyle(
                                    color: isDark
                                        ? (item.isDir ? Colors.white : const Color(0xFFE4E4E7))
                                        : (item.isDir ? Colors.black87 : Colors.black54),
                                    fontSize: 13,
                                    fontWeight: item.isDir ? FontWeight.bold : FontWeight.normal,
                                  ),
                                ),
                                trailing: item.isDir
                                    ? Icon(
                                        Icons.chevron_right,
                                        size: 16,
                                        color: isDark ? Colors.white24 : Colors.black26,
                                      )
                                    : Row(
                                        mainAxisSize: MainAxisSize.min,
                                        children: [
                                          IconButton(
                                            icon: const Icon(Icons.download_rounded, size: 18),
                                            tooltip: '下载到本地',
                                            color: Colors.greenAccent.shade400,
                                            onPressed: () => onDownload(item.path),
                                          ),
                                          if (previewAction != null)
                                            IconButton(
                                              icon: Icon(previewIcon, size: 18),
                                              tooltip: previewTooltip,
                                              color: Theme.of(context).colorScheme.primary,
                                              onPressed: previewAction,
                                            ),
                                          IconButton(
                                            icon: const Icon(Icons.add_comment_outlined, size: 18),
                                            tooltip: '引用到输入框',
                                            color: isDark ? Colors.white54 : Colors.black45,
                                            onPressed: () {
                                              Navigator.pop(context);
                                              onInsertRef('@file:${item.path} ');
                                              HapticFeedback.lightImpact();
                                            },
                                          ),
                                        ],
                                      ),
                                onTap: () {
                                  if (item.isDir) {
                                    onNavigate(item.path);
                                  } else if (previewAction != null) {
                                    previewAction();
                                  } else {
                                    onDownload(item.path);
                                  }
                                },
                              );
                            },
                          ),
          ),
        ],
      ),
    );
  }
}

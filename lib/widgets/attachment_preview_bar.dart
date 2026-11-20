import 'package:flutter/material.dart';
import '../models/models.dart';
import '../constants/app_colors.dart';

class AttachmentPreviewBar extends StatelessWidget {
  final List<UploadedAttachment> attachments;
  final ValueChanged<int> onRemove;
  final bool isDark;

  const AttachmentPreviewBar({
    super.key,
    required this.attachments,
    required this.onRemove,
    required this.isDark,
  });

  @override
  Widget build(BuildContext context) {
    if (attachments.isEmpty) return const SizedBox.shrink();

    return Container(
      margin: const EdgeInsets.only(bottom: 6),
      height: 48,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        itemCount: attachments.length,
        separatorBuilder: (_, __) => const SizedBox(width: 8),
        itemBuilder: (ctx, idx) {
          final att = attachments[idx];
          return Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
            decoration: BoxDecoration(
              color: isDark ? AppColors.darkCard : AppColors.lightBg,
              borderRadius: BorderRadius.circular(10),
              border: Border.all(
                color: att.isUploading
                    ? Colors.orangeAccent.withOpacity(0.6)
                    : Theme.of(context).colorScheme.primary.withOpacity(0.5),
              ),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (att.isImage && att.imageBytes != null)
                  ClipRRect(
                    borderRadius: BorderRadius.circular(6),
                    child: Image.memory(att.imageBytes!, width: 36, height: 36, fit: BoxFit.cover),
                  )
                else
                  Icon(
                    att.isImage ? Icons.image_rounded : Icons.insert_drive_file_rounded,
                    size: 24,
                    color: Theme.of(context).colorScheme.primary,
                  ),
                const SizedBox(width: 8),
                Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 130),
                      child: Text(
                        att.filename,
                        style: TextStyle(
                          fontSize: 11,
                          fontWeight: FontWeight.bold,
                          color: isDark ? Colors.white : Colors.black87,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    Text(
                      att.isUploading
                          ? "正在上传..."
                          : (att.size > 0 ? "${(att.size / 1024).toStringAsFixed(1)} KB · 就绪" : "已就绪"),
                      style: TextStyle(
                        fontSize: 9,
                        color: att.isUploading ? Colors.orangeAccent : Colors.greenAccent,
                      ),
                    ),
                  ],
                ),
                const SizedBox(width: 4),
                InkWell(
                  onTap: () => onRemove(idx),
                  child: Padding(
                    padding: const EdgeInsets.all(4),
                    child: Icon(Icons.close_rounded, size: 16, color: isDark ? Colors.white54 : Colors.black45),
                  ),
                ),
              ],
            ),
          );
        },
      ),
    );
  }
}

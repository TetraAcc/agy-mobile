import 'package:flutter/material.dart';

import '../../core/utils/file_utils.dart';
import '../../models/models.dart';

class SessionChangesBar extends StatefulWidget {
  final SessionChangesData changes;
  final int pendingCommentCount;
  final bool isDark;
  final VoidCallback onOpenReview;
  final ValueChanged<SessionFileChange> onOpenFile;

  const SessionChangesBar({
    super.key,
    required this.changes,
    this.pendingCommentCount = 0,
    required this.isDark,
    required this.onOpenReview,
    required this.onOpenFile,
  });

  @override
  State<SessionChangesBar> createState() => _SessionChangesBarState();
}

class _SessionChangesBarState extends State<SessionChangesBar> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    final changes = widget.changes;
    if (changes.totalFiles <= 0 || changes.files.isEmpty) {
      return const SizedBox.shrink();
    }

    final isDark = widget.isDark;
    final primary = Theme.of(context).colorScheme.primary;
    final borderColor = isDark ? const Color(0xFF2C2C32) : const Color(0xFFE4E4E7);
    final bgColor = isDark ? const Color(0xFF111113) : const Color(0xFFF8F8F9);
    final fileNoun = changes.totalFiles == 1 ? 'file changed' : 'files changed';

    return Container(
      margin: const EdgeInsets.only(bottom: 6),
      decoration: BoxDecoration(
        color: bgColor,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: borderColor),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          InkWell(
            onTap: () => setState(() => _expanded = !_expanded),
            borderRadius: BorderRadius.vertical(
              top: const Radius.circular(10),
              bottom: Radius.circular(_expanded ? 0 : 10),
            ),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
              child: Row(
                children: [
                  Text(
                    '${changes.totalFiles} $fileNoun',
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                      color: isDark ? Colors.white70 : Colors.black87,
                    ),
                  ),
                  const SizedBox(width: 8),
                  Text(
                    '+${changes.totalAdded}',
                    style: const TextStyle(
                      fontSize: 12,
                      fontFamily: 'monospace',
                      fontWeight: FontWeight.bold,
                      color: Color(0xFF4ADE80),
                    ),
                  ),
                  const SizedBox(width: 4),
                  Text(
                    '-${changes.totalRemoved}',
                    style: const TextStyle(
                      fontSize: 12,
                      fontFamily: 'monospace',
                      fontWeight: FontWeight.bold,
                      color: Color(0xFFF87171),
                    ),
                  ),
                  const SizedBox(width: 4),
                  Icon(
                    _expanded ? Icons.keyboard_arrow_up_rounded : Icons.keyboard_arrow_down_rounded,
                    size: 16,
                    color: isDark ? Colors.white54 : Colors.black45,
                  ),
                  const Spacer(),
                  OutlinedButton.icon(
                    onPressed: widget.onOpenReview,
                    style: OutlinedButton.styleFrom(
                      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                      minimumSize: Size.zero,
                      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                      side: BorderSide(
                        color: widget.pendingCommentCount > 0 ? primary : borderColor,
                      ),
                      backgroundColor: widget.pendingCommentCount > 0
                          ? primary.withValues(alpha: 0.14)
                          : (isDark ? const Color(0xFF18181B) : Colors.white),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(6)),
                    ),
                    icon: Icon(
                      Icons.rate_review_outlined,
                      size: 14,
                      color: widget.pendingCommentCount > 0
                          ? primary
                          : (isDark ? Colors.white70 : Colors.black87),
                    ),
                    label: Text(
                      widget.pendingCommentCount > 0 ? '评审 (${widget.pendingCommentCount})' : '评审',
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                        color: widget.pendingCommentCount > 0
                            ? primary
                            : (isDark ? Colors.white : Colors.black87),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
          if (_expanded) ...[
            Divider(height: 1, color: borderColor),
            ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 175),
              child: ListView.builder(
                shrinkWrap: true,
                padding: const EdgeInsets.symmetric(vertical: 4),
                itemCount: changes.files.length,
                itemBuilder: (ctx, idx) {
                  final f = changes.files[idx];
                  return InkWell(
                    onTap: () => widget.onOpenFile(f),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                      child: Row(
                        children: [
                          Icon(
                            FileUtils.getFileIconData(f.fileName, false),
                            size: 15,
                            color: FileUtils.getFileIconColor(f.fileName, false, context),
                          ),
                          const SizedBox(width: 8),
                          Text(
                            f.fileName,
                            style: TextStyle(
                              fontSize: 12.5,
                              fontWeight: FontWeight.w600,
                              color: isDark ? Colors.white : Colors.black87,
                            ),
                          ),
                          if (f.directory.isNotEmpty) ...[
                            const SizedBox(width: 6),
                            Expanded(
                              child: Text(
                                f.directory,
                                style: TextStyle(
                                  fontSize: 11,
                                  fontFamily: 'monospace',
                                  color: isDark ? Colors.white38 : Colors.black38,
                                ),
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                          ] else
                            const Spacer(),
                          const SizedBox(width: 8),
                          Text(
                            '+${f.addedLines}',
                            style: const TextStyle(
                              fontSize: 11.5,
                              fontFamily: 'monospace',
                              fontWeight: FontWeight.bold,
                              color: Color(0xFF4ADE80),
                            ),
                          ),
                          const SizedBox(width: 4),
                          Text(
                            '-${f.removedLines}',
                            style: const TextStyle(
                              fontSize: 11.5,
                              fontFamily: 'monospace',
                              fontWeight: FontWeight.bold,
                              color: Color(0xFFF87171),
                            ),
                          ),
                        ],
                      ),
                    ),
                  );
                },
              ),
            ),
          ],
        ],
      ),
    );
  }
}

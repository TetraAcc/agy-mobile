import 'package:flutter/material.dart';

/// Git 变更 Diff 弹窗审查组件
class GitDiffViewerSheet extends StatelessWidget {
  final String workspace;
  final String status;
  final String diff;

  const GitDiffViewerSheet({
    super.key,
    required this.workspace,
    required this.status,
    required this.diff,
  });

  static void show(BuildContext context, {required String workspace, required String status, required String diff}) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: isDark ? const Color(0xFF0F172A) : Colors.white,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (ctx) => GitDiffViewerSheet(
        workspace: workspace,
        status: status,
        diff: diff,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final diffLines = diff.isEmpty ? <String>[] : diff.split('\n');
    final statusLines = status.isEmpty ? <String>[] : status.split('\n');

    return Container(
      height: MediaQuery.of(context).size.height * 0.88,
      padding: const EdgeInsets.all(14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Row(
                children: [
                  const Icon(Icons.difference_rounded, color: Color(0xFF38BDF8), size: 22),
                  const SizedBox(width: 8),
                  Text(
                    "Git 变更审查 (Diff)",
                    style: TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.bold,
                      color: isDark ? Colors.white : Colors.black87,
                    ),
                  ),
                ],
              ),
              IconButton(
                icon: const Icon(Icons.close_rounded, size: 20),
                onPressed: () => Navigator.pop(context),
              ),
            ],
          ),
          Text(
            "工作区: ${workspace.split(RegExp(r'[\\/]')).last}",
            style: TextStyle(
              fontSize: 11,
              color: isDark ? Colors.white38 : Colors.black38,
              fontFamily: 'monospace',
            ),
          ),
          const SizedBox(height: 10),

          if (statusLines.isNotEmpty && status.trim().isNotEmpty) ...[
            Wrap(
              spacing: 6,
              runSpacing: 6,
              children: statusLines.map((s) {
                final isModified = s.contains('M');
                final isAdded = s.contains('A') || s.contains('?');
                final isDeleted = s.contains('D');
                final color = isModified
                    ? const Color(0xFFF59E0B)
                    : (isAdded ? const Color(0xFF10B981) : (isDeleted ? const Color(0xFFEF4444) : Colors.blueGrey));
                return Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                  decoration: BoxDecoration(
                    color: color.withOpacity(0.15),
                    borderRadius: BorderRadius.circular(6),
                    border: Border.all(color: color.withOpacity(0.3)),
                  ),
                  child: Text(
                    s.trim(),
                    style: TextStyle(
                      fontSize: 11,
                      fontFamily: 'monospace',
                      color: color,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                );
              }).toList(),
            ),
            const SizedBox(height: 10),
          ],

          Expanded(
            child: diff.trim().isEmpty
                ? Center(
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        const Icon(Icons.check_circle_outline_rounded, color: Colors.greenAccent, size: 48),
                        const SizedBox(height: 12),
                        Text(
                          "工作区干净 (Clean)",
                          style: TextStyle(
                            color: isDark ? Colors.white70 : Colors.black87,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          "当前没有未提交的代码修改",
                          style: TextStyle(
                            color: isDark ? Colors.white38 : Colors.black38,
                            fontSize: 12,
                          ),
                        ),
                      ],
                    ),
                  )
                : Container(
                    decoration: BoxDecoration(
                      color: isDark ? const Color(0xFF090D16) : const Color(0xFFF8FAFC),
                      borderRadius: BorderRadius.circular(10),
                      border: Border.all(
                        color: isDark ? const Color(0xFF23324A) : const Color(0xFFE2E8F0),
                      ),
                    ),
                    child: SingleChildScrollView(
                      scrollDirection: Axis.horizontal,
                      child: SingleChildScrollView(
                        padding: const EdgeInsets.all(8),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: diffLines.map((line) {
                            Color? bgColor;
                            Color textColor = isDark ? const Color(0xFFE2E8F0) : const Color(0xFF1E293B);
                            FontWeight fontWeight = FontWeight.normal;

                            if (line.startsWith('+') && !line.startsWith('+++')) {
                              bgColor = const Color(0x2822C55E);
                              textColor = const Color(0xFF4ADE80);
                            } else if (line.startsWith('-') && !line.startsWith('---')) {
                              bgColor = const Color(0x28EF4444);
                              textColor = const Color(0xFFF87171);
                            } else if (line.startsWith('@@')) {
                              bgColor = const Color(0x1F38BDF8);
                              textColor = const Color(0xFF38BDF8);
                              fontWeight = FontWeight.bold;
                            } else if (line.startsWith('diff --git')) {
                              textColor = Theme.of(context).colorScheme.primary;
                              fontWeight = FontWeight.bold;
                            }

                            return Container(
                              color: bgColor,
                              padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
                              child: Text(
                                line,
                                style: TextStyle(
                                  fontFamily: 'monospace',
                                  fontSize: 11.5,
                                  color: textColor,
                                  fontWeight: fontWeight,
                                  height: 1.4,
                                ),
                              ),
                            );
                          }).toList(),
                        ),
                      ),
                    ),
                  ),
          ),
        ],
      ),
    );
  }
}

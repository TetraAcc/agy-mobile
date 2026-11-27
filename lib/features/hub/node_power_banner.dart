import 'package:flutter/material.dart';

import '../../core/theme/app_colors.dart';
import '../../models/host_node.dart';

/// Top status bar displayed while a node has auto-shutdown or auto-sleep armed.
class NodePowerBanner extends StatelessWidget {
  final String nodeName;
  final NodePowerStatus status;
  final bool isDark;
  final bool isUpdating;
  final double maxContentWidth;
  final VoidCallback onCancel;

  const NodePowerBanner({
    super.key,
    required this.nodeName,
    required this.status,
    required this.isDark,
    required this.isUpdating,
    required this.maxContentWidth,
    required this.onCancel,
  });

  String _summaryText() {
    final target = nodeName.isNotEmpty ? nodeName : '当前节点';
    final act = status.actionLabel;
    if (status.isCountdown) {
      return '$target 已空闲，将在 ${status.remainingSeconds}s 后自动$act';
    }
    if (status.isSettling) {
      return '$target 任务已清空，防抖确认中 (${status.remainingSeconds}s 后进入$act倒计时)';
    }
    if (status.isWaitingForActivity) {
      return '已预约：$target 在下轮任务全部完成后自动$act';
    }
    final parts = <String>[];
    if (status.runningSessions > 0) parts.add('${status.runningSessions} 个运行中');
    if (status.pendingApprovals > 0) parts.add('${status.pendingApprovals} 个待审批');
    if (status.queuedMessages > 0) parts.add('${status.queuedMessages} 条排队');
    final detail = parts.isNotEmpty ? '（${parts.join('、')}）' : '';
    return '已预约：$target 全部任务完成后自动$act$detail';
  }

  @override
  Widget build(BuildContext context) {
    final urgent = status.isCountdown || status.isSettling || status.isExecuting;
    final accent = urgent ? AppColors.statusRed(isDark) : AppColors.statusAmber(isDark);
    final bg = accent.withValues(alpha: isDark ? 0.14 : 0.08);
    final border = accent.withValues(alpha: 0.40);

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
      decoration: BoxDecoration(
        color: bg,
        border: Border(bottom: BorderSide(color: border)),
      ),
      child: Center(
        child: ConstrainedBox(
          constraints: BoxConstraints(maxWidth: maxContentWidth),
          child: Row(
            children: [
              Icon(
                status.action == 'sleep'
                    ? Icons.bedtime_rounded
                    : Icons.power_settings_new_rounded,
                size: 16,
                color: accent,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  _summaryText(),
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                    color: isDark ? Colors.white : Colors.black87,
                  ),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              const SizedBox(width: 8),
              OutlinedButton(
                onPressed: isUpdating ? null : onCancel,
                style: OutlinedButton.styleFrom(
                  foregroundColor: accent,
                  side: BorderSide(color: accent.withValues(alpha: 0.65)),
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                  minimumSize: Size.zero,
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                ),
                child: isUpdating
                    ? SizedBox(
                        width: 12,
                        height: 12,
                        child: CircularProgressIndicator(strokeWidth: 1.8, color: accent),
                      )
                    : const Text(
                        '取消',
                        style: TextStyle(fontSize: 11.5, fontWeight: FontWeight.w700),
                      ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

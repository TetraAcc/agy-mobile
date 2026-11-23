import 'package:flutter/material.dart';

import '../../core/theme/app_colors.dart';
import '../../models/models.dart';

class SessionStepsBar extends StatefulWidget {
  final List<PlanStepItem> steps;
  final bool isDark;

  const SessionStepsBar({
    super.key,
    required this.steps,
    required this.isDark,
  });

  @override
  State<SessionStepsBar> createState() => _SessionStepsBarState();
}

class _SessionStepsBarState extends State<SessionStepsBar> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    if (widget.steps.isEmpty) return const SizedBox.shrink();

    final primary = Theme.of(context).colorScheme.primary;
    final doneCount = widget.steps.where((s) => s.status == 'done').length;
    final activeStep = widget.steps.firstWhere(
      (s) => s.status == 'in_progress',
      orElse: () => widget.steps.firstWhere(
        (s) => s.status == 'failed',
        orElse: () => widget.steps.last,
      ),
    );

    return Container(
      width: double.infinity,
      decoration: BoxDecoration(
        color: widget.isDark ? const Color(0xFF18181B) : const Color(0xFFF8F8F9),
        border: Border(
          bottom: BorderSide(
            color: widget.isDark ? const Color(0xFF222226) : const Color(0xFFE4E4E7),
          ),
        ),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          InkWell(
            onTap: () => setState(() => _expanded = !_expanded),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
              child: Row(
                children: [
                  Icon(Icons.checklist_rounded, size: 15, color: primary),
                  const SizedBox(width: 6),
                  Text(
                    '任务进度 $doneCount/${widget.steps.length}',
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                      color: widget.isDark ? Colors.white : Colors.black87,
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      activeStep.title,
                      style: TextStyle(
                        fontSize: 11.5,
                        color: widget.isDark ? Colors.white60 : Colors.black54,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  Icon(
                    _expanded ? Icons.expand_less_rounded : Icons.expand_more_rounded,
                    size: 18,
                    color: widget.isDark ? Colors.white54 : Colors.black45,
                  ),
                ],
              ),
            ),
          ),
          if (_expanded)
            ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 200),
              child: ListView.separated(
                shrinkWrap: true,
                padding: const EdgeInsets.fromLTRB(14, 2, 14, 10),
                itemCount: widget.steps.length,
                separatorBuilder: (_, __) => const SizedBox(height: 5),
                itemBuilder: (_, idx) => _buildStepRow(widget.steps[idx], primary),
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildStepRow(PlanStepItem step, Color primary) {
    final (IconData icon, Color iconColor) = switch (step.status) {
      'done' => (Icons.check_circle_rounded, AppColors.statusGreen(widget.isDark)),
      'in_progress' => (Icons.play_circle_filled_rounded, primary),
      'failed' => (Icons.cancel_rounded, AppColors.statusRed(widget.isDark)),
      'skipped' => (Icons.remove_circle_outline_rounded, widget.isDark ? Colors.white38 : Colors.black38),
      _ => (Icons.radio_button_unchecked_rounded, widget.isDark ? Colors.white38 : Colors.black38),
    };

    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(top: 1.5),
          child: Icon(icon, size: 14, color: iconColor),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            step.title,
            style: TextStyle(
              fontSize: 12,
              height: 1.35,
              decoration: step.status == 'skipped' ? TextDecoration.lineThrough : null,
              color: step.status == 'done'
                  ? (widget.isDark ? Colors.white70 : Colors.black54)
                  : (widget.isDark ? Colors.white : Colors.black87),
              fontWeight: step.status == 'in_progress' ? FontWeight.w600 : FontWeight.normal,
            ),
          ),
        ),
      ],
    );
  }
}

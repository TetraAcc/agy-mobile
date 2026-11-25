import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/config/quick_commands_prefs.dart';
import '../../core/config/responsive_layout.dart';

class QuickCommandsSheet extends ConsumerWidget {
  final bool isDark;
  final ValueChanged<String> onFillPrompt;
  final Future<String?> Function(String prompt) onSendPrompt;

  const QuickCommandsSheet({
    super.key,
    required this.isDark,
    required this.onFillPrompt,
    required this.onSendPrompt,
  });

  static void show(
    BuildContext context, {
    required bool isDark,
    required ValueChanged<String> onFillPrompt,
    required Future<String?> Function(String prompt) onSendPrompt,
  }) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      constraints: ResponsiveLayout.compactSheetConstraints(context),
      backgroundColor: isDark ? const Color(0xFF18181B) : Colors.white,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(18)),
      ),
      builder: (_) => QuickCommandsSheet(
        isDark: isDark,
        onFillPrompt: onFillPrompt,
        onSendPrompt: onSendPrompt,
      ),
    );
  }

  Future<void> _showEditorDialog(
    BuildContext context,
    WidgetRef ref, {
    QuickCommandItem? existing,
  }) async {
    final result = await showDialog<({String title, String prompt})>(
      context: context,
      builder: (_) => _QuickCommandEditorDialog(
        existing: existing,
        isDark: isDark,
      ),
    );

    if (result != null && result.title.isNotEmpty && result.prompt.isNotEmpty) {
      final notifier = ref.read(quickCommandsProvider.notifier);
      if (existing == null) {
        await notifier.addCommand(title: result.title, prompt: result.prompt);
      } else {
        await notifier.updateCommand(existing.id, title: result.title, prompt: result.prompt);
      }
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final commands = ref.watch(quickCommandsProvider);
    final notifier = ref.read(quickCommandsProvider.notifier);
    final primary = Theme.of(context).colorScheme.primary;
    final muted = isDark ? Colors.white54 : Colors.black54;

    return SafeArea(
      child: ConstrainedBox(
        constraints: BoxConstraints(maxHeight: MediaQuery.of(context).size.height * 0.78),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 14, 16, 16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(Icons.bolt_rounded, size: 19, color: primary),
                  const SizedBox(width: 6),
                  Text(
                    '快捷指令',
                    style: TextStyle(
                      fontSize: 15.5,
                      fontWeight: FontWeight.bold,
                      color: isDark ? Colors.white : Colors.black87,
                    ),
                  ),
                  const Spacer(),
                  TextButton.icon(
                    onPressed: () => notifier.resetDefaults(),
                    icon: Icon(Icons.restart_alt_rounded, size: 15, color: muted),
                    label: Text('恢复默认', style: TextStyle(fontSize: 12, color: muted)),
                    style: TextButton.styleFrom(visualDensity: VisualDensity.compact),
                  ),
                  const SizedBox(width: 4),
                  FilledButton.tonalIcon(
                    onPressed: () => _showEditorDialog(context, ref),
                    icon: const Icon(Icons.add_rounded, size: 16),
                    label: const Text('新增', style: TextStyle(fontSize: 12)),
                    style: FilledButton.styleFrom(visualDensity: VisualDensity.compact),
                  ),
                ],
              ),
              const SizedBox(height: 4),
              Text(
                '点按指令条目可填入输入框微调；点击右侧闪电发送按钮可直接送出。',
                style: TextStyle(fontSize: 11.5, color: muted),
              ),
              const SizedBox(height: 10),
              Flexible(
                child: commands.isEmpty
                    ? Center(
                        child: Padding(
                          padding: const EdgeInsets.symmetric(vertical: 28),
                          child: Text(
                            '暂无快捷指令，点击右上角「新增」创建。',
                            style: TextStyle(fontSize: 13, color: muted),
                          ),
                        ),
                      )
                    : ListView.separated(
                        shrinkWrap: true,
                        itemCount: commands.length,
                        separatorBuilder: (_, __) => const SizedBox(height: 8),
                        itemBuilder: (ctx, idx) {
                          final item = commands[idx];
                          return Container(
                            decoration: BoxDecoration(
                              color: isDark ? const Color(0xFF202026) : const Color(0xFFF6F7F9),
                              borderRadius: BorderRadius.circular(12),
                              border: Border.all(
                                color: isDark ? Colors.white10 : Colors.black12,
                              ),
                            ),
                            child: InkWell(
                              borderRadius: BorderRadius.circular(12),
                              onTap: () {
                                Navigator.pop(context);
                                onFillPrompt(item.prompt);
                              },
                              child: Padding(
                                padding: const EdgeInsets.fromLTRB(12, 10, 6, 10),
                                child: Row(
                                  children: [
                                    Expanded(
                                      child: Column(
                                        crossAxisAlignment: CrossAxisAlignment.start,
                                        children: [
                                          Text(
                                            item.title,
                                            style: TextStyle(
                                              fontSize: 13.5,
                                              fontWeight: FontWeight.w600,
                                              color: isDark ? Colors.white : Colors.black87,
                                            ),
                                          ),
                                          const SizedBox(height: 3),
                                          Text(
                                            item.prompt,
                                            maxLines: 2,
                                            overflow: TextOverflow.ellipsis,
                                            style: TextStyle(fontSize: 11.5, color: muted, height: 1.35),
                                          ),
                                        ],
                                      ),
                                    ),
                                    const SizedBox(width: 4),
                                    IconButton(
                                      tooltip: '直接发送',
                                      visualDensity: VisualDensity.compact,
                                      icon: Icon(Icons.send_rounded, size: 17, color: primary),
                                      onPressed: () async {
                                        final messenger = ScaffoldMessenger.maybeOf(context);
                                        Navigator.pop(context);
                                        final err = await onSendPrompt(item.prompt);
                                        if (err != null) {
                                          messenger?.showSnackBar(
                                            SnackBar(
                                              content: Text(err),
                                              backgroundColor: Colors.redAccent.shade700,
                                            ),
                                          );
                                        }
                                      },
                                    ),
                                    IconButton(
                                      tooltip: '编辑',
                                      visualDensity: VisualDensity.compact,
                                      icon: Icon(Icons.edit_outlined, size: 17, color: muted),
                                      onPressed: () => _showEditorDialog(context, ref, existing: item),
                                    ),
                                    IconButton(
                                      tooltip: '删除',
                                      visualDensity: VisualDensity.compact,
                                      icon: Icon(Icons.delete_outline_rounded, size: 17, color: muted),
                                      onPressed: () => notifier.deleteCommand(item.id),
                                    ),
                                  ],
                                ),
                              ),
                            ),
                          );
                        },
                      ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _QuickCommandEditorDialog extends StatefulWidget {
  final QuickCommandItem? existing;
  final bool isDark;

  const _QuickCommandEditorDialog({
    required this.existing,
    required this.isDark,
  });

  @override
  State<_QuickCommandEditorDialog> createState() => _QuickCommandEditorDialogState();
}

class _QuickCommandEditorDialogState extends State<_QuickCommandEditorDialog> {
  late final TextEditingController _titleCtrl;
  late final TextEditingController _promptCtrl;

  @override
  void initState() {
    super.initState();
    _titleCtrl = TextEditingController(text: widget.existing?.title ?? '');
    _promptCtrl = TextEditingController(text: widget.existing?.prompt ?? '');
  }

  @override
  void dispose() {
    _titleCtrl.dispose();
    _promptCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final isDark = widget.isDark;
    final primary = Theme.of(context).colorScheme.primary;
    return AlertDialog(
      backgroundColor: isDark ? const Color(0xFF222226) : Colors.white,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      title: Text(
        widget.existing == null ? '新增快捷指令' : '编辑快捷指令',
        style: TextStyle(
          fontSize: 16,
          fontWeight: FontWeight.bold,
          color: isDark ? Colors.white : Colors.black87,
        ),
      ),
      content: SizedBox(
        width: 360,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: _titleCtrl,
              autofocus: true,
              style: TextStyle(fontSize: 13.5, color: isDark ? Colors.white : Colors.black87),
              decoration: InputDecoration(
                labelText: '简称',
                hintText: '例如：跑全量测试',
                filled: true,
                fillColor: isDark ? const Color(0xFF141418) : const Color(0xFFF5F5F7),
                border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _promptCtrl,
              minLines: 2,
              maxLines: 5,
              style: TextStyle(fontSize: 13, color: isDark ? Colors.white : Colors.black87),
              decoration: InputDecoration(
                labelText: '完整指令内容',
                hintText: '输入要填入或发送给 Agent 的常用指令',
                filled: true,
                fillColor: isDark ? const Color(0xFF141418) : const Color(0xFFF5F5F7),
                border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('取消'),
        ),
        ElevatedButton(
          onPressed: () {
            final title = _titleCtrl.text.trim();
            final prompt = _promptCtrl.text.trim();
            if (title.isEmpty || prompt.isEmpty) return;
            Navigator.pop(context, (title: title, prompt: prompt));
          },
          style: ElevatedButton.styleFrom(
            backgroundColor: primary,
            foregroundColor: isDark ? const Color(0xFF111113) : Colors.white,
          ),
          child: const Text('保存'),
        ),
      ],
    );
  }
}

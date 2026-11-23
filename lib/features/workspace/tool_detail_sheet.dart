import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/config/responsive_layout.dart';
import '../../models/models.dart';

class ToolDetailSheet extends StatefulWidget {
  final int stepIndex;
  final ToolCallItem initialTool;
  final bool isDark;
  final Future<ToolCallOutputData> Function(int stepIndex) onLoadOutput;

  const ToolDetailSheet({
    super.key,
    required this.stepIndex,
    required this.initialTool,
    required this.isDark,
    required this.onLoadOutput,
  });

  static Future<void> show(
    BuildContext context, {
    required int stepIndex,
    required ToolCallItem initialTool,
    required bool isDark,
    required Future<ToolCallOutputData> Function(int stepIndex) onLoadOutput,
  }) {
    return showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      constraints: ResponsiveLayout.workspaceSheetConstraints(context),
      backgroundColor: isDark ? const Color(0xFF111113) : Colors.white,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (_) => ToolDetailSheet(
        stepIndex: stepIndex,
        initialTool: initialTool,
        isDark: isDark,
        onLoadOutput: onLoadOutput,
      ),
    );
  }

  @override
  State<ToolDetailSheet> createState() => _ToolDetailSheetState();
}

class _ToolDetailSheetState extends State<ToolDetailSheet> {
  ToolCallOutputData? _data;
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final res = await widget.onLoadOutput(widget.stepIndex);
      if (!mounted) return;
      setState(() {
        _data = res;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = '$e';
        _loading = false;
      });
    }
  }

  ToolCallItem get _displayTool {
    final loaded = _data?.toolCalls ?? const [];
    for (final t in loaded) {
      if (t.name == widget.initialTool.name) {
        return t;
      }
    }
    return loaded.isNotEmpty ? loaded.first : widget.initialTool;
  }

  void _copy(String text, String tip) {
    Clipboard.setData(ClipboardData(text: text));
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(tip), duration: const Duration(seconds: 1)),
    );
  }

  @override
  Widget build(BuildContext context) {
    final isDark = widget.isDark;
    final tool = _displayTool;
    final cmdText = (tool.args['CommandLine'] ?? tool.args['commandLine'] ?? '').toString();
    final outputText = _data?.output ?? '';
    final statusText = _data?.status ?? '';

    return SafeArea(
      child: SizedBox(
        height: MediaQuery.of(context).size.height * 0.85,
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(
                    tool.name == 'run_command' ? Icons.terminal_rounded : Icons.build_circle_outlined,
                    size: 20,
                    color: Theme.of(context).colorScheme.primary,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          tool.name,
                          style: TextStyle(
                            fontSize: 15,
                            fontWeight: FontWeight.bold,
                            color: isDark ? Colors.white : Colors.black87,
                          ),
                          overflow: TextOverflow.ellipsis,
                        ),
                        Text(
                          'Step #${widget.stepIndex}${statusText.isNotEmpty ? ' · $statusText' : ''}',
                          style: TextStyle(fontSize: 11, color: isDark ? Colors.white54 : Colors.black45),
                        ),
                      ],
                    ),
                  ),
                  IconButton(
                    icon: const Icon(Icons.refresh_rounded, size: 18),
                    tooltip: '重新加载',
                    onPressed: _load,
                  ),
                  IconButton(
                    icon: const Icon(Icons.close_rounded, size: 20),
                    onPressed: () => Navigator.pop(context),
                  ),
                ],
              ),
              const SizedBox(height: 10),
              if (cmdText.isNotEmpty) ...[
                _sectionHeader(
                  '执行命令',
                  onCopy: () => _copy(cmdText, '已复制命令'),
                ),
                Container(
                  width: double.infinity,
                  margin: const EdgeInsets.only(bottom: 10),
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: isDark ? const Color(0xFF090D16) : const Color(0xFFF4F4F5),
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: isDark ? const Color(0xFF2C2C32) : const Color(0xFFCBD5E1)),
                  ),
                  child: SelectableText(
                    cmdText,
                    style: TextStyle(
                      fontFamily: 'monospace',
                      fontSize: 12,
                      color: isDark ? const Color(0xFF38BDF8) : const Color(0xFF0369A1),
                    ),
                  ),
                ),
              ] else if (tool.args.isNotEmpty) ...[
                _sectionHeader('调用参数'),
                Container(
                  width: double.infinity,
                  constraints: const BoxConstraints(maxHeight: 140),
                  margin: const EdgeInsets.only(bottom: 10),
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: isDark ? const Color(0xFF090D16) : const Color(0xFFF4F4F5),
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: isDark ? const Color(0xFF2C2C32) : const Color(0xFFCBD5E1)),
                  ),
                  child: SingleChildScrollView(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: tool.args.entries.map((e) {
                        return Padding(
                          padding: const EdgeInsets.only(bottom: 4),
                          child: SelectableText(
                            '${e.key}: ${e.value}',
                            style: TextStyle(
                              fontFamily: 'monospace',
                              fontSize: 11.5,
                              color: isDark ? Colors.white70 : Colors.black87,
                            ),
                          ),
                        );
                      }).toList(),
                    ),
                  ),
                ),
              ],
              _sectionHeader(
                _data?.truncated == true ? '工具输出（已截断）' : '工具输出',
                onCopy: outputText.isEmpty ? null : () => _copy(outputText, '已复制工具输出'),
              ),
              Expanded(
                child: Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: isDark ? const Color(0xFF090D16) : const Color(0xFFF8F8F9),
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(color: isDark ? const Color(0xFF2C2C32) : const Color(0xFFE4E4E7)),
                  ),
                  child: _loading
                      ? const Center(child: CircularProgressIndicator())
                      : _error != null
                          ? Center(
                              child: Text(
                                '加载失败: $_error',
                                style: TextStyle(color: Colors.redAccent.shade200, fontSize: 12),
                              ),
                            )
                          : outputText.trim().isEmpty
                              ? Center(
                                  child: Text(
                                    '该步骤暂无可展示的工具输出',
                                    style: TextStyle(
                                      color: isDark ? Colors.white38 : Colors.black38,
                                      fontSize: 12,
                                    ),
                                  ),
                                )
                              : SingleChildScrollView(
                                  child: SelectableText(
                                    outputText,
                                    style: TextStyle(
                                      fontFamily: 'monospace',
                                      fontSize: 11.5,
                                      height: 1.45,
                                      color: isDark ? const Color(0xFFE4E4E7) : const Color(0xFF222226),
                                    ),
                                  ),
                                ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _sectionHeader(String title, {VoidCallback? onCopy}) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Row(
        children: [
          Text(
            title,
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w600,
              color: widget.isDark ? Colors.white70 : Colors.black54,
            ),
          ),
          const Spacer(),
          if (onCopy != null)
            TextButton.icon(
              onPressed: onCopy,
              icon: const Icon(Icons.copy_rounded, size: 13),
              label: const Text('复制', style: TextStyle(fontSize: 11)),
              style: TextButton.styleFrom(
                visualDensity: VisualDensity.compact,
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
              ),
            ),
        ],
      ),
    );
  }
}

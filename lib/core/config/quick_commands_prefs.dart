import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

class QuickCommandItem {
  final String id;
  final String title;
  final String prompt;

  const QuickCommandItem({
    required this.id,
    required this.title,
    required this.prompt,
  });

  factory QuickCommandItem.fromJson(Map<String, dynamic> json) {
    return QuickCommandItem(
      id: json['id']?.toString() ?? '',
      title: json['title']?.toString() ?? '',
      prompt: json['prompt']?.toString() ?? '',
    );
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'title': title,
        'prompt': prompt,
      };

  QuickCommandItem copyWith({
    String? id,
    String? title,
    String? prompt,
  }) {
    return QuickCommandItem(
      id: id ?? this.id,
      title: title ?? this.title,
      prompt: prompt ?? this.prompt,
    );
  }
}

const List<QuickCommandItem> defaultQuickCommands = [
  QuickCommandItem(
    id: 'preset_diagnose',
    title: '先排查原因',
    prompt: '先结合日志和源码排查具体原因并告诉我结论，暂不修改代码。',
  ),
  QuickCommandItem(
    id: 'preset_test',
    title: '跑全量测试',
    prompt: '请运行全量静态检查与自动化测试，确认全部通过并汇报结果。',
  ),
  QuickCommandItem(
    id: 'preset_local_only',
    title: '先改本地别推送',
    prompt: '请先在本地完成修改并验证测试，暂时不要提交或推送，我再测试一下。',
  ),
  QuickCommandItem(
    id: 'preset_review_fix',
    title: '按批注修改',
    prompt: '请根据我刚才给出的 Diff 批注逐条修改并验证。',
  ),
  QuickCommandItem(
    id: 'preset_summary',
    title: '总结本次改动',
    prompt: '请简要总结本次修改涉及的文件、核心逻辑与测试验证情况。',
  ),
  QuickCommandItem(
    id: 'preset_commit_push',
    title: '提交并推送',
    prompt: '确认无误后，请提交代码并推送更新。',
  ),
];

class QuickCommandsController extends Notifier<List<QuickCommandItem>> {
  static const _prefKey = 'v2_quick_commands_v1';

  @override
  List<QuickCommandItem> build() {
    _load();
    return defaultQuickCommands;
  }

  Future<void> _load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_prefKey);
      if (raw == null || raw.trim().isEmpty) return;
      final decoded = jsonDecode(raw);
      if (decoded is! List) return;
      final parsed = decoded
          .whereType<Map>()
          .map((e) => QuickCommandItem.fromJson(Map<String, dynamic>.from(e)))
          .where((e) => e.id.isNotEmpty && e.title.trim().isNotEmpty && e.prompt.trim().isNotEmpty)
          .toList();
      if (parsed.isNotEmpty) {
        state = parsed;
      }
    } catch (_) {}
  }

  Future<void> _save(List<QuickCommandItem> items) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(
        _prefKey,
        jsonEncode(items.map((e) => e.toJson()).toList()),
      );
    } catch (_) {}
  }

  Future<void> addCommand({required String title, required String prompt}) async {
    final cleanTitle = title.trim();
    final cleanPrompt = prompt.trim();
    if (cleanTitle.isEmpty || cleanPrompt.isEmpty) return;
    final id = 'qc_${DateTime.now().microsecondsSinceEpoch}';
    final next = [
      QuickCommandItem(id: id, title: cleanTitle, prompt: cleanPrompt),
      ...state,
    ];
    state = next;
    await _save(next);
  }

  Future<void> updateCommand(String id, {required String title, required String prompt}) async {
    final cleanTitle = title.trim();
    final cleanPrompt = prompt.trim();
    if (cleanTitle.isEmpty || cleanPrompt.isEmpty) return;
    final next = state
        .map((e) => e.id == id ? e.copyWith(title: cleanTitle, prompt: cleanPrompt) : e)
        .toList();
    state = next;
    await _save(next);
  }

  Future<void> deleteCommand(String id) async {
    final next = state.where((e) => e.id != id).toList();
    state = next;
    await _save(next);
  }

  Future<void> resetDefaults() async {
    state = List<QuickCommandItem>.from(defaultQuickCommands);
    await _save(state);
  }
}

final quickCommandsProvider = NotifierProvider<QuickCommandsController, List<QuickCommandItem>>(
  QuickCommandsController.new,
);

import 'agent_message.dart';

class PlanStepItem {
  final String title;
  final String status;

  const PlanStepItem({
    required this.title,
    required this.status,
  });

  factory PlanStepItem.fromJson(Map<String, dynamic> json) {
    return PlanStepItem(
      title: json['title']?.toString() ?? '',
      status: json['status']?.toString() ?? 'pending',
    );
  }

  static List<PlanStepItem> extractLatestSteps(List<AgentMessage> messages) {
    for (var i = messages.length - 1; i >= 0; i--) {
      final tcs = messages[i].toolCalls;
      for (var j = tcs.length - 1; j >= 0; j--) {
        if (tcs[j].name == 'update_steps') {
          final raw = tcs[j].args['steps'];
          if (raw is List) {
            return raw
                .whereType<Map>()
                .map((e) => PlanStepItem.fromJson(Map<String, dynamic>.from(e)))
                .where((item) => item.title.trim().isNotEmpty)
                .toList();
          }
        }
      }
    }
    return const [];
  }

  static String extractLatestFocus(List<AgentMessage> messages) {
    for (var i = messages.length - 1; i >= 0; i--) {
      final msg = messages[i];
      if (msg.isUser) {
        return '';
      }
      for (var j = msg.toolCalls.length - 1; j >= 0; j--) {
        if (msg.toolCalls[j].name == 'update_focus') {
          final focus = msg.toolCalls[j].args['focus']?.toString().trim() ?? '';
          if (focus.isNotEmpty) {
            return focus;
          }
        }
      }
    }
    return '';
  }
}

class AskQuestionItem {
  final String question;
  final List<String> options;
  final bool isMultiSelect;

  const AskQuestionItem({
    required this.question,
    required this.options,
    this.isMultiSelect = false,
  });

  factory AskQuestionItem.fromJson(Map<String, dynamic> json) {
    final rawOpts = json['options'] as List<dynamic>? ?? const [];
    return AskQuestionItem(
      question: json['question']?.toString() ?? '',
      options: rawOpts
          .map((e) => e.toString().trim())
          .where((e) => e.isNotEmpty)
          .toList(),
      isMultiSelect: json['is_multi_select'] == true,
    );
  }

  static List<AskQuestionItem> parseFromTool(ToolCallItem tool) {
    if (tool.name != 'ask_question') return const [];
    final raw = tool.args['questions'];
    if (raw is! List) return const [];
    return raw
        .whereType<Map>()
        .map((e) => AskQuestionItem.fromJson(Map<String, dynamic>.from(e)))
        .where((q) => q.question.trim().isNotEmpty)
        .toList();
  }
}

class ToolCallOutputData {
  final String sessionId;
  final int stepIndex;
  final List<ToolCallItem> toolCalls;
  final int? resultStepIndex;
  final String status;
  final String output;
  final bool truncated;

  const ToolCallOutputData({
    required this.sessionId,
    required this.stepIndex,
    this.toolCalls = const [],
    this.resultStepIndex,
    this.status = '',
    this.output = '',
    this.truncated = false,
  });

  factory ToolCallOutputData.fromJson(Map<String, dynamic> json) {
    final rawTools = json['tool_calls'] as List<dynamic>? ?? const [];
    return ToolCallOutputData(
      sessionId: json['session_id']?.toString() ?? '',
      stepIndex: (json['step_index'] as num?)?.toInt() ?? 0,
      toolCalls: rawTools
          .whereType<Map>()
          .map((e) => ToolCallItem.fromJson(Map<String, dynamic>.from(e)))
          .toList(),
      resultStepIndex: (json['result_step_index'] as num?)?.toInt(),
      status: json['status']?.toString() ?? '',
      output: json['output']?.toString() ?? '',
      truncated: json['truncated'] == true,
    );
  }
}

class SessionArtifactItem {
  final String name;
  final String relPath;
  final String rootId;
  final int size;
  final double updatedAt;
  final bool isImage;
  final bool isMarkdown;

  const SessionArtifactItem({
    required this.name,
    required this.relPath,
    this.rootId = 'brain',
    this.size = 0,
    this.updatedAt = 0.0,
    this.isImage = false,
    this.isMarkdown = false,
  });

  factory SessionArtifactItem.fromJson(Map<String, dynamic> json) {
    return SessionArtifactItem(
      name: json['name']?.toString() ?? '',
      relPath: json['rel_path']?.toString() ?? '',
      rootId: json['root_id']?.toString() ?? 'brain',
      size: (json['size'] as num?)?.toInt() ?? 0,
      updatedAt: (json['updated_at'] as num?)?.toDouble() ?? 0.0,
      isImage: json['is_image'] == true,
      isMarkdown: json['is_markdown'] == true,
    );
  }
}

class FileSaveResult {
  final bool ok;
  final String rootId;
  final String path;
  final String name;
  final int size;
  final int totalLines;
  final double mtime;

  const FileSaveResult({
    this.ok = true,
    required this.rootId,
    required this.path,
    required this.name,
    required this.size,
    required this.totalLines,
    required this.mtime,
  });

  factory FileSaveResult.fromJson(Map<String, dynamic> json) {
    return FileSaveResult(
      ok: json['ok'] != false,
      rootId: json['root_id']?.toString() ?? '',
      path: json['path']?.toString() ?? '',
      name: json['name']?.toString() ?? '',
      size: (json['size'] as num?)?.toInt() ?? 0,
      totalLines: (json['total_lines'] as num?)?.toInt() ?? 0,
      mtime: (json['mtime'] as num?)?.toDouble() ?? 0.0,
    );
  }
}

class QueuedMessageItem {
  final String id;
  final String content;
  final String? model;
  final double createdAt;

  const QueuedMessageItem({
    required this.id,
    required this.content,
    this.model,
    this.createdAt = 0.0,
  });

  factory QueuedMessageItem.fromJson(Map<String, dynamic> json) {
    return QueuedMessageItem(
      id: json['id']?.toString() ?? '',
      content: json['content']?.toString() ?? '',
      model: json['model']?.toString(),
      createdAt: (json['created_at'] as num?)?.toDouble() ?? 0.0,
    );
  }
}

class SessionQueueData {
  final String sessionId;
  final bool paused;
  final String lastError;
  final List<QueuedMessageItem> items;

  const SessionQueueData({
    this.sessionId = '',
    this.paused = false,
    this.lastError = '',
    this.items = const [],
  });

  factory SessionQueueData.fromJson(Map<String, dynamic> json) {
    final raw = json['items'] as List<dynamic>? ?? const [];
    return SessionQueueData(
      sessionId: json['session_id']?.toString() ?? '',
      paused: json['paused'] == true,
      lastError: json['last_error']?.toString() ?? '',
      items: raw
          .whereType<Map>()
          .map((e) => QueuedMessageItem.fromJson(Map<String, dynamic>.from(e)))
          .toList(),
    );
  }
}

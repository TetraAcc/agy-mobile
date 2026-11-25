import 'dart:convert';

class ToolCallItem {
  final String name;
  final Map<String, dynamic> args;

  const ToolCallItem({
    required this.name,
    this.args = const {},
  });

  factory ToolCallItem.fromJson(Map<String, dynamic> json) {
    final rawArgs = json['args'] ?? json['arguments'];
    Map<String, dynamic> parsedArgs = const {};
    if (rawArgs is Map<String, dynamic>) {
      parsedArgs = rawArgs;
    } else if (rawArgs is Map) {
      parsedArgs = Map<String, dynamic>.from(rawArgs);
    } else if (rawArgs is String) {
      try {
        final decoded = jsonDecode(rawArgs);
        if (decoded is Map) {
          parsedArgs = Map<String, dynamic>.from(decoded);
        }
      } catch (_) {}
    }
    return ToolCallItem(
      name: json['name']?.toString() ?? 'tool',
      args: parsedArgs,
    );
  }

  Map<String, dynamic> toJson({int maxArgValueChars = 400}) {
    final compactArgs = <String, dynamic>{};
    args.forEach((key, value) {
      if (value is String && value.length > maxArgValueChars) {
        compactArgs[key] = '${value.substring(0, maxArgValueChars)}...';
      } else if (value is String || value is num || value is bool || value == null) {
        compactArgs[key] = value;
      } else {
        try {
          final encoded = jsonEncode(value);
          if (encoded.length <= maxArgValueChars) {
            compactArgs[key] = value;
          }
        } catch (_) {}
      }
    });
    return {
      'name': name,
      if (compactArgs.isNotEmpty) 'args': compactArgs,
    };
  }
}

class AgentMessage {
  final int stepIndex;
  final String source;
  final String msgType;
  final String status;
  final String content;
  final String thinking;
  final List<ToolCallItem> toolCalls;
  final String timestamp;
  final String model;

  const AgentMessage({
    required this.stepIndex,
    required this.source,
    required this.msgType,
    required this.status,
    required this.content,
    required this.thinking,
    required this.toolCalls,
    required this.timestamp,
    this.model = '',
  });

  bool get isUser => source == 'USER_EXPLICIT' || msgType == 'USER_INPUT';
  bool get isPureToolStep => content.isEmpty && thinking.isEmpty && toolCalls.isNotEmpty;

  String get messageKey => '${stepIndex}_${timestamp}_${content.length}';

  factory AgentMessage.fromJson(Map<String, dynamic> json) {
    String rawContent = json['content']?.toString() ?? '';
    if (rawContent.contains('<USER_REQUEST>')) {
      final reg = RegExp(r'<USER_REQUEST>\s*(.*?)\s*</USER_REQUEST>', dotAll: true);
      final match = reg.firstMatch(rawContent);
      if (match != null) {
        rawContent = match.group(1)?.trim() ?? rawContent;
      }
    }
    rawContent = rawContent
        .replaceAll(RegExp(r'<ADDITIONAL_METADATA>.*?</ADDITIONAL_METADATA>', dotAll: true), '')
        .trim();
    rawContent = rawContent
        .replaceAll(RegExp(r'<SYSTEM_MESSAGE>.*?</SYSTEM_MESSAGE>', dotAll: true), '')
        .trim();

    final rawTools = json['tool_calls'] as List<dynamic>? ?? const [];
    final parsedTools = rawTools
        .whereType<Map>()
        .map((e) => ToolCallItem.fromJson(Map<String, dynamic>.from(e)))
        .toList();

    return AgentMessage(
      stepIndex: (json['step_index'] as num?)?.toInt() ?? 0,
      source: json['source']?.toString() ?? 'AGENT',
      msgType: json['msg_type']?.toString() ?? 'UNKNOWN',
      status: json['status']?.toString() ?? '',
      content: rawContent,
      thinking: json['thinking']?.toString() ?? '',
      toolCalls: parsedTools,
      timestamp: json['timestamp']?.toString() ?? '',
      model: json['model']?.toString() ?? '',
    );
  }

  Map<String, dynamic> toJson({
    int maxContentChars = 12000,
    int maxThinkingChars = 2500,
  }) {
    final trimmedContent = content.length > maxContentChars
        ? '${content.substring(0, maxContentChars)}\n...(缓存预览已截断)'
        : content;
    final trimmedThinking = thinking.length > maxThinkingChars
        ? '${thinking.substring(0, maxThinkingChars)}...'
        : thinking;
    return {
      'step_index': stepIndex,
      'source': source,
      'msg_type': msgType,
      'status': status,
      'content': trimmedContent,
      if (trimmedThinking.isNotEmpty) 'thinking': trimmedThinking,
      if (toolCalls.isNotEmpty) 'tool_calls': toolCalls.map((t) => t.toJson()).toList(),
      if (timestamp.isNotEmpty) 'timestamp': timestamp,
      if (model.isNotEmpty) 'model': model,
    };
  }
}

class SessionMessagesPage {
  final String sessionId;
  final List<AgentMessage> messages;
  final bool hasMore;
  final int? nextBeforeStep;
  final bool isRunning;
  final String activeModel;

  const SessionMessagesPage({
    required this.sessionId,
    required this.messages,
    this.hasMore = false,
    this.nextBeforeStep,
    this.isRunning = false,
    this.activeModel = '',
  });

  factory SessionMessagesPage.fromJson(Map<String, dynamic> json) {
    final rawMsgs = json['messages'] as List<dynamic>? ?? const [];
    return SessionMessagesPage(
      sessionId: json['session_id']?.toString() ?? '',
      messages: rawMsgs
          .whereType<Map>()
          .map((e) => AgentMessage.fromJson(Map<String, dynamic>.from(e)))
          .toList(),
      hasMore: json['has_more'] == true,
      nextBeforeStep: (json['next_before_step'] as num?)?.toInt(),
      isRunning: json['is_running'] == true,
      activeModel: json['active_model']?.toString() ?? '',
    );
  }
}

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

  const AgentMessage({
    required this.stepIndex,
    required this.source,
    required this.msgType,
    required this.status,
    required this.content,
    required this.thinking,
    required this.toolCalls,
    required this.timestamp,
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
    );
  }
}

class SessionMessagesPage {
  final String sessionId;
  final List<AgentMessage> messages;
  final bool hasMore;
  final int? nextBeforeStep;
  final bool isRunning;

  const SessionMessagesPage({
    required this.sessionId,
    required this.messages,
    this.hasMore = false,
    this.nextBeforeStep,
    this.isRunning = false,
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
    );
  }
}

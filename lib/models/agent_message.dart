class AgentMessage {
  final int stepIndex;
  final String source;
  final String msgType;
  final String status;
  final String content;
  final String thinking;
  final List<dynamic> toolCalls;
  final String timestamp;

  AgentMessage({
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

  factory AgentMessage.fromJson(Map<String, dynamic> json) {
    String rawContent = json['content'] ?? '';
    if (rawContent.contains('<USER_REQUEST>')) {
      final reg = RegExp(r'<USER_REQUEST>\s*(.*?)\s*</USER_REQUEST>', dotAll: true);
      final match = reg.firstMatch(rawContent);
      if (match != null) {
        rawContent = match.group(1)?.trim() ?? rawContent;
      }
    }
    rawContent = rawContent.replaceAll(RegExp(r'<ADDITIONAL_METADATA>.*?</ADDITIONAL_METADATA>', dotAll: true), '').trim();
    rawContent = rawContent.replaceAll(RegExp(r'<SYSTEM_MESSAGE>.*?</SYSTEM_MESSAGE>', dotAll: true), '').trim();

    return AgentMessage(
      stepIndex: json['step_index'] ?? 0,
      source: json['source'] ?? 'AGENT',
      msgType: json['msg_type'] ?? 'UNKNOWN',
      status: json['status'] ?? '',
      content: rawContent,
      thinking: json['thinking'] ?? '',
      toolCalls: json['tool_calls'] ?? [],
      timestamp: json['timestamp'] ?? '',
    );
  }
}

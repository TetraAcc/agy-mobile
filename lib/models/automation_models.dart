class AutomationRunEvent {
  final String eventId;
  final int timestampMs;
  final int startedAtMs;
  final bool ok;
  final String error;
  final String conversationId;

  const AutomationRunEvent({
    required this.eventId,
    this.timestampMs = 0,
    this.startedAtMs = 0,
    this.ok = true,
    this.error = '',
    this.conversationId = '',
  });

  factory AutomationRunEvent.fromJson(Map<String, dynamic> json) {
    return AutomationRunEvent(
      eventId: json['event_id']?.toString() ?? '',
      timestampMs: (json['timestamp_ms'] as num?)?.toInt() ?? 0,
      startedAtMs: (json['started_at_ms'] as num?)?.toInt() ?? 0,
      ok: json['ok'] != false,
      error: json['error']?.toString() ?? '',
      conversationId: json['conversation_id']?.toString() ?? '',
    );
  }
}

class AutomationItem {
  final String id;
  final String displayName;
  final String description;
  final bool enabled;
  final String cronExpr;
  final String timezone;
  final String scheduleRaw;
  final String prompt;
  final String workspacePath;
  final List<String> workspaceUris;
  final List<String> accessGrants;
  final String nextRunText;
  final int lastRunAtMs;
  final bool? lastRunOk;
  final String lastRunError;
  final int eventCount;
  final List<AutomationRunEvent> recentEvents;

  const AutomationItem({
    required this.id,
    required this.displayName,
    this.description = '',
    this.enabled = false,
    this.cronExpr = '',
    this.timezone = '',
    this.scheduleRaw = '',
    this.prompt = '',
    this.workspacePath = '',
    this.workspaceUris = const [],
    this.accessGrants = const [],
    this.nextRunText = '',
    this.lastRunAtMs = 0,
    this.lastRunOk,
    this.lastRunError = '',
    this.eventCount = 0,
    this.recentEvents = const [],
  });

  factory AutomationItem.fromJson(Map<String, dynamic> json) {
    final rawEvents = json['recent_events'] as List<dynamic>? ?? const [];
    return AutomationItem(
      id: json['id']?.toString() ?? '',
      displayName: json['display_name']?.toString() ?? json['id']?.toString() ?? '未命名自动化',
      description: json['description']?.toString() ?? '',
      enabled: json['enabled'] == true,
      cronExpr: json['cron_expr']?.toString() ?? '',
      timezone: json['timezone']?.toString() ?? '',
      scheduleRaw: json['schedule_raw']?.toString() ?? '',
      prompt: json['prompt']?.toString() ?? '',
      workspacePath: json['workspace_path']?.toString() ?? '',
      workspaceUris: (json['workspace_uris'] as List<dynamic>? ?? const [])
          .map((e) => e.toString())
          .toList(),
      accessGrants: (json['access_grants'] as List<dynamic>? ?? const [])
          .map((e) => e.toString())
          .toList(),
      nextRunText: json['next_run_text']?.toString() ?? '',
      lastRunAtMs: (json['last_run_at_ms'] as num?)?.toInt() ?? 0,
      lastRunOk: json['last_run_ok'] is bool ? json['last_run_ok'] as bool : null,
      lastRunError: json['last_run_error']?.toString() ?? '',
      eventCount: (json['event_count'] as num?)?.toInt() ?? 0,
      recentEvents: rawEvents
          .whereType<Map>()
          .map((e) => AutomationRunEvent.fromJson(Map<String, dynamic>.from(e)))
          .toList(),
    );
  }

  String get cadenceLabel {
    final clean = cronExpr.trim().split(RegExp(r'\s+')).join(' ');
    if (clean.isEmpty) return '未设置调度';
    final parts = clean.split(' ');
    if (parts.length != 5) return clean;
    final min = parts[0];
    final hour = parts[1];
    final dom = parts[2];
    final mon = parts[3];
    final dow = parts[4];
    final minNum = int.tryParse(min);
    final padMin = minNum != null ? minNum.toString().padLeft(2, '0') : min;

    if (hour == '*' && dom == '*' && mon == '*' && dow == '*' && minNum != null) {
      return minNum == 0 ? '每小时整点' : '每小时第 $minNum 分';
    }
    if (dom == '*' && mon == '*' && minNum != null && !hour.contains('*') && !hour.contains('/')) {
      final times = hour
          .split(',')
          .map((h) => int.tryParse(h.trim()))
          .whereType<int>()
          .map((h) => '${h.toString().padLeft(2, '0')}:$padMin')
          .toList();
      if (times.isNotEmpty) {
        if (dow == '*') {
          return '每天 ${times.join(', ')}';
        }
        const dowLabels = {
          '0': '每周日',
          '1': '每周一',
          '2': '每周二',
          '3': '每周三',
          '4': '每周四',
          '5': '每周五',
          '6': '每周六',
          '7': '每周日',
          '1-5': '工作日',
        };
        final prefix = dowLabels[dow];
        if (prefix != null) {
          return '$prefix ${times.join(', ')}';
        }
      }
    }
    return clean;
  }
}

class AutomationListResponse {
  final List<AutomationItem> items;
  final String configDir;

  const AutomationListResponse({
    this.items = const [],
    this.configDir = '',
  });

  factory AutomationListResponse.fromJson(Map<String, dynamic> json) {
    final rawItems = json['items'] as List<dynamic>? ?? const [];
    return AutomationListResponse(
      items: rawItems
          .whereType<Map>()
          .map((e) => AutomationItem.fromJson(Map<String, dynamic>.from(e)))
          .toList(),
      configDir: json['config_dir']?.toString() ?? '',
    );
  }
}

class AutomationLogsResponse {
  final String id;
  final String logFile;
  final List<String> lines;

  const AutomationLogsResponse({
    required this.id,
    this.logFile = '',
    this.lines = const [],
  });

  factory AutomationLogsResponse.fromJson(Map<String, dynamic> json) {
    return AutomationLogsResponse(
      id: json['id']?.toString() ?? '',
      logFile: json['log_file']?.toString() ?? '',
      lines: (json['lines'] as List<dynamic>? ?? const [])
          .map((e) => e.toString())
          .toList(),
    );
  }
}

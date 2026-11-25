class SessionItem {
  final String id;
  final String title;
  final String preview;
  final String updatedAt;
  final String lastModified;
  final bool isPinned;
  final bool isRunning;
  final String workspacePath;
  final String rootId;

  const SessionItem({
    required this.id,
    required this.title,
    this.preview = '',
    this.updatedAt = '',
    this.lastModified = '',
    this.isPinned = false,
    this.isRunning = false,
    this.workspacePath = '',
    this.rootId = '',
  });

  String get time => updatedAt;

  factory SessionItem.fromJson(Map<String, dynamic> json) {
    return SessionItem(
      id: json['id']?.toString() ?? '',
      title: json['title']?.toString() ?? '未命名会话',
      preview: json['preview']?.toString() ?? '',
      updatedAt: (json['updated_at'] ?? json['time'])?.toString() ?? '',
      lastModified: json['last_modified']?.toString() ?? '',
      isPinned: json['is_pinned'] == true,
      isRunning: json['is_running'] == true,
      workspacePath: json['workspace_path']?.toString() ?? '',
      rootId: json['root_id']?.toString() ?? '',
    );
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'title': title,
        'preview': preview,
        'updated_at': updatedAt,
        'last_modified': lastModified,
        'is_pinned': isPinned,
        'is_running': isRunning,
        'workspace_path': workspacePath,
        'root_id': rootId,
      };

  SessionItem copyWith({
    String? title,
    String? preview,
    String? updatedAt,
    String? lastModified,
    bool? isPinned,
    bool? isRunning,
    String? workspacePath,
    String? rootId,
  }) {
    return SessionItem(
      id: id,
      title: title ?? this.title,
      preview: preview ?? this.preview,
      updatedAt: updatedAt ?? this.updatedAt,
      lastModified: lastModified ?? this.lastModified,
      isPinned: isPinned ?? this.isPinned,
      isRunning: isRunning ?? this.isRunning,
      workspacePath: workspacePath ?? this.workspacePath,
      rootId: rootId ?? this.rootId,
    );
  }
}

class SessionTreeData {
  final Map<String, List<SessionItem>> projects;
  final List<SessionItem> generalSessions;
  final bool engineAlive;
  final Set<String> runningSessionIds;

  const SessionTreeData({
    this.projects = const {},
    this.generalSessions = const [],
    this.engineAlive = false,
    this.runningSessionIds = const {},
  });

  factory SessionTreeData.fromJson(Map<String, dynamic> json) {
    final rawProjects = json['projects'] as Map<String, dynamic>? ?? const {};
    final parsedProjects = <String, List<SessionItem>>{};
    rawProjects.forEach((projectName, listVal) {
      if (listVal is List) {
        parsedProjects[projectName] = listVal
            .whereType<Map>()
            .map((item) => SessionItem.fromJson(Map<String, dynamic>.from(item)))
            .toList();
      }
    });

    final rawGeneral = json['general_sessions'] as List<dynamic>? ?? const [];
    final parsedGeneral = rawGeneral
        .whereType<Map>()
        .map((item) => SessionItem.fromJson(Map<String, dynamic>.from(item)))
        .toList();

    final rawRunning = json['running_session_ids'] as List<dynamic>? ?? const [];
    final runningIds = rawRunning.map((e) => e.toString()).toSet();

    for (final list in parsedProjects.values) {
      for (final s in list) {
        if (s.isRunning) runningIds.add(s.id);
      }
    }
    for (final s in parsedGeneral) {
      if (s.isRunning) runningIds.add(s.id);
    }

    return SessionTreeData(
      projects: parsedProjects,
      generalSessions: parsedGeneral,
      engineAlive: json['engine_alive'] == true,
      runningSessionIds: runningIds,
    );
  }
}

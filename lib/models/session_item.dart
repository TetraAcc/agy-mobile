class SessionItem {
  final String id;
  final String title;
  final String preview;
  final String time;
  final bool isActive;
  final String workspacePath;

  SessionItem({
    required this.id,
    required this.title,
    this.preview = '',
    required this.time,
    this.isActive = false,
    this.workspacePath = '',
  });

  factory SessionItem.fromJson(Map<String, dynamic> json) {
    return SessionItem(
      id: json['id'] ?? '',
      title: json['title'] ?? '未命名会话',
      preview: json['preview'] ?? '',
      time: json['time'] ?? '',
      isActive: json['is_active'] ?? false,
      workspacePath: json['workspace_path'] ?? '',
    );
  }
}

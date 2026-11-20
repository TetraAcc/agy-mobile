class SessionItem {
  final String id;
  final String title;
  final String time;
  final bool isActive;

  SessionItem({
    required this.id,
    required this.title,
    required this.time,
    this.isActive = false,
  });

  factory SessionItem.fromJson(Map<String, dynamic> json) {
    return SessionItem(
      id: json['id'] ?? '',
      title: json['title'] ?? '未命名会话',
      time: json['time'] ?? '',
      isActive: json['is_active'] ?? false,
    );
  }
}

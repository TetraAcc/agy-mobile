class HostNode {
  final String id;
  final String name;
  final bool isOnline;
  final bool engineAlive;
  final bool isLocal;
  final double lastSeen;
  final bool canWrite;
  final bool canDelete;

  const HostNode({
    required this.id,
    required this.name,
    this.isOnline = false,
    this.engineAlive = false,
    this.isLocal = false,
    this.lastSeen = 0.0,
    this.canWrite = false,
    this.canDelete = false,
  });

  factory HostNode.fromJson(Map<String, dynamic> json) {
    return HostNode(
      id: json['id']?.toString() ?? '',
      name: json['name']?.toString() ?? '',
      isOnline: json['online'] == true,
      engineAlive: json['engine_alive'] == true,
      isLocal: json['is_local'] == true,
      lastSeen: (json['last_seen'] as num?)?.toDouble() ?? 0.0,
      canWrite: json['can_write'] == true,
      canDelete: json['can_delete'] == true,
    );
  }
}

class HostNode {
  final String id;
  final String name;
  final bool isOnline;
  final bool engineAlive;

  HostNode({
    required this.id,
    required this.name,
    this.isOnline = false,
    this.engineAlive = false,
  });

  factory HostNode.fromJson(Map<String, dynamic> json) {
    return HostNode(
      id: json['id'] ?? '',
      name: json['name'] ?? '',
      isOnline: json['online'] == true,
      engineAlive: json['engine_alive'] == true,
    );
  }
}

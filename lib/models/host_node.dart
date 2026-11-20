class HostNode {
  final String id;
  final String name;
  final bool isOnline;

  HostNode({
    required this.id,
    required this.name,
    this.isOnline = false,
  });

  factory HostNode.fromJson(Map<String, dynamic> json) {
    return HostNode(
      id: json['id'] ?? '',
      name: json['name'] ?? '',
      isOnline: json['online'] ?? false,
    );
  }
}

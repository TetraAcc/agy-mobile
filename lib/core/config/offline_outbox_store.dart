import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

class OfflineOutboxItem {
  final String id;
  final String nodeId;
  final String sessionId;
  final String content;
  final String deliveryMode;
  final String createdAt;
  final String lastError;

  const OfflineOutboxItem({
    required this.id,
    required this.nodeId,
    required this.sessionId,
    required this.content,
    this.deliveryMode = 'queue',
    required this.createdAt,
    this.lastError = '',
  });

  factory OfflineOutboxItem.fromJson(Map<String, dynamic> json) {
    return OfflineOutboxItem(
      id: json['id']?.toString() ?? '',
      nodeId: json['node_id']?.toString() ?? '',
      sessionId: json['session_id']?.toString() ?? '',
      content: json['content']?.toString() ?? '',
      deliveryMode: json['delivery_mode']?.toString() ?? 'queue',
      createdAt: json['created_at']?.toString() ?? '',
      lastError: json['last_error']?.toString() ?? '',
    );
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'node_id': nodeId,
        'session_id': sessionId,
        'content': content,
        'delivery_mode': deliveryMode,
        'created_at': createdAt,
        'last_error': lastError,
      };

  OfflineOutboxItem copyWith({
    String? content,
    String? lastError,
  }) {
    return OfflineOutboxItem(
      id: id,
      nodeId: nodeId,
      sessionId: sessionId,
      content: content ?? this.content,
      deliveryMode: deliveryMode,
      createdAt: createdAt,
      lastError: lastError ?? this.lastError,
    );
  }
}

class OfflineOutboxStore {
  static const _prefKey = 'v2_offline_outbox_v1';

  static Future<List<OfflineOutboxItem>> load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_prefKey);
      if (raw == null || raw.trim().isEmpty) return const [];
      final decoded = jsonDecode(raw);
      if (decoded is! List) return const [];
      return decoded
          .whereType<Map>()
          .map((e) => OfflineOutboxItem.fromJson(Map<String, dynamic>.from(e)))
          .where((e) => e.id.isNotEmpty && e.nodeId.isNotEmpty && e.sessionId.isNotEmpty && e.content.trim().isNotEmpty)
          .toList();
    } catch (_) {
      return const [];
    }
  }

  static Future<void> save(List<OfflineOutboxItem> items) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      if (items.isEmpty) {
        await prefs.remove(_prefKey);
      } else {
        await prefs.setString(
          _prefKey,
          jsonEncode(items.map((e) => e.toJson()).toList()),
        );
      }
    } catch (_) {}
  }

  static Future<void> clear() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(_prefKey);
    } catch (_) {}
  }
}

import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../../models/models.dart';

class CachedSessionMessages {
  final String nodeId;
  final String sessionId;
  final String title;
  final String rootId;
  final String activeModel;
  final List<AgentMessage> messages;
  final int updatedAtMs;

  const CachedSessionMessages({
    required this.nodeId,
    required this.sessionId,
    required this.title,
    this.rootId = 'scratch',
    this.activeModel = '',
    this.messages = const [],
    required this.updatedAtMs,
  });

  DateTime get updatedAt => DateTime.fromMillisecondsSinceEpoch(updatedAtMs);

  factory CachedSessionMessages.fromJson(Map<String, dynamic> json) {
    final rawMsgs = json['messages'] as List<dynamic>? ?? const [];
    return CachedSessionMessages(
      nodeId: json['node_id']?.toString() ?? '',
      sessionId: json['session_id']?.toString() ?? '',
      title: json['title']?.toString() ?? '未命名会话',
      rootId: json['root_id']?.toString() ?? 'scratch',
      activeModel: json['active_model']?.toString() ?? '',
      messages: rawMsgs
          .whereType<Map>()
          .map((e) => AgentMessage.fromJson(Map<String, dynamic>.from(e)))
          .toList(),
      updatedAtMs: (json['updated_at_ms'] as num?)?.toInt() ?? 0,
    );
  }

  Map<String, dynamic> toJson() => {
        'node_id': nodeId,
        'session_id': sessionId,
        'title': title,
        'root_id': rootId,
        if (activeModel.isNotEmpty) 'active_model': activeModel,
        'messages': messages.map((m) => m.toJson()).toList(),
        'updated_at_ms': updatedAtMs,
      };
}

class CachedNodeTree {
  final String nodeId;
  final Map<String, List<SessionItem>> projects;
  final List<SessionItem> generalSessions;
  final int updatedAtMs;

  const CachedNodeTree({
    required this.nodeId,
    this.projects = const {},
    this.generalSessions = const [],
    required this.updatedAtMs,
  });

  bool get isEmpty => projects.isEmpty && generalSessions.isEmpty;

  factory CachedNodeTree.fromJson(Map<String, dynamic> json) {
    final rawProjects = json['projects'] as Map<String, dynamic>? ?? const {};
    final parsedProjects = <String, List<SessionItem>>{};
    rawProjects.forEach((proj, val) {
      if (val is List) {
        parsedProjects[proj] = val
            .whereType<Map>()
            .map((e) => SessionItem.fromJson(Map<String, dynamic>.from(e)))
            .where((s) => s.id.isNotEmpty)
            .toList();
      }
    });
    final rawGeneral = json['general_sessions'] as List<dynamic>? ?? const [];
    final parsedGeneral = rawGeneral
        .whereType<Map>()
        .map((e) => SessionItem.fromJson(Map<String, dynamic>.from(e)))
        .where((s) => s.id.isNotEmpty)
        .toList();
    return CachedNodeTree(
      nodeId: json['node_id']?.toString() ?? '',
      projects: parsedProjects,
      generalSessions: parsedGeneral,
      updatedAtMs: (json['updated_at_ms'] as num?)?.toInt() ?? 0,
    );
  }

  Map<String, dynamic> toJson() => {
        'node_id': nodeId,
        'projects': projects.map(
          (k, v) => MapEntry(k, v.map((s) => s.toJson()).toList()),
        ),
        'general_sessions': generalSessions.map((s) => s.toJson()).toList(),
        'updated_at_ms': updatedAtMs,
      };
}

class CachedHubSnapshot {
  final List<HostNode> nodes;
  final String lastNodeId;
  final Map<String, String> lastSessionIdByNode;
  final Map<String, CachedNodeTree> treesByNode;
  final Map<String, CachedSessionMessages> sessionsByKey;

  const CachedHubSnapshot({
    this.nodes = const [],
    this.lastNodeId = '',
    this.lastSessionIdByNode = const {},
    this.treesByNode = const {},
    this.sessionsByKey = const {},
  });

  static String sessionKey(String nodeId, String sessionId) => '$nodeId::$sessionId';

  CachedSessionMessages? getSession(String nodeId, String sessionId) {
    if (nodeId.isEmpty || sessionId.isEmpty) return null;
    return sessionsByKey[sessionKey(nodeId, sessionId)];
  }

  bool hasCacheForNode(String nodeId) {
    if (nodeId.isEmpty) return false;
    final tree = treesByNode[nodeId];
    if (tree != null && !tree.isEmpty) return true;
    return sessionsByKey.values.any((s) => s.nodeId == nodeId && s.messages.isNotEmpty);
  }

  CachedSessionMessages? latestSessionForNode(String nodeId) {
    if (nodeId.isEmpty) return null;
    final preferredSid = lastSessionIdByNode[nodeId];
    if (preferredSid != null && preferredSid.isNotEmpty) {
      final preferred = getSession(nodeId, preferredSid);
      if (preferred != null) return preferred;
    }
    CachedSessionMessages? best;
    for (final s in sessionsByKey.values) {
      if (s.nodeId != nodeId) continue;
      if (best == null || s.updatedAtMs > best.updatedAtMs) {
        best = s;
      }
    }
    return best;
  }
}

/// Lightweight LRU local cache for recently active sessions (up to 8 sessions,
/// 40 messages per session) enabling instant cold-start rendering and offline
/// read-only history browsing when the host PC is disconnected.
class SessionCacheStore {
  static const _metaPrefKey = 'v23_session_cache_meta_v1';
  static const _sessionsPrefKey = 'v23_session_cache_msgs_v1';
  static const int maxCachedSessions = 8;
  static const int maxMessagesPerSession = 40;
  static const int maxSessionsPerNodeTree = 40;

  static Future<CachedHubSnapshot> loadSnapshot() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      var nodes = const <HostNode>[];
      var lastNodeId = '';
      var lastSessionIdByNode = const <String, String>{};
      var treesByNode = const <String, CachedNodeTree>{};

      final rawMeta = prefs.getString(_metaPrefKey);
      if (rawMeta != null && rawMeta.trim().isNotEmpty) {
        final decoded = jsonDecode(rawMeta);
        if (decoded is Map) {
          final map = Map<String, dynamic>.from(decoded);
          lastNodeId = map['last_node_id']?.toString() ?? '';
          final rawNodes = map['nodes'] as List<dynamic>? ?? const [];
          nodes = rawNodes
              .whereType<Map>()
              .map((e) => HostNode.fromJson(Map<String, dynamic>.from(e)))
              .where((n) => n.id.isNotEmpty)
              .toList();
          final rawLastSids = map['last_session_by_node'];
          if (rawLastSids is Map) {
            lastSessionIdByNode = rawLastSids.map(
              (k, v) => MapEntry(k.toString(), v.toString()),
            );
          }
          final rawTrees = map['trees_by_node'];
          if (rawTrees is Map) {
            final parsedTrees = <String, CachedNodeTree>{};
            rawTrees.forEach((k, v) {
              if (v is Map) {
                final t = CachedNodeTree.fromJson(Map<String, dynamic>.from(v));
                if (t.nodeId.isNotEmpty) {
                  parsedTrees[t.nodeId] = t;
                }
              }
            });
            treesByNode = parsedTrees;
          }
        }
      }

      final sessionsByKey = <String, CachedSessionMessages>{};
      final rawSessions = prefs.getString(_sessionsPrefKey);
      if (rawSessions != null && rawSessions.trim().isNotEmpty) {
        final decoded = jsonDecode(rawSessions);
        if (decoded is List) {
          for (final item in decoded.whereType<Map>()) {
            final parsed = CachedSessionMessages.fromJson(Map<String, dynamic>.from(item));
            if (parsed.nodeId.isNotEmpty && parsed.sessionId.isNotEmpty) {
              sessionsByKey[CachedHubSnapshot.sessionKey(parsed.nodeId, parsed.sessionId)] = parsed;
            }
          }
        }
      }

      return CachedHubSnapshot(
        nodes: nodes,
        lastNodeId: lastNodeId,
        lastSessionIdByNode: lastSessionIdByNode,
        treesByNode: treesByNode,
        sessionsByKey: sessionsByKey,
      );
    } catch (_) {
      return const CachedHubSnapshot();
    }
  }

  static Future<void> _writeMeta(
    SharedPreferences prefs, {
    required List<HostNode> nodes,
    required String lastNodeId,
    required Map<String, String> lastSessionIdByNode,
    required Map<String, CachedNodeTree> treesByNode,
  }) async {
    await prefs.setString(
      _metaPrefKey,
      jsonEncode({
        'last_node_id': lastNodeId,
        'nodes': nodes.map((n) => n.toJson()).toList(),
        'last_session_by_node': lastSessionIdByNode,
        'trees_by_node': treesByNode.map((k, v) => MapEntry(k, v.toJson())),
      }),
    );
  }

  static Future<void> saveNodes(
    List<HostNode> nodes, {
    String? selectedNodeId,
  }) async {
    if (nodes.isEmpty) return;
    try {
      final snapshot = await loadSnapshot();
      final prefs = await SharedPreferences.getInstance();
      await _writeMeta(
        prefs,
        nodes: nodes,
        lastNodeId: (selectedNodeId != null && selectedNodeId.isNotEmpty)
            ? selectedNodeId
            : snapshot.lastNodeId,
        lastSessionIdByNode: snapshot.lastSessionIdByNode,
        treesByNode: snapshot.treesByNode,
      );
    } catch (_) {}
  }

  static Future<void> saveSessionTree(
    String nodeId,
    Map<String, List<SessionItem>> projects,
    List<SessionItem> generalSessions,
  ) async {
    if (nodeId.isEmpty) return;
    try {
      final snapshot = await loadSnapshot();
      final prefs = await SharedPreferences.getInstance();

      var remainingBudget = maxSessionsPerNodeTree;
      final trimmedProjects = <String, List<SessionItem>>{};
      projects.forEach((projName, list) {
        if (remainingBudget <= 0 || list.isEmpty) return;
        final takeCount = list.length <= remainingBudget ? list.length : remainingBudget;
        trimmedProjects[projName] = list
            .take(takeCount)
            .map(
              (s) => SessionItem(
                id: s.id,
                title: s.title,
                preview: s.preview.length > 120 ? s.preview.substring(0, 120) : s.preview,
                updatedAt: s.updatedAt,
                lastModified: s.lastModified,
                isPinned: s.isPinned,
                isRunning: false,
                workspacePath: s.workspacePath,
                rootId: s.rootId,
              ),
            )
            .toList();
        remainingBudget -= takeCount;
      });
      final trimmedGeneral = generalSessions
          .take(remainingBudget > 0 ? remainingBudget : 8)
          .map(
            (s) => SessionItem(
              id: s.id,
              title: s.title,
              preview: s.preview.length > 120 ? s.preview.substring(0, 120) : s.preview,
              updatedAt: s.updatedAt,
              lastModified: s.lastModified,
              isPinned: s.isPinned,
              isRunning: false,
              workspacePath: s.workspacePath,
              rootId: s.rootId,
            ),
          )
          .toList();

      final nextTrees = Map<String, CachedNodeTree>.from(snapshot.treesByNode);
      nextTrees[nodeId] = CachedNodeTree(
        nodeId: nodeId,
        projects: trimmedProjects,
        generalSessions: trimmedGeneral,
        updatedAtMs: DateTime.now().millisecondsSinceEpoch,
      );

      await _writeMeta(
        prefs,
        nodes: snapshot.nodes,
        lastNodeId: snapshot.lastNodeId.isNotEmpty ? snapshot.lastNodeId : nodeId,
        lastSessionIdByNode: snapshot.lastSessionIdByNode,
        treesByNode: nextTrees,
      );
    } catch (_) {}
  }

  static Future<void> saveSessionMessages({
    required String nodeId,
    required String sessionId,
    required String title,
    required String rootId,
    required String activeModel,
    required List<AgentMessage> messages,
  }) async {
    if (nodeId.isEmpty || sessionId.isEmpty) return;
    final confirmed = messages.where((m) => m.stepIndex >= 0).toList();
    if (confirmed.isEmpty) return;
    final sliced = confirmed.length > maxMessagesPerSession
        ? confirmed.sublist(confirmed.length - maxMessagesPerSession)
        : confirmed;

    try {
      final snapshot = await loadSnapshot();
      final prefs = await SharedPreferences.getInstance();
      final nowMs = DateTime.now().millisecondsSinceEpoch;

      final nextSessions = Map<String, CachedSessionMessages>.from(snapshot.sessionsByKey);
      nextSessions[CachedHubSnapshot.sessionKey(nodeId, sessionId)] = CachedSessionMessages(
        nodeId: nodeId,
        sessionId: sessionId,
        title: title,
        rootId: rootId.isNotEmpty ? rootId : 'scratch',
        activeModel: activeModel,
        messages: sliced,
        updatedAtMs: nowMs,
      );

      final ordered = nextSessions.values.toList()
        ..sort((a, b) => b.updatedAtMs.compareTo(a.updatedAtMs));
      final bounded = ordered.take(maxCachedSessions).toList();

      await prefs.setString(
        _sessionsPrefKey,
        jsonEncode(bounded.map((e) => e.toJson()).toList()),
      );

      final nextLastSids = Map<String, String>.from(snapshot.lastSessionIdByNode);
      nextLastSids[nodeId] = sessionId;
      await _writeMeta(
        prefs,
        nodes: snapshot.nodes,
        lastNodeId: nodeId,
        lastSessionIdByNode: nextLastSids,
        treesByNode: snapshot.treesByNode,
      );
    } catch (_) {}
  }

  static Future<void> removeSession(String nodeId, String sessionId) async {
    if (nodeId.isEmpty || sessionId.isEmpty) return;
    try {
      final snapshot = await loadSnapshot();
      final prefs = await SharedPreferences.getInstance();
      final nextSessions = Map<String, CachedSessionMessages>.from(snapshot.sessionsByKey);
      nextSessions.remove(CachedHubSnapshot.sessionKey(nodeId, sessionId));
      await prefs.setString(
        _sessionsPrefKey,
        jsonEncode(nextSessions.values.map((e) => e.toJson()).toList()),
      );

      final nextLastSids = Map<String, String>.from(snapshot.lastSessionIdByNode);
      if (nextLastSids[nodeId] == sessionId) {
        nextLastSids.remove(nodeId);
        await _writeMeta(
          prefs,
          nodes: snapshot.nodes,
          lastNodeId: snapshot.lastNodeId,
          lastSessionIdByNode: nextLastSids,
          treesByNode: snapshot.treesByNode,
        );
      }
    } catch (_) {}
  }

  static Future<void> clear() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(_metaPrefKey);
      await prefs.remove(_sessionsPrefKey);
    } catch (_) {}
  }
}

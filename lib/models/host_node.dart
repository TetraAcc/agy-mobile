class HostNode {
  final String id;
  final String name;
  final bool isOnline;
  final bool engineAlive;
  final bool isLocal;
  final double lastSeen;
  final String version;
  final bool canWrite;
  final bool canDelete;

  const HostNode({
    required this.id,
    required this.name,
    this.isOnline = false,
    this.engineAlive = false,
    this.isLocal = false,
    this.lastSeen = 0.0,
    this.version = '',
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
      version: json['version']?.toString() ?? '',
      canWrite: json['can_write'] == true,
      canDelete: json['can_delete'] == true,
    );
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'online': isOnline,
        'engine_alive': engineAlive,
        'is_local': isLocal,
        'last_seen': lastSeen,
        'version': version,
        'can_write': canWrite,
        'can_delete': canDelete,
      };
}

class NodeUpdateStatus {
  final String currentVersion;
  final bool gitAvailable;
  final String branch;
  final String localCommit;
  final String remoteCommit;
  final int behindCount;
  final bool dirty;
  final int runningSessions;
  final bool updateAvailable;
  final bool canUpdate;
  final String message;

  const NodeUpdateStatus({
    this.currentVersion = '',
    this.gitAvailable = false,
    this.branch = '',
    this.localCommit = '',
    this.remoteCommit = '',
    this.behindCount = 0,
    this.dirty = false,
    this.runningSessions = 0,
    this.updateAvailable = false,
    this.canUpdate = false,
    this.message = '',
  });

  factory NodeUpdateStatus.fromJson(Map<String, dynamic> json) {
    return NodeUpdateStatus(
      currentVersion: json['current_version']?.toString() ?? '',
      gitAvailable: json['git_available'] == true,
      branch: json['branch']?.toString() ?? '',
      localCommit: json['local_commit']?.toString() ?? '',
      remoteCommit: json['remote_commit']?.toString() ?? '',
      behindCount: (json['behind_count'] as num?)?.toInt() ?? 0,
      dirty: json['dirty'] == true,
      runningSessions: (json['running_sessions'] as num?)?.toInt() ?? 0,
      updateAvailable: json['update_available'] == true,
      canUpdate: json['can_update'] == true,
      message: json['message']?.toString() ?? '',
    );
  }
}

class NodeUpdateApplyResult {
  final bool ok;
  final bool updated;
  final bool restarting;
  final String fromVersion;
  final String toVersion;
  final String commit;
  final String message;

  const NodeUpdateApplyResult({
    this.ok = false,
    this.updated = false,
    this.restarting = false,
    this.fromVersion = '',
    this.toVersion = '',
    this.commit = '',
    this.message = '',
  });

  factory NodeUpdateApplyResult.fromJson(Map<String, dynamic> json) {
    return NodeUpdateApplyResult(
      ok: json['ok'] == true,
      updated: json['updated'] == true,
      restarting: json['restarting'] == true,
      fromVersion: json['from_version']?.toString() ?? '',
      toVersion: json['to_version']?.toString() ?? '',
      commit: json['commit']?.toString() ?? '',
      message: json['message']?.toString() ?? '',
    );
  }
}

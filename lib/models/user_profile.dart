class UserPermissionGrant {
  final String nodeId;
  final bool canWrite;
  final bool canDelete;

  const UserPermissionGrant({
    required this.nodeId,
    this.canWrite = true,
    this.canDelete = false,
  });

  factory UserPermissionGrant.fromJson(Map<String, dynamic> json) {
    return UserPermissionGrant(
      nodeId: json['node_id']?.toString() ?? '',
      canWrite: json['can_write'] == true,
      canDelete: json['can_delete'] == true,
    );
  }
}

class UserProfile {
  final int id;
  final String username;
  final String displayName;
  final String role;
  final bool isActive;
  final String defaultNode;
  final List<String> allowedNodes;
  final Map<String, UserPermissionGrant> nodePermissions;

  const UserProfile({
    required this.id,
    required this.username,
    required this.displayName,
    required this.role,
    this.isActive = true,
    this.defaultNode = '',
    this.allowedNodes = const [],
    this.nodePermissions = const {},
  });

  bool get isAdmin => role == 'admin';

  UserPermissionGrant? permissionFor(String nodeId) => nodePermissions[nodeId];

  factory UserProfile.fromJson(Map<String, dynamic> json) {
    final rawAllowed = json['allowed_nodes'] as List<dynamic>? ?? const [];
    final rawPerms = json['node_permissions'] as Map<String, dynamic>? ?? const {};
    final perms = <String, UserPermissionGrant>{};
    rawPerms.forEach((key, value) {
      if (value is Map<String, dynamic>) {
        perms[key] = UserPermissionGrant.fromJson(value);
      } else if (value is Map) {
        perms[key] = UserPermissionGrant.fromJson(Map<String, dynamic>.from(value));
      }
    });

    return UserProfile(
      id: (json['id'] as num?)?.toInt() ?? 0,
      username: json['username']?.toString() ?? '',
      displayName: json['display_name']?.toString() ?? json['username']?.toString() ?? '',
      role: json['role']?.toString() ?? 'member',
      isActive: json['is_active'] != false,
      defaultNode: json['default_node']?.toString() ?? '',
      allowedNodes: rawAllowed.map((e) => e.toString()).toList(),
      nodePermissions: perms,
    );
  }
}

class TokenPair {
  final String accessToken;
  final String refreshToken;
  final int expiresIn;
  final String tokenType;

  const TokenPair({
    required this.accessToken,
    required this.refreshToken,
    required this.expiresIn,
    this.tokenType = 'Bearer',
  });

  factory TokenPair.fromJson(Map<String, dynamic> json) {
    return TokenPair(
      accessToken: json['access_token']?.toString() ?? '',
      refreshToken: json['refresh_token']?.toString() ?? '',
      expiresIn: (json['expires_in'] as num?)?.toInt() ?? 1800,
      tokenType: json['token_type']?.toString() ?? 'Bearer',
    );
  }
}

class LoginResult {
  final bool ok;
  final UserProfile user;
  final TokenPair tokens;

  const LoginResult({
    required this.ok,
    required this.user,
    required this.tokens,
  });

  factory LoginResult.fromJson(Map<String, dynamic> json) {
    return LoginResult(
      ok: json['ok'] == true,
      user: UserProfile.fromJson(Map<String, dynamic>.from(json['user'] as Map)),
      tokens: TokenPair.fromJson(Map<String, dynamic>.from(json['tokens'] as Map)),
    );
  }
}

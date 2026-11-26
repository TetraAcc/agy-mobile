/// Interactive tool/permission approval item reported by a Node Agent.
class ToolApprovalItem {
  final String approvalId;
  final String sessionId;
  final String trajectoryId;
  final int stepIndex;
  final String stepType;
  final String interactionKind;
  final String rawInteractionField;
  final String category;
  final String title;
  final String actionLabel;
  final String target;
  final String cwd;
  final String reason;
  final String shellName;
  final bool canRemember;
  final List<String> allowedScopes;
  final String suggestedPersistPattern;
  final bool editableCommand;
  final Map<String, dynamic> detail;
  final String createdAt;

  const ToolApprovalItem({
    required this.approvalId,
    required this.sessionId,
    required this.trajectoryId,
    required this.stepIndex,
    this.stepType = '',
    required this.interactionKind,
    required this.rawInteractionField,
    this.category = 'other',
    required this.title,
    this.actionLabel = '',
    this.target = '',
    this.cwd = '',
    this.reason = '',
    this.shellName = '',
    this.canRemember = false,
    this.allowedScopes = const ['once'],
    this.suggestedPersistPattern = '',
    this.editableCommand = false,
    this.detail = const {},
    this.createdAt = '',
  });

  factory ToolApprovalItem.fromJson(Map<String, dynamic> json) {
    final rawScopes = json['allowed_scopes'] as List<dynamic>? ?? const ['once'];
    final scopes = rawScopes
        .map((e) => e.toString().trim())
        .where((e) => e.isNotEmpty)
        .toList();
    final rawDetail = json['detail'];
    return ToolApprovalItem(
      approvalId: json['approval_id']?.toString() ?? '',
      sessionId: json['session_id']?.toString() ?? '',
      trajectoryId: json['trajectory_id']?.toString() ?? '',
      stepIndex: (json['step_index'] as num?)?.toInt() ?? 0,
      stepType: json['step_type']?.toString() ?? '',
      interactionKind: json['interaction_kind']?.toString() ?? 'approval',
      rawInteractionField: json['raw_interaction_field']?.toString() ?? '',
      category: json['category']?.toString() ?? 'other',
      title: json['title']?.toString() ?? '工具操作审批',
      actionLabel: json['action_label']?.toString() ?? '',
      target: json['target']?.toString() ?? '',
      cwd: json['cwd']?.toString() ?? '',
      reason: json['reason']?.toString() ?? '',
      shellName: json['shell_name']?.toString() ?? '',
      canRemember: json['can_remember'] == true,
      allowedScopes: scopes.isNotEmpty ? scopes : const ['once'],
      suggestedPersistPattern: json['suggested_persist_pattern']?.toString() ?? '',
      editableCommand: json['editable_command'] == true,
      detail: rawDetail is Map ? Map<String, dynamic>.from(rawDetail) : const {},
      createdAt: json['created_at']?.toString() ?? '',
    );
  }

  Map<String, dynamic> toJson() => {
        'approval_id': approvalId,
        'session_id': sessionId,
        'trajectory_id': trajectoryId,
        'step_index': stepIndex,
        'step_type': stepType,
        'interaction_kind': interactionKind,
        'raw_interaction_field': rawInteractionField,
        'category': category,
        'title': title,
        'action_label': actionLabel,
        'target': target,
        'cwd': cwd,
        'reason': reason,
        'shell_name': shellName,
        'can_remember': canRemember,
        'allowed_scopes': allowedScopes,
        'suggested_persist_pattern': suggestedPersistPattern,
        'editable_command': editableCommand,
        'detail': detail,
        'created_at': createdAt,
      };
}

class PendingApprovalsData {
  final String sessionId;
  final bool supported;
  final List<ToolApprovalItem> approvals;

  const PendingApprovalsData({
    this.sessionId = '',
    this.supported = true,
    this.approvals = const [],
  });

  factory PendingApprovalsData.fromJson(Map<String, dynamic> json) {
    final raw = json['approvals'] as List<dynamic>? ?? const [];
    return PendingApprovalsData(
      sessionId: json['session_id']?.toString() ?? '',
      supported: json['supported'] != false,
      approvals: raw
          .whereType<Map>()
          .map((e) => ToolApprovalItem.fromJson(Map<String, dynamic>.from(e)))
          .toList(),
    );
  }
}

class ApprovalDecisionResult {
  final bool ok;
  final String sessionId;
  final int stepIndex;
  final String decision;
  final String message;
  final List<ToolApprovalItem> remainingApprovals;

  const ApprovalDecisionResult({
    this.ok = false,
    this.sessionId = '',
    this.stepIndex = 0,
    this.decision = '',
    this.message = '',
    this.remainingApprovals = const [],
  });

  factory ApprovalDecisionResult.fromJson(Map<String, dynamic> json) {
    final rawRemaining = json['remaining_approvals'] as List<dynamic>? ?? const [];
    return ApprovalDecisionResult(
      ok: json['ok'] == true,
      sessionId: json['session_id']?.toString() ?? '',
      stepIndex: (json['step_index'] as num?)?.toInt() ?? 0,
      decision: json['decision']?.toString() ?? '',
      message: json['message']?.toString() ?? '',
      remainingApprovals: rawRemaining
          .whereType<Map>()
          .map((e) => ToolApprovalItem.fromJson(Map<String, dynamic>.from(e)))
          .toList(),
    );
  }
}

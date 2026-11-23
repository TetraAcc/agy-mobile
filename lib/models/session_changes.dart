class InlineDiffSegment {
  final String kind; // 'equal' | 'delete' | 'insert'
  final String text;

  const InlineDiffSegment({
    required this.kind,
    required this.text,
  });

  factory InlineDiffSegment.fromJson(Map<String, dynamic> json) {
    return InlineDiffSegment(
      kind: json['kind']?.toString() ?? 'equal',
      text: json['text']?.toString() ?? '',
    );
  }
}

class SessionEditHunk {
  final String hunkId;
  final int stepIndex;
  final String toolName;
  final String timestamp;
  final int? startLine;
  final int? endLine;
  final int addedLines;
  final int removedLines;
  final String beforeText;
  final String afterText;
  final String unifiedDiff;
  final List<InlineDiffSegment> inlineSegments;

  const SessionEditHunk({
    required this.hunkId,
    required this.stepIndex,
    required this.toolName,
    this.timestamp = '',
    this.startLine,
    this.endLine,
    this.addedLines = 0,
    this.removedLines = 0,
    this.beforeText = '',
    this.afterText = '',
    this.unifiedDiff = '',
    this.inlineSegments = const [],
  });

  String get lineLabel {
    if (startLine == null) return 'Step $stepIndex';
    if (endLine == null || endLine == startLine) {
      return 'L$startLine · Step $stepIndex';
    }
    return 'L$startLine-L$endLine · Step $stepIndex';
  }

  factory SessionEditHunk.fromJson(Map<String, dynamic> json) {
    final rawSegs = json['inline_segments'] as List<dynamic>? ?? const [];
    return SessionEditHunk(
      hunkId: json['hunk_id']?.toString() ?? '',
      stepIndex: (json['step_index'] as num?)?.toInt() ?? 0,
      toolName: json['tool_name']?.toString() ?? 'edit_file',
      timestamp: json['timestamp']?.toString() ?? '',
      startLine: (json['start_line'] as num?)?.toInt(),
      endLine: (json['end_line'] as num?)?.toInt(),
      addedLines: (json['added_lines'] as num?)?.toInt() ?? 0,
      removedLines: (json['removed_lines'] as num?)?.toInt() ?? 0,
      beforeText: json['before_text']?.toString() ?? '',
      afterText: json['after_text']?.toString() ?? '',
      unifiedDiff: json['unified_diff']?.toString() ?? '',
      inlineSegments: rawSegs
          .whereType<Map>()
          .map((e) => InlineDiffSegment.fromJson(Map<String, dynamic>.from(e)))
          .toList(),
    );
  }
}

class SessionFileChange {
  final String filePath;
  final String fileName;
  final String directory;
  final int addedLines;
  final int removedLines;
  final int editCount;
  final int lastStepIndex;
  final bool isNewFile;
  final List<SessionEditHunk> hunks;

  const SessionFileChange({
    required this.filePath,
    required this.fileName,
    this.directory = '',
    this.addedLines = 0,
    this.removedLines = 0,
    this.editCount = 0,
    this.lastStepIndex = 0,
    this.isNewFile = false,
    this.hunks = const [],
  });

  factory SessionFileChange.fromJson(Map<String, dynamic> json) {
    final rawHunks = json['hunks'] as List<dynamic>? ?? const [];
    return SessionFileChange(
      filePath: json['file_path']?.toString() ?? '',
      fileName: json['file_name']?.toString() ?? '',
      directory: json['directory']?.toString() ?? '',
      addedLines: (json['added_lines'] as num?)?.toInt() ?? 0,
      removedLines: (json['removed_lines'] as num?)?.toInt() ?? 0,
      editCount: (json['edit_count'] as num?)?.toInt() ?? 0,
      lastStepIndex: (json['last_step_index'] as num?)?.toInt() ?? 0,
      isNewFile: json['is_new_file'] == true,
      hunks: rawHunks
          .whereType<Map>()
          .map((e) => SessionEditHunk.fromJson(Map<String, dynamic>.from(e)))
          .toList(),
    );
  }
}

class SessionChangesData {
  final String sessionId;
  final int totalFiles;
  final int totalAdded;
  final int totalRemoved;
  final List<SessionFileChange> files;

  const SessionChangesData({
    this.sessionId = '',
    this.totalFiles = 0,
    this.totalAdded = 0,
    this.totalRemoved = 0,
    this.files = const [],
  });

  factory SessionChangesData.fromJson(Map<String, dynamic> json) {
    final rawFiles = json['files'] as List<dynamic>? ?? const [];
    return SessionChangesData(
      sessionId: json['session_id']?.toString() ?? '',
      totalFiles: (json['total_files'] as num?)?.toInt() ?? 0,
      totalAdded: (json['total_added'] as num?)?.toInt() ?? 0,
      totalRemoved: (json['total_removed'] as num?)?.toInt() ?? 0,
      files: rawFiles
          .whereType<Map>()
          .map((e) => SessionFileChange.fromJson(Map<String, dynamic>.from(e)))
          .toList(),
    );
  }
}

class GitRepoItem {
  final String id;
  final String rootId;
  final String subPath;
  final String name;
  final String branch;
  final int changeCount;

  const GitRepoItem({
    required this.id,
    required this.rootId,
    this.subPath = '',
    required this.name,
    this.branch = '',
    this.changeCount = 0,
  });

  String get displayLabel {
    final parts = <String>[];
    if (branch.isNotEmpty) parts.add(branch);
    if (changeCount > 0) parts.add('$changeCount 处变更');
    return parts.isEmpty ? name : '$name (${parts.join(' · ')})';
  }

  factory GitRepoItem.fromJson(Map<String, dynamic> json) {
    return GitRepoItem(
      id: json['id']?.toString() ?? '',
      rootId: json['root_id']?.toString() ?? '',
      subPath: json['sub_path']?.toString() ?? '',
      name: json['name']?.toString() ?? '',
      branch: json['branch']?.toString() ?? '',
      changeCount: (json['change_count'] as num?)?.toInt() ?? 0,
    );
  }
}

class ReviewCommentItem {
  final String id;
  final String filePath;
  final String fileName;
  final String locationLabel;
  final String excerpt;
  final String comment;
  final String? hunkId;
  final int? stepIndex;

  const ReviewCommentItem({
    required this.id,
    required this.filePath,
    required this.fileName,
    this.locationLabel = '',
    this.excerpt = '',
    required this.comment,
    this.hunkId,
    this.stepIndex,
  });

  ReviewCommentItem copyWith({String? comment}) {
    return ReviewCommentItem(
      id: id,
      filePath: filePath,
      fileName: fileName,
      locationLabel: locationLabel,
      excerpt: excerpt,
      comment: comment ?? this.comment,
      hunkId: hunkId,
      stepIndex: stepIndex,
    );
  }

  static String formatReviewPrompt(List<ReviewCommentItem> comments) {
    if (comments.isEmpty) return '';
    final buf = StringBuffer('请根据以下修改评审批注，定位对应文件与段落进行修改：\n\n');
    for (var i = 0; i < comments.length; i++) {
      final c = comments[i];
      final metaParts = <String>[c.filePath];
      if (c.locationLabel.isNotEmpty) metaParts.add(c.locationLabel);
      buf.writeln('${i + 1}. **${c.fileName}** (`${metaParts.join(' · ')}`)');
      final cleanExcerpt = c.excerpt.trim().replaceAll('\n', ' ');
      if (cleanExcerpt.isNotEmpty) {
        final shortExcerpt = cleanExcerpt.length > 140 ? '${cleanExcerpt.substring(0, 140)}...' : cleanExcerpt;
        buf.writeln('   > 原文摘录: $shortExcerpt');
      }
      buf.writeln('   - **批注**: ${c.comment.trim()}');
      if (i != comments.length - 1) buf.writeln();
    }
    return buf.toString().trimRight();
  }
}

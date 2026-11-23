class QuotaBucket {
  final String bucketId;
  final String displayName;
  final String window;
  final double remainingFraction;
  final bool disabled;
  final String resetTime;

  const QuotaBucket({
    required this.bucketId,
    required this.displayName,
    required this.window,
    required this.remainingFraction,
    this.disabled = false,
    this.resetTime = '',
  });

  factory QuotaBucket.fromJson(Map<String, dynamic> json) {
    return QuotaBucket(
      bucketId: (json['bucket_id'] ?? json['bucketId'])?.toString() ?? '',
      displayName: (json['display_name'] ?? json['displayName'])?.toString() ?? '',
      window: json['window']?.toString() ?? '',
      remainingFraction: ((json['remaining_fraction'] ?? json['remainingFraction']) as num?)?.toDouble() ?? 1.0,
      disabled: json['disabled'] == true,
      resetTime: (json['reset_time'] ?? json['resetTime'])?.toString() ?? '',
    );
  }
}

class QuotaGroup {
  final String displayName;
  final String description;
  final List<QuotaBucket> buckets;

  const QuotaGroup({
    required this.displayName,
    this.description = '',
    this.buckets = const [],
  });

  factory QuotaGroup.fromJson(Map<String, dynamic> json) {
    final rawBuckets = json['buckets'] as List<dynamic>? ?? const [];
    return QuotaGroup(
      displayName: (json['display_name'] ?? json['displayName'])?.toString() ?? '',
      description: json['description']?.toString() ?? '',
      buckets: rawBuckets
          .whereType<Map>()
          .map((e) => QuotaBucket.fromJson(Map<String, dynamic>.from(e)))
          .toList(),
    );
  }
}

class QuotaData {
  final List<QuotaGroup> groups;
  final String description;

  const QuotaData({
    this.groups = const [],
    this.description = '',
  });

  factory QuotaData.fromJson(Map<String, dynamic> json) {
    final rawGroups = json['groups'] as List<dynamic>? ?? const [];
    return QuotaData(
      groups: rawGroups
          .whereType<Map>()
          .map((e) => QuotaGroup.fromJson(Map<String, dynamic>.from(e)))
          .toList(),
      description: json['description']?.toString() ?? '',
    );
  }
}

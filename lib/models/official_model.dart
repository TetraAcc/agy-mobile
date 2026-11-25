class OfficialModelOption {
  final String id;
  final String displayName;
  final String group;
  final String thinkingBadge;
  final String icon;
  final double? remainingFraction;
  final String resetTime;
  final bool isDefault;

  const OfficialModelOption({
    required this.id,
    required this.displayName,
    required this.group,
    this.thinkingBadge = "",
    this.icon = "⚡",
    this.remainingFraction,
    this.resetTime = "",
    this.isDefault = false,
  });

  static String iconForGroup(String group) {
    switch (group.toLowerCase()) {
      case 'claude':
        return '🧠';
      case 'orchestrator':
        return '🧭';
      case 'gpt':
        return '🌐';
      case 'gemini':
        return '✦';
      default:
        return '⚡';
    }
  }

  factory OfficialModelOption.fromJson(Map<String, dynamic> json) {
    final id = json['id']?.toString().trim() ?? '';
    final label = (json['label'] ?? json['display_name'])?.toString().trim() ?? '';
    final group = json['group']?.toString().trim() ?? '';
    final tag = (json['tag'] ?? json['thinking_badge'])?.toString().trim() ?? '';
    final remRaw = json['remaining_fraction'] ?? json['remainingFraction'];
    return OfficialModelOption(
      id: id,
      displayName: label.isNotEmpty ? label : formatModelDisplayName(id, const []),
      group: group.isNotEmpty ? group : 'Other',
      thinkingBadge: tag,
      icon: iconForGroup(group),
      remainingFraction: remRaw is num ? remRaw.toDouble() : null,
      resetTime: (json['reset_time'] ?? json['resetTime'])?.toString() ?? '',
      isDefault: json['is_default'] == true,
    );
  }
}

String formatModelDisplayName(String modelId, List<OfficialModelOption> catalog) {
  final clean = modelId.trim();
  if (clean.isEmpty) return '';
  for (final opt in catalog) {
    if (opt.id == clean && opt.displayName.isNotEmpty) {
      return opt.displayName;
    }
  }
  for (final opt in kAllOfficialModels) {
    if (opt.id == clean && opt.displayName.isNotEmpty) {
      return opt.displayName;
    }
  }
  const tierLabels = {
    'xhigh': 'XHigh',
    'high': 'High',
    'medium': 'Medium',
    'low': 'Low',
    'thinking': 'Thinking',
    'tiered': 'Tiered',
  };
  final parts = clean.split('-').where((p) => p.isNotEmpty).toList();
  if (parts.isEmpty) return clean;
  String? trailingTier;
  if (parts.length > 1 && tierLabels.containsKey(parts.last.toLowerCase())) {
    trailingTier = tierLabels[parts.removeLast().toLowerCase()];
  }
  final words = <String>[];
  for (final p in parts) {
    final low = p.toLowerCase();
    if (low == 'gpt') {
      words.add('GPT');
    } else if (low == 'oss') {
      words.add('OSS');
    } else if (low.endsWith('b') && int.tryParse(low.substring(0, low.length - 1)) != null) {
      words.add(low.toUpperCase());
    } else {
      words.add('${p[0].toUpperCase()}${p.substring(1)}');
    }
  }
  final collapsed = <String>[];
  for (var i = 0; i < words.length; i++) {
    if (i + 1 < words.length &&
        int.tryParse(words[i]) != null &&
        int.tryParse(words[i + 1]) != null &&
        words[i + 1].length == 1) {
      collapsed.add('${words[i]}.${words[i + 1]}');
      i += 1;
    } else {
      collapsed.add(words[i]);
    }
  }
  final title = collapsed.join(' ');
  return trailingTier != null ? '$title ($trailingTier)' : title;
}

const List<OfficialModelOption> kAllOfficialModels = [
  OfficialModelOption(
    id: "gemini-4-neon-high",
    displayName: "Gemini 4 Neon (High)",
    group: "Gemini",
    thinkingBadge: "New",
    icon: "✦",
    isDefault: true,
  ),
  OfficialModelOption(
    id: "gemini-4-hydrogen-medium",
    displayName: "Gemini 4 Hydrogen (Medium)",
    group: "Gemini",
    thinkingBadge: "New",
    icon: "✦",
  ),
  OfficialModelOption(
    id: "gemini-4-hydrogen-low",
    displayName: "Gemini 4 Hydrogen (Low)",
    group: "Gemini",
    thinkingBadge: "Fast",
    icon: "✦",
  ),
  OfficialModelOption(
    id: "claude-sonnet-5-5-medium",
    displayName: "Claude Sonnet 5.5 (Medium)",
    group: "Claude",
    thinkingBadge: "New",
    icon: "🧠",
  ),
  OfficialModelOption(
    id: "claude-opus-5-5-medium",
    displayName: "Claude Opus 5.5 (Medium)",
    group: "Claude",
    thinkingBadge: "New",
    icon: "🧠",
  ),
  OfficialModelOption(
    id: "gemini-3.8-flash-high",
    displayName: "Gemini 3.8 Flash (High)",
    group: "Gemini",
    thinkingBadge: "High",
    icon: "⚡",
  ),
  OfficialModelOption(
    id: "gpt-oss-120b-medium",
    displayName: "GPT-OSS 120B (Medium)",
    group: "GPT",
    thinkingBadge: "120B",
    icon: "🌐",
  ),
];

class OfficialModelOption {
  final String id;
  final String displayName;
  final String group;
  final String thinkingBadge;
  final String icon;

  const OfficialModelOption({
    required this.id,
    required this.displayName,
    required this.group,
    this.thinkingBadge = "",
    this.icon = "⚡",
  });
}

const List<OfficialModelOption> kAllOfficialModels = [
  OfficialModelOption(
    id: "gemini-3.8-flash-high",
    displayName: "Gemini 3.8 Flash (高思考)",
    group: "Gemini",
    thinkingBadge: "High",
    icon: "⚡",
  ),
  OfficialModelOption(
    id: "gemini-3.8-flash-medium",
    displayName: "Gemini 3.8 Flash (中思考)",
    group: "Gemini",
    thinkingBadge: "Med",
    icon: "⚡",
  ),
  OfficialModelOption(
    id: "gemini-3.8-flash-low",
    displayName: "Gemini 3.8 Flash (极速)",
    group: "Gemini",
    thinkingBadge: "Low",
    icon: "⚡",
  ),
  OfficialModelOption(
    id: "claude-sonnet-4-6",
    displayName: "Claude Sonnet 4.6",
    group: "Claude",
    thinkingBadge: "Fast",
    icon: "💡",
  ),
  OfficialModelOption(
    id: "claude-opus-4-6-thinking",
    displayName: "Claude Opus 4.6 (思考版)",
    group: "Claude",
    thinkingBadge: "Thinking",
    icon: "🧠",
  ),
  OfficialModelOption(
    id: "gpt-oss-120b-medium",
    displayName: "GPT-OSS 120B (开源旗舰)",
    group: "GPT",
    thinkingBadge: "120B",
    icon: "🌐",
  ),
  OfficialModelOption(
    id: "gemini-2.5-pro",
    displayName: "Gemini 2.5 Pro",
    group: "Gemini",
    thinkingBadge: "Pro",
    icon: "💎",
  ),
];

import 'package:flutter/material.dart';

import '../../models/models.dart';

class SearchHighlightColors {
  static Color background({required bool isDark, required bool isFocused}) {
    if (isFocused) {
      return isDark ? const Color(0xFFF59E0B) : const Color(0xFFF59E0B);
    }
    return isDark ? const Color(0x66FBBF24) : const Color(0x99FDE047);
  }

  static Color foreground({required bool isDark, required bool isFocused}) {
    if (isFocused) {
      return const Color(0xFF111113);
    }
    return isDark ? const Color(0xFFFEF3C7) : const Color(0xFF18181B);
  }

  static Color cardBorder({required bool isDark}) {
    return isDark ? const Color(0xCCF59E0B) : const Color(0xFFD97706);
  }

  static Color cardTint({required bool isDark}) {
    return isDark ? const Color(0x14F59E0B) : const Color(0x14F59E0B);
  }
}

bool messageMatchesSearchQuery(AgentMessage msg, String rawQuery) {
  final query = rawQuery.trim().toLowerCase();
  if (query.isEmpty) return false;
  if (msg.content.toLowerCase().contains(query)) return true;
  if (msg.thinking.toLowerCase().contains(query)) return true;
  return msg.toolCalls.any(
    (tc) =>
        tc.name.toLowerCase().contains(query) ||
        tc.args.values.any((v) => v.toString().toLowerCase().contains(query)),
  );
}

int countSearchOccurrences(String text, String rawQuery) {
  final query = rawQuery.trim().toLowerCase();
  if (query.isEmpty || text.isEmpty) return 0;
  final lower = text.toLowerCase();
  var count = 0;
  var start = 0;
  while (true) {
    final idx = lower.indexOf(query, start);
    if (idx < 0) break;
    count++;
    start = idx + query.length;
  }
  return count;
}

TextSpan buildHighlightedTextSpan({
  required String text,
  required String query,
  required TextStyle baseStyle,
  required bool isDark,
  bool isFocused = false,
}) {
  final trimmed = query.trim();
  if (trimmed.isEmpty || text.isEmpty) {
    return TextSpan(text: text, style: baseStyle);
  }

  final lowerText = text.toLowerCase();
  final lowerQuery = trimmed.toLowerCase();
  final firstIdx = lowerText.indexOf(lowerQuery);
  if (firstIdx < 0) {
    return TextSpan(text: text, style: baseStyle);
  }

  final highlightStyle = baseStyle.copyWith(
    backgroundColor: SearchHighlightColors.background(isDark: isDark, isFocused: isFocused),
    color: SearchHighlightColors.foreground(isDark: isDark, isFocused: isFocused),
    fontWeight: isFocused ? FontWeight.w700 : FontWeight.w600,
  );

  final spans = <InlineSpan>[];
  var cursor = 0;
  var matchIdx = firstIdx;
  while (matchIdx >= 0) {
    if (matchIdx > cursor) {
      spans.add(TextSpan(text: text.substring(cursor, matchIdx), style: baseStyle));
    }
    final end = matchIdx + trimmed.length;
    spans.add(TextSpan(text: text.substring(matchIdx, end), style: highlightStyle));
    cursor = end;
    matchIdx = lowerText.indexOf(lowerQuery, cursor);
  }
  if (cursor < text.length) {
    spans.add(TextSpan(text: text.substring(cursor), style: baseStyle));
  }
  return TextSpan(style: baseStyle, children: spans);
}

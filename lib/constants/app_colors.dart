import 'package:flutter/material.dart';

class AccentThemeOption {
  final String id;
  final String name;
  final Color primary;
  final Color secondary;
  final Color previewColor;

  const AccentThemeOption({
    required this.id,
    required this.name,
    required this.primary,
    required this.secondary,
    required this.previewColor,
  });
}

class AppColors {
  // 深色主题核心色彩
  static const Color darkBg = Color(0xFF0B0F19);
  static const Color darkSurface = Color(0xFF161F30);
  static const Color darkCard = Color(0xFF1E293B);
  static const Color darkBorder = Color(0xFF334155);
  static const Color darkTextPrimary = Color(0xFFF8FAFC);
  static const Color darkTextSecondary = Color(0xFF94A3B8);

  // 浅色主题核心色彩
  static const Color lightBg = Color(0xFFF1F5F9);
  static const Color lightSurface = Color(0xFFFFFFFF);
  static const Color lightCard = Color(0xFFF8FAFC);
  static const Color lightBorder = Color(0xFFE2E8F0);
  static const Color lightTextPrimary = Color(0xFF0F172A);
  static const Color lightTextSecondary = Color(0xFF64748B);

  // 默认强调色（兼顾兼容）
  static const Color primarySky = Color(0xFF38BDF8);
  static const Color primaryBlue = Color(0xFF0284C7);
  static const Color accentCyan = Color(0xFF06B6D4);

  // 状态与指示色
  static const Color onlineGreen = Color(0xFF10B981);
  static const Color offlineRed = Color(0xFFEF4444);
  static const Color warningAmber = Color(0xFFF59E0B);
  static const Color thinkingPurple = Color(0xFFA855F7);

  // 强调色主题矩阵
  static const List<AccentThemeOption> accentThemes = [
    AccentThemeOption(
      id: 'emerald',
      name: '翡翠绿 (护眼极客)',
      primary: Color(0xFF10B981),
      secondary: Color(0xFF34D399),
      previewColor: Color(0xFF10B981),
    ),
    AccentThemeOption(
      id: 'teal',
      name: '青竹绿 (北欧温润)',
      primary: Color(0xFF0D9488),
      secondary: Color(0xFF2DD4BF),
      previewColor: Color(0xFF0D9488),
    ),
    AccentThemeOption(
      id: 'violet',
      name: '紫罗兰 (温和沉浸)',
      primary: Color(0xFF8B5CF6),
      secondary: Color(0xFFA78BFA),
      previewColor: Color(0xFF8B5CF6),
    ),
    AccentThemeOption(
      id: 'amber',
      name: '暖琥珀 (夜间护眼)',
      primary: Color(0xFFF59E0B),
      secondary: Color(0xFFFBBF24),
      previewColor: Color(0xFFF59E0B),
    ),
    AccentThemeOption(
      id: 'blue',
      name: '科技蓝 (经典冷调)',
      primary: Color(0xFF0284C7),
      secondary: Color(0xFF38BDF8),
      previewColor: Color(0xFF0284C7),
    ),
  ];

  static AccentThemeOption getThemeById(String id) {
    return accentThemes.firstWhere((t) => t.id == id, orElse: () => accentThemes.first);
  }
}

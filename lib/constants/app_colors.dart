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
  static const Color primarySky = Color(0xFF89B4FA);
  static const Color primaryBlue = Color(0xFF88C0D0);
  static const Color accentCyan = Color(0xFF94E2D5);

  // 状态与指示色
  static const Color onlineGreen = Color(0xFFA6E3A1);
  static const Color offlineRed = Color(0xFFF38BA8);
  static const Color warningAmber = Color(0xFFFAB387);
  static const Color thinkingPurple = Color(0xFFCBA6F7);

  // 权威护眼强调色主题矩阵（源自 Catppuccin Mocha & Nord 柔雾护眼体系）
  static const List<AccentThemeOption> accentThemes = [
    AccentThemeOption(
      id: 'emerald',
      name: '抹茶柔绿 (Catppuccin)',
      primary: Color(0xFFA6E3A1), // 极其温润的自然草本绿，彻底消除眩光
      secondary: Color(0xFF94E2D5),
      previewColor: Color(0xFFA6E3A1),
    ),
    AccentThemeOption(
      id: 'amber',
      name: '蜜桃暖杏 (Catppuccin)',
      primary: Color(0xFFFAB387), // 柔和奶杏暖光，夜间低蓝光最舒适
      secondary: Color(0xFFF9E2AF),
      previewColor: Color(0xFFFAB387),
    ),
    AccentThemeOption(
      id: 'nord_amber',
      name: '麦芒柔金 (Nord)',
      primary: Color(0xFFEBCB8B), // 极光麦浪暗金，不含高亮刺眼白光
      secondary: Color(0xFFD08770),
      previewColor: Color(0xFFEBCB8B),
    ),
    AccentThemeOption(
      id: 'teal',
      name: '霜雪湖蓝 (Nord)',
      primary: Color(0xFF88C0D0), // 北欧冰霜灰蓝，克制清爽不刺眼
      secondary: Color(0xFF81A1C1),
      previewColor: Color(0xFF88C0D0),
    ),
    AccentThemeOption(
      id: 'violet',
      name: '薰衣草雾紫 (Catppuccin)',
      primary: Color(0xFFCBA6F7), // 典雅低饱和粉紫，沉浸不张扬
      secondary: Color(0xFFB4BEFE),
      previewColor: Color(0xFFCBA6F7),
    ),
    AccentThemeOption(
      id: 'blue',
      name: '雾霾天青 (Catppuccin)',
      primary: Color(0xFF89B4FA), // 柔化天青蓝，彻底消除传统深蓝的高光刺痛感
      secondary: Color(0xFF74C7EC),
      previewColor: Color(0xFF89B4FA),
    ),
  ];

  static AccentThemeOption getThemeById(String id) {
    return accentThemes.firstWhere((t) => t.id == id, orElse: () => accentThemes.first);
  }
}

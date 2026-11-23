import 'package:flutter/material.dart';

class AccentThemeOption {
  final String id;
  final String name;
  final Color primary;
  final Color secondary;
  final Color previewColor;
  final Color lightPrimary;
  final Color lightSecondary;
  final Color lightPreviewColor;

  const AccentThemeOption({
    required this.id,
    required this.name,
    required this.primary,
    required this.secondary,
    required this.previewColor,
    required this.lightPrimary,
    required this.lightSecondary,
    required this.lightPreviewColor,
  });

  Color primaryFor(bool isDark) => isDark ? primary : lightPrimary;
  Color secondaryFor(bool isDark) => isDark ? secondary : lightSecondary;
  Color previewFor(bool isDark) => isDark ? previewColor : lightPreviewColor;
}

class AppColors {
  static const Color darkBg = Color(0xFF111113);
  static const Color darkSurface = Color(0xFF18181B);
  static const Color darkCard = Color(0xFF222226);
  static const Color darkBorder = Color(0xFF2C2C32);
  static const Color darkTextPrimary = Color(0xFFF4F4F5);
  static const Color darkTextSecondary = Color(0xFFA1A1AA);

  static const Color lightBg = Color(0xFFFFFFFF);
  static const Color lightSurface = Color(0xFFF8F8F9);
  static const Color lightCard = Color(0xFFF2F2F4);
  static const Color lightBorder = Color(0xFFE4E4E7);
  static const Color lightTextPrimary = Color(0xFF18181B);
  static const Color lightTextSecondary = Color(0xFF71717A);

  static const Color primarySky = Color(0xFF89B4FA);
  static const Color primaryBlue = Color(0xFF88C0D0);
  static const Color accentCyan = Color(0xFF94E2D5);

  static const Color onlineGreen = Color(0xFFA6E3A1);
  static const Color offlineRed = Color(0xFFF38BA8);
  static const Color warningAmber = Color(0xFFFAB387);
  static const Color thinkingPurple = Color(0xFFCBA6F7);

  static Color statusGreen(bool isDark) => isDark ? Colors.greenAccent : const Color(0xFF15803D);
  static Color statusAmber(bool isDark) => isDark ? Colors.amberAccent : const Color(0xFFB45309);
  static Color statusRed(bool isDark) => isDark ? Colors.redAccent : const Color(0xFFDC2626);

  static const List<AccentThemeOption> accentThemes = [
    AccentThemeOption(
      id: 'emerald',
      name: '抹茶柔绿 (Catppuccin)',
      primary: Color(0xFFA6E3A1),
      secondary: Color(0xFF94E2D5),
      previewColor: Color(0xFFA6E3A1),
      lightPrimary: Color(0xFF1E7E3E),
      lightSecondary: Color(0xFF177E78),
      lightPreviewColor: Color(0xFF1E7E3E),
    ),
    AccentThemeOption(
      id: 'amber',
      name: '蜜桃暖杏 (Catppuccin)',
      primary: Color(0xFFFAB387),
      secondary: Color(0xFFF9E2AF),
      previewColor: Color(0xFFFAB387),
      lightPrimary: Color(0xFFC24E10),
      lightSecondary: Color(0xFFB45309),
      lightPreviewColor: Color(0xFFC24E10),
    ),
    AccentThemeOption(
      id: 'nord_amber',
      name: '麦芒柔金 (Nord)',
      primary: Color(0xFFEBCB8B),
      secondary: Color(0xFFD08770),
      previewColor: Color(0xFFEBCB8B),
      lightPrimary: Color(0xFF9A6700),
      lightSecondary: Color(0xFFA85432),
      lightPreviewColor: Color(0xFF9A6700),
    ),
    AccentThemeOption(
      id: 'teal',
      name: '霜雪湖蓝 (Nord)',
      primary: Color(0xFF88C0D0),
      secondary: Color(0xFF81A1C1),
      previewColor: Color(0xFF88C0D0),
      lightPrimary: Color(0xFF1B6E84),
      lightSecondary: Color(0xFF3B6287),
      lightPreviewColor: Color(0xFF1B6E84),
    ),
    AccentThemeOption(
      id: 'violet',
      name: '薰衣草雾紫 (Catppuccin)',
      primary: Color(0xFFCBA6F7),
      secondary: Color(0xFFB4BEFE),
      previewColor: Color(0xFFCBA6F7),
      lightPrimary: Color(0xFF6D3EC7),
      lightSecondary: Color(0xFF4E58C8),
      lightPreviewColor: Color(0xFF6D3EC7),
    ),
    AccentThemeOption(
      id: 'blue',
      name: '雾霾天青 (Catppuccin)',
      primary: Color(0xFF89B4FA),
      secondary: Color(0xFF74C7EC),
      previewColor: Color(0xFF89B4FA),
      lightPrimary: Color(0xFF1D5CD6),
      lightSecondary: Color(0xFF196B96),
      lightPreviewColor: Color(0xFF1D5CD6),
    ),
  ];

  static AccentThemeOption getThemeById(String id) {
    return accentThemes.firstWhere((t) => t.id == id, orElse: () => accentThemes.first);
  }
}

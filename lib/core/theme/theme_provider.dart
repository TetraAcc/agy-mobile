import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'app_colors.dart';

class ThemeState {
  final ThemeMode themeMode;
  final AccentThemeOption accent;

  const ThemeState({
    this.themeMode = ThemeMode.dark,
    required this.accent,
  });

  ThemeState copyWith({ThemeMode? themeMode, AccentThemeOption? accent}) {
    return ThemeState(
      themeMode: themeMode ?? this.themeMode,
      accent: accent ?? this.accent,
    );
  }
}

class ThemeController extends Notifier<ThemeState> {
  static const _darkModeKey = 'is_dark_mode';
  static const _accentKey = 'accent_theme';

  @override
  ThemeState build() {
    _loadPrefs();
    return ThemeState(themeMode: ThemeMode.dark, accent: AppColors.accentThemes.first);
  }

  Future<void> _loadPrefs() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final isDark = prefs.getBool(_darkModeKey) ?? true;
      final accentId = prefs.getString(_accentKey) ?? 'emerald';
      state = ThemeState(
        themeMode: isDark ? ThemeMode.dark : ThemeMode.light,
        accent: AppColors.getThemeById(accentId),
      );
    } catch (_) {}
  }

  Future<void> setDarkMode(bool isDark) async {
    state = state.copyWith(themeMode: isDark ? ThemeMode.dark : ThemeMode.light);
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(_darkModeKey, isDark);
    } catch (_) {}
  }

  Future<void> setAccentTheme(AccentThemeOption option) async {
    state = state.copyWith(accent: option);
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_accentKey, option.id);
    } catch (_) {}
  }
}

final themeProvider = NotifierProvider<ThemeController, ThemeState>(ThemeController.new);

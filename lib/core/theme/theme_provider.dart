import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../config/server_config.dart';
import 'app_colors.dart';
import 'app_fonts.dart';
import 'font_loader_service.dart';

class ThemeState {
  static const double minFontScale = 0.80;
  static const double maxFontScale = 1.60;
  static const double defaultFontScale = 1.0;
  static const double fontScaleStep = 0.05;

  static double clampFontScale(double value) {
    final clamped = value.clamp(minFontScale, maxFontScale).toDouble();
    return (clamped * 100).round() / 100.0;
  }

  final ThemeMode themeMode;
  final AccentThemeOption accent;
  final AppFontOption font;
  final double fontScale;
  final String? loadingFontId;
  final int fontRevision;

  const ThemeState({
    this.themeMode = ThemeMode.dark,
    required this.accent,
    this.font = AppFonts.system,
    this.fontScale = defaultFontScale,
    this.loadingFontId,
    this.fontRevision = 0,
  });

  ThemeState copyWith({
    ThemeMode? themeMode,
    AccentThemeOption? accent,
    AppFontOption? font,
    double? fontScale,
    String? loadingFontId,
    bool clearLoadingFont = false,
    int? fontRevision,
  }) {
    return ThemeState(
      themeMode: themeMode ?? this.themeMode,
      accent: accent ?? this.accent,
      font: font ?? this.font,
      fontScale: fontScale != null ? clampFontScale(fontScale) : this.fontScale,
      loadingFontId: clearLoadingFont ? null : (loadingFontId ?? this.loadingFontId),
      fontRevision: fontRevision ?? this.fontRevision,
    );
  }
}

class ThemeController extends Notifier<ThemeState> {
  static const _darkModeKey = 'is_dark_mode';
  static const _accentKey = 'accent_theme';
  static const _fontKey = 'app_font_id';
  static const _fontScaleKey = 'app_font_scale';

  @override
  ThemeState build() {
    unawaited(_loadPrefs());
    return ThemeState(
      themeMode: ThemeMode.dark,
      accent: AppColors.accentThemes.first,
      font: AppFonts.system,
    );
  }

  Future<void> _loadPrefs() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final isDark = prefs.getBool(_darkModeKey) ?? true;
      final accentId = prefs.getString(_accentKey) ?? 'emerald';
      final fontOpt = AppFonts.getById(prefs.getString(_fontKey));
      final savedScale = prefs.getDouble(_fontScaleKey);
      state = state.copyWith(
        themeMode: isDark ? ThemeMode.dark : ThemeMode.light,
        accent: AppColors.getThemeById(accentId),
        font: fontOpt,
        fontScale: savedScale != null ? ThemeState.clampFontScale(savedScale) : null,
      );
      if (fontOpt.remoteFile != null) {
        final serverCfg = await ServerConfig.load();
        final loaded = await FontLoaderService.ensureLoaded(
          fontOpt,
          baseUrl: serverCfg.baseUrl,
        );
        if (loaded && state.font.id == fontOpt.id) {
          state = state.copyWith(fontRevision: state.fontRevision + 1);
        }
      }
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

  Future<bool> setFont(AppFontOption option, {required String baseUrl}) async {
    if (option.remoteFile == null) {
      state = state.copyWith(
        font: option,
        clearLoadingFont: true,
        fontRevision: state.fontRevision + 1,
      );
      try {
        final prefs = await SharedPreferences.getInstance();
        await prefs.setString(_fontKey, option.id);
      } catch (_) {}
      return true;
    }

    state = state.copyWith(loadingFontId: option.id);
    final loaded = await FontLoaderService.ensureLoaded(option, baseUrl: baseUrl);
    state = state.copyWith(
      font: option,
      clearLoadingFont: true,
      fontRevision: state.fontRevision + 1,
    );
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_fontKey, option.id);
    } catch (_) {}
    return loaded;
  }

  Future<void> setFontScale(double scale) async {
    final next = ThemeState.clampFontScale(scale);
    if ((state.fontScale - next).abs() < 0.001) return;
    state = state.copyWith(fontScale: next);
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setDouble(_fontScaleKey, next);
    } catch (_) {}
  }

  Future<void> stepFontScale(double delta) => setFontScale(state.fontScale + delta);

  Future<void> resetFontScale() => setFontScale(ThemeState.defaultFontScale);
}

final themeProvider = NotifierProvider<ThemeController, ThemeState>(ThemeController.new);

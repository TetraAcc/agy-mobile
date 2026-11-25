import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'core/platform/platform_bridge.dart';
import 'core/theme/app_colors.dart';
import 'core/theme/theme_provider.dart';
import 'features/auth/auth_controller.dart';
import 'features/auth/login_screen.dart';
import 'features/hub/home_screen.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  if (!kIsWeb && defaultTargetPlatform == TargetPlatform.android) {
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
  }
  runApp(const ProviderScope(child: AgyRemoteApp()));
}

class AgyRemoteApp extends ConsumerStatefulWidget {
  const AgyRemoteApp({super.key});

  @override
  ConsumerState<AgyRemoteApp> createState() => _AgyRemoteAppState();
}

class _AgyRemoteAppState extends ConsumerState<AgyRemoteApp> {
  VoidCallback? _disposeWebZoom;
  Timer? _zoomToastTimer;
  bool _showZoomBadge = false;
  int _zoomBadgePercent = 100;

  @override
  void initState() {
    super.initState();
    if (kIsWeb) {
      _disposeWebZoom = PlatformBridge.registerWebZoomShortcuts(
        onStepZoom: (delta) {
          final current = ref.read(themeProvider).fontScale;
          final target = ThemeState.clampFontScale(current + delta);
          unawaited(ref.read(themeProvider.notifier).setFontScale(target));
          _triggerZoomBadge(target);
        },
        onResetZoom: () {
          unawaited(ref.read(themeProvider.notifier).resetFontScale());
          _triggerZoomBadge(ThemeState.defaultFontScale);
        },
      );
    }
  }

  @override
  void dispose() {
    _zoomToastTimer?.cancel();
    _disposeWebZoom?.call();
    super.dispose();
  }

  void _triggerZoomBadge(double scale) {
    if (!mounted) return;
    setState(() {
      _zoomBadgePercent = (scale * 100).round();
      _showZoomBadge = true;
    });
    _zoomToastTimer?.cancel();
    _zoomToastTimer = Timer(const Duration(milliseconds: 1200), () {
      if (mounted) {
        setState(() => _showZoomBadge = false);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final themeState = ref.watch(themeProvider);
    final authState = ref.watch(authControllerProvider);

    return MaterialApp(
      title: 'AGY Remote Hub',
      debugShowCheckedModeBanner: false,
      themeMode: themeState.themeMode,
      builder: (ctx, child) {
        final isDark = Theme.of(ctx).brightness == Brightness.dark;
        final mediaQuery = MediaQuery.of(ctx);
        final combinedFactor =
            (mediaQuery.textScaler.scale(1.0) * themeState.fontScale).clamp(0.75, 2.2).toDouble();
        final overlayStyle = SystemUiOverlayStyle(
          statusBarColor: Colors.transparent,
          statusBarIconBrightness: isDark ? Brightness.light : Brightness.dark,
          statusBarBrightness: isDark ? Brightness.dark : Brightness.light,
          systemNavigationBarColor: Colors.transparent,
          systemNavigationBarDividerColor: Colors.transparent,
          systemNavigationBarIconBrightness: isDark ? Brightness.light : Brightness.dark,
          systemNavigationBarContrastEnforced: false,
        );
        return AnnotatedRegion<SystemUiOverlayStyle>(
          value: overlayStyle,
          child: Stack(
            children: [
              MediaQuery(
                data: mediaQuery.copyWith(textScaler: TextScaler.linear(combinedFactor)),
                child: child ?? const SizedBox.shrink(),
              ),
              if (_showZoomBadge)
                Positioned(
                  top: mediaQuery.padding.top + 14,
                  left: 0,
                  right: 0,
                  child: IgnorePointer(
                    child: Center(
                      child: AnimatedOpacity(
                        opacity: _showZoomBadge ? 1.0 : 0.0,
                        duration: const Duration(milliseconds: 160),
                        child: Container(
                          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
                          decoration: BoxDecoration(
                            color: (isDark ? const Color(0xFF202026) : const Color(0xFF18181B))
                                .withValues(alpha: 0.92),
                            borderRadius: BorderRadius.circular(20),
                            border: Border.all(
                              color: Colors.white.withValues(alpha: 0.14),
                            ),
                            boxShadow: [
                              BoxShadow(
                                color: Colors.black.withValues(alpha: 0.24),
                                blurRadius: 12,
                                offset: const Offset(0, 4),
                              ),
                            ],
                          ),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(
                                Icons.format_size_rounded,
                                size: 15,
                                color: Theme.of(ctx).colorScheme.primary,
                              ),
                              const SizedBox(width: 6),
                              Text(
                                '字号 $_zoomBadgePercent%',
                                style: const TextStyle(
                                  fontSize: 12.5,
                                  fontWeight: FontWeight.w600,
                                  color: Colors.white,
                                  decoration: TextDecoration.none,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
            ],
          ),
        );
      },
      theme: ThemeData(
        useMaterial3: true,
        brightness: Brightness.light,
        fontFamily: themeState.font.fontFamily,
        fontFamilyFallback: themeState.font.fallbacks.isEmpty ? null : themeState.font.fallbacks,
        scaffoldBackgroundColor: AppColors.lightBg,
        colorScheme: ColorScheme.light(
          primary: themeState.accent.lightPrimary,
          onPrimary: Colors.white,
          secondary: themeState.accent.lightSecondary,
          onSecondary: Colors.white,
          surface: AppColors.lightBg,
        ),
      ),
      darkTheme: ThemeData(
        useMaterial3: true,
        brightness: Brightness.dark,
        fontFamily: themeState.font.fontFamily,
        fontFamilyFallback: themeState.font.fallbacks.isEmpty ? null : themeState.font.fallbacks,
        scaffoldBackgroundColor: AppColors.darkBg,
        colorScheme: ColorScheme.dark(
          primary: themeState.accent.primary,
          onPrimary: const Color(0xFF111113),
          secondary: themeState.accent.secondary,
          onSecondary: const Color(0xFF111113),
          surface: AppColors.darkBg,
        ),
      ),
      home: switch (authState.status) {
        AuthStatus.checking => const _AuthCheckingView(),
        AuthStatus.unauthenticated => const LoginScreen(),
        AuthStatus.authenticated => HomeScreen(user: authState.user!),
      },
    );
  }
}

class _AuthCheckingView extends StatelessWidget {
  const _AuthCheckingView();

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Scaffold(
      backgroundColor: isDark ? AppColors.darkBg : AppColors.lightBg,
      body: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            CircularProgressIndicator(color: Theme.of(context).colorScheme.primary),
            const SizedBox(height: 16),
            Text(
              '正在验证会话凭证...',
              style: TextStyle(
                fontSize: 13,
                color: isDark ? Colors.white54 : Colors.black54,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

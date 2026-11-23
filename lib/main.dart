import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

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

class AgyRemoteApp extends ConsumerWidget {
  const AgyRemoteApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final themeState = ref.watch(themeProvider);
    final authState = ref.watch(authControllerProvider);

    return MaterialApp(
      title: 'AGY Remote Hub',
      debugShowCheckedModeBanner: false,
      themeMode: themeState.themeMode,
      builder: (ctx, child) {
        final isDark = Theme.of(ctx).brightness == Brightness.dark;
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
          child: child ?? const SizedBox.shrink(),
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

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme/app_colors.dart';
import 'auth_controller.dart';

class LoginScreen extends ConsumerStatefulWidget {
  const LoginScreen({super.key});

  @override
  ConsumerState<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends ConsumerState<LoginScreen> {
  final _usernameController = TextEditingController();
  final _passwordController = TextEditingController();
  final _serverUrlController = TextEditingController();
  bool _obscurePassword = true;
  bool _showServerField = !kIsWeb;

  @override
  void initState() {
    super.initState();
    _serverUrlController.text = ref.read(authControllerProvider).serverConfig.baseUrl;
  }

  @override
  void dispose() {
    _usernameController.dispose();
    _passwordController.dispose();
    _serverUrlController.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final notifier = ref.read(authControllerProvider.notifier);
    final username = _usernameController.text;
    final password = _passwordController.text;
    if (username.trim().isNotEmpty && password.trim().isNotEmpty && (_showServerField || !kIsWeb)) {
      await notifier.updateServerUrl(_serverUrlController.text);
    }
    await notifier.login(
      username: username,
      password: password,
    );
  }

  @override
  Widget build(BuildContext context) {
    final auth = ref.watch(authControllerProvider);
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final bgColor = isDark ? AppColors.darkBg : AppColors.lightBg;
    final fieldFill = isDark ? const Color(0xFF18181B) : const Color(0xFFF5F5F7);
    final borderColor = isDark ? const Color(0xFF2C2C32) : const Color(0xFFE4E4E7);
    final textColor = isDark ? AppColors.darkTextPrimary : AppColors.lightTextPrimary;
    final mutedColor = isDark ? AppColors.darkTextSecondary : AppColors.lightTextSecondary;

    InputDecoration inputDec({
      required String label,
      required String hint,
      required IconData icon,
      Widget? suffixIcon,
    }) {
      return InputDecoration(
        labelText: label,
        hintText: hint,
        labelStyle: TextStyle(color: mutedColor, fontSize: 13.5),
        hintStyle: TextStyle(color: mutedColor.withValues(alpha: 0.6), fontSize: 13.5),
        prefixIcon: Icon(icon, size: 19, color: mutedColor),
        suffixIcon: suffixIcon,
        filled: true,
        fillColor: fieldFill,
        contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide(color: borderColor),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide(color: borderColor),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide(color: isDark ? Colors.white70 : Colors.black87, width: 1.2),
        ),
      );
    }

    return Scaffold(
      backgroundColor: bgColor,
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 32),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 380),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Center(
                    child: Container(
                      width: 48,
                      height: 48,
                      decoration: BoxDecoration(
                        color: isDark ? const Color(0xFF18181B) : const Color(0xFFF4F4F5),
                        borderRadius: BorderRadius.circular(14),
                        border: Border.all(color: borderColor),
                      ),
                      child: Icon(
                        Icons.change_history_rounded,
                        color: textColor,
                        size: 24,
                      ),
                    ),
                  ),
                  const SizedBox(height: 18),
                  Text(
                    'AGY Remote',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      fontSize: 22,
                      fontWeight: FontWeight.w600,
                      letterSpacing: -0.3,
                      color: textColor,
                    ),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    '登录工作台以连接受控主机',
                    textAlign: TextAlign.center,
                    style: TextStyle(fontSize: 13, color: mutedColor),
                  ),
                  const SizedBox(height: 28),

                  if (auth.errorMessage.isNotEmpty) ...[
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                      decoration: BoxDecoration(
                        color: Colors.redAccent.withValues(alpha: 0.10),
                        borderRadius: BorderRadius.circular(10),
                        border: Border.all(color: Colors.redAccent.withValues(alpha: 0.35)),
                      ),
                      child: Row(
                        children: [
                          const Icon(Icons.error_outline_rounded, color: Colors.redAccent, size: 16),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              auth.errorMessage,
                              style: const TextStyle(color: Colors.redAccent, fontSize: 12.5),
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 16),
                  ],

                  TextField(
                    controller: _usernameController,
                    textInputAction: TextInputAction.next,
                    style: TextStyle(color: textColor, fontSize: 14.5),
                    decoration: inputDec(
                      label: '账号',
                      hint: '请输入用户名',
                      icon: Icons.person_outline_rounded,
                    ),
                  ),
                  const SizedBox(height: 14),

                  TextField(
                    controller: _passwordController,
                    obscureText: _obscurePassword,
                    textInputAction: TextInputAction.done,
                    onSubmitted: (_) => auth.isLoading ? null : _submit(),
                    style: TextStyle(color: textColor, fontSize: 14.5),
                    decoration: inputDec(
                      label: '密码',
                      hint: '请输入密码',
                      icon: Icons.lock_outline_rounded,
                      suffixIcon: IconButton(
                        icon: Icon(
                          _obscurePassword
                              ? Icons.visibility_off_outlined
                              : Icons.visibility_outlined,
                          size: 19,
                          color: mutedColor,
                        ),
                        onPressed: () => setState(() => _obscurePassword = !_obscurePassword),
                      ),
                    ),
                  ),
                  const SizedBox(height: 10),

                  Align(
                    alignment: Alignment.centerRight,
                    child: TextButton.icon(
                      onPressed: () => setState(() => _showServerField = !_showServerField),
                      icon: Icon(
                        _showServerField ? Icons.expand_less_rounded : Icons.dns_outlined,
                        size: 15,
                        color: mutedColor,
                      ),
                      label: Text(
                        _showServerField ? '收起服务器设置' : '网关: ${auth.serverConfig.baseUrl}',
                        style: TextStyle(fontSize: 12, color: mutedColor),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ),

                  if (_showServerField) ...[
                    TextField(
                      controller: _serverUrlController,
                      keyboardType: TextInputType.url,
                      style: TextStyle(color: textColor, fontSize: 13.5),
                      decoration: inputDec(
                        label: '网关地址',
                        hint: 'https://agy.example.com',
                        icon: Icons.link_rounded,
                      ),
                    ),
                    const SizedBox(height: 14),
                  ],

                  const SizedBox(height: 10),
                  FilledButton(
                    onPressed: auth.isLoading ? null : _submit,
                    style: FilledButton.styleFrom(
                      backgroundColor: isDark ? const Color(0xFFF4F4F5) : const Color(0xFF18181B),
                      foregroundColor: isDark ? const Color(0xFF111113) : Colors.white,
                      padding: const EdgeInsets.symmetric(vertical: 15),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                    ),
                    child: auth.isLoading
                        ? SizedBox(
                            width: 20,
                            height: 20,
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              color: isDark ? const Color(0xFF111113) : Colors.white,
                            ),
                          )
                        : const Text(
                            '立即登录',
                            style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
                          ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/config/app_update_service.dart';
import '../../core/config/composer_prefs.dart';
import '../../core/network/api_client.dart';
import '../../core/platform/android_native_bridge.dart';
import '../../core/platform/platform_bridge.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/app_fonts.dart';
import '../../core/theme/theme_provider.dart';
import '../../models/models.dart';
import '../auth/auth_controller.dart' show apiClientProvider;
import '../hub/download_progress_dialog.dart';
import '../hub/hub_controller.dart';

enum SettingsCategory {
  appearance,
  input,
  node,
  network,
  account,
}

class _SettingsCategoryMeta {
  final SettingsCategory category;
  final String title;
  final IconData icon;

  const _SettingsCategoryMeta({
    required this.category,
    required this.title,
    required this.icon,
  });
}

const List<_SettingsCategoryMeta> _kSettingsCategories = [
  _SettingsCategoryMeta(
    category: SettingsCategory.appearance,
    title: '外观与显示',
    icon: Icons.palette_outlined,
  ),
  _SettingsCategoryMeta(
    category: SettingsCategory.input,
    title: '消息与输入',
    icon: Icons.keyboard_outlined,
  ),
  _SettingsCategoryMeta(
    category: SettingsCategory.node,
    title: '节点控制',
    icon: Icons.dns_outlined,
  ),
  _SettingsCategoryMeta(
    category: SettingsCategory.network,
    title: '连接与通知',
    icon: Icons.hub_outlined,
  ),
  _SettingsCategoryMeta(
    category: SettingsCategory.account,
    title: '账号与关于',
    icon: Icons.person_outline_rounded,
  ),
];

class SettingsView extends ConsumerStatefulWidget {
  static const double splitPaneBreakpoint = 720.0;

  final SettingsCategory? initialCategory;
  final bool isSplitPane;
  final UserProfile user;
  final String currentUrl;
  final String currentAppVersion;
  final AppReleaseInfo? initialAppUpdate;
  final ValueChanged<AppReleaseInfo?>? onUpdateBadgeChanged;
  final Future<void> Function(String newUrl) onSaveUrl;
  final VoidCallback onLogout;

  const SettingsView({
    super.key,
    this.initialCategory,
    required this.isSplitPane,
    required this.user,
    required this.currentUrl,
    this.currentAppVersion = kFallbackAppVersion,
    this.initialAppUpdate,
    this.onUpdateBadgeChanged,
    required this.onSaveUrl,
    required this.onLogout,
  });

  static Future<void> open(
    BuildContext context, {
    SettingsCategory? initialCategory,
    required UserProfile user,
    required String currentUrl,
    String currentAppVersion = kFallbackAppVersion,
    AppReleaseInfo? initialAppUpdate,
    ValueChanged<AppReleaseInfo?>? onUpdateBadgeChanged,
    required Future<void> Function(String newUrl) onSaveUrl,
    required VoidCallback onLogout,
  }) {
    final size = MediaQuery.sizeOf(context);
    if (size.width >= splitPaneBreakpoint) {
      final dialogW = (size.width - 48).clamp(480.0, 780.0);
      final dialogH = (size.height - 48).clamp(420.0, 620.0);
      return showDialog<void>(
        context: context,
        builder: (_) => Dialog(
          backgroundColor: Theme.of(context).brightness == Brightness.dark
              ? const Color(0xFF18181B)
              : Colors.white,
          insetPadding: const EdgeInsets.symmetric(horizontal: 24, vertical: 24),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
          clipBehavior: Clip.antiAlias,
          child: SizedBox(
            width: dialogW,
            height: dialogH,
            child: SettingsView(
              initialCategory: initialCategory,
              isSplitPane: true,
              user: user,
              currentUrl: currentUrl,
              currentAppVersion: currentAppVersion,
              initialAppUpdate: initialAppUpdate,
              onUpdateBadgeChanged: onUpdateBadgeChanged,
              onSaveUrl: onSaveUrl,
              onLogout: onLogout,
            ),
          ),
        ),
      );
    }

    return Navigator.of(context).push<void>(
      MaterialPageRoute(
        builder: (_) => SettingsView(
          initialCategory: initialCategory,
          isSplitPane: false,
          user: user,
          currentUrl: currentUrl,
          currentAppVersion: currentAppVersion,
          initialAppUpdate: initialAppUpdate,
          onUpdateBadgeChanged: onUpdateBadgeChanged,
          onSaveUrl: onSaveUrl,
          onLogout: onLogout,
        ),
      ),
    );
  }

  @override
  ConsumerState<SettingsView> createState() => _SettingsViewState();
}

class _SettingsViewState extends ConsumerState<SettingsView> {
  late SettingsCategory _selectedCategory;
  late bool _showMobileDetail;

  late final TextEditingController _urlController;
  late String _savedUrl;
  bool _savingUrl = false;

  bool _loadingNotifyStatus = true;
  bool _discordConfigured = false;
  double _notifyMinRunSeconds = 15;
  double _notifyAskDelaySeconds = 10;
  bool _sendingTestNotify = false;

  late String _appVersion;
  AppReleaseInfo? _latestRelease;
  bool _checkingAppUpdate = false;
  bool _appUpdateChecked = false;
  String? _appUpdateError;
  String? _downloadedApkPath;
  bool _installingApk = false;

  bool _loadingAdminNodes = false;
  List<HostNode> _adminNodes = const [];
  final Map<String, NodeUpdateStatus> _nodeUpdateStatuses = {};
  final Map<String, String> _nodeUpdateErrors = {};
  final Set<String> _checkingNodeIds = {};
  final Set<String> _updatingNodeIds = {};
  String _selectedPowerAction = 'shutdown';

  bool get _isAdmin => widget.user.role == 'admin';

  @override
  void initState() {
    super.initState();
    _selectedCategory = widget.initialCategory ?? SettingsCategory.appearance;
    _showMobileDetail = !widget.isSplitPane && widget.initialCategory != null;
    _savedUrl = widget.currentUrl;
    _urlController = TextEditingController(text: widget.currentUrl);
    _appVersion = widget.currentAppVersion;
    _latestRelease = widget.initialAppUpdate;
    _appUpdateChecked = widget.initialAppUpdate != null;

    final initialPower = ref.read(hubControllerProvider).nodePowerStatus;
    if (initialPower != null && initialPower.enabled) {
      _selectedPowerAction = initialPower.action;
    }

    _loadNotifyStatus();
    unawaited(ref.read(hubControllerProvider.notifier).refreshNodePowerStatus());
    if (AndroidNativeBridge.isAndroidNative) {
      unawaited(_initAppUpdateSection());
    }
    if (_isAdmin) {
      _loadAdminNodes();
    }
  }

  @override
  void dispose() {
    _urlController.dispose();
    super.dispose();
  }

  Future<void> _initAppUpdateSection() async {
    final ver = await AppUpdateService.resolveCurrentVersion();
    if (!mounted) return;
    setState(() => _appVersion = ver);
    if (_latestRelease == null) {
      await _checkAppUpdate(force: false);
    }
  }

  Future<void> _checkAppUpdate({required bool force}) async {
    if (_checkingAppUpdate) return;
    setState(() {
      _checkingAppUpdate = true;
      _appUpdateError = null;
    });
    try {
      final info = await ref.read(apiClientProvider).getAppLatestRelease(force: force);
      if (!mounted) return;
      final hasNew = isAppUpdateAvailable(_appVersion, info.latestVersion);
      if (hasNew && force) {
        await AppUpdateService.clearIgnoredVersion();
      }
      setState(() {
        _latestRelease = info;
        _appUpdateChecked = true;
        _checkingAppUpdate = false;
        if (info.error.isNotEmpty && info.source == 'gateway_fallback') {
          _appUpdateError = '暂未连接到 GitHub Releases：${info.error}';
        }
      });
      widget.onUpdateBadgeChanged?.call(hasNew ? info : null);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _checkingAppUpdate = false;
        _appUpdateChecked = true;
        _appUpdateError = '检查版本失败: $e';
      });
    }
  }

  String _formatApkSize(int bytes) {
    if (bytes <= 0) return '';
    if (bytes >= 1048576) {
      return '${(bytes / 1048576).toStringAsFixed(1)} MB';
    }
    if (bytes >= 1024) {
      return '${(bytes / 1024).toStringAsFixed(0)} KB';
    }
    return '$bytes B';
  }

  Future<void> _downloadAndInstallApk(AppReleaseInfo release) async {
    if (_installingApk) return;
    if (_downloadedApkPath != null) {
      await _triggerInstallApk(_downloadedApkPath!, release);
      return;
    }
    if (release.apkUrl.trim().isEmpty) {
      await PlatformBridge.openExternalUrl(release.htmlUrl);
      return;
    }
    setState(() {
      _installingApk = true;
      _appUpdateError = null;
    });
    try {
      final dl = await runWithDownloadProgressDialog<({String? path, String? error, bool cancelled})>(
        context: context,
        autoOpen: false,
        titleOverride: '正在下载新版安装包...',
        formatBytes: _formatApkSize,
        task: (onProgress, cancelToken) => AppUpdateService.downloadApkToCache(
          apkUrl: release.apkUrl,
          filename: release.apkName.isNotEmpty
              ? release.apkName
              : 'agy-remote-v${release.latestVersion}.apk',
          onProgress: onProgress,
          cancelToken: cancelToken,
        ),
      );
      if (!mounted) return;
      if (dl.cancelled) return;
      if (dl.error != null || dl.path == null) {
        setState(() {
          _appUpdateError = dl.error ?? '下载安装包失败，可尝试使用浏览器下载';
        });
        return;
      }
      _downloadedApkPath = dl.path;
      await _triggerInstallApk(dl.path!, release);
    } finally {
      if (mounted) {
        setState(() => _installingApk = false);
      }
    }
  }

  Future<void> _triggerInstallApk(String apkPath, AppReleaseInfo release) async {
    final res = await AndroidNativeBridge.installApk(apkPath);
    if (!mounted) return;
    if (res.ok) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('已拉起系统安装界面，请按提示完成覆盖升级')),
      );
      return;
    }
    setState(() {
      _appUpdateError = res.error ?? '拉起安装器失败，可点击「浏览器下载」手动安装';
    });
    if (res.needsPermission) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('请先开启「允许安装未知应用」权限，返回后再次点击「立即安装」'),
          duration: Duration(seconds: 4),
        ),
      );
    } else if (release.htmlUrl.isNotEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(_appUpdateError!),
          action: SnackBarAction(
            label: '浏览器下载',
            onPressed: () => PlatformBridge.openExternalUrl(release.htmlUrl),
          ),
        ),
      );
    }
  }

  Future<void> _loadAdminNodes() async {
    setState(() => _loadingAdminNodes = true);
    try {
      final list = await ref.read(apiClientProvider).getAdminNodes();
      if (!mounted) return;
      setState(() {
        _adminNodes = list;
        _loadingAdminNodes = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _adminNodes = ref.read(hubControllerProvider).nodes;
        _loadingAdminNodes = false;
      });
    }
  }

  Future<void> _checkNodeUpdate(HostNode node) async {
    if (_checkingNodeIds.contains(node.id) || _updatingNodeIds.contains(node.id)) return;
    setState(() {
      _checkingNodeIds.add(node.id);
      _nodeUpdateErrors.remove(node.id);
    });
    try {
      final st = await ref.read(apiClientProvider).getNodeUpdateStatus(node.id, fetch: true);
      if (!mounted) return;
      setState(() {
        _nodeUpdateStatuses[node.id] = st;
      });
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() {
        _nodeUpdateErrors[node.id] = e.statusCode == 404
            ? '该节点版本过旧，尚未支持远程更新（请先在该电脑运行一次 update_windows_agent.ps1）'
            : e.message;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _nodeUpdateErrors[node.id] = '检查失败: $e';
      });
    } finally {
      if (mounted) {
        setState(() => _checkingNodeIds.remove(node.id));
      }
    }
  }

  Future<void> _applyNodeUpdate(HostNode node, {bool force = false}) async {
    if (_updatingNodeIds.contains(node.id)) return;
    setState(() {
      _updatingNodeIds.add(node.id);
      _nodeUpdateErrors.remove(node.id);
    });
    try {
      final res = await ref.read(apiClientProvider).applyNodeUpdate(node.id, force: force);
      if (!mounted) return;
      if (res.ok) {
        setState(() {
          _nodeUpdateErrors[node.id] = res.message.isNotEmpty ? res.message : '节点更新指令已发送';
          _nodeUpdateStatuses.remove(node.id);
        });
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(res.message.isNotEmpty ? res.message : '${node.name} 正在重启升级...')),
        );
        if (res.restarting) {
          Future.delayed(const Duration(seconds: 7), () {
            if (!mounted) return;
            _loadAdminNodes();
            unawaited(ref.read(hubControllerProvider.notifier).refreshNodes());
          });
        }
      } else {
        setState(() {
          _nodeUpdateErrors[node.id] = res.message.isNotEmpty ? res.message : '更新未执行';
        });
      }
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() {
        _nodeUpdateErrors[node.id] = e.statusCode == 404
            ? '该节点版本过旧，请先手动更新一次'
            : e.message;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _nodeUpdateErrors[node.id] = '更新失败: $e';
      });
    } finally {
      if (mounted) {
        setState(() => _updatingNodeIds.remove(node.id));
      }
    }
  }

  Future<void> _loadNotifyStatus() async {
    try {
      final st = await ref.read(apiClientProvider).getNotificationStatus();
      if (!mounted) return;
      setState(() {
        _discordConfigured = st.discordConfigured;
        _notifyMinRunSeconds = st.minRunSeconds;
        _notifyAskDelaySeconds = st.askQuestionDelaySeconds;
        _loadingNotifyStatus = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() => _loadingNotifyStatus = false);
    }
  }

  Future<void> _sendTestNotification() async {
    if (_sendingTestNotify) return;
    setState(() => _sendingTestNotify = true);
    try {
      final (ok, msg) = await ref.read(apiClientProvider).sendTestNotification();
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(msg.isNotEmpty ? msg : (ok ? '测试通知已发送' : '测试通知发送失败')),
          backgroundColor: ok ? null : Colors.redAccent.shade700,
        ),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('测试通知失败: $e'),
          backgroundColor: Colors.redAccent.shade700,
        ),
      );
    } finally {
      if (mounted) {
        setState(() => _sendingTestNotify = false);
      }
    }
  }

  Future<void> _saveGatewayUrl() async {
    final next = _urlController.text.trim();
    if (next.isEmpty || _savingUrl) return;
    setState(() => _savingUrl = true);
    try {
      await widget.onSaveUrl(next);
      if (!mounted) return;
      setState(() {
        _savedUrl = next;
        _savingUrl = false;
      });
    } finally {
      if (mounted) {
        setState(() => _savingUrl = false);
      }
    }
  }

  String _categorySummary(
    SettingsCategory category, {
    required bool isDark,
    required ThemeState themeState,
    required ComposerPrefs prefs,
    required HubState hubState,
  }) {
    switch (category) {
      case SettingsCategory.appearance:
        final modeLabel = isDark ? '夜间' : '日间';
        final accentLabel = themeState.accent.name.split(' ').first;
        final scalePct = '${(themeState.fontScale * 100).round()}%';
        return '$modeLabel · $accentLabel · ${themeState.font.name} · $scalePct';
      case SettingsCategory.input:
        final queueLabel = prefs.queueMode == ComposerPrefs.queueModeImmediate ? '立即发送' : '排队入列';
        final sendLabel = prefs.isCtrlEnterToSend ? 'Ctrl+Enter 发送' : 'Enter 发送';
        return '$queueLabel · $sendLabel';
      case SettingsCategory.node:
        final node = hubState.currentNode;
        final power = hubState.nodePowerStatus;
        final nodeName = node?.name ?? hubState.selectedNodeId;
        if (power != null && power.enabled) {
          return '$nodeName · 已预约${power.actionLabel}';
        }
        return nodeName.isNotEmpty ? '当前节点：$nodeName' : '电源控制与节点版本';
      case SettingsCategory.network:
        final notifyLabel = _loadingNotifyStatus
            ? '通知检查中'
            : (_discordConfigured ? 'Discord 已启用' : 'Discord 未配置');
        return '$_savedUrl · $notifyLabel';
      case SettingsCategory.account:
        final release = _latestRelease;
        final hasNew = release != null && isAppUpdateAvailable(_appVersion, release.latestVersion);
        final name = widget.user.displayName.trim().isNotEmpty
            ? widget.user.displayName.trim()
            : widget.user.username;
        return '$name · v$_appVersion${hasNew ? " · 有新版本" : ""}';
    }
  }

  _SettingsCategoryMeta _metaFor(SettingsCategory c) {
    return _kSettingsCategories.firstWhere((m) => m.category == c);
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final primary = Theme.of(context).colorScheme.primary;
    final themeState = ref.watch(themeProvider);
    final prefs = ref.watch(composerPrefsProvider);
    final hubState = ref.watch(hubControllerProvider);

    if (widget.isSplitPane) {
      return _buildDesktopSplitPane(
        isDark: isDark,
        primary: primary,
        themeState: themeState,
        prefs: prefs,
        hubState: hubState,
      );
    }
    return _buildMobileTwoLevel(
      isDark: isDark,
      primary: primary,
      themeState: themeState,
      prefs: prefs,
      hubState: hubState,
    );
  }

  Widget _buildDesktopSplitPane({
    required bool isDark,
    required Color primary,
    required ThemeState themeState,
    required ComposerPrefs prefs,
    required HubState hubState,
  }) {
    final bg = isDark ? const Color(0xFF18181B) : Colors.white;
    final navBg = isDark ? const Color(0xFF111113) : const Color(0xFFF8F8F9);
    final border = isDark ? const Color(0xFF2C2C32) : const Color(0xFFE4E4E7);
    final activeMeta = _metaFor(_selectedCategory);
    final hasUpdate = _latestRelease != null &&
        isAppUpdateAvailable(_appVersion, _latestRelease!.latestVersion);

    return ColoredBox(
      color: bg,
      child: Row(
        children: [
          Container(
            width: 196,
            color: navBg,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 16, 12, 12),
                  child: Text(
                    '设置',
                    style: TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w700,
                      color: isDark ? Colors.white : Colors.black87,
                    ),
                  ),
                ),
                Expanded(
                  child: ListView(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                    children: _kSettingsCategories.map((meta) {
                      final active = _selectedCategory == meta.category;
                      final showDot = meta.category == SettingsCategory.account && hasUpdate;
                      return Padding(
                        padding: const EdgeInsets.only(bottom: 3),
                        child: InkWell(
                          key: ValueKey('settings_nav_${meta.category.name}'),
                          borderRadius: BorderRadius.circular(9),
                          onTap: () => setState(() => _selectedCategory = meta.category),
                          child: Container(
                            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 9),
                            decoration: BoxDecoration(
                              color: active
                                  ? primary.withValues(alpha: isDark ? 0.16 : 0.11)
                                  : Colors.transparent,
                              borderRadius: BorderRadius.circular(9),
                              border: Border.all(
                                color: active
                                    ? primary.withValues(alpha: 0.45)
                                    : Colors.transparent,
                              ),
                            ),
                            child: Row(
                              children: [
                                Icon(
                                  meta.icon,
                                  size: 17,
                                  color: active
                                      ? primary
                                      : (isDark ? Colors.white60 : Colors.black54),
                                ),
                                const SizedBox(width: 9),
                                Expanded(
                                  child: Text(
                                    meta.title,
                                    style: TextStyle(
                                      fontSize: 13,
                                      fontWeight: active ? FontWeight.w600 : FontWeight.w500,
                                      color: active
                                          ? (isDark ? Colors.white : Colors.black87)
                                          : (isDark ? Colors.white70 : Colors.black54),
                                    ),
                                  ),
                                ),
                                if (showDot)
                                  Container(
                                    width: 7,
                                    height: 7,
                                    decoration: const BoxDecoration(
                                      shape: BoxShape.circle,
                                      color: Colors.redAccent,
                                    ),
                                  ),
                              ],
                            ),
                          ),
                        ),
                      );
                    }).toList(),
                  ),
                ),
              ],
            ),
          ),
          VerticalDivider(width: 1, thickness: 1, color: border),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 14, 12, 12),
                  child: Row(
                    children: [
                      Icon(activeMeta.icon, size: 18, color: primary),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          activeMeta.title,
                          style: TextStyle(
                            fontSize: 15.5,
                            fontWeight: FontWeight.w700,
                            color: isDark ? Colors.white : Colors.black87,
                          ),
                        ),
                      ),
                      IconButton(
                        tooltip: '关闭设置',
                        visualDensity: VisualDensity.compact,
                        icon: const Icon(Icons.close_rounded, size: 20),
                        onPressed: () => Navigator.of(context).pop(),
                      ),
                    ],
                  ),
                ),
                Divider(height: 1, thickness: 1, color: border),
                Expanded(
                  child: SingleChildScrollView(
                    padding: const EdgeInsets.all(20),
                    child: _buildCategoryContent(
                      _selectedCategory,
                      isDark: isDark,
                      primary: primary,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildMobileTwoLevel({
    required bool isDark,
    required Color primary,
    required ThemeState themeState,
    required ComposerPrefs prefs,
    required HubState hubState,
  }) {
    final bg = isDark ? AppColors.darkBg : AppColors.lightBg;
    final activeMeta = _metaFor(_selectedCategory);
    final hasUpdate = _latestRelease != null &&
        isAppUpdateAvailable(_appVersion, _latestRelease!.latestVersion);

    return PopScope(
      canPop: !_showMobileDetail,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop && _showMobileDetail) {
          setState(() => _showMobileDetail = false);
        }
      },
      child: Scaffold(
        backgroundColor: bg,
        appBar: AppBar(
          backgroundColor: bg,
          elevation: 0,
          scrolledUnderElevation: 0,
          leading: IconButton(
            tooltip: _showMobileDetail ? '返回分类列表' : '返回',
            icon: const Icon(Icons.arrow_back_rounded),
            onPressed: () {
              if (_showMobileDetail) {
                setState(() => _showMobileDetail = false);
              } else {
                Navigator.of(context).pop();
              }
            },
          ),
          title: Text(
            _showMobileDetail ? activeMeta.title : '设置',
            style: TextStyle(
              fontSize: 16,
              fontWeight: FontWeight.w700,
              color: isDark ? Colors.white : Colors.black87,
            ),
          ),
          bottom: PreferredSize(
            preferredSize: const Size.fromHeight(0.5),
            child: Container(
              height: 0.5,
              color: isDark ? AppColors.darkBorder : AppColors.lightBorder,
            ),
          ),
        ),
        body: _showMobileDetail
            ? SingleChildScrollView(
                padding: const EdgeInsets.all(16),
                child: _buildCategoryContent(
                  _selectedCategory,
                  isDark: isDark,
                  primary: primary,
                ),
              )
            : ListView.separated(
                padding: const EdgeInsets.all(14),
                itemCount: _kSettingsCategories.length,
                separatorBuilder: (_, __) => const SizedBox(height: 8),
                itemBuilder: (_, idx) {
                  final meta = _kSettingsCategories[idx];
                  final summary = _categorySummary(
                    meta.category,
                    isDark: isDark,
                    themeState: themeState,
                    prefs: prefs,
                    hubState: hubState,
                  );
                  final showDot = meta.category == SettingsCategory.account && hasUpdate;
                  return Material(
                    color: isDark ? const Color(0xFF18181B) : const Color(0xFFF8F8F9),
                    borderRadius: BorderRadius.circular(12),
                    child: InkWell(
                      key: ValueKey('settings_mobile_item_${meta.category.name}'),
                      borderRadius: BorderRadius.circular(12),
                      onTap: () {
                        setState(() {
                          _selectedCategory = meta.category;
                          _showMobileDetail = true;
                        });
                      },
                      child: Container(
                        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 13),
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(12),
                          border: Border.all(
                            color: isDark ? const Color(0xFF2C2C32) : const Color(0xFFE4E4E7),
                          ),
                        ),
                        child: Row(
                          children: [
                            Container(
                              width: 34,
                              height: 34,
                              decoration: BoxDecoration(
                                color: primary.withValues(alpha: isDark ? 0.16 : 0.12),
                                borderRadius: BorderRadius.circular(9),
                              ),
                              child: Icon(meta.icon, size: 18, color: primary),
                            ),
                            const SizedBox(width: 12),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Row(
                                    children: [
                                      Text(
                                        meta.title,
                                        style: TextStyle(
                                          fontSize: 14,
                                          fontWeight: FontWeight.w600,
                                          color: isDark ? Colors.white : Colors.black87,
                                        ),
                                      ),
                                      if (showDot) ...[
                                        const SizedBox(width: 6),
                                        Container(
                                          width: 7,
                                          height: 7,
                                          decoration: const BoxDecoration(
                                            shape: BoxShape.circle,
                                            color: Colors.redAccent,
                                          ),
                                        ),
                                      ],
                                    ],
                                  ),
                                  const SizedBox(height: 2),
                                  Text(
                                    summary,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: TextStyle(
                                      fontSize: 11.5,
                                      color: isDark ? Colors.white54 : Colors.black54,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                            Icon(
                              Icons.chevron_right_rounded,
                              size: 20,
                              color: isDark ? Colors.white38 : Colors.black38,
                            ),
                          ],
                        ),
                      ),
                    ),
                  );
                },
              ),
      ),
    );
  }

  Widget _buildCategoryContent(
    SettingsCategory category, {
    required bool isDark,
    required Color primary,
  }) {
    switch (category) {
      case SettingsCategory.appearance:
        return _buildAppearanceSection(isDark, primary);
      case SettingsCategory.input:
        return _buildInputSection(isDark, primary);
      case SettingsCategory.node:
        return _buildNodeSection(isDark, primary);
      case SettingsCategory.network:
        return _buildNetworkSection(isDark, primary);
      case SettingsCategory.account:
        return _buildAccountSection(isDark, primary);
    }
  }

  Widget _buildAppearanceSection(bool isDark, Color primary) {
    final themeState = ref.watch(themeProvider);
    final themeNotifier = ref.read(themeProvider.notifier);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _buildSegmented(
          title: '主题模式',
          subtitle: isDark ? '深色护眼模式' : '浅色清爽模式',
          options: const [
            (id: 'dark', label: '夜间'),
            (id: 'light', label: '日间'),
          ],
          selectedId: isDark ? 'dark' : 'light',
          onSelected: (id) => themeNotifier.setDarkMode(id == 'dark'),
          isDark: isDark,
          primary: primary,
        ),
        const SizedBox(height: 18),
        Divider(color: isDark ? Colors.white12 : Colors.black12, height: 1),
        const SizedBox(height: 14),
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Flexible(
              child: Text(
                '护眼强调色',
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: primary),
              ),
            ),
            const SizedBox(width: 8),
            Flexible(
              child: Text(
                themeState.accent.name.split(' ').first,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: 11.5, fontWeight: FontWeight.w600, color: primary),
              ),
            ),
          ],
        ),
        const SizedBox(height: 10),
        Wrap(
          spacing: 12,
          runSpacing: 10,
          children: AppColors.accentThemes.map((opt) {
            final isSelected = opt.id == themeState.accent.id;
            final swatch = opt.previewFor(isDark);
            return InkWell(
              onTap: () => themeNotifier.setAccentTheme(opt),
              borderRadius: BorderRadius.circular(18),
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 200),
                width: 30,
                height: 30,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: swatch,
                  border: Border.all(
                    color: isSelected
                        ? (isDark ? Colors.white : Colors.black87)
                        : Colors.transparent,
                    width: 2,
                  ),
                  boxShadow: [
                    if (isSelected)
                      BoxShadow(
                        color: swatch.withValues(alpha: 0.4),
                        blurRadius: 6,
                        spreadRadius: 1,
                      ),
                  ],
                ),
                child: isSelected
                    ? Center(
                        child: Icon(
                          Icons.check_rounded,
                          size: 15,
                          color: isDark ? const Color(0xFF111113) : Colors.white,
                        ),
                      )
                    : null,
              ),
            );
          }).toList(),
        ),
        const SizedBox(height: 18),
        Divider(color: isDark ? Colors.white12 : Colors.black12, height: 1),
        const SizedBox(height: 14),
        Text(
          '界面字体',
          style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: primary),
        ),
        const SizedBox(height: 8),
        LayoutBuilder(
          builder: (context, constraints) {
            const spacing = 8.0;
            final maxWidth = constraints.maxWidth.isFinite ? constraints.maxWidth : 440.0;
            final itemWidth = ((maxWidth - spacing) / 2).floorToDouble();
            return Wrap(
              spacing: spacing,
              runSpacing: spacing,
              children: AppFonts.options.map((opt) {
                final isSelected = themeState.font.id == opt.id;
                final isLoading = themeState.loadingFontId == opt.id;
                return InkWell(
                  borderRadius: BorderRadius.circular(10),
                  onTap: themeState.loadingFontId != null
                      ? null
                      : () async {
                          final ok = await themeNotifier.setFont(
                            opt,
                            baseUrl: widget.currentUrl,
                          );
                          if (!ok && context.mounted) {
                            ScaffoldMessenger.of(context).showSnackBar(
                              SnackBar(
                                content: Text('字体文件暂不可用，已切换为系统相近字体 (${opt.name})'),
                                duration: const Duration(seconds: 2),
                              ),
                            );
                          }
                        },
                  child: Container(
                    width: itemWidth > 0 ? itemWidth : null,
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                    decoration: BoxDecoration(
                      color: isSelected
                          ? primary.withValues(alpha: isDark ? 0.14 : 0.08)
                          : (isDark ? const Color(0xFF111113) : const Color(0xFFF4F4F5)),
                      borderRadius: BorderRadius.circular(10),
                      border: Border.all(
                        color: isSelected
                            ? primary.withValues(alpha: 0.7)
                            : (isDark ? const Color(0xFF2C2C32) : const Color(0xFFE4E4E7)),
                        width: isSelected ? 1.2 : 1,
                      ),
                    ),
                    child: Row(
                      children: [
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Text(
                                opt.name,
                                style: TextStyle(
                                  fontSize: 12.5,
                                  fontWeight: isSelected ? FontWeight.w600 : FontWeight.w500,
                                  color: isSelected
                                      ? primary
                                      : (isDark ? Colors.white : Colors.black87),
                                ),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                              const SizedBox(height: 2),
                              Text(
                                opt.description,
                                style: TextStyle(
                                  fontSize: 10,
                                  color: isDark ? Colors.white54 : Colors.black54,
                                ),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ],
                          ),
                        ),
                        if (isLoading)
                          SizedBox(
                            width: 14,
                            height: 14,
                            child: CircularProgressIndicator(strokeWidth: 1.8, color: primary),
                          )
                        else if (isSelected)
                          Icon(Icons.check_rounded, size: 15, color: primary),
                      ],
                    ),
                  ),
                );
              }).toList(),
            );
          },
        ),
        const SizedBox(height: 18),
        Divider(color: isDark ? Colors.white12 : Colors.black12, height: 1),
        const SizedBox(height: 14),
        Row(
          children: [
            Flexible(
              child: Text(
                '界面字号',
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: primary),
              ),
            ),
            const SizedBox(width: 8),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
              decoration: BoxDecoration(
                color: primary.withValues(alpha: isDark ? 0.16 : 0.10),
                borderRadius: BorderRadius.circular(6),
              ),
              child: Text(
                '${(themeState.fontScale * 100).round()}%',
                style: TextStyle(fontSize: 11, fontWeight: FontWeight.w700, color: primary),
              ),
            ),
            const Spacer(),
            if ((themeState.fontScale - ThemeState.defaultFontScale).abs() > 0.001)
              TextButton(
                onPressed: () => themeNotifier.resetFontScale(),
                style: TextButton.styleFrom(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                  minimumSize: Size.zero,
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                ),
                child: const Text('恢复默认', style: TextStyle(fontSize: 11.5)),
              ),
          ],
        ),
        const SizedBox(height: 6),
        Row(
          children: [
            IconButton(
              tooltip: '减小字号',
              icon: const Icon(Icons.text_decrease_rounded, size: 18),
              visualDensity: VisualDensity.compact,
              onPressed: themeState.fontScale <= ThemeState.minFontScale + 0.001
                  ? null
                  : () => themeNotifier.stepFontScale(-ThemeState.fontScaleStep),
            ),
            Expanded(
              child: Slider(
                value: themeState.fontScale.clamp(ThemeState.minFontScale, ThemeState.maxFontScale),
                min: ThemeState.minFontScale,
                max: ThemeState.maxFontScale,
                divisions: 16,
                label: '${(themeState.fontScale * 100).round()}%',
                onChanged: (val) => themeNotifier.setFontScale(val),
              ),
            ),
            IconButton(
              tooltip: '增大字号',
              icon: const Icon(Icons.text_increase_rounded, size: 18),
              visualDensity: VisualDensity.compact,
              onPressed: themeState.fontScale >= ThemeState.maxFontScale - 0.001
                  ? null
                  : () => themeNotifier.stepFontScale(ThemeState.fontScaleStep),
            ),
          ],
        ),
        const SizedBox(height: 4),
        Wrap(
          spacing: 6,
          runSpacing: 6,
          children: const [
            (label: '紧凑 85%', scale: 0.85),
            (label: '标准 100%', scale: 1.00),
            (label: '舒适 115%', scale: 1.15),
            (label: '大号 130%', scale: 1.30),
          ].map((preset) {
            final selected = (themeState.fontScale - preset.scale).abs() < 0.015;
            return InkWell(
              borderRadius: BorderRadius.circular(8),
              onTap: () => themeNotifier.setFontScale(preset.scale),
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                decoration: BoxDecoration(
                  color: selected
                      ? primary.withValues(alpha: isDark ? 0.16 : 0.10)
                      : (isDark ? const Color(0xFF111113) : const Color(0xFFF4F4F5)),
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(
                    color: selected
                        ? primary.withValues(alpha: 0.7)
                        : (isDark ? const Color(0xFF2C2C32) : const Color(0xFFE4E4E7)),
                    width: selected ? 1.1 : 1,
                  ),
                ),
                child: Text(
                  preset.label,
                  style: TextStyle(
                    fontSize: 11.5,
                    fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
                    color: selected ? primary : (isDark ? Colors.white70 : Colors.black87),
                  ),
                ),
              ),
            );
          }).toList(),
        ),
        if (kIsWeb) ...[
          const SizedBox(height: 8),
          Text(
            'Web 端支持 Ctrl + 滚轮、Ctrl + / - 快捷缩放，Ctrl + 0 恢复默认',
            style: TextStyle(fontSize: 11, color: isDark ? Colors.white54 : Colors.black45),
          ),
        ],
      ],
    );
  }

  Widget _buildInputSection(bool isDark, Color primary) {
    final prefs = ref.watch(composerPrefsProvider);
    final prefsNotifier = ref.read(composerPrefsProvider.notifier);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          '消息与输入',
          style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: primary),
        ),
        const SizedBox(height: 12),
        _buildSegmented(
          title: '运行中发送策略',
          subtitle: '配置 Agent 运行期间发送新消息的行为',
          options: const [
            (id: ComposerPrefs.queueModeQueue, label: '排队入列'),
            (id: ComposerPrefs.queueModeImmediate, label: '立即发送'),
          ],
          selectedId: prefs.queueMode,
          onSelected: prefsNotifier.setQueueMode,
          isDark: isDark,
          primary: primary,
        ),
        const SizedBox(height: 16),
        _buildSegmented(
          title: '发送快捷键',
          subtitle: prefs.isCtrlEnterToSend ? 'Ctrl+Enter 发送 / Enter 换行' : 'Enter 发送 / Shift+Enter 换行',
          options: const [
            (id: ComposerPrefs.sendKeyEnter, label: 'Enter'),
            (id: ComposerPrefs.sendKeyCtrlEnter, label: 'Ctrl+Enter'),
          ],
          selectedId: prefs.sendKey,
          onSelected: prefsNotifier.setSendKey,
          isDark: isDark,
          primary: primary,
        ),
      ],
    );
  }

  Widget _buildNodeSection(bool isDark, Color primary) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _buildNodePowerSection(isDark, primary),
        if (_isAdmin) ...[
          const SizedBox(height: 18),
          Divider(color: isDark ? Colors.white12 : Colors.black12, height: 1),
          const SizedBox(height: 14),
          Row(
            children: [
              Text(
                '节点版本与远程自更新',
                style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: primary),
              ),
              const Spacer(),
              if (_loadingAdminNodes)
                const SizedBox(
                  width: 12,
                  height: 12,
                  child: CircularProgressIndicator(strokeWidth: 1.6),
                )
              else
                InkWell(
                  onTap: _loadAdminNodes,
                  borderRadius: BorderRadius.circular(6),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(Icons.refresh_rounded, size: 13, color: isDark ? Colors.white54 : Colors.black54),
                        const SizedBox(width: 3),
                        Text(
                          '刷新',
                          style: TextStyle(fontSize: 11, color: isDark ? Colors.white54 : Colors.black54),
                        ),
                      ],
                    ),
                  ),
                ),
            ],
          ),
          const SizedBox(height: 8),
          if (_adminNodes.isEmpty && !_loadingAdminNodes)
            Text(
              '暂无已注册节点',
              style: TextStyle(fontSize: 11.5, color: isDark ? Colors.white38 : Colors.black45),
            )
          else
            ..._adminNodes.map((node) {
              final st = _nodeUpdateStatuses[node.id];
              final note = _nodeUpdateErrors[node.id] ?? st?.message ?? '';
              final isChecking = _checkingNodeIds.contains(node.id);
              final isUpdating = _updatingNodeIds.contains(node.id);
              final canTriggerUpdate = st != null && st.updateAvailable && st.canUpdate;
              final versionLabel = node.version.isNotEmpty ? 'v${node.version}' : '旧版 / 未知';
              return Container(
                margin: const EdgeInsets.only(bottom: 8),
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                decoration: BoxDecoration(
                  color: isDark ? const Color(0xFF111113) : const Color(0xFFF8F8F9),
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(
                    color: isDark ? const Color(0xFF2C2C32) : const Color(0xFFE4E4E7),
                  ),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Container(
                          width: 7,
                          height: 7,
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            color: node.isOnline
                                ? AppColors.statusGreen(isDark)
                                : (isDark ? Colors.white24 : Colors.black26),
                          ),
                        ),
                        const SizedBox(width: 7),
                        Expanded(
                          child: Text(
                            '${node.name} ($versionLabel)',
                            style: TextStyle(
                              fontSize: 12.5,
                              fontWeight: FontWeight.w600,
                              color: isDark ? Colors.white : Colors.black87,
                            ),
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        if (node.isOnline) ...[
                          TextButton(
                            onPressed: (isChecking || isUpdating) ? null : () => _checkNodeUpdate(node),
                            style: TextButton.styleFrom(
                              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                              minimumSize: Size.zero,
                              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                            ),
                            child: Text(
                              isChecking ? '检查中...' : '检查更新',
                              style: const TextStyle(fontSize: 11.5),
                            ),
                          ),
                          if (canTriggerUpdate) ...[
                            const SizedBox(width: 4),
                            FilledButton(
                              onPressed: isUpdating
                                  ? null
                                  : () => _applyNodeUpdate(
                                        node,
                                        force: st.runningSessions > 0,
                                      ),
                              style: FilledButton.styleFrom(
                                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                                minimumSize: Size.zero,
                                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                              ),
                              child: Text(
                                isUpdating
                                    ? '更新中...'
                                    : (st.runningSessions > 0 ? '强制更新' : '一键更新'),
                                style: const TextStyle(fontSize: 11.5),
                              ),
                            ),
                          ],
                        ] else
                          Text(
                            '离线',
                            style: TextStyle(
                              fontSize: 11,
                              color: isDark ? Colors.white38 : Colors.black38,
                            ),
                          ),
                      ],
                    ),
                    if (note.isNotEmpty) ...[
                      const SizedBox(height: 4),
                      Text(
                        note,
                        style: TextStyle(
                          fontSize: 11,
                          color: st != null && st.dirty
                              ? AppColors.statusAmber(isDark)
                              : (isDark ? Colors.white60 : Colors.black54),
                        ),
                      ),
                    ],
                  ],
                ),
              );
            }),
        ],
      ],
    );
  }

  Widget _buildNetworkSection(bool isDark, Color primary) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          '网关连接',
          style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: primary),
        ),
        const SizedBox(height: 8),
        if (kIsWeb) ...[
          Text(
            widget.currentUrl,
            style: TextStyle(
              fontSize: 12.5,
              fontFamily: 'monospace',
              color: isDark ? Colors.white70 : Colors.black87,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            'Web 版自动连接当前同源网关。',
            style: TextStyle(fontSize: 11, color: isDark ? Colors.white38 : Colors.black45),
          ),
        ] else ...[
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _urlController,
                  keyboardType: TextInputType.url,
                  style: TextStyle(color: isDark ? Colors.white : Colors.black87, fontSize: 13),
                  decoration: InputDecoration(
                    hintText: 'https://agy.example.com',
                    hintStyle: TextStyle(color: isDark ? Colors.white24 : Colors.black26),
                    filled: true,
                    fillColor: isDark ? const Color(0xFF111113) : const Color(0xFFF4F4F5),
                    contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                    border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              FilledButton(
                onPressed: _savingUrl ? null : _saveGatewayUrl,
                child: Text(_savingUrl ? '保存中' : '保存地址', style: const TextStyle(fontSize: 12)),
              ),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            '修改网关地址后将在下次重连生效。',
            style: TextStyle(fontSize: 11, color: isDark ? Colors.white38 : Colors.black45),
          ),
        ],
        const SizedBox(height: 18),
        Divider(color: isDark ? Colors.white12 : Colors.black12, height: 1),
        const SizedBox(height: 14),
        Row(
          children: [
            Text(
              'Discord 离线通知',
              style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: primary),
            ),
            const Spacer(),
            if (_loadingNotifyStatus)
              const SizedBox(
                width: 12,
                height: 12,
                child: CircularProgressIndicator(strokeWidth: 1.6),
              )
            else
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
                decoration: BoxDecoration(
                  color: (_discordConfigured
                          ? AppColors.statusGreen(isDark)
                          : (isDark ? Colors.white30 : Colors.black26))
                      .withValues(alpha: 0.14),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Text(
                  _discordConfigured ? '已在网关启用' : '未配置 Webhook',
                  style: TextStyle(
                    fontSize: 10.5,
                    fontWeight: FontWeight.w600,
                    color: _discordConfigured
                        ? AppColors.statusGreen(isDark)
                        : (isDark ? Colors.white54 : Colors.black45),
                  ),
                ),
              ),
          ],
        ),
        const SizedBox(height: 6),
        Text(
          _discordConfigured
              ? '离线或无活跃连接时，运行 >= ${_notifyMinRunSeconds.toInt()}s 完成、报错或 ask_question 超过 ${_notifyAskDelaySeconds.toInt()}s 未确认会自动推送至 Discord。'
              : '在网关 gateway_config.json 中填写 discord_webhook_url 后重启网关即可启用。',
          style: TextStyle(fontSize: 11, color: isDark ? Colors.white54 : Colors.black54),
        ),
        if (_discordConfigured && _isAdmin) ...[
          const SizedBox(height: 10),
          OutlinedButton.icon(
            onPressed: _sendingTestNotify ? null : _sendTestNotification,
            icon: _sendingTestNotify
                ? const SizedBox(
                    width: 13,
                    height: 13,
                    child: CircularProgressIndicator(strokeWidth: 1.8),
                  )
                : const Icon(Icons.notifications_active_outlined, size: 15),
            label: Text(
              _sendingTestNotify ? '发送中...' : '发送测试通知',
              style: const TextStyle(fontSize: 12),
            ),
            style: OutlinedButton.styleFrom(visualDensity: VisualDensity.compact),
          ),
        ],
      ],
    );
  }

  Widget _buildAccountSection(bool isDark, Color primary) {
    final displayName = widget.user.displayName.trim().isNotEmpty
        ? widget.user.displayName.trim()
        : widget.user.username;
    final roleLabel = widget.user.role == 'admin' ? '管理员' : '成员';

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          '当前账号',
          style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: primary),
        ),
        const SizedBox(height: 8),
        Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: isDark ? const Color(0xFF111113) : const Color(0xFFF8F8F9),
            borderRadius: BorderRadius.circular(12),
            border: Border.all(
              color: isDark ? const Color(0xFF2C2C32) : const Color(0xFFE4E4E7),
            ),
          ),
          child: Row(
            children: [
              CircleAvatar(
                radius: 20,
                backgroundColor: primary.withValues(alpha: 0.18),
                child: Icon(Icons.person_rounded, size: 22, color: primary),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Flexible(
                          child: Text(
                            displayName,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: 14,
                              fontWeight: FontWeight.w700,
                              color: isDark ? Colors.white : Colors.black87,
                            ),
                          ),
                        ),
                        const SizedBox(width: 6),
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1.5),
                          decoration: BoxDecoration(
                            color: primary.withValues(alpha: isDark ? 0.18 : 0.12),
                            borderRadius: BorderRadius.circular(6),
                          ),
                          child: Text(
                            roleLabel,
                            style: TextStyle(
                              fontSize: 10,
                              fontWeight: FontWeight.w600,
                              color: primary,
                            ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 2),
                    Text(
                      '@${widget.user.username}',
                      style: TextStyle(
                        fontSize: 11.5,
                        fontFamily: 'monospace',
                        color: isDark ? Colors.white54 : Colors.black54,
                      ),
                    ),
                  ],
                ),
              ),
              OutlinedButton.icon(
                onPressed: () {
                  Navigator.of(context).pop();
                  widget.onLogout();
                },
                icon: Icon(Icons.logout_rounded, size: 15, color: Colors.redAccent.shade200),
                label: Text(
                  '退出登录',
                  style: TextStyle(fontSize: 12, color: Colors.redAccent.shade200),
                ),
                style: OutlinedButton.styleFrom(
                  side: BorderSide(color: Colors.redAccent.shade200.withValues(alpha: 0.5)),
                  visualDensity: VisualDensity.compact,
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 18),
        Divider(color: isDark ? Colors.white12 : Colors.black12, height: 1),
        const SizedBox(height: 14),
        _buildAppUpdateSection(isDark, primary),
      ],
    );
  }

  Widget _buildAppUpdateSection(bool isDark, Color primary) {
    final release = _latestRelease;
    final hasUpdate = release != null && isAppUpdateAvailable(_appVersion, release.latestVersion);
    final sizeText = release != null ? _formatApkSize(release.apkSize) : '';

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Text(
              '应用版本与更新',
              style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: primary),
            ),
            const Spacer(),
            if (AndroidNativeBridge.isAndroidNative)
              TextButton(
                onPressed: _checkingAppUpdate ? null : () => _checkAppUpdate(force: true),
                style: TextButton.styleFrom(
                  padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                  minimumSize: Size.zero,
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                ),
                child: Text(
                  _checkingAppUpdate ? '检查中...' : '检查更新',
                  style: const TextStyle(fontSize: 11.5),
                ),
              ),
          ],
        ),
        const SizedBox(height: 6),
        Row(
          children: [
            Text(
              '当前版本 v$_appVersion',
              style: TextStyle(
                fontSize: 12.5,
                fontFamily: 'monospace',
                color: isDark ? Colors.white70 : Colors.black87,
              ),
            ),
            if (AndroidNativeBridge.isAndroidNative &&
                _appUpdateChecked &&
                !hasUpdate &&
                _appUpdateError == null) ...[
              const SizedBox(width: 8),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                decoration: BoxDecoration(
                  color: AppColors.statusGreen(isDark).withValues(alpha: 0.14),
                  borderRadius: BorderRadius.circular(6),
                ),
                child: Text(
                  '已是最新',
                  style: TextStyle(
                    fontSize: 10,
                    fontWeight: FontWeight.w600,
                    color: AppColors.statusGreen(isDark),
                  ),
                ),
              ),
            ],
          ],
        ),
        if (AndroidNativeBridge.isAndroidNative && hasUpdate) ...[
          const SizedBox(height: 8),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: primary.withValues(alpha: isDark ? 0.12 : 0.08),
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: primary.withValues(alpha: 0.45)),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Icon(Icons.system_update_rounded, size: 16, color: primary),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(
                        '发现新版本 v${release.latestVersion}${sizeText.isNotEmpty ? ' ($sizeText)' : ''}',
                        style: TextStyle(
                          fontSize: 12.5,
                          fontWeight: FontWeight.w700,
                          color: isDark ? Colors.white : Colors.black87,
                        ),
                      ),
                    ),
                  ],
                ),
                if (release.releaseNotes.isNotEmpty) ...[
                  const SizedBox(height: 4),
                  Text(
                    release.releaseNotes,
                    maxLines: 4,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 11,
                      height: 1.4,
                      color: isDark ? Colors.white70 : Colors.black54,
                    ),
                  ),
                ],
                const SizedBox(height: 8),
                Wrap(
                  spacing: 8,
                  runSpacing: 6,
                  children: [
                    FilledButton.icon(
                      onPressed: _installingApk ? null : () => _downloadAndInstallApk(release),
                      icon: Icon(
                        _downloadedApkPath != null
                            ? Icons.install_mobile_rounded
                            : Icons.download_rounded,
                        size: 14,
                      ),
                      label: Text(
                        _downloadedApkPath != null ? '立即安装' : '下载并安装',
                        style: const TextStyle(fontSize: 11.5),
                      ),
                      style: FilledButton.styleFrom(
                        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                        minimumSize: Size.zero,
                        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                      ),
                    ),
                    if (release.htmlUrl.isNotEmpty)
                      OutlinedButton(
                        onPressed: () => PlatformBridge.openExternalUrl(
                          release.apkUrl.isNotEmpty ? release.apkUrl : release.htmlUrl,
                        ),
                        style: OutlinedButton.styleFrom(
                          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                          minimumSize: Size.zero,
                          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                        ),
                        child: const Text('浏览器下载', style: TextStyle(fontSize: 11.5)),
                      ),
                    TextButton(
                      onPressed: () async {
                        await AppUpdateService.setIgnoredVersion(release.latestVersion);
                        if (!mounted) return;
                        setState(() => _latestRelease = null);
                        widget.onUpdateBadgeChanged?.call(null);
                      },
                      style: TextButton.styleFrom(
                        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
                        minimumSize: Size.zero,
                        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                      ),
                      child: Text(
                        '忽略此版本',
                        style: TextStyle(
                          fontSize: 11.5,
                          color: isDark ? Colors.white54 : Colors.black54,
                        ),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ],
        if (_appUpdateError != null) ...[
          const SizedBox(height: 6),
          Text(
            _appUpdateError!,
            style: TextStyle(
              fontSize: 11,
              color: AppColors.statusAmber(isDark),
            ),
          ),
        ],
      ],
    );
  }

  Widget _buildNodePowerSection(bool isDark, Color primary) {
    final hubState = ref.watch(hubControllerProvider);
    final hubNotifier = ref.read(hubControllerProvider.notifier);
    final node = hubState.currentNode;
    final power = hubState.nodePowerStatus;
    final armed = power != null && power.enabled;
    final activeAction = armed ? power.action : _selectedPowerAction;
    final nodeName = node?.name ?? hubState.selectedNodeId;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Text(
              '完成后自动电源',
              style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: primary),
            ),
            const Spacer(),
            if (nodeName.isNotEmpty)
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
                decoration: BoxDecoration(
                  color: (armed ? AppColors.statusAmber(isDark) : primary).withValues(alpha: 0.14),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Text(
                  armed ? '$nodeName · 已预约${power.actionLabel}' : nodeName,
                  style: TextStyle(
                    fontSize: 10.5,
                    fontWeight: FontWeight.w600,
                    color: armed ? AppColors.statusAmber(isDark) : primary,
                  ),
                ),
              ),
          ],
        ),
        const SizedBox(height: 6),
        if (node == null)
          Text(
            '请先选择一个可用节点。',
            style: TextStyle(fontSize: 11.5, color: isDark ? Colors.white54 : Colors.black54),
          )
        else if (node.isLocal)
          Text(
            '当前为网关宿主机（${node.name}），系统策略禁止远程关机或睡眠。',
            style: TextStyle(fontSize: 11.5, color: isDark ? Colors.white54 : Colors.black54),
          )
        else if (!node.canWrite)
          Text(
            '当前账号对 ${node.name} 为只读权限，无法预约关机或睡眠。',
            style: TextStyle(fontSize: 11.5, color: isDark ? Colors.white54 : Colors.black54),
          )
        else if (power != null && !power.supported)
          Text(
            power.message.isNotEmpty ? power.message : '该节点未开启远程电源控制支持。',
            style: TextStyle(fontSize: 11.5, color: isDark ? Colors.white54 : Colors.black54),
          )
        else ...[
          Text(
            armed && power.message.isNotEmpty
                ? power.message
                : '当该节点所有会话、排队队列和工具审批全部清空后，静默确认 20s 并进入 60s 可取消倒计时。',
            style: TextStyle(
              fontSize: 11,
              color: armed
                  ? AppColors.statusAmber(isDark)
                  : (isDark ? Colors.white54 : Colors.black54),
            ),
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              Container(
                decoration: BoxDecoration(
                  color: isDark ? const Color(0xFF111113) : const Color(0xFFF4F4F5),
                  borderRadius: BorderRadius.circular(8),
                ),
                padding: const EdgeInsets.all(3),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: const [
                    (id: 'shutdown', label: '关机'),
                    (id: 'sleep', label: '睡眠'),
                  ].map((opt) {
                    final selected = activeAction == opt.id;
                    return InkWell(
                      borderRadius: BorderRadius.circular(6),
                      onTap: hubState.isUpdatingNodePower
                          ? null
                          : () async {
                              setState(() => _selectedPowerAction = opt.id);
                              if (armed && opt.id != power.action) {
                                final err = await hubNotifier.scheduleNodePower(action: opt.id);
                                if (err != null && mounted) {
                                  ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(err)));
                                }
                              }
                            },
                      child: Container(
                        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                        decoration: BoxDecoration(
                          color: selected
                              ? primary.withValues(alpha: isDark ? 0.22 : 0.14)
                              : Colors.transparent,
                          borderRadius: BorderRadius.circular(6),
                        ),
                        child: Text(
                          opt.label,
                          style: TextStyle(
                            fontSize: 11.5,
                            fontWeight: selected ? FontWeight.bold : FontWeight.normal,
                            color: selected ? primary : (isDark ? Colors.white60 : Colors.black54),
                          ),
                        ),
                      ),
                    );
                  }).toList(),
                ),
              ),
              const Spacer(),
              if (armed)
                OutlinedButton.icon(
                  onPressed: hubState.isUpdatingNodePower
                      ? null
                      : () async {
                          final err = await hubNotifier.cancelNodePower();
                          if (err != null && mounted) {
                            ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(err)));
                          }
                        },
                  icon: Icon(Icons.close_rounded, size: 15, color: AppColors.statusRed(isDark)),
                  label: Text(
                    '取消预约',
                    style: TextStyle(fontSize: 11.5, color: AppColors.statusRed(isDark)),
                  ),
                  style: OutlinedButton.styleFrom(
                    side: BorderSide(color: AppColors.statusRed(isDark).withValues(alpha: 0.6)),
                    visualDensity: VisualDensity.compact,
                  ),
                )
              else
                FilledButton.icon(
                  onPressed: hubState.isUpdatingNodePower
                      ? null
                      : () async {
                          final err = await hubNotifier.scheduleNodePower(action: _selectedPowerAction);
                          if (err != null && mounted) {
                            ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(err)));
                          }
                        },
                  icon: Icon(
                    _selectedPowerAction == 'sleep'
                        ? Icons.bedtime_rounded
                        : Icons.power_settings_new_rounded,
                    size: 15,
                  ),
                  label: Text(
                    hubState.isUpdatingNodePower
                        ? '提交中...'
                        : '开启完成后${_selectedPowerAction == 'sleep' ? '睡眠' : '关机'}',
                    style: const TextStyle(fontSize: 11.5),
                  ),
                  style: FilledButton.styleFrom(
                    visualDensity: VisualDensity.compact,
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                  ),
                ),
            ],
          ),
        ],
      ],
    );
  }

  Widget _buildSegmented({
    required String title,
    required String subtitle,
    required List<({String id, String label})> options,
    required String selectedId,
    required ValueChanged<String> onSelected,
    required bool isDark,
    required Color primary,
  }) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                title,
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                  color: isDark ? Colors.white : Colors.black87,
                ),
              ),
              const SizedBox(height: 2),
              Text(
                subtitle,
                style: TextStyle(fontSize: 11, color: isDark ? Colors.white54 : Colors.black54),
              ),
            ],
          ),
        ),
        const SizedBox(width: 10),
        Container(
          padding: const EdgeInsets.all(3),
          decoration: BoxDecoration(
            color: isDark ? const Color(0xFF111113) : const Color(0xFFF4F4F5),
            borderRadius: BorderRadius.circular(18),
            border: Border.all(color: isDark ? Colors.white12 : Colors.black12),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: options.map((opt) {
              final active = opt.id == selectedId;
              return InkWell(
                onTap: () => onSelected(opt.id),
                borderRadius: BorderRadius.circular(14),
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                  decoration: BoxDecoration(
                    color: active ? (isDark ? const Color(0xFF2C2C32) : Colors.white) : Colors.transparent,
                    borderRadius: BorderRadius.circular(14),
                    boxShadow: active && !isDark
                        ? [
                            BoxShadow(
                              color: Colors.black.withValues(alpha: 0.06),
                              blurRadius: 3,
                              offset: const Offset(0, 1),
                            ),
                          ]
                        : null,
                  ),
                  child: Text(
                    opt.label,
                    style: TextStyle(
                      fontSize: 11.5,
                      fontWeight: active ? FontWeight.bold : FontWeight.normal,
                      color: active ? primary : (isDark ? Colors.white60 : Colors.black54),
                    ),
                  ),
                ),
              );
            }).toList(),
          ),
        ),
      ],
    );
  }
}

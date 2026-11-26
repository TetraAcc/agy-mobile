import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/theme/app_colors.dart';
import '../../core/utils/file_utils.dart';
import '../../models/models.dart';

class PluginCardInfo {
  final String catalogId;
  final String slug;
  final String displayName;
  final String subtitle;
  final IconData icon;
  final bool isAuthRequired;

  const PluginCardInfo({
    required this.catalogId,
    required this.slug,
    required this.displayName,
    required this.subtitle,
    required this.icon,
    required this.isAuthRequired,
  });
}

enum ActionNeededKind {
  pluginAuth,
  browserIntervention,
}

class ActionNeededNotice {
  final ActionNeededKind kind;
  final String title;
  final String description;
  final String retryPrompt;
  final IconData icon;

  const ActionNeededNotice({
    required this.kind,
    required this.title,
    required this.description,
    required this.retryPrompt,
    required this.icon,
  });
}

class ToolChipPresentation {
  final String label;
  final IconData icon;
  final String? editTargetPath;
  final bool isPluginOrMcp;

  const ToolChipPresentation({
    required this.label,
    required this.icon,
    this.editTargetPath,
    this.isPluginOrMcp = false,
  });
}

class RichPresenceParser {
  static final RegExp _fencedCodeRe = RegExp(r'```[\s\S]*?```|~~~[\s\S]*?~~~', multiLine: true);
  static final RegExp _inlineCodeRe = RegExp(r'`[^`\n]+`');
  static final RegExp _pluginCardTagRe = RegExp(
    r'''<plugin-card\b[^>]*\bcatalog-id\s*=\s*(?:"([^"]+)"|'([^']+)')[^>]*>(?:\s*</plugin-card>)?|<plugin-card\b[^>]*\bcatalog-id\s*=\s*(?:"([^"]+)"|'([^']+)')[^>]*/\s*>''',
    caseSensitive: false,
  );
  static final RegExp _authContextRe = RegExp(
    r'(?:needs?\s+authentication|re-?authenticate|reconnect|sign\s+in|not\s+signed\s+in|token\s+expired|plugins?\s+manager|重新登录|登录已过期|登录失效|请先登录|授权已过期|重新授权)',
    caseSensitive: false,
  );

  static const Map<String, ({String name, String subtitle, IconData icon})> _knownPlugins = {
    'gmail': (
      name: 'Gmail',
      subtitle: '邮件读取、检索与草稿管理',
      icon: Icons.mail_outline_rounded,
    ),
    'gcalendar': (
      name: 'Google Calendar',
      subtitle: '日程查询、创建与会议管理',
      icon: Icons.calendar_month_outlined,
    ),
    'gdrive': (
      name: 'Google Drive',
      subtitle: '云端硬盘文件检索与同步',
      icon: Icons.add_to_drive_rounded,
    ),
    'gdocs': (
      name: 'Google Docs',
      subtitle: '在线文档读取与协作编辑',
      icon: Icons.description_outlined,
    ),
    'gsheets': (
      name: 'Google Sheets',
      subtitle: '电子表格读取与数据分析',
      icon: Icons.table_chart_outlined,
    ),
    'gslides': (
      name: 'Google Slides',
      subtitle: '演示文稿读取与编排',
      icon: Icons.slideshow_outlined,
    ),
    'canva': (
      name: 'Canva',
      subtitle: '设计稿评审、批注与编辑',
      icon: Icons.palette_outlined,
    ),
    'cloudflare': (
      name: 'Cloudflare',
      subtitle: 'Workers、Tunnel 与边缘配置',
      icon: Icons.cloud_outlined,
    ),
    'vercel-plugin': (
      name: 'Vercel',
      subtitle: '部署、环境变量与日志排查',
      icon: Icons.rocket_launch_outlined,
    ),
    'figma': (
      name: 'Figma',
      subtitle: '设计稿查看与组件同步',
      icon: Icons.design_services_outlined,
    ),
    'flutter': (
      name: 'Flutter & Dart',
      subtitle: '热重载、静态分析与调试工具',
      icon: Icons.flutter_dash_rounded,
    ),
    'chrome-devtools-plugin': (
      name: 'Chrome DevTools',
      subtitle: '浏览器调试、性能与网络抓包',
      icon: Icons.bug_report_outlined,
    ),
    'gemini-api': (
      name: 'Gemini API',
      subtitle: '官方 SDK 文档与多模态能力',
      icon: Icons.auto_awesome_outlined,
    ),
    'ppt-master': (
      name: 'PPT Master',
      subtitle: '幻灯片生成与排版工具',
      icon: Icons.co_present_outlined,
    ),
    'google_maps_platform': (
      name: 'Google Maps Platform',
      subtitle: '地图、地理编码与路线服务',
      icon: Icons.map_outlined,
    ),
  };

  /// Replace fenced & inline code blocks with spaces so regex matching never fires on code examples.
  static String _maskCodeSegments(String input) {
    if (!input.contains('`') && !input.contains('~')) return input;
    var masked = input.replaceAllMapped(_fencedCodeRe, (m) => ' ' * (m.end - m.start));
    masked = masked.replaceAllMapped(_inlineCodeRe, (m) => ' ' * (m.end - m.start));
    return masked;
  }

  static String _extractSlug(String catalogId) {
    final clean = catalogId.trim().replaceAll('\\', '/');
    if (clean.isEmpty) return '';
    final parts = clean.split('/').where((e) => e.trim().isNotEmpty).toList();
    return parts.isEmpty ? clean.toLowerCase() : parts.last.trim().toLowerCase();
  }

  static String _prettifySlug(String slug) {
    if (slug.isEmpty) return 'Antigravity 插件';
    return slug
        .replaceAll('_', '-')
        .split('-')
        .where((w) => w.isNotEmpty)
        .map((w) {
          final low = w.toLowerCase();
          if (low == 'api' || low == 'mcp' || low == 'cli' || low == 'ppt') {
            return low.toUpperCase();
          }
          return '${w[0].toUpperCase()}${w.substring(1)}';
        })
        .join(' ');
  }

  /// Extract all real `<plugin-card catalog-id="...">` occurrences outside code blocks.
  static List<PluginCardInfo> extractPluginCards(String markdown) {
    if (!markdown.toLowerCase().contains('<plugin-card')) return const [];
    final masked = _maskCodeSegments(markdown);
    final matches = _pluginCardTagRe.allMatches(masked).toList();
    if (matches.isEmpty) return const [];

    final isAuthContext = _authContextRe.hasMatch(masked);
    final seen = <String>{};
    final result = <PluginCardInfo>[];

    for (final m in matches) {
      final rawId = (m.group(1) ?? m.group(2) ?? m.group(3) ?? m.group(4) ?? '').trim();
      if (rawId.isEmpty || rawId == '...' || rawId.contains('<') || rawId.contains('>')) {
        continue;
      }
      final dedupeKey = rawId.toLowerCase();
      if (!seen.add(dedupeKey)) continue;

      final slug = _extractSlug(rawId);
      final known = _knownPlugins[slug];
      result.add(
        PluginCardInfo(
          catalogId: rawId,
          slug: slug,
          displayName: known?.name ?? _prettifySlug(slug),
          subtitle: known?.subtitle ?? 'Antigravity 扩展插件',
          icon: known?.icon ?? Icons.extension_rounded,
          isAuthRequired: isAuthContext,
        ),
      );
    }
    return result;
  }

  /// Remove real `<plugin-card ...>` tags outside code spans while preserving code examples intact.
  static String stripPluginCardTags(String markdown) {
    if (!markdown.toLowerCase().contains('<plugin-card')) return markdown;
    final masked = _maskCodeSegments(markdown);
    final matches = _pluginCardTagRe.allMatches(masked).toList();
    if (matches.isEmpty) return markdown;

    final buf = StringBuffer();
    var cursor = 0;
    for (final m in matches) {
      if (m.start > cursor) {
        buf.write(markdown.substring(cursor, m.start));
      }
      cursor = m.end;
    }
    if (cursor < markdown.length) {
      buf.write(markdown.substring(cursor));
    }

    return buf
        .toString()
        .replaceAll(RegExp(r'\n{3,}'), '\n\n')
        .trim();
  }

  /// Detect blocking host-side action notices (OAuth sign-in or browser verification) when no plugin card covers them.
  static ActionNeededNotice? detectActionNeededNotice(
    String markdown, {
    required bool hasPluginCards,
    String nodeName = '',
  }) {
    if (markdown.trim().isEmpty) return null;
    final masked = _maskCodeSegments(markdown);
    final hostLabel = nodeName.trim().isNotEmpty ? '【${nodeName.trim()}】' : '对应宿主机';

    if (!hasPluginCards) {
      final hasPluginAuthSignal = RegExp(
        r'(?:needs?\s+authentication|plugins?\s+manager.{0,40}(?:reconnect|sign\s+in|重新登录|授权)|(?:reconnect|sign\s+in|重新登录).{0,40}plugins?\s+manager)',
        caseSensitive: false,
        dotAll: true,
      ).hasMatch(masked);
      if (hasPluginAuthSignal) {
        return ActionNeededNotice(
          kind: ActionNeededKind.pluginAuth,
          title: '插件账号需要重新授权',
          description: '检测到插件鉴权失效。请在$hostLabel的 Antigravity → Plugins Manager 中重新登录对应账号，完成后点击下方按钮让 Agent 继续。',
          retryPrompt: '我已在宿主机完成插件重新登录，请重试刚才的操作。',
          icon: Icons.vpn_key_outlined,
        );
      }
    }

    final hasBrowserGate = RegExp(
      r'(?:PAYMENT_REQUIRED|complete\s+the\s+payment|solve\s+(?:the\s+)?captcha|verify\s+you\s+are\s+human|请在浏览器(?:中|里)?完成(?:登录|支付|验证|人机验证)|需要你在浏览器中(?:完成|处理|登录|支付))',
      caseSensitive: false,
    ).hasMatch(masked);
    if (hasBrowserGate) {
      return ActionNeededNotice(
        kind: ActionNeededKind.browserIntervention,
        title: '需要宿主机浏览器人工接管',
        description: '当前网页流程遇到登录、支付或人机验证，无法自动绕过。请在$hostLabel的浏览器窗口完成操作后点击下方按钮继续。',
        retryPrompt: '我已在宿主机浏览器完成验证/操作，请继续执行。',
        icon: Icons.open_in_browser_rounded,
      );
    }

    return null;
  }

  /// Format tool call chips with dedicated icons & human-friendly labels for plugins, MCP, and built-ins.
  static ToolChipPresentation describeToolCall(ToolCallItem tool) {
    final name = tool.name.trim();
    final args = tool.args;

    if (name == 'edit_file' || name == 'replace_file_content' || name == 'multi_replace_file_content') {
      final p = FileUtils.cleanPath(args['Path'] ?? args['path'] ?? args['TargetFile'] ?? args['target_file']);
      final f = p.isEmpty ? '文件' : p.split(RegExp(r'[\\/]')).last;
      return ToolChipPresentation(
        label: 'edit: $f',
        icon: Icons.edit_note_rounded,
        editTargetPath: p.isNotEmpty ? p : null,
      );
    }
    if (name == 'write_file') {
      final p = FileUtils.cleanPath(args['Path'] ?? args['path']);
      final f = p.isEmpty ? '文件' : p.split(RegExp(r'[\\/]')).last;
      return ToolChipPresentation(
        label: 'write: $f',
        icon: Icons.post_add_rounded,
        editTargetPath: p.isNotEmpty ? p : null,
      );
    }
    if (name == 'read_file') {
      final p = FileUtils.cleanPath(args['Path'] ?? args['path']);
      final f = p.isEmpty ? '文件' : p.split(RegExp(r'[\\/]')).last;
      return ToolChipPresentation(
        label: 'read: $f',
        icon: Icons.menu_book_rounded,
      );
    }
    if (name == 'run_command') {
      final summary = (args['toolSummary'] ?? '').toString().trim();
      final cmdLine = (args['CommandLine'] ?? args['command'] ?? '').toString().trim();
      final pluginCli = _detectPluginCliCommand(cmdLine);
      if (pluginCli != null) {
        return ToolChipPresentation(
          label: summary.isNotEmpty ? '${pluginCli.prefix}: $summary' : pluginCli.prefix,
          icon: pluginCli.icon,
          isPluginOrMcp: true,
        );
      }
      return ToolChipPresentation(
        label: summary.isNotEmpty ? summary : 'run_command',
        icon: Icons.terminal_rounded,
      );
    }
    if (name == 'call_mcp_tool') {
      final server = (args['ServerName'] ?? args['server'] ?? '').toString().trim();
      final toolName = (args['ToolName'] ?? args['tool'] ?? '').toString().trim();
      final cleanServer = server.contains('_') ? server.split('_').first : server;
      final label = [cleanServer, toolName].where((e) => e.isNotEmpty).join('/');
      return ToolChipPresentation(
        label: label.isNotEmpty ? 'MCP: $label' : 'MCP 工具调用',
        icon: Icons.hub_rounded,
        isPluginOrMcp: true,
      );
    }
    if (name.startsWith('mcp_')) {
      final summary = (args['toolSummary'] ?? '').toString().trim();
      final shortName = name.replaceFirst('mcp_', '').replaceAll('_', ' ');
      return ToolChipPresentation(
        label: summary.isNotEmpty ? 'MCP: $summary' : 'MCP: $shortName',
        icon: Icons.hub_rounded,
        isPluginOrMcp: true,
      );
    }
    if (name == 'list_plugin_accounts') {
      return const ToolChipPresentation(
        label: '检查插件账号',
        icon: Icons.manage_accounts_outlined,
        isPluginOrMcp: true,
      );
    }
    if (name == 'search_marketplace') {
      final rawQueries = args['queries'];
      final qText = rawQueries is List && rawQueries.isNotEmpty ? rawQueries.first.toString().trim() : '';
      return ToolChipPresentation(
        label: qText.isNotEmpty ? '插件市场: $qText' : '搜索插件市场',
        icon: Icons.extension_rounded,
        isPluginOrMcp: true,
      );
    }
    if (name == 'search_web') {
      final q = (args['query'] ?? '').toString().trim();
      return ToolChipPresentation(
        label: q.isNotEmpty ? '搜索: $q' : '网页搜索',
        icon: Icons.travel_explore_rounded,
      );
    }
    if (name == 'invoke_subagent') {
      final role = (args['Role'] ?? args['TypeName'] ?? '').toString().trim();
      return ToolChipPresentation(
        label: role.isNotEmpty ? '子代理: $role' : '启动子代理',
        icon: Icons.smart_toy_outlined,
      );
    }
    if (name == 'webview_browser') {
      return const ToolChipPresentation(
        label: '浏览器操作',
        icon: Icons.language_rounded,
      );
    }
    if (name == 'generate_image') {
      return const ToolChipPresentation(
        label: '生成图片',
        icon: Icons.image_outlined,
      );
    }
    if (name == 'schedule') {
      return const ToolChipPresentation(
        label: '定时任务',
        icon: Icons.alarm_rounded,
      );
    }
    if (name == 'ask_question') {
      return const ToolChipPresentation(
        label: '交互确认',
        icon: Icons.quiz_outlined,
      );
    }
    if (name == 'update_steps') {
      return const ToolChipPresentation(
        label: '更新进度',
        icon: Icons.checklist_rounded,
      );
    }
    if (name == 'update_focus') {
      final focus = (args['focus'] ?? '').toString().trim();
      return ToolChipPresentation(
        label: focus.isNotEmpty ? focus : '更新焦点',
        icon: Icons.track_changes_rounded,
      );
    }
    if (name == 'enter_plan_mode' || name == 'exit_plan_mode') {
      return ToolChipPresentation(
        label: name == 'enter_plan_mode' ? '进入规划模式' : '提交执行计划',
        icon: Icons.architecture_rounded,
      );
    }

    return ToolChipPresentation(
      label: name.isNotEmpty ? name : 'tool',
      icon: Icons.settings_suggest_rounded,
    );
  }

  static ({String prefix, IconData icon})? _detectPluginCliCommand(String cmdLine) {
    if (cmdLine.isEmpty) return null;
    final lower = cmdLine.toLowerCase();
    final checks = <({RegExp re, String prefix, IconData icon})>[
      (re: RegExp(r'(?:^|[\s;&|])gmail(?:\.cmd|\.exe)?(?:\s|$)'), prefix: 'Gmail', icon: Icons.mail_outline_rounded),
      (re: RegExp(r'(?:^|[\s;&|])gcalendar(?:\.cmd|\.exe)?(?:\s|$)'), prefix: 'Calendar', icon: Icons.calendar_month_outlined),
      (re: RegExp(r'(?:^|[\s;&|])gdrive(?:\.cmd|\.exe)?(?:\s|$)'), prefix: 'Drive', icon: Icons.add_to_drive_rounded),
      (re: RegExp(r'(?:^|[\s;&|])gdocs(?:\.cmd|\.exe)?(?:\s|$)'), prefix: 'Docs', icon: Icons.description_outlined),
      (re: RegExp(r'(?:^|[\s;&|])gsheets(?:\.cmd|\.exe)?(?:\s|$)'), prefix: 'Sheets', icon: Icons.table_chart_outlined),
      (re: RegExp(r'(?:^|[\s;&|])gslides(?:\.cmd|\.exe)?(?:\s|$)'), prefix: 'Slides', icon: Icons.slideshow_outlined),
      (re: RegExp(r'(?:^|[\s;&|])canva(?:\.cmd|\.exe)?(?:\s|$)'), prefix: 'Canva', icon: Icons.palette_outlined),
    ];
    for (final item in checks) {
      if (item.re.hasMatch(lower)) {
        return (prefix: item.prefix, icon: item.icon);
      }
    }
    return null;
  }
}

class PluginPresenceCard extends StatefulWidget {
  final PluginCardInfo info;
  final bool isDark;
  final String nodeName;
  final Future<String?> Function(String replyText)? onQuickReply;

  const PluginPresenceCard({
    super.key,
    required this.info,
    required this.isDark,
    this.nodeName = '',
    this.onQuickReply,
  });

  @override
  State<PluginPresenceCard> createState() => _PluginPresenceCardState();
}

class _PluginPresenceCardState extends State<PluginPresenceCard> {
  bool _sending = false;
  bool _sent = false;

  Future<void> _sendRetryPrompt() async {
    if (widget.onQuickReply == null || _sending) return;
    setState(() => _sending = true);
    final prompt = widget.info.isAuthRequired
        ? '我已在宿主机完成 ${widget.info.displayName} 插件重新登录，请继续刚才的操作。'
        : '我已在宿主机处理好 ${widget.info.displayName} 插件，请继续。';
    final err = await widget.onQuickReply!(prompt);
    if (!mounted) return;
    setState(() {
      _sending = false;
      if (err == null) _sent = true;
    });
    if (err != null) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(err), backgroundColor: Colors.redAccent.shade700),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final isDark = widget.isDark;
    final primary = Theme.of(context).colorScheme.primary;
    final isAuth = widget.info.isAuthRequired;
    final accent = isAuth ? AppColors.statusAmber(isDark) : primary;
    final bgColor = isAuth
        ? (isDark ? const Color(0xFF231D12) : const Color(0xFFFFFBEB))
        : (isDark ? const Color(0xFF16181F) : const Color(0xFFF8FAFC));
    final borderColor = isAuth
        ? accent.withValues(alpha: isDark ? 0.45 : 0.4)
        : (isDark ? const Color(0xFF2C2F3A) : const Color(0xFFE2E8F0));
    final hostLabel = widget.nodeName.trim().isNotEmpty ? '【${widget.nodeName.trim()}】' : '宿主机';

    return Container(
      margin: const EdgeInsets.only(top: 10),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: bgColor,
        borderRadius: BorderRadius.circular(11),
        border: Border.all(color: borderColor),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 30,
                height: 30,
                decoration: BoxDecoration(
                  color: accent.withValues(alpha: isDark ? 0.18 : 0.12),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Icon(widget.info.icon, size: 17, color: accent),
              ),
              const SizedBox(width: 9),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Flexible(
                          child: Text(
                            widget.info.displayName,
                            style: TextStyle(
                              fontSize: 13,
                              fontWeight: FontWeight.w700,
                              color: isDark ? Colors.white : const Color(0xFF18181B),
                            ),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        const SizedBox(width: 6),
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1.5),
                          decoration: BoxDecoration(
                            color: accent.withValues(alpha: isDark ? 0.22 : 0.14),
                            borderRadius: BorderRadius.circular(5),
                          ),
                          child: Text(
                            isAuth ? '需重新登录' : '插件卡片',
                            style: TextStyle(
                              fontSize: 10,
                              fontWeight: FontWeight.w700,
                              color: accent,
                            ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 1),
                    Text(
                      widget.info.subtitle,
                      style: TextStyle(
                        fontSize: 11,
                        color: isDark ? Colors.white54 : Colors.black54,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            isAuth
                ? 'OAuth 授权由宿主机客户端托管，远程端暂无法直接登录。请在$hostLabel的 Antigravity → Plugins Manager 中重新点击 Sign in，完成后可点下方按钮重试。'
                : '该卡片对应 Antigravity 插件（ID: ${widget.info.catalogId}）。请在$hostLabel的 Antigravity 插件市场中安装或启用。',
            style: TextStyle(
              fontSize: 11.5,
              height: 1.48,
              color: isDark ? const Color(0xFFD4D4D8) : const Color(0xFF3F3F46),
            ),
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 6,
            alignment: WrapAlignment.spaceBetween,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              InkWell(
                borderRadius: BorderRadius.circular(6),
                onTap: () {
                  Clipboard.setData(ClipboardData(text: widget.info.catalogId));
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(
                      content: Text('已复制插件 ID: ${widget.info.catalogId}'),
                      duration: const Duration(seconds: 1),
                    ),
                  );
                },
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 3),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.copy_rounded, size: 12, color: isDark ? Colors.white54 : Colors.black45),
                      const SizedBox(width: 4),
                      Text(
                        '复制插件 ID',
                        style: TextStyle(
                          fontSize: 11,
                          color: isDark ? Colors.white54 : Colors.black54,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              if (widget.onQuickReply != null)
                _sent
                    ? Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(Icons.check_circle_outline_rounded, size: 14, color: AppColors.statusGreen(isDark)),
                          const SizedBox(width: 4),
                          Text(
                            '已通知重试',
                            style: TextStyle(
                              fontSize: 11.5,
                              fontWeight: FontWeight.w600,
                              color: AppColors.statusGreen(isDark),
                            ),
                          ),
                        ],
                      )
                    : FilledButton.tonalIcon(
                        onPressed: _sending ? null : _sendRetryPrompt,
                        style: FilledButton.styleFrom(
                          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                          minimumSize: Size.zero,
                          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                          backgroundColor: accent.withValues(alpha: isDark ? 0.22 : 0.14),
                          foregroundColor: accent,
                        ),
                        icon: _sending
                            ? SizedBox(
                                width: 12,
                                height: 12,
                                child: CircularProgressIndicator(strokeWidth: 1.8, color: accent),
                              )
                            : const Icon(Icons.refresh_rounded, size: 14),
                        label: Text(
                          isAuth ? '我已登录，重试' : '已安装，继续',
                          style: const TextStyle(fontSize: 11.5, fontWeight: FontWeight.w600),
                        ),
                      ),
            ],
          ),
        ],
      ),
    );
  }
}

class ActionNeededCard extends StatefulWidget {
  final ActionNeededNotice notice;
  final bool isDark;
  final Future<String?> Function(String replyText)? onQuickReply;

  const ActionNeededCard({
    super.key,
    required this.notice,
    required this.isDark,
    this.onQuickReply,
  });

  @override
  State<ActionNeededCard> createState() => _ActionNeededCardState();
}

class _ActionNeededCardState extends State<ActionNeededCard> {
  bool _sending = false;
  bool _sent = false;

  Future<void> _handleContinue() async {
    if (widget.onQuickReply == null || _sending) return;
    setState(() => _sending = true);
    final err = await widget.onQuickReply!(widget.notice.retryPrompt);
    if (!mounted) return;
    setState(() {
      _sending = false;
      if (err == null) _sent = true;
    });
    if (err != null) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(err), backgroundColor: Colors.redAccent.shade700),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final isDark = widget.isDark;
    final accent = AppColors.statusAmber(isDark);
    return Container(
      margin: const EdgeInsets.only(top: 10),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: isDark ? const Color(0xFF231D12) : const Color(0xFFFFFBEB),
        borderRadius: BorderRadius.circular(11),
        border: Border.all(color: accent.withValues(alpha: isDark ? 0.45 : 0.4)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(widget.notice.icon, size: 17, color: accent),
              const SizedBox(width: 7),
              Expanded(
                child: Text(
                  widget.notice.title,
                  style: TextStyle(
                    fontSize: 12.5,
                    fontWeight: FontWeight.w700,
                    color: accent,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            widget.notice.description,
            style: TextStyle(
              fontSize: 11.5,
              height: 1.48,
              color: isDark ? const Color(0xFFD4D4D8) : const Color(0xFF3F3F46),
            ),
          ),
          if (widget.onQuickReply != null) ...[
            const SizedBox(height: 8),
            Align(
              alignment: Alignment.centerRight,
              child: _sent
                  ? Text(
                      '已通知继续执行',
                      style: TextStyle(
                        fontSize: 11.5,
                        fontWeight: FontWeight.w600,
                        color: AppColors.statusGreen(isDark),
                      ),
                    )
                  : FilledButton.tonalIcon(
                      onPressed: _sending ? null : _handleContinue,
                      style: FilledButton.styleFrom(
                        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                        minimumSize: Size.zero,
                        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                        backgroundColor: accent.withValues(alpha: isDark ? 0.22 : 0.14),
                        foregroundColor: accent,
                      ),
                      icon: _sending
                          ? SizedBox(
                              width: 12,
                              height: 12,
                              child: CircularProgressIndicator(strokeWidth: 1.8, color: accent),
                            )
                          : const Icon(Icons.play_arrow_rounded, size: 15),
                      label: const Text('我已处理，继续', style: TextStyle(fontSize: 11.5, fontWeight: FontWeight.w600)),
                    ),
            ),
          ],
        ],
      ),
    );
  }
}

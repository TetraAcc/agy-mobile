import 'package:flutter/material.dart';

class SlashCommandOption {
  final String command;
  final String label;
  final String description;
  final IconData icon;

  const SlashCommandOption({
    required this.command,
    required this.label,
    required this.description,
    required this.icon,
  });
}

const List<SlashCommandOption> kOfficialSlashCommands = [
  SlashCommandOption(
    command: "/goal",
    label: "目标长程自治执行",
    description: "运行高自治度的长期复杂任务，直到彻底达成目标",
    icon: Icons.flag_rounded,
  ),
  SlashCommandOption(
    command: "/plan",
    label: "深度规划分析",
    description: "在编码或修改前进行严谨的逐步拆解与架构推演",
    icon: Icons.alt_route_rounded,
  ),
  SlashCommandOption(
    command: "/compact",
    label: "压缩会话上下文",
    description: "压缩并精简过长的历史记录，释放上下文窗口与 Token",
    icon: Icons.compress_rounded,
  ),
  SlashCommandOption(
    command: "/schedule",
    label: "定时自动化任务",
    description: "创建单次倒计时或 Cron 周期性定时任务",
    icon: Icons.schedule_rounded,
  ),
  SlashCommandOption(
    command: "/browser",
    label: "网页浏览与交互",
    description: "启动内置浏览器执行网页自动化、测试与数据抓取",
    icon: Icons.language_rounded,
  ),
  SlashCommandOption(
    command: "/boost",
    label: "全方位深度思考",
    description: "开启高阶推理、多视角审查与严格代码验证",
    icon: Icons.rocket_launch_rounded,
  ),
  SlashCommandOption(
    command: "/learn",
    label: "记录纠偏与经验",
    description: "持久化保存本次解决的复杂配置或纠错知识库",
    icon: Icons.psychology_rounded,
  ),
  SlashCommandOption(
    command: "/teamwork",
    label: "多 Agent 团队协作",
    description: "构建自主协同的多 Agent 协作流水线",
    icon: Icons.groups_rounded,
  ),
  SlashCommandOption(
    command: "/plugin",
    label: "插件与技能管理",
    description: "管理、启用或搜索安装生态中的定制化扩展插件",
    icon: Icons.extension_rounded,
  ),
];

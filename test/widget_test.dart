import 'package:flutter_test/flutter_test.dart';
import 'package:agy_remote/models/models.dart';
import 'package:agy_remote/constants/app_colors.dart';
import 'package:agy_remote/utils/file_utils.dart';

void main() {
  group('官方模型与指令配置测试', () {
    test('官方真实模型矩阵完整性与思考分级', () {
      expect(kAllOfficialModels.isNotEmpty, true);
      final modelIds = kAllOfficialModels.map((m) => m.id).toList();
      expect(modelIds.contains('gemini-3.8-flash-high'), true);
      expect(modelIds.contains('gemini-3.8-flash-medium'), true);
      expect(modelIds.contains('gemini-3.8-flash-low'), true);
      expect(modelIds.contains('claude-sonnet-4-6'), true);
      expect(modelIds.contains('claude-opus-4-6-thinking'), true);
      expect(modelIds.contains('gpt-oss-120b-medium'), true);
      expect(modelIds.contains('gemini-2.5-pro'), true);

      // 验证思考标签有效性
      final flashHigh = kAllOfficialModels.firstWhere((m) => m.id == 'gemini-3.8-flash-high');
      expect(flashHigh.thinkingBadge, 'High');
    });

    test('官方斜杠指令完整性', () {
      expect(kOfficialSlashCommands.isNotEmpty, true);
      final commands = kOfficialSlashCommands.map((c) => c.command).toList();
      expect(commands.contains('/goal'), true);
      expect(commands.contains('/plan'), true);
      expect(commands.contains('/compact'), true);
      expect(commands.contains('/browser'), true);
      expect(commands.contains('/schedule'), true);
    });
  });

  group('AgentMessage 消息解析与标签智能清洗测试', () {
    test('准确提取 USER_REQUEST 标签并剥离系统标签', () {
      const rawText = '''
<USER_REQUEST>
帮我写一个快速排序算法
</USER_REQUEST>
<ADDITIONAL_METADATA>
The current local time is: 2026-11-21T07:00:00+09:00.
</ADDITIONAL_METADATA>
<SYSTEM_MESSAGE>
Some internal instructions here.
</SYSTEM_MESSAGE>
''';
      final msg = AgentMessage.fromJson({
        'step_index': 1,
        'source': 'USER_EXPLICIT',
        'msg_type': 'USER_INPUT',
        'status': 'DONE',
        'content': rawText,
        'thinking': '',
        'tool_calls': [],
      });

      expect(msg.isUser, true);
      expect(msg.content, '帮我写一个快速排序算法');
      expect(msg.content.contains('ADDITIONAL_METADATA'), false);
      expect(msg.content.contains('SYSTEM_MESSAGE'), false);
    });

    test('纯工具步骤判定 (isPureToolStep)', () {
      final toolMsg = AgentMessage.fromJson({
        'step_index': 2,
        'source': 'AGENT',
        'msg_type': 'PLANNER_RESPONSE',
        'status': 'DONE',
        'content': '',
        'thinking': '',
        'tool_calls': [{'name': 'run_command', 'args': {}}],
      });

      expect(toolMsg.isPureToolStep, true);
      expect(toolMsg.isUser, false);
    });

    test('普通 Agent 思考回复与普通文本', () {
      final normalMsg = AgentMessage.fromJson({
        'step_index': 3,
        'source': 'AGENT',
        'msg_type': 'PLANNER_RESPONSE',
        'status': 'DONE',
        'content': '已为你完成算法实现。',
        'thinking': '正在推导时间复杂度为 O(N log N)...',
        'tool_calls': [],
      });

      expect(normalMsg.isPureToolStep, false);
      expect(normalMsg.content, '已为你完成算法实现。');
      expect(normalMsg.thinking.isNotEmpty, true);
    });
  });

  group('主机节点与工程结构模型解析测试', () {
    test('HostNode 解析', () {
      final node = HostNode.fromJson({
        'id': 'windows',
        'name': 'Windows PC',
        'online': true,
      });
      expect(node.id, 'windows');
      expect(node.name, 'Windows PC');
      expect(node.isOnline, true);
    });

    test('SessionItem 解析', () {
      final session = SessionItem.fromJson({
        'id': 'sess-123',
        'title': 'Agy网页版开发',
        'time': '2026-11-21',
        'is_active': true,
        'workspace_path': r'C:\Users\User\Projects\demo',
      });
      expect(session.id, 'sess-123');
      expect(session.title, 'Agy网页版开发');
      expect(session.isActive, true);
      expect(session.workspacePath, r'C:\Users\User\Projects\demo');
    });

    test('FileItem 解析', () {
      final file = FileItem.fromJson({
        'name': 'main.dart',
        'is_dir': false,
        'path': 'lib/main.dart',
        'size': 12345,
      });
      expect(file.name, 'main.dart');
      expect(file.isDir, false);
      expect(file.size, 12345);
    });

    test('AppColors 常量与多主题矩阵有效性', () {
      expect(AppColors.darkBg.value, 0xFF0B0F19);
      expect(AppColors.primarySky.value, 0xFF38BDF8);
      expect(AppColors.onlineGreen.value, 0xFF10B981);
      expect(AppColors.accentThemes.length, 5);
      final emerald = AppColors.getThemeById('emerald');
      expect(emerald.id, 'emerald');
      expect(emerald.name.contains('翡翠'), true);
      final fallback = AppColors.getThemeById('non_existent');
      expect(fallback.id, 'emerald');
    });
  });

  group('FileUtils 工具类测试', () {
    test('isBinaryFile 正确识别纯文本与二进制后缀', () {
      expect(FileUtils.isBinaryFile('test.dart'), false);
      expect(FileUtils.isBinaryFile('README.md'), false);
      expect(FileUtils.isBinaryFile('main.py'), false);
      expect(FileUtils.isBinaryFile('archive.zip'), true);
      expect(FileUtils.isBinaryFile('doc.pdf'), true);
      expect(FileUtils.isBinaryFile('binary.wasm'), true);
      expect(FileUtils.isBinaryFile('photo.png'), true);
    });

    test('cleanPath 与 cleanCodeString 处理', () {
      expect(FileUtils.cleanPath('"C:\\test\\path.dart"'), 'C:\\test\\path.dart');
      expect(FileUtils.cleanCodeString(r'"print(\"hello\nworld\")"'), 'print("hello\nworld")');
    });

    test('parseToolArgs 解析各种格式', () {
      expect(FileUtils.parseToolArgs({'a': 1})['a'], 1);
      expect(FileUtils.parseToolArgs('{"b": 2}')['b'], 2);
      expect(FileUtils.parseToolArgs('invalid json'), {});
      expect(FileUtils.parseToolArgs(null), {});
    });

    test('extractDownloadableFiles 识别正文生成文件', () {
      const text = '文件已保存到 C:\\Users\\user\\report.pdf 和 /home/deck/output.zip，请查收。';
      final files = FileUtils.extractDownloadableFiles(text);
      expect(files.length, 2);
      expect(files.contains(r'C:\Users\user\report.pdf'), true);
      expect(files.contains('/home/deck/output.zip'), true);
    });
  });
}

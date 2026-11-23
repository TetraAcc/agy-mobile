import 'package:agy_remote/core/platform/android_native_bridge.dart';
import 'package:agy_remote/core/theme/app_colors.dart';
import 'package:agy_remote/core/theme/app_fonts.dart';
import 'package:agy_remote/core/utils/file_utils.dart';
import 'package:agy_remote/models/models.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('v2 模型与官方配置测试', () {
    test('官方模型矩阵完整性', () {
      final modelIds = kAllOfficialModels.map((m) => m.id).toList();
      expect(modelIds, containsAll(['gemini-3.8-flash-high', 'claude-sonnet-4-6', 'gemini-2.5-pro']));
    });

    test('SessionChangesData、GitRepoItem 与 ReviewCommentItem 解析与格式化', () {
      final changes = SessionChangesData.fromJson({
        'session_id': 's1',
        'total_files': 1,
        'total_added': 2,
        'total_removed': 1,
        'files': [
          {
            'file_path': 'C:/novel/ch1.md',
            'file_name': 'ch1.md',
            'directory': 'C:/novel',
            'added_lines': 2,
            'removed_lines': 1,
            'edit_count': 1,
            'last_step_index': 5,
            'hunks': [
              {
                'hunk_id': 's5_h1',
                'step_index': 5,
                'tool_name': 'edit_file',
                'start_line': 12,
                'end_line': 12,
                'added_lines': 1,
                'removed_lines': 1,
                'before_text': '旧句子',
                'after_text': '新句子',
                'inline_segments': [
                  {'kind': 'delete', 'text': '旧'},
                  {'kind': 'insert', 'text': '新'},
                  {'kind': 'equal', 'text': '句子'},
                ],
              },
            ],
          },
        ],
      });
      expect(changes.totalFiles, 1);
      expect(changes.files.first.hunks.first.lineLabel, 'L12 · Step 5');
      expect(changes.files.first.hunks.first.inlineSegments.length, 3);

      final repo = GitRepoItem.fromJson({
        'id': 'scratch/agy_mobile_app',
        'root_id': 'scratch',
        'sub_path': 'agy_mobile_app',
        'name': 'agy_mobile_app',
        'branch': 'main',
        'change_count': 3,
      });
      expect(repo.displayLabel, 'agy_mobile_app (main · 3 处变更)');

      final prompt = ReviewCommentItem.formatReviewPrompt([
        const ReviewCommentItem(
          id: 'c1',
          filePath: 'C:/novel/ch1.md',
          fileName: 'ch1.md',
          locationLabel: 'L12 · Step 5',
          excerpt: '新句子',
          comment: '语气再克制一些',
        ),
      ]);
      expect(prompt, contains('**ch1.md**'));
      expect(prompt, contains('L12 · Step 5'));
      expect(prompt, contains('语气再克制一些'));
    });

    test('UserProfile 与 HostNode 权限解析', () {
      final user = UserProfile.fromJson({
        'id': 1,
        'username': 'tetra',
        'display_name': 'Tetra',
        'role': 'admin',
        'default_node': 'windows',
        'allowed_nodes': ['windows', 'deck'],
        'node_permissions': {
          'windows': {'node_id': 'windows', 'can_write': true, 'can_delete': true},
          'deck': {'node_id': 'deck', 'can_write': true, 'can_delete': false},
        },
      });
      expect(user.isAdmin, true);
      expect(user.permissionFor('windows')?.canDelete, true);
      expect(user.permissionFor('deck')?.canDelete, false);

      final node = HostNode.fromJson({
        'id': 'windows',
        'name': 'Windows PC',
        'online': true,
        'engine_alive': true,
        'can_write': true,
        'can_delete': false,
      });
      expect(node.isOnline, true);
      expect(node.engineAlive, true);
      expect(node.canWrite, true);
      expect(node.canDelete, false);
    });

    test('SessionTreeData 解析 is_pinned 与 root_id', () {
      final tree = SessionTreeData.fromJson({
        'projects': {
          'DemoProj': [
            {
              'id': 's1',
              'title': 'Pinned Task',
              'updated_at': '2026-11-23',
              'is_pinned': true,
              'is_running': true,
              'workspace_path': r'C:\proj',
              'root_id': 'ws_123',
            },
          ],
        },
        'general_sessions': [],
        'engine_alive': true,
        'running_session_ids': ['s1'],
      });
      expect(tree.projects['DemoProj']?.first.isPinned, true);
      expect(tree.projects['DemoProj']?.first.rootId, 'ws_123');
      expect(tree.runningSessionIds.contains('s1'), true);
    });

    test('AgentMessage 清洗用户请求并解析 tool_calls.args', () {
      final userMsg = AgentMessage.fromJson({
        'step_index': 1,
        'source': 'USER_EXPLICIT',
        'msg_type': 'USER_INPUT',
        'status': 'DONE',
        'content': '<USER_REQUEST>\n测试内容\n</USER_REQUEST>\n<SYSTEM_MESSAGE>hidden</SYSTEM_MESSAGE>',
        'tool_calls': [],
      });
      expect(userMsg.isUser, true);
      expect(userMsg.content, '测试内容');

      final toolMsg = AgentMessage.fromJson({
        'step_index': 2,
        'source': 'MODEL',
        'msg_type': 'PLANNER_RESPONSE',
        'status': 'DONE',
        'content': '',
        'thinking': '',
        'tool_calls': [
          {'name': 'edit_file', 'args': {'Path': 'lib/main.dart'}},
        ],
      });
      expect(toolMsg.isPureToolStep, true);
      expect(toolMsg.toolCalls.first.args['Path'], 'lib/main.dart');
    });

    test('QuotaData 解析 snake_case 契约', () {
      final quota = QuotaData.fromJson({
        'groups': [
          {
            'display_name': 'Gemini',
            'buckets': [
              {
                'bucket_id': '5h',
                'display_name': '5h Sliding',
                'window': '5h',
                'remaining_fraction': 0.769,
                'reset_time': '2026-11-23T06:00:00Z',
              },
            ],
          },
        ],
        'description': 'ok',
      });
      expect(quota.groups.length, 1);
      expect(quota.groups.first.displayName, 'Gemini');
      expect(quota.groups.first.buckets.first.remainingFraction, closeTo(0.769, 0.0001));
    });
  });

  group('AppColors 与 FileUtils 测试', () {
    test('AppColors 常量检查与日/夜间双色适配', () {
      expect(AppColors.darkBg.toARGB32(), 0xFF111113);
      expect(AppColors.lightBg.toARGB32(), 0xFFFFFFFF);
      expect(AppColors.accentThemes.length, 6);
      expect(AppColors.getThemeById('non_existent').id, 'emerald');
      for (final opt in AppColors.accentThemes) {
        expect(opt.lightPrimary, isNot(opt.primary));
        expect(opt.lightPrimary.computeLuminance(), lessThan(0.25));
        expect(opt.primaryFor(true), opt.primary);
        expect(opt.primaryFor(false), opt.lightPrimary);
        expect(opt.secondaryFor(true), opt.secondary);
        expect(opt.secondaryFor(false), opt.lightSecondary);
        expect(opt.previewFor(true), opt.previewColor);
        expect(opt.previewFor(false), opt.lightPreviewColor);
      }
      expect(AppColors.statusGreen(false).computeLuminance(), lessThan(0.25));
      expect(AppColors.statusAmber(false).computeLuminance(), lessThan(0.25));
      expect(AppColors.statusRed(false).computeLuminance(), lessThan(0.25));
    });

    test('FileUtils 二进制、图片与 PDF 识别与路径提取', () {
      expect(FileUtils.isBinaryFile('app.dart'), false);
      expect(FileUtils.isBinaryFile('bundle.zip'), true);
      expect(FileUtils.isBinaryFile('doc.pdf'), true);
      expect(FileUtils.isPdfFile('讲义_100%.PDF'), true);
      expect(FileUtils.isPdfFile('app.dart'), false);
      expect(FileUtils.isImageFile('shot.png'), true);
      expect(FileUtils.isImageFile('diagram.SVG'), true);
      expect(FileUtils.isImageFile('doc.pdf'), false);
      final files = FileUtils.extractDownloadableFiles(r'生成文件 C:\temp\out.pdf 和 /home/deck/a.zip');
      expect(files.length, 2);
    });

    test('桌面端移植模型 PlanStepItem AskQuestionItem 与 ToolCallOutputData 解析', () {
      const msg1 = AgentMessage(
        stepIndex: 1,
        source: 'MODEL',
        msgType: 'PLANNER_RESPONSE',
        status: 'DONE',
        content: '',
        thinking: '',
        toolCalls: [
          ToolCallItem(
            name: 'update_steps',
            args: {
              'steps': [
                {'title': '准备环境', 'status': 'done'},
                {'title': '运行测试', 'status': 'in_progress'},
              ],
            },
          ),
          ToolCallItem(name: 'update_focus', args: {'focus': '正在排查测试日志'}),
          ToolCallItem(
            name: 'ask_question',
            args: {
              'questions': [
                {
                  'question': '希望先移植哪项？',
                  'options': ['Artifacts 面板', '文件轻编辑'],
                  'is_multi_select': true,
                },
              ],
            },
          ),
        ],
        timestamp: '',
      );

      final steps = PlanStepItem.extractLatestSteps([msg1]);
      expect(steps.length, 2);
      expect(steps.first.status, 'done');
      expect(steps.last.title, '运行测试');
      expect(PlanStepItem.extractLatestFocus([msg1]), '正在排查测试日志');

      const userMsg = AgentMessage(
        stepIndex: 2,
        source: 'USER_EXPLICIT',
        msgType: 'USER_INPUT',
        status: 'DONE',
        content: '继续',
        thinking: '',
        toolCalls: [],
        timestamp: '',
      );
      expect(PlanStepItem.extractLatestFocus([msg1, userMsg]), '');

      final qs = AskQuestionItem.parseFromTool(msg1.toolCalls[2]);
      expect(qs.length, 1);
      expect(qs.first.isMultiSelect, true);
      expect(qs.first.options, ['Artifacts 面板', '文件轻编辑']);

      final toolOut = ToolCallOutputData.fromJson({
        'session_id': 's1',
        'step_index': 3,
        'result_step_index': 4,
        'status': 'DONE',
        'output': 'all green',
        'truncated': false,
        'tool_calls': [
          {'name': 'run_command', 'args': {'CommandLine': 'pytest'}},
        ],
      });
      expect(toolOut.resultStepIndex, 4);
      expect(toolOut.output, 'all green');

      final saveRes = FileSaveResult.fromJson({
        'ok': true,
        'root_id': 'scratch',
        'path': 'ch01.md',
        'name': 'ch01.md',
        'size': 20,
        'total_lines': 2,
        'mtime': 1234.5,
      });
      expect(saveRes.mtime, closeTo(1234.5, 0.01));

      final queueData = SessionQueueData.fromJson({
        'session_id': 's9',
        'paused': true,
        'last_error': 'timeout',
        'items': [
          {'id': 'q1', 'content': '下一条指令', 'model': 'gemini-3.8-flash-high', 'created_at': 99.5},
        ],
      });
      expect(queueData.sessionId, 's9');
      expect(queueData.paused, true);
      expect(queueData.lastError, 'timeout');
      expect(queueData.items.length, 1);
      expect(queueData.items.first.id, 'q1');
      expect(queueData.items.first.content, '下一条指令');
    });

    test('AndroidNativeBridge inferMimeType 与 SharedIncomingPayload 解析', () {
      expect(AndroidNativeBridge.inferMimeType('report.pdf'), 'application/pdf');
      expect(AndroidNativeBridge.inferMimeType('shot.PNG'), 'image/png');
      expect(AndroidNativeBridge.inferMimeType('photo.jpeg'), 'image/jpeg');
      expect(AndroidNativeBridge.inferMimeType('demo.mp4'), 'video/mp4');
      expect(AndroidNativeBridge.inferMimeType('clip.mkv'), 'video/x-matroska');
      expect(AndroidNativeBridge.inferMimeType('voice.mp3'), 'audio/mpeg');
      expect(AndroidNativeBridge.inferMimeType('notes.md'), 'text/markdown');
      expect(AndroidNativeBridge.inferMimeType('archive.zip'), 'application/zip');
      expect(AndroidNativeBridge.inferMimeType('noext'), '*/*');
      expect(FileUtils.isVideoFile('demo.mp4'), true);
      expect(FileUtils.isAudioFile('voice.mp3'), true);
      expect(FileUtils.isMediaStreamFile('demo.mp4'), true);

      final share = SharedIncomingPayload.fromMap({
        'text': 'https://example.com/issue',
        'files': [
          {'path': '/tmp/a.png', 'name': 'a.png', 'mimeType': 'image/png'},
          {'path': '/tmp/doc.pdf', 'name': 'doc.pdf', 'mimeType': 'application/pdf'},
        ],
      });
      expect(share.isEmpty, false);
      expect(share.files.length, 2);
      expect(share.files[0].isImage, true);
      expect(share.files[1].isImage, false);

      expect(AppFonts.options.length, 4);
      expect(AppFonts.getById('wenkai').remoteFile, 'LXGWWenKaiLite-Regular.ttf');
      expect(AppFonts.getById('serif').remoteFile, 'NotoSerifSC-Regular.ttf');
      expect(AppFonts.getById('unknown').id, 'system');
    });
  });
}

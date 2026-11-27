import 'dart:async';
import 'dart:convert';

import 'package:agy_remote/core/config/composer_prefs.dart';
import 'package:agy_remote/core/config/offline_outbox_store.dart';
import 'package:agy_remote/core/config/quick_commands_prefs.dart';
import 'package:agy_remote/core/config/responsive_layout.dart';
import 'package:agy_remote/core/config/server_config.dart';
import 'package:agy_remote/core/network/token_store.dart';
import 'package:agy_remote/core/platform/platform_bridge.dart';
import 'package:agy_remote/features/auth/auth_controller.dart';
import 'package:agy_remote/features/auth/login_screen.dart';
import 'package:agy_remote/features/chat/bottom_input_bar.dart';
import 'package:agy_remote/features/chat/code_block_builder.dart';
import 'package:agy_remote/features/chat/context_menu_sheet.dart';
import 'package:agy_remote/features/chat/markdown_message_body.dart';
import 'package:agy_remote/features/chat/message_card.dart';
import 'package:agy_remote/features/chat/model_picker_sheet.dart';
import 'package:agy_remote/features/chat/offline_outbox_bar.dart';
import 'package:agy_remote/features/chat/quick_commands_sheet.dart';
import 'package:agy_remote/features/chat/rich_presence_cards.dart';
import 'package:agy_remote/features/chat/session_queue_bar.dart';
import 'package:agy_remote/features/chat/session_steps_bar.dart';
import 'package:agy_remote/features/chat/tool_approval_card.dart';
import 'package:agy_remote/features/hub/download_progress_dialog.dart';
import 'package:agy_remote/features/hub/node_power_banner.dart';
import 'package:agy_remote/features/sessions/new_session_dialog.dart';
import 'package:agy_remote/features/sessions/quota_drawer.dart';
import 'package:agy_remote/features/workspace/change_review_sheet.dart';
import 'package:agy_remote/features/workspace/file_viewer_sheet.dart';
import 'package:agy_remote/features/workspace/session_changes_bar.dart';
import 'package:agy_remote/features/workspace/terminal_panel.dart';
import 'package:agy_remote/features/workspace/workspace_file_picker_dialog.dart';
import 'package:agy_remote/models/models.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:web_socket_channel/web_socket_channel.dart';
import 'package:xterm/xterm.dart';

class _TestAuthController extends AuthController {
  @override
  AuthState build() {
    return AuthState(
      status: AuthStatus.unauthenticated,
      serverConfig: ServerConfig(ServerConfig.defaultBaseUrl()),
    );
  }

  @override
  Future<void> restoreSession() async {}
}

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  testWidgets('LoginScreen 空输入校验展示错误提示', (tester) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          authControllerProvider.overrideWith(_TestAuthController.new),
        ],
        child: const MaterialApp(home: LoginScreen()),
      ),
    );
    await tester.pump();
    final btn = find.text('立即登录');
    await tester.ensureVisible(btn);
    await tester.tap(btn);
    await tester.pump();
    expect(find.text('请输入账号和密码'), findsOneWidget);
  });

  testWidgets('MarkdownMessageBody 无打字机直接渲染正文与代码块', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: MarkdownMessageBody(
            text: '你好\n\n```python\nprint(123)\n```',
            isDark: true,
            resolveMediaUrl: (p) => p,
            onOpenUrl: (_) {},
            onDownloadPath: (_) {},
          ),
        ),
      ),
    );
    expect(find.textContaining('你好'), findsOneWidget);
    expect(find.text('PYTHON'), findsOneWidget);
    expect(find.text('复制'), findsOneWidget);
    expect(find.textContaining('打字机流式输出中'), findsNothing);
  });

  testWidgets('MessageCard 读取 tool.args 展示文件名', (tester) async {
    const msg = AgentMessage(
      stepIndex: 2,
      source: 'MODEL',
      msgType: 'PLANNER_RESPONSE',
      status: 'DONE',
      content: '已编辑完成',
      thinking: '',
      toolCalls: [ToolCallItem(name: 'edit_file', args: {'Path': r'C:\proj\demo.dart'})],
      timestamp: '',
    );

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: MessageCard(
            msg: msg,
            isDark: true,
            resolveMediaUrl: (p) => p,
            onDownloadFile: (_, {filename}) {},
            onOpenUrl: (_) {},
          ),
        ),
      ),
    );
    expect(find.text('edit: demo.dart'), findsOneWidget);
    expect(find.text('已编辑完成'), findsOneWidget);
  });

  testWidgets('WorkspaceFilePickerDialog 空目录显示空态而非无限转圈', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: WorkspaceFilePickerDialog(
            roots: const [FileRootItem(id: 'scratch', name: 'scratch', path: '/scratch')],
            activeRootId: 'scratch',
            rootName: 'scratch',
            currentSubPath: '',
            files: const [],
            isLoading: false,
            isDark: true,
            onSelectRoot: (_) {},
            onNavigate: (_) {},
            onDownload: (_) {},
            onReadFile: (_) {},
            onInsertRef: (_) {},
          ),
        ),
      ),
    );
    expect(find.byType(CircularProgressIndicator), findsNothing);
    expect(find.text('当前目录为空'), findsOneWidget);
  });

  testWidgets('BottomInputBar 只读节点禁用输入并提示只读', (tester) async {
    final controller = TextEditingController();
    addTearDown(controller.dispose);

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: BottomInputBar(
            inputController: controller,
            isConnected: true,
            isThinking: false,
            canWrite: false,
            isDark: true,
            pendingAttachments: const [],
            onRemoveAttachment: (_) {},
            onShowAddContext: () {},
            onSendMessage: () {},
            onStopTask: () {},
          ),
        ),
      ),
    );
    expect(find.text('当前节点为只读权限'), findsOneWidget);
  });

  testWidgets('ContextMenuSheet 仅保留 5 项真实功能且无假菜单', (tester) async {
    var diffTapped = false;
    var artifactsTapped = false;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (ctx) => Center(
              child: ElevatedButton(
                onPressed: () => ContextMenuSheet.show(
                  ctx,
                  isDark: true,
                  onPickFile: () {},
                  onPickImage: () {},
                  onRequestGitDiff: () => diffTapped = true,
                  onOpenWorkspaceFiles: () {},
                  onOpenSessionArtifacts: () => artifactsTapped = true,
                ),
                child: const Text('打开加号菜单'),
              ),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('打开加号菜单'));
    await tester.pumpAndSettle();
    expect(find.text('提及'), findsNothing);
    expect(find.text('快捷操作'), findsNothing);
    expect(find.text('浏览器'), findsNothing);
    expect(find.text('添加本地文件'), findsOneWidget);
    expect(find.text('上传图片'), findsOneWidget);
    expect(find.text('工作区文件'), findsOneWidget);
    expect(find.text('变更评审 (Diff)'), findsOneWidget);
    expect(find.text('会话文档 (Artifacts)'), findsOneWidget);

    await tester.tap(find.text('会话文档 (Artifacts)'));
    await tester.pumpAndSettle();
    expect(artifactsTapped, true);
    expect(diffTapped, false);
  });

  testWidgets('MessageCard edit_file 胶囊可点击跳转对应文件 Diff', (tester) async {
    String? openedPath;
    int? openedStep;
    const msg = AgentMessage(
      stepIndex: 7,
      source: 'MODEL',
      msgType: 'PLANNER_RESPONSE',
      status: 'DONE',
      content: '已改写第一段',
      thinking: '',
      toolCalls: [ToolCallItem(name: 'edit_file', args: {'Path': r'C:\novel\ch01.md'})],
      timestamp: '',
    );

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: MessageCard(
            msg: msg,
            isDark: true,
            resolveMediaUrl: (p) => p,
            onDownloadFile: (_, {filename}) {},
            onOpenUrl: (_) {},
            onOpenEditDiff: (p, step) {
              openedPath = p;
              openedStep = step;
            },
          ),
        ),
      ),
    );

    await tester.tap(find.text('edit: ch01.md'));
    await tester.pump();
    expect(openedPath, r'C:\novel\ch01.md');
    expect(openedStep, 7);
  });

  testWidgets('MessageCard 支持在每轮对话末尾内嵌展示本轮修改 Diff 卡片', (tester) async {
    var turnReviewTapped = false;
    String? turnFileTapped;
    const msg = AgentMessage(
      stepIndex: 4,
      source: 'MODEL',
      msgType: 'PLANNER_RESPONSE',
      status: 'DONE',
      content: '已完成第一轮改写',
      thinking: '',
      toolCalls: [],
      timestamp: '',
    );
    const turn = SessionTurnChange(
      turnId: 1,
      turnNumber: 1,
      firstStepIndex: 2,
      lastStepIndex: 2,
      totalFiles: 1,
      totalAdded: 6,
      totalRemoved: 2,
      files: [
        SessionFileChange(
          filePath: 'C:/novel/ch01.md',
          fileName: 'ch01.md',
          directory: 'C:/novel',
          addedLines: 6,
          removedLines: 2,
          editCount: 1,
          lastStepIndex: 2,
        ),
      ],
    );

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: MessageCard(
            msg: msg,
            isDark: true,
            resolveMediaUrl: (p) => p,
            onDownloadFile: (_, {filename}) {},
            onOpenUrl: (_) {},
            turnChanges: turn,
            onOpenTurnReview: () => turnReviewTapped = true,
            onOpenTurnFile: (f) => turnFileTapped = f.fileName,
          ),
        ),
      ),
    );

    expect(find.text('本轮修改'), findsOneWidget);
    expect(find.text('1 file changed'), findsOneWidget);
    await tester.tap(find.text('评审'));
    await tester.pump();
    expect(turnReviewTapped, true);

    await tester.tap(find.text('1 file changed'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('ch01.md'));
    await tester.pump();
    expect(turnFileTapped, 'ch01.md');
  });

  testWidgets('SessionChangesBar 展示统计、展开文件清单并响应评审和文件点击', (tester) async {
    var reviewTapped = false;
    SessionFileChange? openedFile;
    const changes = SessionChangesData(
      sessionId: 's1',
      totalFiles: 1,
      totalAdded: 12,
      totalRemoved: 4,
      files: [
        SessionFileChange(
          filePath: 'C:/novel/ch01.md',
          fileName: 'ch01.md',
          directory: 'C:/novel',
          addedLines: 12,
          removedLines: 4,
          editCount: 2,
          lastStepIndex: 8,
        ),
      ],
    );

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SessionChangesBar(
            changes: changes,
            pendingCommentCount: 1,
            isDark: true,
            onOpenReview: () => reviewTapped = true,
            onOpenFile: (f) => openedFile = f,
          ),
        ),
      ),
    );

    expect(find.text('1 file changed'), findsOneWidget);
    expect(find.text('评审 (1)'), findsOneWidget);
    await tester.tap(find.text('评审 (1)'));
    await tester.pump();
    expect(reviewTapped, true);

    await tester.tap(find.text('1 file changed'));
    await tester.pumpAndSettle();
    expect(find.text('ch01.md'), findsOneWidget);
    await tester.tap(find.text('ch01.md'));
    await tester.pump();
    expect(openedFile?.fileName, 'ch01.md');
  });

  testWidgets('ChangeReviewSheet 展示句词对比、添加批注并提交结构化 Review', (tester) async {
    String? sentPrompt;
    const changes = SessionChangesData(
      sessionId: 's1',
      totalFiles: 1,
      totalAdded: 1,
      totalRemoved: 1,
      files: [
        SessionFileChange(
          filePath: 'C:/novel/ch01.md',
          fileName: 'ch01.md',
          directory: 'C:/novel',
          addedLines: 1,
          removedLines: 1,
          editCount: 1,
          lastStepIndex: 5,
          hunks: [
            SessionEditHunk(
              hunkId: 's5_h1',
              stepIndex: 5,
              toolName: 'edit_file',
              startLine: 18,
              endLine: 18,
              addedLines: 1,
              removedLines: 1,
              beforeText: '他微笑着推开门',
              afterText: '他冷着脸推开门',
              unifiedDiff: '--- a/ch01.md\n+++ b/ch01.md\n@@ -1,1 +1,1 @@\n-他微笑着推开门\n+他冷着脸推开门',
              inlineSegments: [
                InlineDiffSegment(kind: 'equal', text: '他'),
                InlineDiffSegment(kind: 'delete', text: '微笑着'),
                InlineDiffSegment(kind: 'insert', text: '冷着脸'),
                InlineDiffSegment(kind: 'equal', text: '推开门'),
              ],
            ),
          ],
        ),
      ],
    );

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (ctx) => Center(
              child: ElevatedButton(
                onPressed: () => ChangeReviewSheet.show(
                  ctx,
                  initialSessionChanges: changes,
                  onFillPrompt: (_) {},
                  onSendPrompt: (p) async {
                    sentPrompt = p;
                    return null;
                  },
                ),
                child: const Text('打开评审面板'),
              ),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('打开评审面板'));
    await tester.pumpAndSettle();

    // First shows changed file list ("评审" -> open file list -> click file)
    expect(find.text('ch01.md'), findsOneWidget);
    await tester.tap(find.text('ch01.md'));
    await tester.pumpAndSettle();

    expect(find.text('L18 · Step 5 (edit_file)'), findsOneWidget);
    await tester.tap(find.text('批注'));
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField), '眼神不要太凶，改为沉默推门');
    await tester.tap(find.text('保存批注'));
    await tester.pumpAndSettle();

    expect(find.text('已添加 1 条批注'), findsOneWidget);
    expect(find.text('眼神不要太凶，改为沉默推门'), findsOneWidget);

    await tester.tap(find.text('提交批注'));
    await tester.pumpAndSettle();

    expect(sentPrompt, contains('C:/novel/ch01.md'));
    expect(sentPrompt, contains('L18 · Step 5'));
    expect(sentPrompt, contains('眼神不要太凶，改为沉默推门'));
  });

  testWidgets('WorkspaceFilePickerDialog 对 PDF/图片触发预览且支持独立下载', (tester) async {
    final previewedPdfs = <String>[];
    final previewedImages = <String>[];
    final downloaded = <String>[];

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: WorkspaceFilePickerDialog(
            roots: const [FileRootItem(id: 'ws_1', name: 'proj', path: r'C:\proj')],
            activeRootId: 'ws_1',
            rootName: 'proj',
            currentSubPath: '',
            files: const [
              FileItem(name: '讲义_100%.pdf', isDir: false, path: '讲义_100%.pdf', size: 1024),
              FileItem(name: 'chart.png', isDir: false, path: 'chart.png', size: 512),
            ],
            isLoading: false,
            statusMessage: '已发起下载: chart.png',
            isDark: true,
            onSelectRoot: (_) {},
            onNavigate: (_) {},
            onDownload: downloaded.add,
            onReadFile: (_) {},
            onPreviewPdf: previewedPdfs.add,
            onPreviewImage: previewedImages.add,
            onInsertRef: (_) {},
          ),
        ),
      ),
    );

    expect(find.text('已发起下载: chart.png'), findsOneWidget);
    await tester.tap(find.text('讲义_100%.pdf'));
    await tester.pump();
    expect(previewedPdfs, ['讲义_100%.pdf']);

    await tester.tap(find.text('chart.png'));
    await tester.pump();
    expect(previewedImages, ['chart.png']);

    await tester.tap(find.byIcon(Icons.download_rounded).first);
    await tester.pump();
    expect(downloaded, ['讲义_100%.pdf']);
  });

  testWidgets('SessionStepsBar 展示任务进度并可展开完整清单', (tester) async {
    const steps = [
      PlanStepItem(title: '编写接口', status: 'done'),
      PlanStepItem(title: '部署双端', status: 'in_progress'),
    ];
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: SessionStepsBar(steps: steps, isDark: true),
        ),
      ),
    );

    expect(find.text('任务进度 1/2'), findsOneWidget);
    expect(find.text('部署双端'), findsOneWidget);
    await tester.tap(find.text('任务进度 1/2'));
    await tester.pumpAndSettle();
    expect(find.text('编写接口'), findsOneWidget);
  });

  testWidgets('MessageCard 支持点击运行命令胶囊及交互式 ask_question 提交', (tester) async {
    int? openedToolStep;
    String? openedToolName;
    String? quickReply;
    const msg = AgentMessage(
      stepIndex: 12,
      source: 'MODEL',
      msgType: 'PLANNER_RESPONSE',
      status: 'DONE',
      content: '',
      thinking: '',
      toolCalls: [
        ToolCallItem(name: 'run_command', args: {'toolSummary': 'Run pytest', 'CommandLine': 'pytest -v'}),
        ToolCallItem(
          name: 'ask_question',
          args: {
            'questions': [
              {
                'question': '是否继续发布？',
                'options': ['(Recommended) 立即发布', '暂缓'],
                'is_multi_select': false,
              },
            ],
          },
        ),
      ],
      timestamp: '',
    );

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: MessageCard(
              msg: msg,
              isDark: true,
              resolveMediaUrl: (p) => p,
              onDownloadFile: (_, {filename}) {},
              onOpenUrl: (_) {},
              onOpenToolDetail: (step, tool) {
                openedToolStep = step;
                openedToolName = tool.name;
              },
              onSubmitQuickReply: (text) async {
                quickReply = text;
                return null;
              },
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('Run pytest'));
    await tester.pump();
    expect(openedToolStep, 12);
    expect(openedToolName, 'run_command');

    await tester.tap(find.text('(Recommended) 立即发布'));
    await tester.pump();
    await tester.tap(find.text('提交选择'));
    await tester.pumpAndSettle();
    expect(quickReply, contains('是否继续发布？'));
    expect(quickReply, contains('(Recommended) 立即发布'));
    expect(find.text('已发送'), findsOneWidget);
  });

  testWidgets('FileViewerSheet 支持编辑保存并更新内容与引用路径', (tester) async {
    String? savedContent;
    double? savedExpectedMtime;
    String? insertedRef;

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (ctx) => Center(
              child: ElevatedButton(
                onPressed: () => FileViewerSheet.show(
                  ctx,
                  rootId: 'scratch',
                  name: 'ch01.md',
                  path: 'novel/ch01.md',
                  content: '旧第一行',
                  totalLines: 1,
                  truncated: false,
                  size: 12,
                  mtime: 100.0,
                  canWrite: true,
                  onSave: (content, expectedMtime) async {
                    savedContent = content;
                    savedExpectedMtime = expectedMtime;
                    return FileSaveResult(
                      rootId: 'scratch',
                      path: 'novel/ch01.md',
                      name: 'ch01.md',
                      size: content.length,
                      totalLines: 2,
                      mtime: 200.0,
                    );
                  },
                  onInsertReference: (refText) => insertedRef = refText,
                  onDownloadFallback: (_) {},
                ),
                child: const Text('预览文本'),
              ),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('预览文本'));
    await tester.pumpAndSettle();
    expect(find.text('旧第一行'), findsOneWidget);

    await tester.tap(find.text('编辑'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), '新版第一行\n新版第二行');
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();

    expect(savedContent, '新版第一行\n新版第二行');
    expect(savedExpectedMtime, closeTo(100.0, 0.01));
    expect(find.text('共 2 行'), findsOneWidget);

    await tester.tap(find.text('引用'));
    await tester.pumpAndSettle();
    expect(insertedRef, '`novel/ch01.md` ');
  });

  testWidgets('BottomInputBar 运行中支持排队入列与立即发送模式且与停止共存', (tester) async {
    final ctrl = TextEditingController();
    addTearDown(ctrl.dispose);
    var sentCount = 0;
    var stopCount = 0;

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: BottomInputBar(
            inputController: ctrl,
            isConnected: true,
            isThinking: true,
            canWrite: true,
            isDark: true,
            queueMode: ComposerPrefs.queueModeQueue,
            sendKey: ComposerPrefs.sendKeyEnter,
            pendingAttachments: const [],
            onRemoveAttachment: (_) {},
            onShowAddContext: () {},
            onSendMessage: () => sentCount++,
            onStopTask: () => stopCount++,
          ),
        ),
      ),
    );

    expect(find.byIcon(Icons.stop_rounded), findsOneWidget);
    expect(find.byIcon(Icons.playlist_add_rounded), findsNothing);

    await tester.enterText(find.byType(TextField), '下一条任务');
    await tester.pump();
    expect(find.byIcon(Icons.playlist_add_rounded), findsOneWidget);
    await tester.tap(find.byIcon(Icons.playlist_add_rounded));
    await tester.pump();
    expect(sentCount, 1);

    // Switch to immediate mode -> displays immediate send icon
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: BottomInputBar(
            inputController: ctrl,
            isConnected: true,
            isThinking: true,
            canWrite: true,
            isDark: true,
            queueMode: ComposerPrefs.queueModeImmediate,
            sendKey: ComposerPrefs.sendKeyCtrlEnter,
            pendingAttachments: const [],
            onRemoveAttachment: (_) {},
            onShowAddContext: () {},
            onSendMessage: () => sentCount++,
            onStopTask: () => stopCount++,
          ),
        ),
      ),
    );
    await tester.pump();
    expect(find.byIcon(Icons.send_rounded), findsOneWidget);
    await tester.tap(find.byIcon(Icons.stop_rounded));
    await tester.pump();
    expect(stopCount, 1);
  });

  testWidgets('SessionQueueBar 展示队列并支持暂停、编辑、插队直发与删除', (tester) async {
    bool? pausedToggled;
    String? editedId;
    String? editedText;
    String? deletedId;
    String? sentNowId;

    const queue = SessionQueueData(
      sessionId: 's1',
      paused: false,
      items: [
        QueuedMessageItem(id: 'q1', content: '先改第一章结尾'),
      ],
    );

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SessionQueueBar(
            queue: queue,
            isDark: true,
            onTogglePause: (p) async => pausedToggled = p,
            onEditItem: (id, txt) async {
              editedId = id;
              editedText = txt;
            },
            onDeleteItem: (id) async => deletedId = id,
            onSendNow: (id) async => sentNowId = id,
            onClearAll: () async {},
          ),
        ),
      ),
    );

    expect(find.text('待发队列 (1)'), findsOneWidget);
    await tester.tap(find.text('暂停'));
    await tester.pump();
    expect(pausedToggled, true);

    await tester.tap(find.text('待发队列 (1)'));
    await tester.pumpAndSettle();
    expect(find.text('先改第一章结尾'), findsOneWidget);

    await tester.tap(find.byIcon(Icons.edit_outlined));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), '改为先改第二章');
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();
    expect(editedId, 'q1');
    expect(editedText, '改为先改第二章');

    await tester.tap(find.byIcon(Icons.send_rounded));
    await tester.pump();
    expect(sentNowId, 'q1');

    await tester.tap(find.byIcon(Icons.delete_outline_rounded));
    await tester.pump();
    expect(deletedId, 'q1');
  });

  testWidgets('Android 端 BottomInputBar 键盘回车保持换行且支持输入法贴图', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    addTearDown(() => debugDefaultTargetPlatformOverride = null);

    final ctrl = TextEditingController();
    addTearDown(ctrl.dispose);
    var sendCount = 0;
    PickedLocalFile? insertedFile;

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: BottomInputBar(
            inputController: ctrl,
            isConnected: true,
            isThinking: false,
            isDark: true,
            sendKey: ComposerPrefs.sendKeyEnter,
            pendingAttachments: const [],
            onRemoveAttachment: (_) {},
            onShowAddContext: () {},
            onSendMessage: () => sendCount += 1,
            onStopTask: () {},
            onInsertRichContent: (file) => insertedFile = file,
          ),
        ),
      ),
    );

    final field = tester.widget<TextField>(find.byType(TextField));
    expect(field.textInputAction, TextInputAction.newline);
    expect(field.contentInsertionConfiguration, isNotNull);

    field.contentInsertionConfiguration!.onContentInserted(
      KeyboardInsertedContent(
        mimeType: 'image/png',
        uri: 'content://ime/clipboard_1.png',
        data: Uint8List.fromList([0x89, 0x50, 0x4E, 0x47]),
      ),
    );
    expect(insertedFile, isNotNull);
    expect(insertedFile!.isImage, true);
    expect(insertedFile!.filename.endsWith('.png'), true);
    expect(sendCount, 0);
  });

  testWidgets('ContextMenuSheet 在传入 onTakePhoto 时展示拍照上传选项', (tester) async {
    var photoTapped = false;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ContextMenuSheet(
            isDark: true,
            canWrite: true,
            onPickFile: () {},
            onPickImage: () {},
            onTakePhoto: () => photoTapped = true,
            onRequestGitDiff: () {},
            onOpenWorkspaceFiles: () {},
          ),
        ),
      ),
    );

    expect(find.text('拍照上传'), findsOneWidget);
    await tester.tap(find.text('拍照上传'));
    await tester.pump();
    expect(photoTapped, true);
  });

  testWidgets('QuotaDrawer 在顶部展示已置顶分组且将置顶会话排在普通会话之前', (tester) async {
    tester.view.physicalSize = const Size(800, 1200);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: QuotaDrawer(
            nodes: const [
              HostNode(id: 'win', name: 'Windows PC', isOnline: true, engineAlive: true, canWrite: true),
            ],
            selectedNode: 'win',
            onSwitchNode: (_) {},
            quotaData: null,
            isLoadingQuota: false,
            onRequestQuota: () {},
            onNewSession: () {},
            projects: const {
              'Novel': [
                SessionItem(id: 'p1', title: '普通章节会话', isPinned: false),
                SessionItem(id: 'p2', title: '项目置顶会话', isPinned: true),
              ],
            },
            generalSessions: const [
              SessionItem(id: 'g1', title: '最新未置顶会话', isPinned: false),
              SessionItem(id: 'g2', title: '较早但已置顶会话', isPinned: true),
            ],
            activeSessionId: 'g1',
            onSwitchSession: (_) {},
            onDeleteSession: (_) {},
            isDark: true,
            onToggleTheme: (_) {},
            onSelectAccentTheme: (_) {},
          ),
        ),
      ),
    );
    await tester.pump();

    expect(find.text('已置顶 (2)'), findsOneWidget);
    final pinnedHeaderY = tester.getTopLeft(find.text('已置顶 (2)')).dy;
    final projectsHeaderY = tester.getTopLeft(find.text('项目列表')).dy;
    final pinnedGeneralY = tester.getTopLeft(find.text('较早但已置顶会话').first).dy;
    final normalGeneralY = tester.getTopLeft(find.text('最新未置顶会话')).dy;
    expect(pinnedHeaderY, lessThan(projectsHeaderY));
    expect(pinnedGeneralY, lessThan(normalGeneralY));
  });

  testWidgets('runWithDownloadProgressDialog 同步极速失败时自动关闭弹窗不卡死且不崩溃', (tester) async {
    String? result;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (ctx) => Center(
              child: ElevatedButton(
                onPressed: () async {
                  result = await runWithDownloadProgressDialog<String>(
                    context: ctx,
                    autoOpen: false,
                    formatBytes: (b) => '$b B',
                    task: (_, __) async => '该文件不在当前受控工作区根目录内，无法下载',
                  );
                },
                child: const Text('触发快速失败下载'),
              ),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('触发快速失败下载'));
    await tester.pumpAndSettle();

    expect(result, '该文件不在当前受控工作区根目录内，无法下载');
    expect(find.byType(AlertDialog), findsNothing);
    expect(find.text('正在下载文件...'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('runWithDownloadProgressDialog 点击取消按钮后立刻取消任务并关闭弹窗', (tester) async {
    final completer = Completer<String>();
    var tokenCancelled = false;
    String? result;

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (ctx) => Center(
              child: ElevatedButton(
                onPressed: () async {
                  result = await runWithDownloadProgressDialog<String>(
                    context: ctx,
                    autoOpen: false,
                    formatBytes: (b) => '$b B',
                    task: (_, cancelToken) async {
                      unawaited(cancelToken.whenCancel.then((_) {
                        tokenCancelled = true;
                        if (!completer.isCompleted) {
                          completer.complete('cancelled');
                        }
                      }));
                      return completer.future;
                    },
                  );
                },
                child: const Text('触发挂起下载'),
              ),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('触发挂起下载'));
    await tester.pump();
    await tester.pump();
    expect(find.text('正在下载文件...'), findsOneWidget);
    expect(find.text('取消'), findsOneWidget);

    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();

    expect(tokenCancelled, true);
    expect(result, 'cancelled');
    expect(find.byType(AlertDialog), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('ResponsiveLayout 断点与平板工作区弹窗宽度约束', (tester) async {
    Future<void> checkViewport(
      Size size,
      void Function(BuildContext ctx) verify,
    ) async {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1.0;
      addTearDown(() {
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
      });
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (ctx) {
              verify(ctx);
              return const SizedBox.shrink();
            },
          ),
        ),
      );
    }

    // 1. 手机竖屏 390x844
    await checkViewport(const Size(390, 844), (ctx) {
      expect(ResponsiveLayout.isTabletOrLarger(ctx), false);
      expect(ResponsiveLayout.usePermanentSidebar(ctx), false);
      expect(ResponsiveLayout.nodeBadgeMaxWidth(ctx), 88.0);
      expect(ResponsiveLayout.contentMaxWidth(ctx), 780.0);
    });

    // 2. 小新 Pad Pro 12.7 竖屏 736x1178
    await checkViewport(const Size(736, 1178), (ctx) {
      expect(ResponsiveLayout.isTabletOrLarger(ctx), true);
      expect(ResponsiveLayout.usePermanentSidebar(ctx), false);
      expect(ResponsiveLayout.contentMaxWidth(ctx), 840.0);
      expect(ResponsiveLayout.workspaceSheetConstraints(ctx).maxWidth, greaterThan(640.0));
    });

    // 3. 小新 Pad Pro 12.7 横屏 1280x800
    await checkViewport(const Size(1280, 800), (ctx) {
      expect(ResponsiveLayout.isTabletOrLarger(ctx), true);
      expect(ResponsiveLayout.usePermanentSidebar(ctx), true);
      expect(ResponsiveLayout.contentMaxWidth(ctx), 840.0);
      expect(ResponsiveLayout.workspaceSheetConstraints(ctx).maxWidth, 1080.0);
      expect(ResponsiveLayout.nodeBadgeMaxWidth(ctx), 180.0);
    });
  });

  testWidgets('QuotaDrawer 常驻侧边栏模式切换会话与新建会话不误触发 Navigator.pop', (tester) async {
    tester.view.physicalSize = const Size(1280, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });

    var newSessionTapped = 0;
    String? switchedId;

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Row(
            children: [
              QuotaDrawer(
                nodes: const [
                  HostNode(id: 'win', name: 'Windows PC', isOnline: true, engineAlive: true, canWrite: true),
                ],
                selectedNode: 'win',
                onSwitchNode: (_) {},
                quotaData: null,
                isLoadingQuota: false,
                onRequestQuota: () {},
                onNewSession: () => newSessionTapped += 1,
                projects: const {},
                generalSessions: const [
                  SessionItem(id: 's-tab', title: '平板横屏测试会话'),
                ],
                activeSessionId: '',
                onSwitchSession: (s) => switchedId = s.id,
                onDeleteSession: (_) {},
                isDark: true,
                onToggleTheme: (_) {},
                onSelectAccentTheme: (_) {},
                isPermanentSidebar: true,
              ),
              const Expanded(
                child: Center(child: Text('主聊天区')),
              ),
            ],
          ),
        ),
      ),
    );
    await tester.pump();

    expect(find.byType(Drawer), findsNothing);
    expect(find.text('主聊天区'), findsOneWidget);

    await tester.tap(find.text('新建会话'));
    await tester.pump();
    expect(newSessionTapped, 1);

    await tester.tap(find.text('平板横屏测试会话'));
    await tester.pump();
    expect(switchedId, 's-tab');
    // 路由未被 pop 掉，整个双栏界面保持可见
    expect(find.text('主聊天区'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('SessionChangesBar 标注最新修改且 ChangeReviewSheet 支持单步/最新/全部范围切换', (tester) async {
    final requestedScopes = <String>[];

    const multiStepChanges = SessionChangesData(
      sessionId: 's1',
      totalFiles: 1,
      totalAdded: 5,
      totalRemoved: 1,
      files: [
        SessionFileChange(
          filePath: 'C:/novel/ch01.md',
          fileName: 'ch01.md',
          directory: 'C:/novel',
          addedLines: 5,
          removedLines: 1,
          editCount: 2,
          lastStepIndex: 8,
          hunks: [
            SessionEditHunk(
              hunkId: 's3_h1',
              stepIndex: 3,
              toolName: 'edit_file',
              addedLines: 2,
              removedLines: 0,
              beforeText: '旧段落A',
              afterText: '新段落A',
              inlineSegments: [InlineDiffSegment(kind: 'insert', text: '新段落A')],
            ),
            SessionEditHunk(
              hunkId: 's8_h2',
              stepIndex: 8,
              toolName: 'edit_file',
              addedLines: 3,
              removedLines: 1,
              beforeText: '旧段落B',
              afterText: '新段落B',
              inlineSegments: [InlineDiffSegment(kind: 'insert', text: '新段落B')],
            ),
          ],
        ),
      ],
    );

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Column(
            children: [
              SessionChangesBar(
                changes: multiStepChanges,
                isDark: true,
                onOpenReview: () {},
                onOpenFile: (_) {},
              ),
              Expanded(
                child: ChangeReviewSheet(
                  initialSessionChanges: multiStepChanges,
                  initialFilePath: 'C:/novel/ch01.md',
                  initialStepIndex: 8,
                  initialTurnId: 4,
                  initialScope: 'step',
                  onLoadSessionChangesScoped: ({String scope = 'all', int? stepIndex, int? turnId}) async {
                    requestedScopes.add('$scope:${stepIndex ?? "none"}:${turnId ?? "none"}');
                    return multiStepChanges;
                  },
                  onFillPrompt: (_) {},
                  onSendPrompt: (_) async => null,
                ),
              ),
            ],
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    // 底部条显式带有「最新修改」徽标
    expect(find.text('最新修改'), findsWidgets);
    // 默认单步模式下只展示 Step 8 的 hunk，不混入 Step 3 的 hunk
    expect(find.text('单步 #8'), findsOneWidget);
    expect(find.text('本轮修改'), findsOneWidget);
    expect(find.textContaining('新段落B'), findsOneWidget);
    expect(find.textContaining('新段落A'), findsNothing);
    expect(requestedScopes.first, 'all:8:none');

    // 点击「本轮修改」后按 turnId=4 请求
    await tester.tap(find.text('本轮修改'));
    await tester.pumpAndSettle();
    expect(requestedScopes.last, 'all:none:4');

    // 点击「全部修改」后展示全部两个步骤的 hunk
    await tester.tap(find.text('全部修改'));
    await tester.pumpAndSettle();
    expect(requestedScopes.last, 'all:none:none');
    expect(find.textContaining('新段落A'), findsOneWidget);
    expect(find.textContaining('新段落B'), findsOneWidget);
  });

  testWidgets('QuotaDrawer 折叠项目内存在运行中会话时展示项目旁呼吸灯提示', (tester) async {
    var refreshNodesCalls = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 320,
            child: QuotaDrawer(
              nodes: const [
                HostNode(id: 'win', name: 'Windows PC', isOnline: true, engineAlive: true),
              ],
              selectedNode: 'win',
              onSwitchNode: (_) {},
              onRefreshNodes: () => refreshNodesCalls += 1,
              quotaData: null,
              isLoadingQuota: false,
              onRequestQuota: () {},
              onNewSession: () {},
              projects: const {
                'RunningProj': [
                  SessionItem(id: 's-run-1', title: '正在生成的代码任务'),
                  SessionItem(id: 's-run-2', title: '后台测试任务', isRunning: true),
                ],
                'IdleProj': [
                  SessionItem(id: 's-idle-1', title: '已结束的历史任务'),
                ],
              },
              generalSessions: const [
                SessionItem(id: 'g-active', title: '当前通用对话'),
              ],
              activeSessionId: 'g-active',
              runningSessionIds: const {'s-run-1'},
              onSwitchSession: (_) {},
              onDeleteSession: (_) {},
              isDark: true,
              onToggleTheme: (_) {},
              onSelectAccentTheme: (_) {},
              isPermanentSidebar: true,
            ),
          ),
        ),
      ),
    );

    await tester.pump();
    await tester.pump(const Duration(milliseconds: 600));

    // RunningProj 与 IdleProj 均处于折叠态，但仅有前者显示呼吸灯与并发数字角标 2
    expect(find.byKey(const ValueKey('proj_breathing_RunningProj')), findsOneWidget);
    expect(find.byKey(const ValueKey('proj_breathing_IdleProj')), findsNothing);
    expect(find.text('2'), findsOneWidget);

    // 点击节点标题栏上的手动刷新按钮可触发刷新回调
    await tester.tap(find.byTooltip('刷新节点状态'));
    await tester.pump();
    expect(refreshNodesCalls, 1);
  });

  testWidgets('MessageCard 展示本轮任务耗时、ContextMenuSheet 含快捷指令、OfflineOutboxBar 交互正常',
      (tester) async {
    SharedPreferences.setMockInitialValues({});
    const aiMsg = AgentMessage(
      stepIndex: 4,
      source: 'MODEL',
      msgType: 'PLANNER_RESPONSE',
      status: 'DONE',
      content: '已完成结构调整',
      thinking: '',
      toolCalls: [],
      timestamp: '2026-11-25T09:01:24Z',
    );

    var quickOpened = false;
    var retryAllTapped = false;
    String? editedId;
    String? editedText;
    String? deletedId;

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Column(
            children: [
              MessageCard(
                msg: aiMsg,
                isDark: true,
                resolveMediaUrl: (p) => p,
                onDownloadFile: (_, {filename}) {},
                onOpenUrl: (_) {},
                turnDuration: const Duration(minutes: 1, seconds: 24),
              ),
              OfflineOutboxBar(
                items: const [
                  OfflineOutboxItem(
                    id: 'out-1',
                    nodeId: 'win',
                    sessionId: 's1',
                    content: '暂存的离线指令',
                    createdAt: '2026-11-25T09:05:00Z',
                  ),
                ],
                isDark: true,
                onRetryAll: () => retryAllTapped = true,
                onRetryItem: (_) {},
                onEditItem: (id, txt) {
                  editedId = id;
                  editedText = txt;
                },
                onDeleteItem: (id) => deletedId = id,
                onClearAll: () {},
              ),
              Builder(
                builder: (ctx) => ElevatedButton(
                  onPressed: () => ContextMenuSheet.show(
                    ctx,
                    isDark: true,
                    onPickFile: () {},
                    onPickImage: () {},
                    onRequestGitDiff: () {},
                    onOpenWorkspaceFiles: () {},
                    onOpenQuickCommands: () => quickOpened = true,
                  ),
                  child: const Text('打开菜单'),
                ),
              ),
            ],
          ),
        ),
      ),
    );

    await tester.pumpAndSettle();
    expect(find.text('耗时 1m 24s'), findsOneWidget);
    expect(find.text('等待重连 (1)'), findsOneWidget);

    await tester.tap(find.text('重试'));
    await tester.pump();
    expect(retryAllTapped, true);

    await tester.tap(find.text('等待重连 (1)'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('编辑内容'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).last, '修改后的离线消息');
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();
    expect(editedId, 'out-1');
    expect(editedText, '修改后的离线消息');

    await tester.tap(find.byTooltip('撤回删除'));
    await tester.pumpAndSettle();
    expect(deletedId, 'out-1');

    await tester.tap(find.text('打开菜单'));
    await tester.pumpAndSettle();
    expect(find.text('快捷指令'), findsOneWidget);
    await tester.tap(find.text('快捷指令'));
    await tester.pumpAndSettle();
    expect(quickOpened, true);
  });

  testWidgets('QuickCommandsSheet 支持新增编辑自定义指令并一键填入', (tester) async {
    SharedPreferences.setMockInitialValues({});
    String? filledPrompt;

    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (ctx) => ElevatedButton(
                onPressed: () => QuickCommandsSheet.show(
                  ctx,
                  isDark: true,
                  onFillPrompt: (p) => filledPrompt = p,
                  onSendPrompt: (_) async => null,
                ),
                child: const Text('弹出快捷指令'),
              ),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('弹出快捷指令'));
    await tester.pumpAndSettle();
    expect(find.text(defaultQuickCommands.first.title), findsOneWidget);

    // 新增自定义指令
    await tester.tap(find.text('新增'));
    await tester.pumpAndSettle();
    final fields = find.byType(TextField);
    await tester.enterText(fields.at(0), '同步发布');
    await tester.enterText(fields.at(1), '请提交代码并打包更新到 Deck');
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();
    expect(find.text('同步发布'), findsOneWidget);

    // 点击填入输入框
    await tester.tap(find.text('同步发布'));
    await tester.pumpAndSettle();
    expect(filledPrompt, '请提交代码并打包更新到 Deck');
  });

  testWidgets('MessageCard 渲染 ERROR_MESSAGE 额度超限错误卡片', (tester) async {
    const msg = AgentMessage(
      stepIndex: 68,
      source: 'SYSTEM',
      msgType: 'ERROR_MESSAGE',
      status: 'ERROR',
      content: 'RESOURCE_EXHAUSTED (code 429): Third-party quota reached. Resets in 50m3s.\n模型: claude-sonnet-5-5-medium',
      thinking: '',
      toolCalls: [],
      timestamp: '2026-11-25T02:24:49Z',
    );

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: MessageCard(
            msg: msg,
            isDark: true,
            resolveMediaUrl: (p) => p,
            onDownloadFile: (_, {filename}) {},
            onOpenUrl: (_) {},
            turnDuration: const Duration(seconds: 12),
          ),
        ),
      ),
    );

    expect(find.text('模型额度已用尽'), findsOneWidget);
    expect(find.textContaining('RESOURCE_EXHAUSTED (code 429)'), findsOneWidget);
    expect(find.textContaining('Resets in 50m3s.'), findsOneWidget);
    expect(find.text('耗时 12s'), findsOneWidget);
    expect(find.text('复制错误'), findsOneWidget);
  });

  testWidgets('BottomInputBar 模型胶囊、ModelPickerSheet 搜索切换与 MessageCard 模型展示/429换模型', (tester) async {
    final controller = TextEditingController();
    addTearDown(controller.dispose);
    var switchFromErrorTapped = false;
    String? pickedModel;

    const catalog = [
      OfficialModelOption(
        id: 'gemini-4-neon-high',
        displayName: 'Gemini 4 Neon (High)',
        group: 'Gemini',
        thinkingBadge: 'New',
        remainingFraction: 0.82,
      ),
      OfficialModelOption(
        id: 'gemini-4-neon-low',
        displayName: 'Gemini 4 Neon (Low)',
        group: 'Gemini',
        thinkingBadge: 'New',
        remainingFraction: 0.82,
      ),
      OfficialModelOption(
        id: 'claude-sonnet-5-5-low',
        displayName: 'Claude Sonnet 5.5 (Low)',
        group: 'Claude',
        thinkingBadge: 'New',
        remainingFraction: 0.48,
      ),
      OfficialModelOption(
        id: 'claude-sonnet-5-5-medium',
        displayName: 'Claude Sonnet 5.5 (Medium)',
        group: 'Claude',
        thinkingBadge: 'New',
        remainingFraction: 0.48,
      ),
      OfficialModelOption(
        id: 'gemini-pro-orchestrator-neon',
        displayName: 'Orchestrator (Neon)',
        group: 'Orchestrator',
        thinkingBadge: 'New',
        remainingFraction: 0.58,
      ),
    ];

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Column(
            children: [
              MessageCard(
                msg: const AgentMessage(
                  stepIndex: 2,
                  source: 'MODEL',
                  msgType: 'PLANNER_RESPONSE',
                  status: 'DONE',
                  content: '普通回复内容',
                  thinking: '',
                  toolCalls: [],
                  timestamp: '',
                  model: 'gemini-4-neon-high',
                ),
                isDark: true,
                resolveMediaUrl: (p) => p,
                onDownloadFile: (_, {filename}) {},
                onOpenUrl: (_) {},
                modelLabel: 'Gemini 4 Neon (High)',
              ),
              MessageCard(
                msg: const AgentMessage(
                  stepIndex: 3,
                  source: 'SYSTEM',
                  msgType: 'ERROR_MESSAGE',
                  status: 'ERROR',
                  content: 'RESOURCE_EXHAUSTED (code 429): Third-party quota reached.',
                  thinking: '',
                  toolCalls: [],
                  timestamp: '',
                ),
                isDark: true,
                resolveMediaUrl: (p) => p,
                onDownloadFile: (_, {filename}) {},
                onOpenUrl: (_) {},
                onSwitchModel: () => switchFromErrorTapped = true,
              ),
              Builder(
                builder: (ctx) => BottomInputBar(
                  inputController: controller,
                  isConnected: true,
                  isThinking: false,
                  canWrite: true,
                  isDark: true,
                  pendingAttachments: const [],
                  onRemoveAttachment: (_) {},
                  onShowAddContext: () {},
                  onSendMessage: () {},
                  onStopTask: () {},
                  activeModelLabel: 'Gemini 4 Neon (High)',
                  isModelSwitchPending: false,
                  onPickModel: () => ModelPickerSheet.show(
                    ctx,
                    isDark: true,
                    models: catalog,
                    activeModel: 'gemini-4-neon-high',
                    pendingModel: '',
                    onSelectModel: (id) => pickedModel = id,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );

    // 1. 普通消息底部与输入栏胶囊展示模型名，429 卡片展示切换模型按钮
    expect(find.text('Gemini 4 Neon (High)'), findsNWidgets(2));
    expect(find.text('切换模型'), findsOneWidget);
    await tester.tap(find.text('切换模型'));
    await tester.pump();
    expect(switchFromErrorTapped, true);

    // 2. 点击输入栏模型胶囊，按系列折叠展示，默认展开当前 Gemini 4 Neon 二级思考强度
    await tester.tap(find.text('Gemini 4 Neon (High)').last);
    await tester.pumpAndSettle();
    expect(find.text('切换当前会话模型'), findsOneWidget);
    expect(find.text('Gemini 4 Neon'), findsOneWidget);
    expect(find.text('Claude Sonnet 5.5'), findsOneWidget);
    expect(find.text('当前·High'), findsOneWidget);
    expect(find.text('82%'), findsOneWidget);
    expect(find.text('48%'), findsOneWidget);

    // 3. 点击 Claude Sonnet 5.5 展开其二级菜单，选择 Medium 挡位
    await tester.tap(find.text('Claude Sonnet 5.5'));
    await tester.pumpAndSettle();
    expect(find.text('Low'), findsOneWidget);
    expect(find.text('Medium'), findsOneWidget);
    await tester.tap(find.text('Medium'));
    await tester.pumpAndSettle();
    expect(pickedModel, 'claude-sonnet-5-5-medium');
  });

  testWidgets('NewSessionDialog 复用二级模型选择器且 Leaving Soon 自动沉底', (tester) async {
    String? startedModel;
    const catalog = [
      OfficialModelOption(
        id: 'gemini-3.8-flash-high',
        displayName: 'Gemini 3.8 Flash (High)',
        group: 'Gemini',
        thinkingBadge: 'Leaving Soon',
        remainingFraction: 0.82,
      ),
      OfficialModelOption(
        id: 'gemini-4-neon-high',
        displayName: 'Gemini 4 Neon (High)',
        group: 'Gemini',
        thinkingBadge: 'New',
        remainingFraction: 0.82,
      ),
      OfficialModelOption(
        id: 'gemini-4-neon-low',
        displayName: 'Gemini 4 Neon (Low)',
        group: 'Gemini',
        thinkingBadge: 'New',
        remainingFraction: 0.82,
      ),
    ];

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: NewSessionDialog(
            initialMode: 'auto',
            initialModel: 'gemini-4-neon-high',
            models: catalog,
            onStart: (prompt, mode, model, wsPath, rootId) => startedModel = model,
          ),
        ),
      ),
    );

    expect(find.text('Gemini 4 Neon (High)'), findsOneWidget);
    await tester.tap(find.text('Gemini 4 Neon (High)'));
    await tester.pumpAndSettle();

    expect(find.text('选择新会话模型'), findsOneWidget);
    // Gemini 4 Neon (New) should be positioned above Gemini 3.8 Flash (Leaving Soon)
    final neonY = tester.getTopLeft(find.text('Gemini 4 Neon')).dy;
    final flashY = tester.getTopLeft(find.text('Gemini 3.8 Flash')).dy;
    expect(neonY, lessThan(flashY));

    // Switch to Low variant inside already-expanded Gemini 4 Neon
    await tester.tap(find.text('Low'));
    await tester.pumpAndSettle();
    expect(find.text('Gemini 4 Neon (Low)'), findsOneWidget);

    await tester.enterText(find.byType(TextField).first, '测试新建会话');
    await tester.tap(find.text('立即开启'));
    await tester.pumpAndSettle();
    expect(startedModel, 'gemini-4-neon-low');
  });

  testWidgets('QuotaDrawer 支持图钉按钮与长按菜单切换置顶，只读权限隐藏置顶按钮', (tester) async {
    tester.view.physicalSize = const Size(800, 1200);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });

    final toggled = <(String, bool)>[];

    Widget buildDrawer({required bool canWrite}) {
      return MaterialApp(
        home: Scaffold(
          body: QuotaDrawer(
            nodes: [
              HostNode(
                id: 'win',
                name: 'Windows PC',
                isOnline: true,
                engineAlive: true,
                canWrite: canWrite,
              ),
            ],
            selectedNode: 'win',
            onSwitchNode: (_) {},
            quotaData: null,
            isLoadingQuota: false,
            onRequestQuota: () {},
            canWrite: canWrite,
            onNewSession: () {},
            projects: const {},
            generalSessions: const [
              SessionItem(id: 'g1', title: '待置顶对话', isPinned: false),
              SessionItem(id: 'g2', title: '已置顶对话', isPinned: true),
            ],
            activeSessionId: 'g1',
            onSwitchSession: (_) {},
            onTogglePinSession: (s) => toggled.add((s.id, s.isPinned)),
            onDeleteSession: (_) {},
            isDark: true,
            onToggleTheme: (_) {},
            onSelectAccentTheme: (_) {},
            isPermanentSidebar: true,
          ),
        ),
      );
    }

    await tester.pumpWidget(buildDrawer(canWrite: true));
    await tester.pump();

    // 1. 点击未置顶项右侧空心图钉触发置顶回调
    await tester.tap(find.byIcon(Icons.push_pin_outlined).last);
    await tester.pump();
    expect(toggled.last, ('g1', false));

    // 2. 长按已置顶会话弹出底部菜单并点击「取消置顶」
    await tester.longPress(find.text('已置顶对话').last);
    await tester.pumpAndSettle();
    expect(find.text('取消置顶'), findsOneWidget);
    await tester.tap(find.text('取消置顶'));
    await tester.pumpAndSettle();
    expect(toggled.last, ('g2', true));

    // 3. 只读权限下，未置顶项不显示可操作的图钉按钮
    await tester.pumpWidget(buildDrawer(canWrite: false));
    await tester.pump();
    expect(find.byIcon(Icons.push_pin_outlined), findsNothing);
  });

  testWidgets('CodeBlockWidget 遵循 MediaQuery.textScaler 按比例缩放代码字号', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: MediaQuery(
          data: MediaQueryData(textScaler: TextScaler.linear(1.4)),
          child: Scaffold(
            body: CodeBlockWidget(
              code: 'print("hello")',
              language: 'python',
              isDark: true,
            ),
          ),
        ),
      ),
    );
    await tester.pump();

    final richText = tester.widget<RichText>(
      find.byWidgetPredicate(
        (w) => w is RichText && w.text.toPlainText().contains('print("hello")'),
      ),
    );
    expect(richText.text.style?.fontSize, closeTo(12.5 * 1.4, 0.01));
  });

  testWidgets('ChangeReviewSheet 行级 Diff 在窄屏下默认随容器自动折行且支持切换单行横滚', (tester) async {
    const longLine =
        '+这是一段非常非常长的行级 Diff 修改内容，用于在窄屏或收窄浏览器窗口时验证文本是否会自动折行完整显示而不会向右溢出被裁切掉。';
    const changes = SessionChangesData(
      sessionId: 's-wrap',
      totalFiles: 1,
      totalAdded: 1,
      totalRemoved: 1,
      files: [
        SessionFileChange(
          filePath: 'lib/demo/long_diff.dart',
          fileName: 'long_diff.dart',
          directory: 'lib/demo',
          editCount: 1,
          addedLines: 1,
          removedLines: 1,
          hunks: [
            SessionEditHunk(
              hunkId: 'h-wrap',
              stepIndex: 5,
              toolName: 'edit_file',
              startLine: 10,
              endLine: 12,
              addedLines: 1,
              removedLines: 1,
              beforeText: 'old line',
              afterText: 'new long line',
              unifiedDiff: '@@ -10,1 +10,1 @@\n-old line\n$longLine',
            ),
          ],
        ),
      ],
    );

    await tester.pumpWidget(
      MaterialApp(
        home: MediaQuery(
          data: const MediaQueryData(size: Size(320, 760)),
          child: Scaffold(
            body: Center(
              child: SizedBox(
                width: 320,
                height: 700,
                child: ChangeReviewSheet(
                  initialSessionChanges: changes,
                  initialFilePath: 'lib/demo/long_diff.dart',
                  onFillPrompt: (_) {},
                  onSendPrompt: (_) async => null,
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    // `.dart` 文件默认进入行级 Diff 模式，且默认开启自动换行
    expect(find.text('自动换行'), findsOneWidget);
    final diffTextFinder = find.text(longLine);
    expect(diffTextFinder, findsOneWidget);

    // 默认自动换行时不应存在横向滚动容器包裹 Diff 文本，且文本宽不超过窄屏容器并发生多行折行
    expect(
      find.byWidgetPredicate(
        (w) => w is SingleChildScrollView && w.scrollDirection == Axis.horizontal,
      ),
      findsNothing,
    );
    final diffSize = tester.getSize(diffTextFinder);
    expect(diffSize.width, lessThanOrEqualTo(320));
    expect(diffSize.height, greaterThan(30));

    // 点击 Diff 行依然弹出批注对话框
    await tester.tap(diffTextFinder);
    await tester.pumpAndSettle();
    expect(find.textContaining('添加批注'), findsOneWidget);
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();

    // 点击切换到「单行横滚」模式
    await tester.tap(find.text('自动换行'));
    await tester.pumpAndSettle();
    expect(find.text('单行横滚'), findsOneWidget);
    expect(
      find.byWidgetPredicate(
        (w) => w is SingleChildScrollView && w.scrollDirection == Axis.horizontal,
      ),
      findsOneWidget,
    );
  });

  testWidgets('MessageCard 渲染插件 Rich Presence 卡片、Gmail 重登引导、MCP 工具胶囊并忽略代码块内示例标签', (tester) async {
    String? submittedReply;
    const msg = AgentMessage(
      stepIndex: 20,
      source: 'MODEL',
      msgType: 'PLANNER_RESPONSE',
      status: 'DONE',
      content: 'Gmail 授权已过期，请先重新登录：\n\n'
          '<plugin-card catalog-id="gmail"></plugin-card>\n\n'
          '代码说明中的示例标签不应触发卡片：`<plugin-card catalog-id="canva"></plugin-card>`',
      thinking: '',
      toolCalls: [
        ToolCallItem(
          name: 'run_command',
          args: {
            'CommandLine': 'gmail readonly search "is:unread" --max 5',
            'toolSummary': '查询未读邮件',
          },
        ),
        ToolCallItem(
          name: 'call_mcp_tool',
          args: {
            'ServerName': 'cloudflare_cloudflare',
            'ToolName': 'docs',
          },
        ),
        ToolCallItem(
          name: 'list_plugin_accounts',
          args: {},
        ),
      ],
      timestamp: '',
    );

    // 确认解析器跳过行内代码里的 canva，只提取真实 gmail 标签
    final parsedCards = RichPresenceParser.extractPluginCards(msg.content);
    expect(parsedCards.length, 1);
    expect(parsedCards.first.slug, 'gmail');
    expect(parsedCards.first.isAuthRequired, true);

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: MessageCard(
              msg: msg,
              isDark: true,
              nodeName: 'Windows PC',
              resolveMediaUrl: (p) => p,
              onDownloadFile: (_, {filename}) {},
              onOpenUrl: (_) {},
              onOpenToolDetail: (_, __) {},
              onSubmitQuickReply: (reply) async {
                submittedReply = reply;
                return null;
              },
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    // 1. 工具胶囊呈现专属插件/MCP 标签
    expect(find.text('Gmail: 查询未读邮件'), findsOneWidget);
    expect(find.text('MCP: cloudflare/docs'), findsOneWidget);
    expect(find.text('检查插件账号'), findsOneWidget);

    // 2. Gmail 插件卡片展示登录提示、节点名称及重试按钮，不出现裸 <plugin-card> 文本或误解析的 Canva 卡片
    expect(find.text('Gmail'), findsOneWidget);
    expect(find.text('需重新登录'), findsOneWidget);
    expect(find.textContaining('【Windows PC】'), findsOneWidget);
    expect(find.text('Canva'), findsNothing);

    // 3. 点击「我已登录，重试」触发快捷回复并切换为已通知状态
    await tester.tap(find.text('我已登录，重试'));
    await tester.pumpAndSettle();
    expect(submittedReply, contains('Gmail'));
    expect(find.text('已通知重试'), findsOneWidget);
  });

  testWidgets('MessageCard 对无插件标签的浏览器人机验证场景渲染人工接管提示卡片', (tester) async {
    String? reply;
    const msg = AgentMessage(
      stepIndex: 21,
      source: 'MODEL',
      msgType: 'PLANNER_RESPONSE',
      status: 'DONE',
      content: '当前结账页触发了 PAYMENT_REQUIRED，请在浏览器中完成支付后通知我继续。',
      thinking: '',
      toolCalls: [
        ToolCallItem(name: 'webview_browser', args: {}),
      ],
      timestamp: '',
    );

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: MessageCard(
              msg: msg,
              isDark: false,
              nodeName: 'Steam Deck',
              resolveMediaUrl: (p) => p,
              onDownloadFile: (_, {filename}) {},
              onOpenUrl: (_) {},
              onSubmitQuickReply: (text) async {
                reply = text;
                return null;
              },
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('浏览器操作'), findsOneWidget);
    expect(find.text('需要宿主机浏览器人工接管'), findsOneWidget);
    expect(find.textContaining('【Steam Deck】'), findsOneWidget);

    await tester.tap(find.text('我已处理，继续'));
    await tester.pumpAndSettle();
    expect(reply, contains('继续执行'));
    expect(find.text('已通知继续执行'), findsOneWidget);
  });

  testWidgets('FileViewerSheet 嵌入式模式支持行号高亮、Markdown 渲染切换与独立下载按钮', (tester) async {
    var downloadCount = 0;

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 520,
            height: 640,
            child: FileViewerSheet(
              rootId: 'scratch',
              name: 'guide.md',
              path: 'docs/guide.md',
              content: '# 标题一\n\n第二行正文\n第三行重点',
              totalLines: 4,
              truncated: false,
              size: 64,
              canWrite: true,
              isEmbedded: true,
              highlightStartLine: 3,
              highlightEndLine: 4,
              onDownload: () => downloadCount++,
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    // 指定行号高亮时应默认停留在源码视图并在路径栏显示行号区间
    expect(find.textContaining('L3-L4'), findsOneWidget);
    expect(find.text('第三行重点'), findsOneWidget);
    expect(find.byTooltip('切换 Markdown 预览'), findsOneWidget);

    // 切换到 Markdown 渲染视图
    await tester.tap(find.byTooltip('切换 Markdown 预览'));
    await tester.pumpAndSettle();
    expect(find.byTooltip('切换源码视图'), findsOneWidget);
    expect(find.text('标题一'), findsOneWidget);

    // 点击独立下载按钮
    await tester.tap(find.byTooltip('下载文件'));
    await tester.pump();
    expect(downloadCount, 1);
  });

  testWidgets('MessageCard 对话文件卡片优先触发智能预览并保留独立下载按钮，二进制包直接下载', (tester) async {
    String? openedPath;
    String? downloadedPath;

    const msg = AgentMessage(
      stepIndex: 30,
      source: 'MODEL',
      msgType: 'PLANNER_RESPONSE',
      status: 'DONE',
      content: '已生成脚本与打包产物：\n'
          '脚本路径：C:/repo/script.py\n'
          '打包产物：C:/repo/release.zip',
      thinking: '',
      toolCalls: [],
      timestamp: '',
    );

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: MessageCard(
              msg: msg,
              isDark: true,
              resolveMediaUrl: (p) => p,
              onOpenFile: (p, {filename}) => openedPath = p,
              onDownloadFile: (p, {filename}) => downloadedPath = p,
              onOpenUrl: (_) {},
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    // 点击 script.py 文件卡片的「预览」按钮应走 onOpenFile 而不是 onDownloadFile
    await tester.tap(find.text('预览'));
    await tester.pump();
    expect(openedPath, contains('script.py'));
    expect(downloadedPath, isNull);

    // 点击卡片右侧独立下载图标应触发 onDownloadFile
    await tester.tap(find.byTooltip('下载文件'));
    await tester.pump();
    expect(downloadedPath, contains('script.py'));

    // 点击二进制文件 release.zip 卡片上的「下载」按钮直接触发下载
    openedPath = null;
    downloadedPath = null;
    await tester.tap(find.text('下载'));
    await tester.pump();
    expect(openedPath, isNull);
    expect(downloadedPath, contains('release.zip'));
  });

  testWidgets('TerminalPanel 建立 PTY WebSocket 后渲染终端并支持快捷键与 Deck 接入当前会话', (tester) async {
    final incoming = StreamController<dynamic>.broadcast();
    final sentFrames = <Map<String, dynamic>>[];
    Uri? connectedUri;
    final fakeChannel = _FakeTerminalWsChannel(
      incoming: incoming,
      onSend: (raw) {
        if (raw is String) {
          sentFrames.add(Map<String, dynamic>.from(jsonDecode(raw) as Map));
        }
      },
    );
    addTearDown(() async {
      await incoming.close();
    });

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 560,
            height: 620,
            child: TerminalPanel(
              serverConfig: const ServerConfig('https://hub.example.com'),
              tokenStore: MemoryTokenStore(initialAccess: 'tok-test'),
              nodeId: 'deck-node',
              nodeName: 'Steam Deck',
              initialCwd: '/home/deck/work',
              activeSessionId: 'sid-deck-42',
              isEmbedded: true,
              wsConnectOverride: (uri, {headers}) {
                connectedUri = uri;
                return fakeChannel;
              },
            ),
          ),
        ),
      ),
    );
    await tester.pump();

    expect(connectedUri?.path, '/ws/v2/nodes/deck-node/terminal');
    expect(connectedUri?.queryParameters['cwd'], '/home/deck/work');

    // 服务端返回 ready + output 帧
    incoming.add(jsonEncode({
      'type': 'ready',
      'shell': 'bash',
      'platform': 'deck',
      'cwd': '/home/deck/work',
    }));
    incoming.add(jsonEncode({
      'type': 'output',
      'data': 'deck@steamdeck:~/work\$ ',
    }));
    await tester.pumpAndSettle();

    expect(find.text('Steam Deck · bash'), findsOneWidget);
    expect(find.text('接入当前会话'), findsOneWidget);
    expect(find.text('/rewind'), findsOneWidget);

    // 点击「接入当前会话」应发送 agy --conversation=sid-deck-42\r
    await tester.tap(find.text('接入当前会话'));
    await tester.pump();
    expect(
      sentFrames.any((f) => f['type'] == 'input' && f['data'] == 'agy --conversation=sid-deck-42\r'),
      true,
    );

    // 点击 Ctrl+C 和滚动到可视区域后的 /rewind 快捷键应发送对应控制序列
    await tester.tap(find.text('Ctrl+C'));
    await tester.ensureVisible(find.text('/rewind'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('/rewind'));
    await tester.pump();
    expect(
      sentFrames.any((f) => f['type'] == 'input' && f['data'] == '\x03'),
      true,
    );
    expect(
      sentFrames.any((f) => f['type'] == 'input' && f['data'] == '/rewind\r'),
      true,
    );

    // 验证 TerminalView 配置了 AgyMono 等宽回退链
    final termView = tester.widget<TerminalView>(find.byType(TerminalView));
    expect(termView.textStyle.fontFamilyFallback, contains('AgyMono'));
    expect(termView.autofocus, true);

    // 切换到全键盘模式，验证 F1-F12 功能区、Home/End 及粘滞修饰键（Ctrl+L -> \x0c）
    await tester.tap(find.text('全键盘'));
    await tester.pumpAndSettle();
    expect(find.text('快捷栏'), findsOneWidget);
    expect(find.text('F1'), findsOneWidget);
    expect(find.text('F5'), findsOneWidget);
    expect(find.text('F12'), findsOneWidget);
    expect(find.text('Shift'), findsOneWidget);

    await tester.tap(find.text('F5'));
    await tester.pump();
    expect(
      sentFrames.any((f) => f['type'] == 'input' && f['data'] == '\x1b[15~'),
      true,
    );

    // 点亮 Ctrl 粘滞键后点击字母 L，应发送 \x0c 并自动复位 Ctrl
    await tester.tap(find.text('Ctrl'));
    await tester.pump();
    await tester.tap(find.text('L'));
    await tester.pump();
    expect(
      sentFrames.any((f) => f['type'] == 'input' && f['data'] == '\x0c'),
      true,
    );

    // 再切回快捷栏模式
    await tester.tap(find.text('快捷栏'));
    await tester.pumpAndSettle();
    expect(find.text('全键盘'), findsOneWidget);
    expect(find.text('F5'), findsNothing);
    expect(connectedUri?.queryParameters.containsKey('token'), false);
  });

  testWidgets('TerminalPanel 全键盘修饰键对方向键/退格/系统输入生效且切回快捷栏复位 Shift', (tester) async {
    final incoming = StreamController<dynamic>.broadcast();
    final sentFrames = <Map<String, dynamic>>[];
    final fakeChannel = _FakeTerminalWsChannel(
      incoming: incoming,
      onSend: (raw) {
        if (raw is String) {
          sentFrames.add(Map<String, dynamic>.from(jsonDecode(raw) as Map));
        }
      },
    );
    addTearDown(() async {
      await incoming.close();
    });

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 420,
            height: 520,
            child: TerminalPanel(
              serverConfig: const ServerConfig('https://hub.example.com'),
              tokenStore: MemoryTokenStore(initialAccess: 'tok-test'),
              nodeId: 'win-node',
              nodeName: 'Windows',
              isEmbedded: true,
              wsConnectOverride: (uri, {headers}) => fakeChannel,
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    incoming.add(jsonEncode({
      'type': 'ready',
      'shell': 'pwsh',
      'platform': 'windows',
      'cwd': r'C:\work',
    }));
    await tester.pumpAndSettle();

    // 展开全键盘：Ctrl + ← 应发送 \x1b[1;5D
    await tester.tap(find.text('全键盘'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Ctrl'));
    await tester.pump();
    await tester.tap(find.text('←'));
    await tester.pump();
    expect(
      sentFrames.any((f) => f['type'] == 'input' && f['data'] == '\x1b[1;5D'),
      true,
    );

    // Alt + ⌫ 应发送 \x1b\x7f
    await tester.tap(find.text('Alt'));
    await tester.pump();
    await tester.tap(find.text('⌫'));
    await tester.pump();
    expect(
      sentFrames.any((f) => f['type'] == 'input' && f['data'] == '\x1b\x7f'),
      true,
    );

    // 点亮 Shift 后模拟终端输出小写字母 a，应应用 Shift 发送大写 A 并复位 Shift
    await tester.tap(find.text('Shift'));
    await tester.pump();
    final termView = tester.widget<TerminalView>(find.byType(TerminalView));
    termView.terminal.textInput('a');
    await tester.pump();
    expect(
      sentFrames.any((f) => f['type'] == 'input' && f['data'] == 'A'),
      true,
    );

    // 再次点亮 Shift 后直接切回快捷栏，点击 Tab 应发送普通 \t 而非残留的 \x1b[Z
    await tester.tap(find.text('Shift'));
    await tester.pump();
    await tester.tap(find.text('快捷栏'));
    await tester.pumpAndSettle();
    sentFrames.clear();
    await tester.tap(find.text('Tab'));
    await tester.pump();
    expect(
      sentFrames.any((f) => f['type'] == 'input' && f['data'] == '\t'),
      true,
    );
    expect(
      sentFrames.any((f) => f['type'] == 'input' && f['data'] == '\x1b[Z'),
      false,
    );
  });

  testWidgets('TerminalPanel 4401 刷新期间手动重连不覆盖新连接，且极矮屏展开全键盘不溢出', (tester) async {
    final channels = <_FakeTerminalWsChannel>[];
    final controllers = <StreamController<dynamic>>[];
    final sentByConn = <int, List<Map<String, dynamic>>>{};
    final refreshCompleter = Completer<bool>();
    final liveStates = <bool>[];
    var connIdx = 0;

    addTearDown(() async {
      for (final c in controllers) {
        if (!c.isClosed) await c.close();
      }
    });

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 390,
            height: 210, // 模拟横屏手机弹出键盘后的极矮可用高度
            child: TerminalPanel(
              serverConfig: const ServerConfig('https://hub.example.com'),
              tokenStore: MemoryTokenStore(initialAccess: 'tok-test'),
              onRefreshAuth: () => refreshCompleter.future,
              nodeId: 'win-node',
              nodeName: 'Windows',
              isEmbedded: true,
              onConnectionChanged: liveStates.add,
              wsConnectOverride: (uri, {headers}) {
                final idx = connIdx++;
                final ctrl = StreamController<dynamic>.broadcast();
                controllers.add(ctrl);
                sentByConn[idx] = [];
                final ch = _FakeTerminalWsChannel(
                  incoming: ctrl,
                  onSend: (raw) {
                    if (raw is String) {
                      sentByConn[idx]!.add(Map<String, dynamic>.from(jsonDecode(raw) as Map));
                    }
                  },
                );
                channels.add(ch);
                return ch;
              },
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    expect(channels.length, 1);

    // 极矮屏幕下展开全键盘不应触发 RenderFlex overflow
    await tester.tap(find.text('全键盘'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);

    // 模拟连接 0 因 4401 关闭并卡在异步 refreshCompleter
    channels[0].closeCodeOverride = 4401;
    await controllers[0].close();
    await tester.pump();

    // 在刷新尚未返回前用户手动点击「重新连接终端」，立即开启连接 1
    await tester.tap(find.byTooltip('重新连接终端'));
    await tester.pump();
    expect(channels.length, 2);

    controllers[1].add(jsonEncode({
      'type': 'ready',
      'shell': 'pwsh',
      'platform': 'windows',
      'cwd': r'C:\work',
    }));
    await tester.pump();
    expect(liveStates.last, true);

    // 此时旧连接的刷新终于完成，不得覆盖连接 1
    refreshCompleter.complete(true);
    await tester.pump();
    expect(channels.length, 2);
  });

  testWidgets('ToolApprovalDock 支持编辑命令、选择授权范围、拒绝附言与只读权限拦截且矮屏不溢出', (tester) async {
    final recorded = <({bool allow, String scope, String denyReason, String? editedTarget})>[];
    const items = [
      ToolApprovalItem(
        approvalId: 'traj-1:3:permission',
        sessionId: 's1',
        trajectoryId: 'traj-1',
        stepIndex: 3,
        interactionKind: 'permission',
        rawInteractionField: 'permission',
        category: 'command',
        title: '终端命令权限审批',
        actionLabel: 'Run command',
        target: 'npm run build',
        cwd: r'C:\repo\web',
        reason: '命令包含构建脚本触发确认',
        shellName: 'pwsh',
        canRemember: true,
        allowedScopes: ['once', 'conversation', 'workspace'],
        suggestedPersistPattern: 'npm run *',
        editableCommand: true,
      ),
      ToolApprovalItem(
        approvalId: 'traj-1:4:mcp',
        sessionId: 's1',
        trajectoryId: 'traj-1',
        stepIndex: 4,
        interactionKind: 'mcp',
        rawInteractionField: 'mcp',
        category: 'mcp',
        title: 'MCP 工具审批',
        target: 'github/list_issues',
      ),
    ];

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: BottomInputBar(
            inputController: TextEditingController(),
            isConnected: true,
            isThinking: true,
            canWrite: true,
            isDark: true,
            pendingAttachments: const [],
            onRemoveAttachment: (_) {},
            onShowAddContext: () {},
            onSendMessage: () {},
            onStopTask: () {},
            approvalBar: ToolApprovalDock(
              approvals: items,
              resolvingIds: const {},
              canWrite: true,
              isDark: true,
              onResolve: (
                item, {
                required bool allow,
                String scope = 'once',
                String denyReason = '',
                String? editedTarget,
              }) async {
                recorded.add((
                  allow: allow,
                  scope: scope,
                  denyReason: denyReason,
                  editedTarget: editedTarget,
                ));
                return null;
              },
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('终端命令权限审批'), findsOneWidget);
    expect(find.text('队列 1/2'), findsOneWidget);
    expect(find.text('npm run build'), findsOneWidget);
    expect(find.text('本会话允许'), findsOneWidget);

    // 切换授权范围并编辑命令后允许
    await tester.tap(find.text('本会话允许'));
    await tester.pump();
    await tester.tap(find.byTooltip('编辑命令后再允许'));
    await tester.pump();
    await tester.enterText(find.byType(TextField).first, 'npm run build -- --profile');
    await tester.pump();
    await tester.tap(find.text('本会话允许').last);
    await tester.pump();

    expect(recorded.length, 1);
    expect(recorded.first.allow, true);
    expect(recorded.first.scope, 'conversation');
    expect(recorded.first.editedTarget, 'npm run build -- --profile');

    // 打开拒绝附言并提交拒绝
    await tester.tap(find.byTooltip('添加拒绝附言'));
    await tester.pump();
    await tester.enterText(find.widgetWithText(TextField, '可选：告诉 Agent 拒绝原因或替代方案...'), '先只跑单测');
    await tester.pump();
    await tester.tap(find.text('拒绝'));
    await tester.pump();

    expect(recorded.length, 2);
    expect(recorded[1].allow, false);
    expect(recorded[1].denyReason, '先只跑单测');

    // 只读模式 + 极矮横屏无溢出且隐藏操作按钮
    tester.view.physicalSize = const Size(568, 320);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Align(
            alignment: Alignment.bottomCenter,
            child: BottomInputBar(
              inputController: TextEditingController(),
              isConnected: true,
              isThinking: true,
              canWrite: false,
              isDark: false,
              pendingAttachments: const [],
              onRemoveAttachment: (_) {},
              onShowAddContext: () {},
              onSendMessage: () {},
              onStopTask: () {},
              approvalBar: ToolApprovalDock(
                approvals: items,
                resolvingIds: const {},
                canWrite: false,
                isDark: false,
                onResolve: (
                  _, {
                  required bool allow,
                  String scope = 'once',
                  String denyReason = '',
                  String? editedTarget,
                }) async =>
                    null,
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(find.text('当前账号为只读权限，无权远程审批此操作。'), findsOneWidget);
    expect(find.text('拒绝'), findsNothing);
  });

  testWidgets('TerminalPanel 在提供 onMinimize 与 onClose 时分离渲染收起与结束会话按钮且互不误触', (tester) async {
    final incoming = StreamController<dynamic>.broadcast();
    final fakeChannel = _FakeTerminalWsChannel(
      incoming: incoming,
      onSend: (_) {},
    );
    addTearDown(() async {
      await incoming.close();
    });

    var minimizeCount = 0;
    var closeCount = 0;

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 390,
            height: 640,
            child: TerminalPanel(
              serverConfig: const ServerConfig('https://hub.example.com'),
              tokenStore: MemoryTokenStore(initialAccess: 'tok-test'),
              nodeId: 'deck-node',
              nodeName: 'Deck',
              isEmbedded: true,
              onMinimize: () => minimizeCount += 1,
              onClose: () => closeCount += 1,
              wsConnectOverride: (uri, {headers}) => fakeChannel,
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    incoming.add(jsonEncode({
      'type': 'ready',
      'shell': 'bash',
      'platform': 'deck',
      'cwd': '/home/deck',
    }));
    await tester.pumpAndSettle();

    expect(find.byTooltip('收起终端（后台保持运行）'), findsOneWidget);
    expect(find.byTooltip('结束终端会话'), findsOneWidget);
    expect(find.byTooltip('关闭终端'), findsNothing);

    await tester.tap(find.byTooltip('收起终端（后台保持运行）'));
    await tester.pump();
    expect(minimizeCount, 1);
    expect(closeCount, 0);

    await tester.tap(find.byTooltip('结束终端会话'));
    await tester.pump();
    expect(minimizeCount, 1);
    expect(closeCount, 1);
  });

  testWidgets('NodePowerBanner 正确渲染待命、多任务监听与倒计时状态并响应取消', (tester) async {
    final parsed = NodePowerStatus.fromJson({
      'supported': true,
      'enabled': true,
      'action': 'sleep',
      'state': 'countdown',
      'running_sessions': 0,
      'queued_messages': 0,
      'pending_approvals': 0,
      'remaining_seconds': 42,
      'armed_by': 'simeng',
    });
    expect(parsed.actionLabel, '睡眠');
    expect(parsed.isCountdown, isTrue);
    expect(parsed.remainingSeconds, 42);

    var cancelCount = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Column(
            children: [
              NodePowerBanner(
                nodeName: 'Windows PC',
                status: const NodePowerStatus(
                  enabled: true,
                  action: 'shutdown',
                  state: 'armed',
                  runningSessions: 2,
                  pendingApprovals: 1,
                  queuedMessages: 3,
                ),
                isDark: true,
                isUpdating: false,
                maxContentWidth: 800,
                onCancel: () => cancelCount += 1,
              ),
              NodePowerBanner(
                nodeName: 'Windows PC',
                status: parsed,
                isDark: false,
                isUpdating: false,
                maxContentWidth: 800,
                onCancel: () => cancelCount += 1,
              ),
            ],
          ),
        ),
      ),
    );
    await tester.pump();

    expect(find.textContaining('2 个运行中、1 个待审批、3 条排队'), findsOneWidget);
    expect(find.textContaining('将在 42s 后自动睡眠'), findsOneWidget);

    await tester.tap(find.text('取消').first);
    await tester.pump();
    expect(cancelCount, 1);
  });

  testWidgets('QuotaDrawer 常驻侧边栏会为会话标题保留充足宽度不被时间戳挤压', (tester) async {
    tester.view.physicalSize = const Size(1280, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });

    const longTitle = '排查电源睡眠与网卡节能设置诊断任务';
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: ResponsiveLayout.permanentSidebarWidth,
            height: 800,
            child: QuotaDrawer(
              nodes: const [
                HostNode(id: 'win', name: 'Simeng PC', isOnline: true, engineAlive: true, canWrite: true, canDelete: true),
              ],
              selectedNode: 'win',
              onSwitchNode: (_) {},
              quotaData: null,
              isLoadingQuota: false,
              onRequestQuota: () {},
              onNewSession: () {},
              projects: const {
                '工作区': [
                  SessionItem(
                    id: 'sess-long-title',
                    title: longTitle,
                    updatedAt: '2026-11-22',
                  ),
                ],
              },
              generalSessions: const [],
              activeSessionId: 'sess-long-title',
              runningSessionIds: const {},
              canWrite: true,
              canDelete: true,
              onSwitchSession: (_) {},
              onDeleteSession: (_) {},
              onTogglePinSession: (_) {},
              isDark: true,
              onToggleTheme: (_) {},
              onSelectAccentTheme: (_) {},
              isPermanentSidebar: true,
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final titleFinder = find.text(longTitle);
    final timeFinder = find.text('2026-11-22');
    expect(titleFinder, findsOneWidget);
    expect(timeFinder, findsOneWidget);

    final titleRect = tester.getRect(titleFinder);
    final timeRect = tester.getRect(timeFinder);
    expect(titleRect.width, greaterThanOrEqualTo(180.0));
    expect(titleRect.bottom, lessThanOrEqualTo(timeRect.top + 2.0));
  });
}

class _FakeTerminalWsSink extends Fake implements WebSocketSink {
  final void Function(dynamic data) onSend;
  final Completer<void> _done = Completer<void>();

  _FakeTerminalWsSink(this.onSend);

  @override
  void add(dynamic data) => onSend(data);

  @override
  Future close([int? closeCode, String? closeReason]) async {
    if (!_done.isCompleted) {
      _done.complete();
    }
  }

  @override
  Future get done => _done.future;
}

class _FakeTerminalWsChannel extends Fake implements WebSocketChannel {
  final StreamController<dynamic> incoming;
  late final _FakeTerminalWsSink _sink;
  int? closeCodeOverride;
  String? closeReasonOverride;

  _FakeTerminalWsChannel({
    required this.incoming,
    required void Function(dynamic data) onSend,
  }) {
    _sink = _FakeTerminalWsSink(onSend);
  }

  @override
  Stream<dynamic> get stream => incoming.stream;

  @override
  WebSocketSink get sink => _sink;

  @override
  int? get closeCode => closeCodeOverride;

  @override
  String? get closeReason => closeReasonOverride;

  @override
  Future<void> get ready => Future<void>.value();
}

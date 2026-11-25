import 'dart:async';

import 'package:agy_remote/core/config/composer_prefs.dart';
import 'package:agy_remote/core/config/offline_outbox_store.dart';
import 'package:agy_remote/core/config/quick_commands_prefs.dart';
import 'package:agy_remote/core/config/responsive_layout.dart';
import 'package:agy_remote/core/config/server_config.dart';
import 'package:agy_remote/core/platform/platform_bridge.dart';
import 'package:agy_remote/features/auth/auth_controller.dart';
import 'package:agy_remote/features/auth/login_screen.dart';
import 'package:agy_remote/features/chat/bottom_input_bar.dart';
import 'package:agy_remote/features/chat/context_menu_sheet.dart';
import 'package:agy_remote/features/chat/markdown_message_body.dart';
import 'package:agy_remote/features/chat/message_card.dart';
import 'package:agy_remote/features/chat/model_picker_sheet.dart';
import 'package:agy_remote/features/chat/offline_outbox_bar.dart';
import 'package:agy_remote/features/chat/quick_commands_sheet.dart';
import 'package:agy_remote/features/chat/session_queue_bar.dart';
import 'package:agy_remote/features/chat/session_steps_bar.dart';
import 'package:agy_remote/features/hub/download_progress_dialog.dart';
import 'package:agy_remote/features/sessions/quota_drawer.dart';
import 'package:agy_remote/features/workspace/change_review_sheet.dart';
import 'package:agy_remote/features/workspace/file_viewer_sheet.dart';
import 'package:agy_remote/features/workspace/session_changes_bar.dart';
import 'package:agy_remote/features/workspace/workspace_file_picker_dialog.dart';
import 'package:agy_remote/models/models.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

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
        id: 'claude-sonnet-5-5-medium',
        displayName: 'Claude Sonnet 5.5 (Medium)',
        group: 'Claude',
        thinkingBadge: 'New',
        remainingFraction: 0.48,
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

    // 2. 点击输入栏模型胶囊，弹出选择器，搜索并选择 Claude Sonnet 5.5
    await tester.tap(find.text('Gemini 4 Neon (High)').last);
    await tester.pumpAndSettle();
    expect(find.text('切换当前会话模型'), findsOneWidget);
    expect(find.text('82%'), findsOneWidget);
    expect(find.text('48%'), findsOneWidget);

    await tester.enterText(find.byType(TextField).last, 'claude');
    await tester.pumpAndSettle();
    expect(find.text('Claude Sonnet 5.5 (Medium)'), findsOneWidget);
    await tester.tap(find.text('Claude Sonnet 5.5 (Medium)'));
    await tester.pumpAndSettle();
    expect(pickedModel, 'claude-sonnet-5-5-medium');
  });
}

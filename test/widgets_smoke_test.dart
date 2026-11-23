import 'package:agy_remote/core/config/composer_prefs.dart';
import 'package:agy_remote/core/config/server_config.dart';
import 'package:agy_remote/core/platform/platform_bridge.dart';
import 'package:agy_remote/features/auth/auth_controller.dart';
import 'package:agy_remote/features/auth/login_screen.dart';
import 'package:agy_remote/features/chat/bottom_input_bar.dart';
import 'package:agy_remote/features/chat/context_menu_sheet.dart';
import 'package:agy_remote/features/chat/markdown_message_body.dart';
import 'package:agy_remote/features/chat/message_card.dart';
import 'package:agy_remote/features/chat/session_queue_bar.dart';
import 'package:agy_remote/features/chat/session_steps_bar.dart';
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
}

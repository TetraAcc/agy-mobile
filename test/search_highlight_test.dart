import 'package:agy_remote/core/utils/search_highlight_utils.dart';
import 'package:agy_remote/features/chat/message_card.dart';
import 'package:agy_remote/models/models.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('对话搜索高亮工具测试', () {
    test('buildHighlightedTextSpan 大小写不敏感切分并正确设置背景色', () {
      const base = TextStyle(fontSize: 14, color: Colors.white);
      final span = buildHighlightedTextSpan(
        text: '使用 Mistral Small 3.2 和 mistral 模型',
        query: 'mistral',
        baseStyle: base,
        isDark: true,
        isFocused: true,
      );

      expect(span.children, isNotNull);
      final children = span.children!.cast<TextSpan>();
      expect(children.map((c) => c.text).join(), '使用 Mistral Small 3.2 和 mistral 模型');

      final highlighted = children
          .where((c) => c.style?.backgroundColor != null)
          .toList();
      expect(highlighted.length, 2);
      expect(highlighted[0].text, 'Mistral');
      expect(highlighted[1].text, 'mistral');
      expect(
        highlighted[0].style?.backgroundColor,
        SearchHighlightColors.background(isDark: true, isFocused: true),
      );
    });

    test('messageMatchesSearchQuery 支持正文、思考与工具参数匹配', () {
      const msg = AgentMessage(
        stepIndex: 1,
        source: 'MODEL',
        msgType: 'PLANNER_RESPONSE',
        status: 'DONE',
        content: '普通回复内容',
        thinking: '内部思考提到 Orchestrator',
        toolCalls: [
          ToolCallItem(name: 'read_file', args: {'Path': 'server/updater.py'}),
        ],
        timestamp: '',
      );

      expect(messageMatchesSearchQuery(msg, '普通回复'), true);
      expect(messageMatchesSearchQuery(msg, 'orchestrator'), true);
      expect(messageMatchesSearchQuery(msg, 'updater.py'), true);
      expect(messageMatchesSearchQuery(msg, '不存在的词'), false);
    });

    test('HostNode 与 NodeUpdateStatus JSON 解析', () {
      final node = HostNode.fromJson({
        'id': 'windows',
        'name': 'Windows PC',
        'online': true,
        'engine_alive': true,
        'version': '2.3.1',
        'can_write': true,
      });
      expect(node.version, '2.3.1');
      expect(node.toJson()['version'], '2.3.1');

      final status = NodeUpdateStatus.fromJson({
        'current_version': '2.2.2',
        'git_available': true,
        'branch': 'main',
        'behind_count': 2,
        'update_available': true,
        'can_update': true,
        'message': '发现 2 个新提交，可一键更新',
      });
      expect(status.updateAvailable, true);
      expect(status.behindCount, 2);
      expect(status.canUpdate, true);
    });
  });

  group('MessageCard 搜索高亮与思考自动展开测试', () {
    testWidgets('Markdown 正文与思考过程命中关键词时高亮并自动展开思考', (tester) async {
      const msg = AgentMessage(
        stepIndex: 3,
        source: 'MODEL',
        msgType: 'PLANNER_RESPONSE',
        status: 'DONE',
        content: '推荐 **Mistral** 模型与 `mistral_cfg` 配置。',
        thinking: '思考里也提到了 Mistral 推理显存。',
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
                searchQuery: 'mistral',
                isFocusedSearchMatch: true,
                resolveMediaUrl: (p) => p,
                onDownloadFile: (_, {filename}) {},
                onOpenUrl: (_) {},
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      // 命中思考过程时，标题提示并自动展开显示思考正文
      expect(find.textContaining('思考过程（命中搜索）'), findsOneWidget);
      expect(
        find.byWidgetPredicate(
          (w) =>
              w is SelectableText &&
              w.textSpan != null &&
              w.textSpan!.toPlainText().contains('思考里也提到了 Mistral 推理显存。'),
        ),
        findsOneWidget,
      );

      // 验证确实存在带搜索高亮背景色的 TextSpan
      bool hasHighlightSpan(InlineSpan span) {
        if (span is TextSpan) {
          if (span.style?.backgroundColor ==
              SearchHighlightColors.background(isDark: true, isFocused: true)) {
            return true;
          }
          if (span.children != null) {
            return span.children!.any(hasHighlightSpan);
          }
        }
        return false;
      }

      final highlightedWidgets = find.byWidgetPredicate((w) {
        if (w is SelectableText && w.textSpan != null) {
          return hasHighlightSpan(w.textSpan!);
        }
        if (w is RichText) {
          return hasHighlightSpan(w.text);
        }
        return false;
      });
      expect(highlightedWidgets, findsAtLeastNWidgets(2));
    });
  });
}

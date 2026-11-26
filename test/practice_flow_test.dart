import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ll_love_learn/controller.dart';
import 'package:ll_love_learn/device.dart';
import 'package:ll_love_learn/domain.dart';
import 'package:ll_love_learn/main.dart';
import 'package:ll_love_learn/practice.dart';
import 'package:ll_love_learn/remote.dart';
import 'package:ll_love_learn/storage.dart';
import 'package:material_ui/material_ui.dart';

class MemorySlots implements Slots {
  final Map<int, String> data = {};

  @override
  Future<String?> read(int index) async => data[index];

  @override
  Future<void> write(int index, String snapshot) async =>
      data[index] = snapshot;
}

/// 这个测试验证的是提交流程与界面，识别器本身不该介入。
/// 网页端的真实识别走服务器请求，同样的道理在 widget 测试里不能等。
class ImmediateGrader implements Grader {
  @override
  Future<List<Grade>> grade(List<Answer> answers) async => [
    for (final answer in answers)
      answer.ink.isEmpty
          ? (verdict: Verdict.blank, candidates: const <String>[])
          : (verdict: Verdict.pending, candidates: const <String>[]),
  ];
}

void main() {
  testWidgets('write, resume, submit, and correct a daily practice', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(910, 960));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final store = JournalStore(MemorySlots());
    final controller = await tester.runAsync(() => Controller.load(store));
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          controllerProvider.overrideWith((ref) => controller!),
          graderProvider.overrideWithValue(ImmediateGrader()),
        ],
        // 练习页本身就是 WebApp 登录后进入的界面，这里直接挂载
        child: appShell(const Dashboard(showSettings: false)),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('今日听写'), findsOneWidget);
    await tester.tap(find.text('开始听写'));
    await tester.pumpAndSettle();
    final board = find.byType(InkBoard);
    await tester.drag(board, const Offset(32, 48));
    await tester.pumpAndSettle();
    expect(controller!.data.draft!.answers.first.ink, hasLength(1));

    await tester.tap(find.byType(BackButton));
    await tester.pumpAndSettle();
    expect(find.text('继续听写'), findsOneWidget);
    await tester.tap(find.text('继续听写'));
    await tester.pumpAndSettle();
    expect(controller.data.draft!.answers.first.ink, hasLength(1));

    await tester.tap(find.widgetWithText(ChoiceChip, '5'));
    await tester.pumpAndSettle();
    // 限定到页面按钮（弹窗里同名按钮只在点击后出现），
    // 顺带断言此刻仍在作答页。
    expect(find.byType(AlertDialog), findsNothing);
    await tester.tap(find.widgetWithText(FilledButton, '提交批改'));
    await tester.pumpAndSettle();
    await tester.tap(
      find.descendant(
        of: find.byType(AlertDialog),
        matching: find.widgetWithText(FilledButton, '提交批改'),
      ),
    );
    await tester.pumpAndSettle();
    expect(controller.data.draft, isNull);
    expect(find.text('批改结果'), findsOneWidget);
    expect(find.text('空白 4'), findsOneWidget);
    expect(find.text('待确认 1'), findsOneWidget);
    await tester.tap(find.widgetWithText(TextButton, '家长订正').first);
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(SimpleDialogOption, '正确'));
    await tester.pumpAndSettle();
    expect(find.text('正确 1'), findsOneWidget);
    expect(controller.data.draft, isNull);
    final saved = await JournalStore(store.slots).load();
    final first = saved!.history.single.answers.first;
    expect(first.verdict, Verdict.correct);
    expect(first.automatic, Verdict.pending);
    expect(first.ink, hasLength(1));
  });
}

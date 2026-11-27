import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ll_love_learn/controller.dart';
import 'package:ll_love_learn/device.dart';
import 'package:ll_love_learn/domain.dart';
import 'package:ll_love_learn/main.dart';
import 'package:ll_love_learn/pinyin.dart';
import 'package:ll_love_learn/practice.dart';
import 'package:ll_love_learn/remote.dart';
import 'package:ll_love_learn/sentences.dart';
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

class UnavailableModel extends DigitalInk {
  @override
  Future<bool> ready() async => false;
}

/// 这个测试验证的是提交流程与界面，识别器本身不该介入。
/// 真实 DigitalInk.grade 是异步的，在 widget 测试的 fake async 环境里
/// 不一定能被 pumpAndSettle 驱动完，会让提交停在 await 上。
class ImmediateGrader implements Grader {
  @override
  Future<List<Grade>> grade(List<Answer> answers) async => [
    for (final answer in answers)
      (
        verdict: answer.untouched ? Verdict.blank : Verdict.pending,
        cells: [
          for (var i = 0; i < answer.question.prompt.letters.length; i++)
            (
              verdict: i < answer.cells.length && answer.cells[i].isNotEmpty
                  ? Verdict.pending
                  : Verdict.blank,
              candidates: const <String>[],
            ),
        ],
      ),
  ];
}

void main() {
  testWidgets('write, resume, submit, and correct a daily practice', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(910, 960));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    // 拼音表在 main() 里异步加载，widget 测试里手动载入
    await tester.runAsync(() => PinyinBook.load());
    await tester.runAsync(() => SentenceBook.load());
    final store = JournalStore(MemorySlots());
    final controller = await tester.runAsync(() => Controller.load(store));
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          startup.overrideWith((ref) async => controller!),
          inkProvider.overrideWithValue(UnavailableModel()),
          graderProvider.overrideWithValue(ImmediateGrader()),
        ],
        child: const DictationApp(),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('今日听写'), findsOneWidget);
    await tester.tap(find.text('开始听写'));
    await tester.pumpAndSettle();
    // 默写整个词语：每个字一个田字格，格子上方显示该字的拼音
    final prompt = controller!.data.draft!.answers.first.question.prompt;
    expect(find.byType(InkBoard), findsNWidgets(prompt.letters.length));
    expect(prompt.syllables.first, isNotEmpty);
    expect(find.text(prompt.syllables.first), findsOneWidget);
    await tester.tap(find.text('隐藏拼音'));
    await tester.pumpAndSettle();
    expect(find.text(prompt.syllables.first), findsNothing);
    await tester.tap(find.text('显示拼音'));
    await tester.pumpAndSettle();
    expect(find.text(prompt.syllables.first), findsOneWidget);
    // 一个词语对应多个田字格，写在第一格
    final board = find.byType(InkBoard).first;
    await tester.drag(board, const Offset(32, 48));
    await tester.pumpAndSettle();
    expect(controller.data.draft!.answers.first.strokeCount, 1);

    await tester.tap(find.byType(BackButton));
    await tester.pumpAndSettle();
    expect(find.text('继续听写'), findsOneWidget);
    await tester.tap(find.text('继续听写'));
    await tester.pumpAndSettle();
    expect(controller.data.draft!.answers.first.strokeCount, 1);

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
    expect(first.cells.first, hasLength(1));
    expect(first.cellVerdicts.first, Verdict.pending);
  });
}

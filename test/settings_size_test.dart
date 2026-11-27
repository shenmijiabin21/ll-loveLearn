import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ll_love_learn/controller.dart';
import 'package:ll_love_learn/domain.dart';
import 'package:ll_love_learn/settings.dart';
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

void main() {
  testWidgets('家长在练习设置里改每次练习的词汇数量', (tester) async {
    await tester.binding.setSurfaceSize(const Size(900, 1200));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final store = JournalStore(MemorySlots());
    final controller = await tester.runAsync(() => Controller.load(store));

    await tester.pumpWidget(
      ProviderScope(
        overrides: [controllerProvider.overrideWith((ref) => controller!)],
        child: const MaterialApp(home: SettingsPage()),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('每次练习新词数量'), findsOneWidget);
    expect(
      find.text('每天 5 个新词 · 到期的复习词另算（最多 5 个）'),
      findsOneWidget,
    );

    await tester.tap(find.widgetWithText(ChoiceChip, '3 个'));
    await tester.pumpAndSettle();

    expect(controller!.data.size, 3);
    expect(
      find.text('每天 3 个新词 · 到期的复习词另算（最多 5 个）'),
      findsOneWidget,
    );
    // 下一组题就该是 3 个词
    expect(controller.data.dailyQuestions(controller.today), hasLength(3));

    // 设置会落盘：换一个 store 重新读出来还是 3
    final saved = await tester.runAsync(
      () => JournalStore(store.slots).load(),
    );
    expect(saved!.size, 3);

    // 切回 5 个
    await tester.tap(find.widgetWithText(ChoiceChip, '5 个'));
    await tester.pumpAndSettle();
    expect(controller.data.size, defaultPracticeSize);
  });
}

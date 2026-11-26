import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ll_love_learn/domain.dart';
import 'package:ll_love_learn/storage.dart';

Library demo() =>
    Library.fromJson(jsonDecode(File('assets/demo.json').readAsStringSync()));

class MemorySlots implements Slots {
  final Map<int, String> data = {};

  @override
  Future<String?> read(int index) async => data[index];

  @override
  Future<void> write(int index, String snapshot) async =>
      data[index] = snapshot;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const today = '2026-11-25';

  test('reverse ordering and selected lesson determine new items', () {
    final journal = Journal(demo());
    expect(journal.library.lessons.map((lesson) => lesson.key), [
      '3a-2',
      '3a-1',
      '2b-2',
      '2b-1',
      '2a-2',
      '2a-1',
    ]);
    expect(journal.dailyQuestions(today).map((q) => q.prompt.character), [
      '观',
      '记',
      '影',
      '静',
      '湖',
    ]);
    journal.start = '2b-1';
    expect(journal.dailyQuestions(today).map((q) => q.prompt.character), [
      '跑',
      '跳',
      '书',
      '灯',
      '门',
    ]);
    expect(journal.dailyQuestions(today).last.prompt.speech, '大门。请写第二个字。大门。');
  });

  test('library rejects a phrase with the wrong target position', () {
    expect(
      () => Prompt.fromJson({'character': '门', 'phrase': '大门', 'position': 1}),
      throwsFormatException,
    );
  });

  test('review reschedules at 1, 3 and 7 days and uses parent verdicts', () {
    final journal = Journal(demo());
    final question = journal.dailyQuestions(today).first;
    void record(String date, Verdict verdict, {bool daily = false}) {
      journal.history.add(
        Practice(date, date, daily, [
          Answer(
            Question(question.id, question.prompt, question.lesson, !daily),
            automatic: verdict,
          ),
        ], submitted: true),
      );
    }

    record(today, Verdict.blank, daily: true);
    expect(journal.dailyQuestions(today), isEmpty);
    expect(journal.focus.single.due, '2026-11-26');
    expect(journal.dailyQuestions('2026-11-26').first.review, isTrue);
    record('2026-11-26', Verdict.correct);
    expect(journal.focus.single.due, '2026-11-29');
    record('2026-11-27', Verdict.correct);
    expect(journal.focus.single.streak, 1);
    record('2026-11-29', Verdict.correct);
    expect(journal.focus.single.due, '2026-12-06');
    record('2026-12-06', Verdict.correct);
    expect(journal.focus, isEmpty);
    journal.history.last.answers.single.override = Verdict.wrong;
    expect(journal.focus.single.due, '2026-12-07');
    expect(journal.focus.single.errors, 2);
  });

  test(
    'snapshot saves preserve ink and recover the previous valid revision',
    () async {
      final journal = Journal(demo());
      final question = journal.dailyQuestions(today).first;
      journal.draft = Practice('1', today, true, [
        Answer(
          question,
          ink: [
            [const InkPoint(.2, .3, 11), const InkPoint(.4, .7, 12)],
          ],
        ),
      ]);
      final slots = MemorySlots();
      final store = JournalStore(slots);
      await store.save(journal);
      journal.draft = null;
      await store.save(journal);
      expect((await JournalStore(slots).load())?.draft, isNull);
      // 破坏最新的那一槽，回退到上一份有效快照
      await slots.write(0, '{');
      final recovered = await JournalStore(slots).load();
      expect(recovered?.draft?.answers.single.ink.single.last.y, .7);
    },
  );
}

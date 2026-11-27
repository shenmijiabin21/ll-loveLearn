import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ll_love_learn/device.dart';
import 'package:ll_love_learn/domain.dart';
import 'package:ll_love_learn/pinyin.dart';
import 'package:ll_love_learn/sentences.dart';
import 'package:ll_love_learn/storage.dart';
import 'package:ll_love_learn/storage_native.dart';

Library demo() =>
    Library.fromJson(jsonDecode(File('assets/demo.json').readAsStringSync()));

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
    expect(journal.dailyQuestions(today).map((q) => q.prompt.phrase), [
      '观察',
      '记录',
      '影子',
      '安静',
      '湖水',
    ]);
    journal.start = '2b-1';
    expect(journal.dailyQuestions(today).map((q) => q.prompt.phrase), [
      '跑步',
      '跳远',
      '书本',
      '台灯',
      '大门',
    ]);
    // 默写单位是整个词语：读题语句必须通顺，不再问「第几个字」
    expect(journal.dailyQuestions(today).last.prompt.speech, '请默写词语：大门。大门。');
  });

  test('library rejects a phrase with the wrong target position', () {
    expect(
      () => Prompt.fromJson({'character': '门', 'phrase': '大门', 'position': 1}),
      throwsFormatException,
    );
  });

  test('词语按字拆格，拼音按词语读法（多音字）显示', () async {
    await PinyinBook.load();
    await SentenceBook.load();
    final prompt = Prompt.fromJson({
      'character': '叠',
      'phrase': '重叠',
      'position': 2,
    });
    expect(prompt.letters, ['重', '叠']);
    expect(prompt.syllables, ['chóng', 'dié']);
    expect(prompt.pinyinText, 'chóng dié');
    // 读题先读例句，再指定例句里要默写的词语
    expect(prompt.sentence, '两座山峰的影子重叠在一起。');
    expect(prompt.speech, '两座山峰的影子重叠在一起。请写这句话里的词语：重叠。');

    final jia = Prompt.fromJson({
      'character': '假',
      'phrase': '放假',
      'position': 2,
    });
    expect(jia.pinyinText, 'fàng jià');
  });

  test('字库里的每个词语都有一条包含它的例句', () async {
    await SentenceBook.load();
    final library = Library.fromJson(
      jsonDecode(File('assets/library_renjiao_23.json').readAsStringSync()),
    );
    final phrases = {
      for (final lesson in library.lessons)
        for (final word in lesson.words) word.phrase,
    };
    expect(phrases, hasLength(564));
    final missing = <String>[];
    for (final phrase in phrases) {
      final sentence = SentenceBook.of(phrase);
      if (sentence == null || !sentence.contains(phrase)) missing.add(phrase);
    }
    expect(missing, isEmpty);
    // 每个字的拼音也要齐
    await PinyinBook.load();
    final noPinyin = [
      for (final phrase in phrases)
        if (PinyinBook.of(phrase).any((syllable) => syllable.isEmpty)) phrase,
    ];
    expect(noPinyin, isEmpty);
  });

  test('没有例句时读题退回「请默写词语」', () async {
    await SentenceBook.load();
    final prompt = Prompt.fromJson({
      'character': '测',
      'phrase': '测试',
      'position': 1,
    });
    expect(prompt.sentence, isNull);
    expect(prompt.speech, '请默写词语：测试。测试。');
  });

  test('answer keeps one ink per character and reads legacy single-cell data', () {
    final question = Question(
      'demo/1',
      Prompt.fromJson({'character': '门', 'phrase': '大门', 'position': 2}),
      '三年级上册 · 第 1 课',
      false,
    );
    final answer = Answer(question);
    expect(answer.cells, hasLength(2));
    expect(answer.untouched, isTrue);
    answer.cells[1].add([const InkPoint(.1, .2, 1)]);
    expect(answer.strokeCount, 1);
    expect(answer.toJson()['cells'], hasLength(2));

    // 旧数据只有一条 ink，要能升级成逐格结构而不丢历史
    final legacy = Answer.fromJson({
      'question': {
        'id': question.id,
        'prompt': question.prompt.toJson(),
        'lesson': question.lesson,
        'review': question.review,
      },
      'ink': [
        [
          [.2, .3, 5],
        ],
      ],
      'skipped': false,
      'automatic': 'correct',
      'override': null,
      'candidates': ['门'],
    });
    expect(legacy.cells, hasLength(2));
    expect(legacy.cells.first.single.single.time, 5);
    expect(legacy.cells.last, isEmpty);
  });

  test('整词判定：全对才正确，任一格判错即错', () {
    expect(combineCells([Verdict.correct, Verdict.correct]), Verdict.correct);
    expect(combineCells([Verdict.correct, Verdict.wrong]), Verdict.wrong);
    expect(combineCells([Verdict.correct, Verdict.pending]), Verdict.pending);
    expect(combineCells([Verdict.correct, Verdict.blank]), Verdict.pending);
    expect(combineCells([Verdict.blank, Verdict.blank]), Verdict.blank);
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

  test('only separated, plausible recognition yields an automatic verdict', () {
    const spaced = [(text: '门', score: 1.0), (text: '问', score: 3.0)];
    expect(classify('门', spaced).verdict, Verdict.correct);
    expect(classify('目', spaced).verdict, Verdict.wrong);
    expect(classify('问', spaced).verdict, Verdict.pending);
    expect(
      classify('门', [(text: '门', score: 0.0), (text: '问', score: 0.0)]).verdict,
      Verdict.pending,
    );
    expect(classify('门', [(text: '门', score: 0.0)]).verdict, Verdict.pending);
  });

  test(
    'without a mobile model, strokes stay pending and empty answers are blank',
    () async {
      final questions = Journal(demo()).dailyQuestions(today);
      final grades = await DigitalInk().grade([
        Answer(
          questions.first,
          cells: [
            [
              [const InkPoint(.2, .3, 3)],
            ],
          ],
        ),
        Answer(questions.last),
      ]);
      expect(grades.map((grade) => grade.verdict), [
        Verdict.pending,
        Verdict.blank,
      ]);
      // 逐格结果与词语字数对齐
      expect(grades.first.cells.length, questions.first.prompt.letters.length);
      expect(grades.first.cells.first.verdict, Verdict.pending);
      expect(grades.last.cells.every((cell) => cell.verdict == Verdict.blank),
          isTrue);
    },
  );

  test(
    'disk saves preserve ink and recover the previous valid revision',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'daily-dictation-',
      );
      addTearDown(() => directory.delete(recursive: true));
      final journal = Journal(demo());
      final question = journal.dailyQuestions(today).first;
      journal.draft = Practice('1', today, true, [
        Answer(
          question,
          cells: [
            [
              [const InkPoint(.2, .3, 11), const InkPoint(.4, .7, 12)],
            ],
          ],
        ),
      ]);
      final slots = NativeSlots(directory);
      final store = JournalStore(slots);
      await store.save(journal);
      journal.draft = null;
      await store.save(journal);
      expect((await JournalStore(slots).load())?.draft, isNull);
      await slots.write(0, '{');
      final recovered = await JournalStore(slots).load();
      expect(recovered?.draft?.answers.single.cells.first.single.last.y, .7);
    },
  );
}

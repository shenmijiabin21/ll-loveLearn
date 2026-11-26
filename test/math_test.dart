import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ll_love_learn/math_question.dart';

MathLibrary samples() => MathLibrary.fromJson(
  jsonDecode(
    File('assets/samples/math_schema_samples.json').readAsStringSync(),
  ),
);

MathQuestion questionOf(String id) =>
    samples().questions.firstWhere((question) => question.id == id);

void main() {
  const carry = 'sample/add-carry/25+17';
  const borrow = 'sample/sub-borrow/52-27';
  const multiply = 'sample/mul-array/3x4';

  group('题库解析', () {
    test('三道样例题都能解析，步骤与槽位数量正确', () {
      final library = samples();
      expect(library.questions.map((q) => q.id), [
        carry,
        borrow,
        multiply,
      ]);
      expect(library.sample, isTrue);
      expect(
        library.questions.map((q) => q.steps.length),
        [3, 4, 3],
      );
    });

    test('末步没有得数槽位时拒绝解析', () {
      final raw =
          jsonDecode(
                File(
                  'assets/samples/math_schema_samples.json',
                ).readAsStringSync(),
              )
              as Map<String, dynamic>;
      final questions = raw['questions'] as List;
      final first = questions.first as Map<String, dynamic>;
      final steps = first['steps'] as List;
      (steps.last as Map<String, dynamic>)['slots'] = [
        {'id': 'tens', 'label': '十位', 'answer': '4', 'input': 'digit'},
      ];
      expect(() => MathLibrary.fromJson(raw), throwsFormatException);
    });

    test('非数学题库被拒绝', () {
      final raw =
          jsonDecode(
                File(
                  'assets/samples/math_schema_samples.json',
                ).readAsStringSync(),
              )
              as Map<String, dynamic>;
      raw['subject'] = 'chinese';
      expect(() => MathLibrary.fromJson(raw), throwsFormatException);
    });

    test('槽位宽度不足以容纳答案时拒绝解析', () {
      expect(
        () => MathSlot.fromJson({
          'id': 'sum',
          'label': '5 + 7',
          'answer': '12',
          'input': 'number',
          'width': 1,
        }),
        throwsFormatException,
      );
    });
  });

  group('输入归一化', () {
    test('全角数字、空格和千分位都被归一', () {
      expect(normalizeMathInput('１２'), '12');
      expect(normalizeMathInput(' 1 2 '), '12');
      expect(normalizeMathInput('1,234'), '1234');
    });

    test('前导零按数值视为同一答案', () {
      expect(mathValueEquals('02', 2), isTrue);
      expect(mathValueEquals('12', '12'), isTrue);
      expect(mathValueEquals('12', 13), isFalse);
      expect(mathValueEquals('', 0), isFalse);
    });
  });

  group('逐格判定', () {
    test('进位题第一步：三格全对才通过', () {
      final step = questionOf(carry).steps.first;
      expect(step.slots.map((s) => s.id), ['sum', 'ones', 'carry']);

      final allRight = {
        'sum': judgeSlot(step.slots[0], '12'),
        'ones': judgeSlot(step.slots[1], '2'),
        'carry': judgeSlot(step.slots[2], '1'),
      };
      expect(stepPasses(allRight, step), isTrue);

      // 进位格可留空，不影响通过
      final noCarry = {
        'sum': judgeSlot(step.slots[0], '12'),
        'ones': judgeSlot(step.slots[1], '2'),
        'carry': judgeSlot(step.slots[2], ''),
      };
      expect(noCarry['carry'], SlotVerdict.correct);
      expect(stepPasses(noCarry, step), isTrue);
    });

    test('必填格留空判为空白，填错判为错误', () {
      final step = questionOf(carry).steps.first;
      expect(judgeSlot(step.slots[0], ''), SlotVerdict.blank);
      expect(judgeSlot(step.slots[0], '13'), SlotVerdict.wrong);
      expect(stepPasses({'sum': SlotVerdict.blank}, step), isFalse);
      expect(stepPasses({'sum': SlotVerdict.wrong}, step), isFalse);
    });

    test('退位题与乘法题的末步都要求填出得数', () {
      for (final id in [borrow, multiply]) {
        final question = questionOf(id);
        final last = question.steps.last;
        final slot = last.slots.firstWhere((s) => s.id == 'answer');
        expect(judgeSlot(slot, '${question.answer.value}'), SlotVerdict.correct);
        expect(judgeSlot(slot, '99'), SlotVerdict.wrong);
      }
    });
  });

  group('视觉参数', () {
    test('动画声明被原样保留，未知类型不影响解析', () {
      final step = questionOf(borrow).steps.first;
      expect(step.visual?['type'], 'borrow');
      expect(step.visual?['tensAfter'], 4);

      final raw =
          jsonDecode(
                File(
                  'assets/samples/math_schema_samples.json',
                ).readAsStringSync(),
              )
              as Map<String, dynamic>;
      final questions = raw['questions'] as List;
      final first = questions.first as Map<String, dynamic>;
      final steps = first['steps'] as List;
      ((steps.first as Map<String, dynamic>)['visual']
              as Map<String, dynamic>)['type'] =
          'future-animation';
      final parsed = MathLibrary.fromJson(raw);
      expect(parsed.questions.first.steps.first.visual?['type'], 'future-animation');
    });

    test('visual 缺少 type 时拒绝解析', () {
      expect(
        () => MathStep.fromJson({
          'id': 'ones',
          'hint': '先算个位',
          'slots': [
            {'id': 'ones', 'label': '个位', 'answer': '2', 'input': 'digit'},
          ],
          'visual': {'duration': 400},
        }),
        throwsFormatException,
      );
    });
  });
}

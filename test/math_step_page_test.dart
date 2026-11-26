import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ll_love_learn/main.dart';
import 'package:ll_love_learn/math_question.dart';
import 'package:ll_love_learn/math_step.dart';
import 'package:material_ui/material_ui.dart';

MathQuestion questionOf(String id) {
  final library = MathLibrary.fromJson(
    jsonDecode(
      File('assets/samples/math_schema_samples.json').readAsStringSync(),
    ),
  );
  return library.questions.firstWhere((question) => question.id == id);
}

Future<void> pumpPage(WidgetTester tester, MathQuestion question) async {
  await tester.binding.setSurfaceSize(const Size(900, 1400));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  await tester.pumpWidget(appShell(MathStepPage(question: question)));
  await tester.pumpAndSettle();
}

/// 点键盘上的数字。键帽文字即数字本身，避免按位置取键。
Future<void> tapDigits(WidgetTester tester, String digits) async {
  for (final digit in digits.split('')) {
    await tester.tap(find.widgetWithText(OutlinedButton, digit));
    await tester.pump();
  }
}

void main() {
  const carry = 'sample/add-carry/25+17';

  testWidgets('填对一步后自动推进到下一步', (tester) async {
    await pumpPage(tester, questionOf(carry));

    expect(find.textContaining('第 1 / 3 步'), findsOneWidget);
    // 焦点在第一个必填格「5 + 7」
    await tapDigits(tester, '12');
    await tester.tap(find.text('确认这一步'));
    await tester.pump();

    // 进位格可留空，但「个位」还空着，不应通过
    expect(find.textContaining('第 1 / 3 步'), findsOneWidget);

    await tester.tap(find.text('个位'));
    await tester.pump();
    await tapDigits(tester, '2');
    await tester.tap(find.text('确认这一步'));
    await tester.pump();

    // hold 400ms 后自动进入第二步
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.textContaining('第 2 / 3 步'), findsOneWidget);
  });

  testWidgets('填错时停在原地并提示', (tester) async {
    await pumpPage(tester, questionOf(carry));

    await tapDigits(tester, '13');
    await tester.tap(find.text('确认这一步'));
    await tester.pump();

    expect(find.text('标红的格子还不对，可以重新填。'), findsOneWidget);
    expect(find.textContaining('第 1 / 3 步'), findsOneWidget);
  });

  testWidgets('留空必填格判为不通过', (tester) async {
    await pumpPage(tester, questionOf(carry));

    await tester.tap(find.text('确认这一步'));
    await tester.pump();

    expect(find.text('标红的格子还不对，可以重新填。'), findsOneWidget);
  });

  testWidgets('点看讲解后记录标记为引导后完成', (tester) async {
    await pumpPage(tester, questionOf(carry));

    await tester.tap(find.text('看讲解'));
    await tester.pump();

    expect(find.text('讲解模式'), findsOneWidget);
    expect(find.text('看讲解'), findsNothing);
  });

  testWidgets('清空键抹掉当前格内容', (tester) async {
    await pumpPage(tester, questionOf(carry));

    await tapDigits(tester, '12');
    // 题干是「25 + 17」，页面上唯一的「12」就是刚填进槽位的值
    expect(find.text('12'), findsOneWidget);

    await tester.tap(find.text('清空'));
    await tester.pump();
    expect(find.text('12'), findsNothing);
  });
}

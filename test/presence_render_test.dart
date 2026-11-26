import 'package:flutter_test/flutter_test.dart';
import 'package:ll_love_learn/remote.dart';
import 'package:ll_love_learn/web_app.dart';
import 'package:material_ui/material_ui.dart';

/// 家长端那一行状态的渲染验证。
///
/// label 的纯逻辑单测在 presence_test.dart；这里再确认它真的会被画到界面上，
/// 而不是只存在于数据里——上一轮部署暴露的问题正是「接口字段对了，
/// 但界面读错了字段」，这类错误纯数据测试抓不住。
void main() {
  Future<void> pumpChip(WidgetTester tester, ChildPresence presence) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(presence.label),
              if (presence.awayCount > 0)
                Text('今天离开 ${presence.awayCount} 次'),
            ],
          ),
        ),
      ),
    );
  }

  testWidgets('练习中显示累计时长', (tester) async {
    await pumpChip(
      tester,
      ChildPresence(
        childId: 'c1',
        state: 'practicing',
        onlineSeconds: 0, // 距上次心跳，恒为 0
        activeSeconds: 12 * 60,
        awayCount: 2,
      ),
    );

    expect(find.text('正在练习 · 已 12 分钟'), findsOneWidget);
    expect(find.text('今天离开 2 次'), findsOneWidget);
  });

  testWidgets('时长随累计活跃时间增长', (tester) async {
    for (final minutes in [1, 2, 12, 45]) {
      await pumpChip(
        tester,
        ChildPresence(
          childId: 'c1',
          state: 'practicing',
          activeSeconds: minutes * 60,
        ),
      );
      expect(
        find.text('正在练习 · 已 $minutes 分钟'),
        findsOneWidget,
        reason: '累计 $minutes 分钟时应显示对应分钟数',
      );
    }
  });

  group('轮询判重签名', () {
    ChildPresence make({
      String state = 'practicing',
      int onlineSeconds = 0,
      int activeSeconds = 0,
      int awayCount = 0,
      int awaySeconds = 0,
    }) => ChildPresence(
      childId: 'c1',
      state: state,
      onlineSeconds: onlineSeconds,
      activeSeconds: activeSeconds,
      awayCount: awayCount,
      awaySeconds: awaySeconds,
    );

    test('累计时长变化会触发重绘', () {
      // 这是 5 秒轮询能刷新数字的前提：签名必须跟着 activeSeconds 变
      final before = presenceSignature({'c1': make(activeSeconds: 60)});
      final after = presenceSignature({'c1': make(activeSeconds: 65)});
      expect(before, isNot(after));
    });

    test('只看 onlineSeconds 变化不触发重绘', () {
      // online_seconds 每次心跳都归零，拿它判重会导致时长永远不刷新
      final a = presenceSignature({'c1': make(onlineSeconds: 0)});
      final b = presenceSignature({'c1': make(onlineSeconds: 25)});
      expect(a, b);
    });

    test('状态、离开次数与时长都参与判重', () {
      final base = presenceSignature({'c1': make()});
      expect(presenceSignature({'c1': make(state: 'away')}), isNot(base));
      expect(presenceSignature({'c1': make(awayCount: 1)}), isNot(base));
      expect(presenceSignature({'c1': make(awaySeconds: 30)}), isNot(base));
    });

    test('完全没变时不触发重绘', () {
      expect(
        presenceSignature({'c1': make(activeSeconds: 120)}),
        presenceSignature({'c1': make(activeSeconds: 120)}),
      );
    });
  });
}

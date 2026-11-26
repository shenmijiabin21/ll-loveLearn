import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ll_love_learn/presence.dart';
import 'package:ll_love_learn/remote.dart';

/// PracticePresence 只负责收集素材（落笔数、离开次数/时长、可见性），
/// 不判断「算不算在练」——那个结论由服务端按时间差推导。
/// 所以这里验证的是素材统计是否正确、上报是否及时。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late List<PresenceReport> sent;
  late PracticePresence presence;

  setUp(() {
    sent = [];
    presence = PracticePresence(
      heartbeat: const Duration(hours: 1), // 测试里只靠手动触发
      report: (report) async => sent.add(report),
    );
  });

  tearDown(() => presence.stop());

  test('start 后立即按当前素材上报一次', () async {
    presence.start('p1');
    await Future<void>.delayed(Duration.zero);

    expect(sent, isNotEmpty);
    expect(sent.last.practiceId, 'p1');
    expect(sent.last.visible, isTrue);
    expect(sent.last.strokes, 0);
  });

  test('每一笔都计入 strokes，并刷新落笔时间', () async {
    presence.start('p1');
    expect(sent.last.lastStrokeAgeSeconds, isNull, reason: '还没落笔');

    presence
      ..stroke()
      ..stroke()
      ..stroke();
    presence.flushNow();
    await Future<void>.delayed(Duration.zero);

    expect(sent.last.strokes, 3);
    // 刚写完，距上次落笔应该是 0 秒左右
    expect(sent.last.lastStrokeAgeSeconds, isNotNull);
    expect(sent.last.lastStrokeAgeSeconds, lessThan(2));
  });

  test('停笔后上报的是时间差，而不是「写过」这个布尔值', () async {
    presence.start('p1');
    presence.stroke();
    presence.flushNow();
    await Future<void>.delayed(Duration.zero);
    expect(sent.last.lastStrokeAgeSeconds, lessThan(2));

    // 模拟停笔：再次上报时时间差必须变大，服务端据此判 idle。
    // 上报的是整秒，所以等 2.2 秒才能稳定得到 >= 2。
    await Future<void>.delayed(const Duration(milliseconds: 2200));
    presence.flushNow();
    await Future<void>.delayed(Duration.zero);
    expect(sent.last.lastStrokeAgeSeconds, greaterThanOrEqualTo(2));
    expect(sent.last.strokes, 1);
  });

  test('切到后台计一次离开，回来时清空离开状态', () async {
    presence.start('p1');
    presence.didChangeAppLifecycleState(AppLifecycleState.hidden);
    await Future<void>.delayed(Duration.zero);

    expect(sent.last.visible, isFalse);
    expect(sent.last.awayCount, 1);

    presence.didChangeAppLifecycleState(AppLifecycleState.resumed);
    await Future<void>.delayed(Duration.zero);

    expect(sent.last.visible, isTrue);
    // 次数是累计的，不会因为回到前台就归零
    expect(sent.last.awayCount, 1);
  });

  test('inactive 也按离开处理', () async {
    // 桌面浏览器失焦报 inactive，方向安全：宁可多记一次离开
    presence.start('p1');
    presence.didChangeAppLifecycleState(AppLifecycleState.inactive);
    await Future<void>.delayed(Duration.zero);

    expect(sent.last.visible, isFalse);
    expect(sent.last.awayCount, 1);
  });

  test('重复的 hidden 不会重复计次', () async {
    presence.start('p1');
    presence
      ..didChangeAppLifecycleState(AppLifecycleState.hidden)
      ..didChangeAppLifecycleState(AppLifecycleState.paused)
      ..didChangeAppLifecycleState(AppLifecycleState.hidden);
    await Future<void>.delayed(Duration.zero);

    expect(sent.last.awayCount, 1);
  });

  test('换练习时落笔与计数重置，离开累计保留（同一天）', () async {
    presence.start('p1');
    presence
      ..stroke()
      ..stroke();
    presence.didChangeAppLifecycleState(AppLifecycleState.hidden);
    presence.didChangeAppLifecycleState(AppLifecycleState.resumed);

    presence.start('p2');
    await Future<void>.delayed(Duration.zero);

    expect(sent.last.practiceId, 'p2');
    expect(sent.last.strokes, 0);
    expect(sent.last.lastStrokeAgeSeconds, isNull, reason: '新练习还没落笔');
    expect(sent.last.awayCount, 1);
  });

  test('上报失败不会把异常抛到调用方', () async {
    final failing = PracticePresence(
      heartbeat: const Duration(hours: 1),
      report: (_) async => throw StateError('offline'),
    );
    failing.start('p1');
    // 没有未捕获异常即通过
    await Future<void>.delayed(Duration.zero);
    failing.stop();
  });

  test('stop 之后不再上报', () async {
    presence.start('p1');
    await Future<void>.delayed(Duration.zero);
    final count = sent.length;

    presence.stop();
    presence.stroke();
    await Future<void>.delayed(Duration.zero);

    expect(sent.length, count + 1, reason: 'stop 时补发最后一次后即静默');
  });
}

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ll_love_learn/live.dart';
import 'package:ll_love_learn/presence.dart';
import 'package:ll_love_learn/remote.dart';

void main() {
  test('服务端推送的 presence 帧能被解析成家长端要显示的文案', () {
    final p = ChildPresence.fromJson({
      'child_id': 'c1',
      'state': 'practicing',
      'active_seconds': 185,
      'strokes': 42,
      'done': false,
    });
    expect(p.state, 'practicing');
    expect(p.activeSeconds, 185);
    expect(p.label, '正在练习 · 已 3 分钟');

    expect(
      ChildPresence.fromJson({'state': 'idle'}).label,
      '开着页面但没在写',
    );
    expect(ChildPresence.fromJson({'state': 'away'}).label, '已离开页面');
    expect(ChildPresence.fromJson({'state': 'done'}).label, '今天已完成');
    expect(ChildPresence.fromJson({'state': 'offline'}).label, '不在页面');
  });

  test('progress 帧给出「第几题 / 已写几题」', () {
    final running = LiveProgress.fromJson({
      'type': 'progress',
      'child_id': 'c1',
      'practice_id': 'p1',
      'index': 3,
      'total': 5,
      'written': 2,
      'submitted': false,
    });
    expect(running.label, '第 3 / 5 题 · 已写 2 题');
    // 提交后 draft 归空，不再显示进度
    expect(
      LiveProgress.fromJson({
        'type': 'progress',
        'child_id': 'c1',
        'submitted': true,
      }).label,
      '',
    );
  });

  test('实时通道把收到的帧原样交给上层，pong 等控制帧不会崩', () {
    final events = <Map<String, dynamic>>[];
    final states = <bool>[];
    final monitor = LiveMonitor(
      url: 'ws://example/ws/live',
      onEvent: events.add,
      onState: states.add,
    );
    addTearDown(monitor.dispose);

    monitor.handleMessage(
      '{"type":"presence","presence":{"child_id":"c1","state":"practicing"}}',
    );
    monitor.handleMessage('{"type":"pong"}');
    monitor.handleMessage(
      '{"type":"progress","child_id":"c1","index":2,"total":5,"written":1}',
    );
    monitor.handleMessage('not json'); // 坏帧被吞掉

    expect(events.map((e) => e['type']), ['presence', 'pong', 'progress']);
    // 非 Web 平台不建立连接（avoid 误重连），也不回调状态
    expect(states, isEmpty);
    expect(monitor.connected, isFalse);
  });

  test('默认没有上报器：手机端与测试环境不采集在线状态', () {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    expect(container.read(presenceProvider), isNull);
  });

  test('实时通道地址：相对基地址补成 wss，绝对基地址保留主机', () {
    // 线上：apiBase 是 /api，靠页面 origin 补全
    expect(
      ApiClient.buildLiveUrl(
        apiBase: '/api',
        token: 'abc',
        origin: Uri.parse('https://110.42.192.37/'),
      ),
      'wss://110.42.192.37/api/ws/live?token=abc',
    );
    // 本地联调：绝对地址 + http → ws
    expect(
      ApiClient.buildLiveUrl(apiBase: 'http://localhost:8000', token: 'abc'),
      'ws://localhost:8000/ws/live?token=abc',
    );
    // 域名带 path 的情况
    expect(
      ApiClient.buildLiveUrl(
        apiBase: 'https://dictation.example.com/api',
        token: 'abc',
      ),
      'wss://dictation.example.com/api/ws/live?token=abc',
    );
    // 没有 origin 的相对基地址算不出地址（非 Web 环境）
    expect(ApiClient.buildLiveUrl(apiBase: '/api', token: 'abc'), isNull);
  });
}

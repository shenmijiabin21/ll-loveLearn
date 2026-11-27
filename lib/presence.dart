import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'domain.dart';
import 'remote.dart';

/// 孩子「此刻是否在练习」的素材采集。
///
/// 两条证据来源互不依赖：
///   1. 落笔时间 —— 真实产出，孩子切走、挂机、把设备放一边都会停；
///   2. 页面可见性 —— 切标签页 / 失焦能立刻知道。
///
/// 这里只负责收集素材并上报，最终状态由服务端按时间差推导
/// （见 server/app/presence.py），客户端自报的结论不作数。
class PracticePresence with WidgetsBindingObserver {
  PracticePresence({
    required this.report,
    this.heartbeat = const Duration(seconds: 30),
    this.strokeThrottle = const Duration(seconds: 2),
  });

  /// 上报回调；失败会被吞掉——在线状态是锦上添花，不能打断练习
  final Future<void> Function(PresenceReport report) report;
  final Duration heartbeat;

  /// 落笔后的上报节流：孩子写一两个字就上报一次，家长端才看得到「正在动」
  final Duration strokeThrottle;

  final _clock = Stopwatch();
  Timer? _timer;
  DateTime? _lastReport;

  /// 本次练习最近一次落笔；null 表示还没落笔。
  /// 上报的是「距上次落笔多少秒」而不是「有没有落过笔」——后者一旦为真
  /// 就永远为真，停笔的孩子会被一直算作正在练习。
  DateTime? _lastStroke;

  String? _practiceId;
  bool _visible = true;
  bool _started = false;
  bool _done = false;

  int _strokes = 0;
  int _awayCount = 0;
  DateTime? _awaySince;
  Duration _awayTotal = Duration.zero;

  /// 本次练习开始时调用。切换练习会重置落笔统计。
  void start(String? practiceId) {
    _practiceId = practiceId;
    _strokes = 0;
    _lastStroke = null;
    _done = false;
    if (_started) {
      _flush();
      return;
    }
    _started = true;
    WidgetsBinding.instance.addObserver(this);
    _clock.start();
    _timer = Timer.periodic(heartbeat, (_) => _flush());
    // 开始就要报到：否则家长端要等一个心跳周期才知道孩子坐下了
    _flush();
  }

  /// 每一笔写入后调用。节流后立即上报，让家长端接近实时看到进度。
  void stroke() {
    _strokes++;
    _lastStroke = DateTime.now();
    final last = _lastReport;
    if (last == null || DateTime.now().difference(last) >= strokeThrottle) {
      _flush();
    }
  }

  /// Flutter Web 引擎把浏览器的 visibilitychange / blur / focus 映射成这些状态：
  ///   visibilityState=hidden → hidden，窗口 blur → inactive，focus → resumed。
  /// 两者都按「离开」处理：切标签页报 hidden，点到别的窗口报 inactive，
  /// 都是孩子没在看这一页。方向安全：宁可多记一次离开，也不要把跑神记成学习。
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _setVisible(state == AppLifecycleState.resumed);
  }

  void _setVisible(bool visible) {
    if (_visible == visible) return;
    _visible = visible;
    if (visible) {
      _closeAway();
      _flush();
    } else {
      _awaySince = DateTime.now();
      _awayCount++;
      // 离开的瞬间就上报：家长能立刻看到，不用等下一个心跳周期
      _flush();
    }
  }

  void _closeAway() {
    final since = _awaySince;
    if (since == null) return;
    _awayTotal += DateTime.now().difference(since);
    _awaySince = null;
  }

  PresenceReport snapshot() {
    final last = _lastStroke;
    final awayNow = _awaySince == null
        ? Duration.zero
        : DateTime.now().difference(_awaySince!);
    final away = _awayTotal + awayNow;
    final active = _clock.elapsed - away;
    return PresenceReport(
      date: day(DateTime.now()),
      practiceId: _practiceId,
      visible: _visible,
      lastStrokeAgeSeconds: last == null
          ? null
          : DateTime.now().difference(last).inSeconds,
      strokes: _strokes,
      awayCount: _awayCount,
      awaySeconds: away.inSeconds.clamp(0, 86400 * 7),
      activeSeconds: active.inSeconds.clamp(0, 86400 * 7),
      done: _done,
    );
  }

  void _flush() {
    if (!_started) return;
    _lastReport = DateTime.now();
    unawaited(report(snapshot()).catchError((Object _) {}));
  }

  /// 立即上报（绕过心跳周期）
  void flushNow() => _flush();

  /// 这一组已经提交：告诉服务端「今天完成了」，家长端立刻显示已完成
  void finish() {
    if (!_started) return;
    _done = true;
    _practiceId = null;
    _flush();
    stop(keepDone: true);
  }

  void stop({bool keepDone = false}) {
    if (!_started) return;
    // 停报之前先结算当前这段离开，否则最后一次离开的时长会丢
    _closeAway();
    if (!keepDone) _flush();
    _timer?.cancel();
    _timer = null;
    _clock.stop();
    WidgetsBinding.instance.removeObserver(this);
    _started = false;
  }

  /// 最近一次落笔距今多久，供界面提示用；还没落笔时为 null
  Duration? get sinceLastStroke {
    final last = _lastStroke;
    return last == null ? null : DateTime.now().difference(last);
  }
}

/// 练习页用的上报器；手机端/测试里没有登录态，默认为 null（不采集）。
final presenceProvider = Provider<PracticePresence?>((ref) => null);

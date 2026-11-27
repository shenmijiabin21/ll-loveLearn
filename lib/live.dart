import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';

import 'live_socket_stub.dart'
    if (dart.library.js_interop) 'live_socket_web.dart'
    as socket;

/// 家长端实时通道客户端。
///
/// 连上服务端 `/ws/live`，收到的事件交给上层：
///   snapshot  首帧，当前所有可见孩子的在线状态
///   presence  单个孩子的状态变化（孩子心跳 / 落笔保存 / 切走页面）
///   progress  孩子的练习进度（第几题、已写几题、是否已提交）
///   pong      探活
///
/// 断线自动重连（1s、2s、4s…最多 15s）；连接状态变化通过 [onState] 交给上层，
/// 上层据此决定要不要退回 HTTP 轮询兜底。
class LiveMonitor {
  LiveMonitor({
    required this.url,
    required this.onEvent,
    required this.onState,
  });

  final String url;
  final void Function(Map<String, dynamic> event) onEvent;
  final void Function(bool connected) onState;

  socket.LiveSocket? _socket;
  Timer? _retry;
  int _attempt = 0;
  bool _closed = false;
  bool _connected = false;

  bool get connected => _connected;

  void connect() {
    // 非 Web 平台没有 WebSocket 实现，直接不启动（家长端走轮询兜底）
    if (_closed || !kIsWeb) return;
    _retry?.cancel();
    _socket?.close();
    _socket = socket.LiveSocket(
      url: url,
      onMessage: handleMessage,
      onState: _handleState,
    );
  }

  /// 收到一帧文本。抽成公开方法，便于测试直接喂帧而不依赖浏览器。
  ///
  /// 坏帧一律丢弃：一条解析不了的帧不该把实时通道带崩。
  void handleMessage(String message) {
    try {
      final decoded = jsonDecode(message);
      if (decoded is Map<String, dynamic>) onEvent(decoded);
    } on FormatException {
      // 不是 JSON，忽略
    }
  }

  void _handleState(bool connected) {
    if (_closed) return;
    _connected = connected;
    onState(connected);
    _retry?.cancel();
    if (connected) {
      _attempt = 0;
      return;
    }
    // 指数退避重连：1s、2s、4s、8s，之后固定 15s
    final seconds = math.min(15, 1 << math.min(_attempt, 4));
    _attempt++;
    _retry = Timer(Duration(seconds: seconds), connect);
  }

  void dispose() {
    _closed = true;
    _retry?.cancel();
    _retry = null;
    _socket?.close();
    _socket = null;
    _connected = false;
  }
}

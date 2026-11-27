import 'dart:js_interop';

import 'package:web/web.dart' as web;

/// 浏览器 WebSocket 的最小封装：只暴露「收到一条文本」「连接状态变化」。
class LiveSocket {
  LiveSocket({
    required String url,
    required void Function(String message) onMessage,
    required void Function(bool connected) onState,
  }) {
    final socket = web.WebSocket(url);
    _socket = socket;
    // package:web 的 on* 只有 getter，所以统一用 addEventListener
    socket.addEventListener(
      'open',
      ((web.Event _) => onState(true)).toJS,
    );
    socket.addEventListener(
      'close',
      ((web.Event _) => onState(false)).toJS,
    );
    socket.addEventListener(
      'error',
      ((web.Event _) => onState(false)).toJS,
    );
    socket.addEventListener(
      'message',
      ((web.MessageEvent event) {
        final data = event.data;
        if (data != null && data.isA<JSString>()) {
          onMessage((data as JSString).toDart);
        }
      }).toJS,
    );
  }

  late final web.WebSocket _socket;

  void send(String text) {
    try {
      _socket.send(text.toJS);
    } on Object {
      // 连接正在关闭时发送会抛错，交给 close 事件触发重连
    }
  }

  void close() {
    try {
      _socket.close();
    } on Object {
      // 已经关闭
    }
  }
}

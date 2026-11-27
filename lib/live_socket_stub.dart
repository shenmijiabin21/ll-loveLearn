/// 非 Web 平台的 WebSocket 占位实现。
///
/// 手机端与 VM 测试里没有浏览器 WebSocket，LiveMonitor 会直接不启动，
/// 家长端退回 HTTP 轮询兜底。
class LiveSocket {
  LiveSocket({
    required String url,
    required void Function(String message) onMessage,
    required void Function(bool connected) onState,
  }) {
    onState(false);
  }

  void send(String text) {}

  void close() {}
}

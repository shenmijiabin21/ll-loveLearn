import 'domain.dart';
import 'web_bridge_stub.dart'
    if (dart.library.js_interop) 'web_bridge.dart'
    as bridge;

/// 浏览器语音合成。必须同步调用：移动端浏览器只在用户点击那一帧允许发声。
class Speech {
  Future<bool> play(String text) async => bridge.speak(text);

  Future<void> stop() async => bridge.stopSpeak();
}

typedef Grade = ({Verdict verdict, List<String> candidates});

abstract interface class Grader {
  Future<List<Grade>> grade(List<Answer> answers);
}

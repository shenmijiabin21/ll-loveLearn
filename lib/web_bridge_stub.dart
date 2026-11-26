import 'dart:typed_data';

// 非 web 编译目标（例如 `flutter test` 跑在 Dart VM 上）的替身：
// package:web 只在浏览器里可用，这里提供等价的空实现让测试能加载。

bool speak(String text, {double rate = 0.7}) => false;

void stopSpeak() {}

void warmUpSpeech() {}

void downloadBytes(String filename, String mimeType, Uint8List bytes) {}

Future<(String?, int, String)> pickTextFile(String mimeType) async =>
    (null, 0, '');

void lockPageScroll() {}

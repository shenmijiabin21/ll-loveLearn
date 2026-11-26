import 'dart:async';
import 'dart:js_interop';
import 'dart:typed_data';

import 'package:web/web.dart' as web;

/// 同步调用浏览器语音合成。
///
/// 必须同步执行：移动端浏览器只在「用户点击」这一帧内允许发声，
/// 任何 await 都会丢掉手势上下文，导致无声。
bool speak(String text, {double rate = 0.7}) {
  try {
    final synth = web.window.speechSynthesis;
    synth.cancel();
    final utter = web.SpeechSynthesisUtterance(text);
    utter.lang = 'zh-CN';
    utter.rate = rate;
    utter.pitch = 1;
    utter.volume = 1;
    // 优先挑中文语音
    final voices = synth.getVoices().toDart;
    for (final voice in voices) {
      final lang = voice.lang.toLowerCase();
      if (lang.startsWith('zh')) {
        utter.voice = voice;
        break;
      }
    }
    synth.speak(utter);
    synth.resume();
    return true;
  } catch (_) {
    return false;
  }
}

/// 提前加载语音列表：移动端浏览器首次 getVoices() 常为空，
/// 需要先触发一次加载，之后按语言挑中文语音才可靠。
void warmUpSpeech() {
  try {
    final synth = web.window.speechSynthesis;
    synth.getVoices();
    synth.addEventListener(
      'voiceschanged',
      ((web.Event event) {
        synth.getVoices();
      }).toJS,
    );
  } catch (_) {}
}

void stopSpeak() {
  try {
    web.window.speechSynthesis.cancel();
  } catch (_) {}
}

void downloadBytes(String filename, String mimeType, Uint8List bytes) {
  final blob = web.Blob(
    [bytes.toJS].toJS,
    web.BlobPropertyBag(type: mimeType),
  );
  final url = web.URL.createObjectURL(blob);
  final anchor = web.document.createElement('a') as web.HTMLAnchorElement;
  anchor.href = url;
  anchor.download = filename;
  web.document.body?.append(anchor);
  anchor.click();
  anchor.remove();
  web.URL.revokeObjectURL(url);
}

/// 用隐藏的 <input type=file> 选文件并读出文本。
///
/// 返回 (文件名, 字节数, 文本)；用户取消时文件名和文本为 null。
/// 用 FileReader 而不是 File.text()，老一点的浏览器也能用。
Future<(String?, int, String)> pickTextFile(String mimeType) {
  final completer = Completer<(String?, int, String)>();
  final input = web.document.createElement('input') as web.HTMLInputElement
    ..type = 'file'
    ..accept = mimeType;
  input.addEventListener(
    'change',
    ((web.Event _) {
      final file = input.files?.item(0);
      if (file == null) {
        completer.complete((null, 0, ''));
        return;
      }
      final reader = web.FileReader();
      reader.addEventListener(
        'load',
        ((web.Event _) {
          final result = reader.result;
          completer.complete((
            file.name,
            file.size,
            (result as JSString?)?.toDart ?? '',
          ));
        }).toJS,
      );
      reader.addEventListener(
        'error',
        ((web.Event _) {
          completer.complete((null, 0, ''));
        }).toJS,
      );
      reader.readAsText(file);
    }).toJS,
  );
  input.click();
  return completer.future;
}

/// 禁用浏览器层的滚动与下拉刷新，让手势全部交给 Flutter 画布，
/// 否则手写时会连带整页上下滑动。
void lockPageScroll() {
  try {
    // documentElement 的静态类型是 Element，能改样式的都是 HTMLElement
    final root = web.document.documentElement as web.HTMLElement?;
    root?.style.setProperty('touch-action', 'none');
    root?.style.setProperty('overscroll-behavior', 'none');
    final body = web.document.body;
    if (body != null) {
      // 只禁用触摸滚动与下拉刷新：手写手势全部交给 Flutter 画布。
      // 不改 position/overflow，避免影响移动端键盘与地址栏行为。
      body.style.setProperty('touch-action', 'none');
      body.style.setProperty('overscroll-behavior', 'none');
      body.style.setProperty('margin', '0');
    }
  } catch (_) {
    // 忽略：部分旧浏览器不支持这些属性
  }
}

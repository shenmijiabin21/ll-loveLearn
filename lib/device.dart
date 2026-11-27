import 'package:flutter/foundation.dart';
import 'package:flutter_tts/flutter_tts.dart';
import 'package:google_mlkit_digital_ink_recognition/google_mlkit_digital_ink_recognition.dart'
    as ml;

import 'domain.dart';
import 'web_bridge_stub.dart'
    if (dart.library.js_interop) 'web_bridge.dart'
    as bridge;

bool get hasMobileServices =>
    !kIsWeb &&
    (defaultTargetPlatform == TargetPlatform.iOS ||
        defaultTargetPlatform == TargetPlatform.android);

class Speech {
  FlutterTts? _tts;
  bool _initialized = false;

  Future<bool> play(String text) async {
    if (kIsWeb) return _playWeb(text);
    if (!hasMobileServices) return false;
    final tts = _tts ??= FlutterTts();
    try {
      await tts.stop();
      if (!_initialized) {
        final voices = await tts.getVoices;
        if (voices is! List) return false;
        final android = defaultTargetPlatform == TargetPlatform.android;
        final chinese = voices.whereType<Map>().where((voice) {
          final locale = '${voice['locale']}'.toLowerCase();
          final features = '${voice['features']}'.split('\t');
          return (locale == 'zh-cn' ||
                  locale == 'zh-hans' ||
                  locale == 'zh-hans-cn') &&
              (!android ||
                  (voice['network_required'] == '0' &&
                      !features.contains('notInstalled')));
        }).firstOrNull;
        if (chinese == null) return false;
        if (await tts.setVoice({
              'name': '${chinese['name']}',
              'locale': '${chinese['locale']}',
              if (chinese['identifier'] != null)
                'identifier': '${chinese['identifier']}',
            }) !=
            1) {
          return false;
        }
        await tts.setSpeechRate(0.38);
        _initialized = true;
      }
      return await tts.speak(text) == 1;
    } on Exception {
      _initialized = false;
      return false;
    }
  }

  // 网页端必须同步触发浏览器语音：await 会丢掉用户手势，移动端浏览器会静音。
  Future<bool> _playWeb(String text) async => bridge.speak(text);

  Future<void> stop() async {
    if (kIsWeb) {
      bridge.stopSpeak();
      return;
    }
    try {
      await _tts?.stop();
    } on Exception {
      // Speech may be unavailable after the platform audio session is closed.
    }
  }
}

/// 单个田字格（词语中的一个字）的判定结果。
typedef CellGrade = ({Verdict verdict, List<String> candidates});

/// 整个词语的判定：verdict 为整词结论，cells 为逐字结果。
typedef Grade = ({Verdict verdict, List<CellGrade> cells});
typedef Candidate = ({String text, double score});

CellGrade classify(String expected, List<Candidate> candidates) {
  final labels = candidates
      .map((item) => item.text.trim())
      .where((text) => text.isNotEmpty && text.length <= 32)
      .take(5)
      .toList();
  final first = candidates.firstOrNull;
  final next = first == null
      ? null
      : candidates
            .skip(1)
            .where((item) => item.text.trim() != first.text.trim())
            .firstOrNull;
  final top = first?.text.trim() ?? '';
  final plausible = RegExp(r'^\p{Script=Han}$', unicode: true).hasMatch(top);
  // The score is a distance, not a probability. A missing or tied score
  // deliberately routes the answer to the parent.
  final separated =
      first != null &&
      next != null &&
      first.score.isFinite &&
      next.score.isFinite &&
      next.score - first.score >= 1.0;
  final verdict = switch ((plausible, separated, top == expected)) {
    (true, true, true) => Verdict.correct,
    (true, true, false) when !labels.contains(expected) => Verdict.wrong,
    _ => Verdict.pending,
  };
  return (verdict: verdict, candidates: labels);
}

abstract interface class Grader {
  Future<List<Grade>> grade(List<Answer> answers);
}

class DigitalInk implements Grader {
  static const language = 'zh-Hani-CN';

  Future<bool> ready() async =>
      hasMobileServices &&
      await ml.DigitalInkRecognizerModelManager().isModelDownloaded(language);

  Future<bool> download() async =>
      hasMobileServices &&
      await ml.DigitalInkRecognizerModelManager().downloadModel(language);

  @override
  Future<List<Grade>> grade(List<Answer> answers) async {
    ml.DigitalInkRecognizer? recognizer;
    try {
      if (answers.any((answer) => !answer.untouched) && await ready()) {
        recognizer = ml.DigitalInkRecognizer(languageCode: language);
      }
    } on Exception {
      // Existing writing remains available for manual review.
    }
    try {
      return [
        for (final answer in answers) await _gradeOne(answer, recognizer),
      ];
    } finally {
      try {
        await recognizer?.close();
      } on Exception {
        // Closing a native recognizer does not invalidate saved results.
      }
    }
  }

  Future<Grade> _gradeOne(
    Answer answer,
    ml.DigitalInkRecognizer? recognizer,
  ) async {
    final letters = answer.question.prompt.letters;
    final cells = <CellGrade>[];
    for (var index = 0; index < letters.length; index++) {
      cells.add(await _gradeCell(answer, letters[index], index, recognizer));
    }
    return (
      verdict: combineCells([for (final cell in cells) cell.verdict]),
      cells: cells,
    );
  }

  Future<CellGrade> _gradeCell(
    Answer answer,
    String expected,
    int index,
    ml.DigitalInkRecognizer? recognizer,
  ) async {
    final ink = index < answer.cells.length
        ? answer.cells[index]
        : const <List<InkPoint>>[];
    if (ink.isEmpty) {
      return (verdict: Verdict.blank, candidates: const <String>[]);
    }
    if (recognizer == null) {
      return (verdict: Verdict.pending, candidates: const <String>[]);
    }
    try {
      const side = 300.0;
      final writing = ml.Ink()
        ..strokes = [
          for (final stroke in ink)
            ml.Stroke()
              ..points = [
                for (final point in stroke)
                  ml.StrokePoint(
                    x: point.x * side,
                    y: point.y * side,
                    t: point.time,
                  ),
              ],
        ];
      final candidates = await recognizer.recognize(
        writing,
        context: ml.DigitalInkRecognitionContext(
          writingArea: ml.WritingArea(width: side, height: side),
        ),
      );
      return classify(expected, [
        for (final candidate in candidates)
          (text: candidate.text, score: candidate.score),
      ]);
    } on Exception {
      return (verdict: Verdict.pending, candidates: const <String>[]);
    } on TypeError {
      return (verdict: Verdict.pending, candidates: const <String>[]);
    }
  }
}

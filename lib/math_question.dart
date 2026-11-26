import 'domain.dart';

/// 数学题库模型，与语文字库（Library/Lesson/Prompt）并列。
///
/// 设计见 docs/math-content-schema.md：每道题拆成有序步骤，每步有若干可填槽位，
/// 判定精确到槽位，才能做到「这一步哪里错了」而不是只回一个整题对错。
class MathSlot {
  const MathSlot({
    required this.id,
    required this.label,
    required this.answer,
    required this.input,
    required this.width,
    this.optional = false,
  });

  factory MathSlot.fromJson(Object? value) {
    final json = object(value);
    final answer = field(json['answer'], 32);
    final input = field(json['input'], 16);
    if (input != 'digit' && input != 'number') {
      throw const FormatException('槽位输入类型无效');
    }
    final width = json['width'] == null
        ? answer.runes.length.clamp(1, 12)
        : integer(json['width'], 1, 12);
    if (width < answer.runes.length) {
      throw const FormatException('槽位宽度小于答案长度');
    }
    return MathSlot(
      id: field(json['id'], 40),
      label: field(json['label'], 60),
      answer: answer,
      input: input,
      width: width,
      optional: json['optional'] == true,
    );
  }

  final String id;

  /// 格子左侧的说明文字，如「5 + 7」「个位」
  final String label;
  final String answer;

  /// digit 为单个数字，number 为可多位的整数
  final String input;
  final int width;

  /// 为 true 时留空也算通过（进位、借位这类标记格）
  final bool optional;
}

class MathStep {
  const MathStep({
    required this.id,
    required this.hint,
    required this.slots,
    this.visual,
    this.hold = 300,
  });

  factory MathStep.fromJson(Object? value) {
    final json = object(value);
    final slots = items(json['slots'], MathSlot.fromJson, 8);
    if (slots.isEmpty ||
        slots.map((slot) => slot.id).toSet().length != slots.length) {
      throw const FormatException('步骤无槽位或槽位 id 重复');
    }
    final visual = json['visual'];
    Map<String, dynamic>? parsedVisual;
    if (visual != null) {
      final map = object(visual);
      field(map['type'], 40);
      parsedVisual = map;
    }
    return MathStep(
      id: field(json['id'], 40),
      hint: field(json['hint'], 160),
      slots: slots,
      visual: parsedVisual,
      hold: json['hold'] == null ? 300 : integer(json['hold'], 0, 2000),
    );
  }

  final String id;
  final String hint;
  final List<MathSlot> slots;

  /// 原样保留的动画声明，最小页面不渲染，留给后续渲染器
  final Map<String, dynamic>? visual;
  final int hold;
}

class MathAnswer {
  const MathAnswer(this.type, this.value);

  factory MathAnswer.fromJson(Object? value) {
    final json = object(value);
    final type = field(json['type'], 16);
    if (type != 'number') {
      throw const FormatException('第一版仅支持数值答案');
    }
    final raw = json['value'];
    if (raw is! num || !raw.isFinite) {
      throw const FormatException('答案必须是数值');
    }
    return MathAnswer(type, raw);
  }

  final String type;
  final num value;
}

class MathStem {
  const MathStem(this.type, this.text);

  factory MathStem.fromJson(Object? value) {
    final json = object(value);
    return MathStem(field(json['type'], 24), field(json['text'], 200));
  }

  final String type;
  final String text;
}

class MathQuestion {
  MathQuestion({
    required this.id,
    required this.grade,
    required this.volume,
    required this.unit,
    required this.skill,
    required this.difficulty,
    required this.stem,
    required this.answer,
    required this.steps,
  });

  factory MathQuestion.fromJson(Object? value) {
    final json = object(value);
    final steps = items(json['steps'], MathStep.fromJson, 12);
    final answer = MathAnswer.fromJson(json['answer']);
    if (steps.isEmpty) throw const FormatException('题目没有步骤');
    final last = steps.last;
    MathSlot? finalSlot;
    for (final slot in last.slots) {
      if (slot.id == 'answer') {
        finalSlot = slot;
        break;
      }
    }
    if (finalSlot == null || !mathValueEquals(finalSlot.answer, answer.value)) {
      throw const FormatException('末步缺少得数槽位，或得数与 answer 不一致');
    }
    return MathQuestion(
      id: field(json['id'], 120),
      grade: integer(json['grade'], 1, 6),
      volume: field(json['volume'], 8),
      unit: field(json['unit'], 80),
      skill: field(json['skill'], 80),
      difficulty: json['difficulty'] == null
          ? 1
          : integer(json['difficulty'], 1, 5),
      stem: MathStem.fromJson(json['stem']),
      answer: answer,
      steps: steps,
    );
  }

  final String id;
  final int grade;
  final String volume;
  final String unit;

  /// 复习调度按知识点聚合，不按单题
  final String skill;
  final int difficulty;
  final MathStem stem;
  final MathAnswer answer;
  final List<MathStep> steps;
}

class MathLibrary {
  MathLibrary({
    required this.edition,
    required this.title,
    required this.source,
    required this.sample,
    required this.questions,
  });

  factory MathLibrary.fromJson(Object? value) {
    final json = object(value);
    // 先校验身份，避免把语文字库喂进来时先报一堆无关的字段错误
    if (json['schema'] != 1) {
      throw const FormatException('题库版本不受支持');
    }
    if (json['subject'] != 'math') {
      throw const FormatException('这不是数学题库');
    }
    final edition = field(json['edition'], 64);
    final questions = items(json['questions'], MathQuestion.fromJson, 600);
    if (!RegExp(r'^[a-zA-Z0-9._-]+$').hasMatch(edition) ||
        questions.isEmpty ||
        questions.map((question) => question.id).toSet().length !=
            questions.length) {
      throw const FormatException('题库版本无效或题目 id 重复');
    }
    return MathLibrary(
      edition: edition,
      title: field(json['title'], 100),
      source: field(json['source'], 400),
      sample: json['sample'] == true,
      questions: questions,
    );
  }

  final String edition;
  final String title;
  final String source;
  final bool sample;
  final List<MathQuestion> questions;
}

/// 全角数字转半角，去掉空格与千分位逗号。
///
/// 孩子在不同输入法下可能打出全角或带分隔符的数字，这些都不该判错。
String normalizeMathInput(String raw) {
  final buffer = StringBuffer();
  for (final rune in raw.runes) {
    var code = rune;
    if (code >= 0xFF10 && code <= 0xFF19) code -= 0xFEE0; // ０-９
    if (code == 0xFF0D) code = 0x2D; // －
    if (code == 0xFF0B) code = 0x2B; // ＋
    final text = String.fromCharCode(code);
    if (text == ',' || text == '，' || text == ' ' || text == '　') {
      continue;
    }
    buffer.write(text);
  }
  return buffer.toString();
}

/// 按数值比较，因此「02」与「2」视为同一答案。
bool mathValueEquals(String input, Object? expected) {
  final left = normalizeMathInput(input);
  final right = normalizeMathInput('$expected');
  if (left == right) return true;
  final a = int.tryParse(left);
  final b = int.tryParse(right);
  return a != null && b != null && a == b;
}

enum SlotVerdict { correct, wrong, blank }

/// 单格判定：留空只有在 optional 时才算通过。
SlotVerdict judgeSlot(MathSlot slot, String raw) {
  final value = normalizeMathInput(raw);
  if (value.isEmpty) {
    return slot.optional ? SlotVerdict.correct : SlotVerdict.blank;
  }
  return mathValueEquals(value, slot.answer)
      ? SlotVerdict.correct
      : SlotVerdict.wrong;
}

/// 一步通过的条件：没有任何格子是错误或空的。
bool stepPasses(Map<String, SlotVerdict> verdicts, MathStep step) =>
    step.slots.every(
      (slot) => verdicts[slot.id] == SlotVerdict.correct,
    );

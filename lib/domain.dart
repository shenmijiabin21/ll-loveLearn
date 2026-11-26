typedef Json = Map<String, dynamic>;
typedef Ink = List<List<InkPoint>>;

// 顺序即练习顺序：由后往前（三年级下册 → 三年级上册 → 二年级下册 → 二年级上册）
const volumes = {
  '3b': '三年级下册',
  '3a': '三年级上册',
  '2b': '二年级下册',
  '2a': '二年级上册',
};
const _positions = ['一', '二', '三', '四', '五', '六', '七', '八'];
final _han = RegExp(r'^\p{Script=Han}$', unicode: true);

Json object(Object? value) {
  if (value is! Json) throw const FormatException('需要 JSON 对象');
  return value;
}

List<T> items<T>(Object? value, T Function(Object?) parse, [int max = 20000]) {
  if (value is! List || value.length > max) {
    throw const FormatException('列表缺失或超出长度限制');
  }
  return value.map(parse).toList();
}

String field(Object? value, int max) {
  if (value is! String || value.trim().isEmpty || value.length > max) {
    throw const FormatException('文字字段缺失或超出长度限制');
  }
  return value.trim();
}

int integer(Object? value, int min, int max) {
  if (value is! int || value < min || value > max) {
    throw const FormatException('数字字段超出范围');
  }
  return value;
}

String day(DateTime date) =>
    '${date.year.toString().padLeft(4, '0')}-'
    '${date.month.toString().padLeft(2, '0')}-'
    '${date.day.toString().padLeft(2, '0')}';

String readDay(Object? value) {
  final text = field(value, 10);
  final date = DateTime.tryParse(text);
  if (date == null || day(date) != text) throw const FormatException('日期格式错误');
  return text;
}

String daysAfter(String date, int count) {
  final start = DateTime.parse('${date}T00:00:00Z');
  return day(start.add(Duration(days: count)));
}

class Prompt {
  const Prompt(this.character, this.phrase, this.position);

  factory Prompt.fromJson(Object? value) {
    final json = object(value);
    final character = field(json['character'], 2);
    final phrase = field(json['phrase'], 16);
    final letters = phrase.runes.map(String.fromCharCode).toList();
    final position = integer(json['position'], 1, _positions.length);
    if (letters.length < 2 ||
        letters.length > _positions.length ||
        letters.any((letter) => !_han.hasMatch(letter)) ||
        position > letters.length ||
        letters[position - 1] != character) {
      throw const FormatException('词语须为 2 至 8 个汉字，指定位置必须与目标字一致');
    }
    return Prompt(character, phrase, position);
  }

  final String character;
  final String phrase;
  final int position;
  String get speech => '$phrase。请写第${_positions[position - 1]}个字。$phrase。';
  Json toJson() => {
    'character': character,
    'phrase': phrase,
    'position': position,
  };
}

class Lesson {
  Lesson.fromJson(Object? value)
    : volume = field(object(value)['volume'], 2),
      number = integer(object(value)['number'], 1, 200),
      title = field(object(value)['title'], 100),
      words = items(object(value)['words'], Prompt.fromJson, 100) {
    if (!volumes.containsKey(volume) ||
        words.isEmpty ||
        words.map((word) => word.character).toSet().length != words.length) {
      throw const FormatException('册次无效、课内无字或目标字重复');
    }
  }

  final String volume;
  final int number;
  final String title;
  final List<Prompt> words;
  String get key => '$volume-$number';
  String get label => '${volumes[volume]} · 第 $number 课';
  Json toJson() => {
    'volume': volume,
    'number': number,
    'title': title,
    'words': words,
  };
}

class Library {
  Library.fromJson(Object? value)
    : edition = field(object(value)['edition'], 64),
      title = field(object(value)['title'], 100),
      source = field(object(value)['source'], 400),
      sample = object(value)['sample'] as bool,
      lessons = items(object(value)['lessons'], Lesson.fromJson, 600) {
    if (object(value)['schema'] != 1 ||
        !RegExp(r'^[a-zA-Z0-9._-]+$').hasMatch(edition) ||
        lessons.isEmpty ||
        lessons.map((lesson) => lesson.key).toSet().length != lessons.length) {
      throw const FormatException('字库版本或课程编号无效');
    }
    lessons.sort((a, b) {
      final order = volumes.keys.toList();
      final byVolume = order
          .indexOf(a.volume)
          .compareTo(order.indexOf(b.volume));
      return byVolume == 0 ? b.number.compareTo(a.number) : byVolume;
    });
  }

  final String edition;
  final String title;
  final String source;
  final bool sample;
  final List<Lesson> lessons;
  Json toJson() => {
    'schema': 1,
    'edition': edition,
    'title': title,
    'source': source,
    'sample': sample,
    'lessons': lessons,
  };
}

enum Verdict {
  correct('正确'),
  wrong('错字'),
  blank('空白'),
  pending('待确认');

  const Verdict(this.label);
  final String label;
}

class InkPoint {
  const InkPoint(this.x, this.y, this.time);

  factory InkPoint.fromJson(Object? value) {
    if (value is! List || value.length != 3) {
      throw const FormatException('笔迹坐标无效');
    }
    final x = value[0];
    final y = value[1];
    if (x is! num ||
        y is! num ||
        !x.isFinite ||
        !y.isFinite ||
        x < 0 ||
        x > 1 ||
        y < 0 ||
        y > 1) {
      throw const FormatException('笔迹坐标超出范围');
    }
    return InkPoint(
      x.toDouble(),
      y.toDouble(),
      integer(value[2], 0, 9007199254740991),
    );
  }

  final double x;
  final double y;
  final int time;
  List<num> toJson() => [x, y, time];
}

class Question {
  const Question(this.id, this.prompt, this.lesson, this.review);

  factory Question.fromJson(Object? value) {
    final json = object(value);
    return Question(
      field(json['id'], 120),
      Prompt.fromJson(json['prompt']),
      field(json['lesson'], 150),
      json['review'] as bool,
    );
  }

  final String id;
  final Prompt prompt;
  final String lesson;
  final bool review;
  Json toJson() => {
    'id': id,
    'prompt': prompt,
    'lesson': lesson,
    'review': review,
  };
}

class Answer {
  Answer(
    this.question, {
    Ink? ink,
    this.skipped = false,
    this.automatic,
    this.override,
    this.candidates = const [],
  }) : ink = ink ?? [];

  factory Answer.fromJson(Object? value) {
    final json = object(value);
    final ink = items(
      json['ink'],
      (stroke) => items(stroke, InkPoint.fromJson, 4096),
      128,
    );
    if (ink.any((stroke) => stroke.isEmpty)) {
      throw const FormatException('笔迹为空');
    }
    return Answer(
      Question.fromJson(json['question']),
      ink: ink,
      skipped: json['skipped'] as bool,
      automatic: _verdict(json['automatic']),
      override: _verdict(json['override']),
      candidates: items(json['candidates'], (v) => field(v, 32), 5),
    );
  }

  static Verdict? _verdict(Object? value) =>
      value == null ? null : Verdict.values.byName(field(value, 12));

  final Question question;
  final Ink ink;
  bool skipped;
  Verdict? automatic;
  Verdict? override;
  List<String> candidates;
  Verdict? get verdict => override ?? automatic;
  Json toJson() => {
    'question': question,
    'ink': ink,
    'skipped': skipped,
    'automatic': automatic?.name,
    'override': override?.name,
    'candidates': candidates,
  };
}

class Practice {
  Practice(
    this.id,
    this.date,
    this.daily,
    this.answers, {
    this.index = 0,
    this.submitted = false,
  });

  factory Practice.fromJson(Object? value) {
    final json = object(value);
    final answers = items(json['answers'], Answer.fromJson, 20);
    final submitted = json['submitted'] as bool;
    if (answers.isEmpty ||
        answers.any((answer) => submitted != (answer.automatic != null)) ||
        (!submitted && answers.any((answer) => answer.override != null))) {
      throw const FormatException('练习状态无效');
    }
    return Practice(
      field(json['id'], 64),
      readDay(json['date']),
      json['daily'] as bool,
      answers,
      index: integer(json['index'], 0, answers.length - 1),
      submitted: submitted,
    );
  }

  final String id;
  final String date;
  final bool daily;
  final List<Answer> answers;
  int index;
  bool submitted;
  int count(Verdict verdict) =>
      answers.where((answer) => answer.verdict == verdict).length;
  Json toJson() => {
    'id': id,
    'date': date,
    'daily': daily,
    'index': index,
    'submitted': submitted,
    'answers': answers,
  };
}

class Focus {
  Focus(this.question, this.due);
  final Question question;
  String due;
  int streak = 0;
  int errors = 0;
  bool pending = false;
  bool get active => streak < 3 || pending;
}

class Journal {
  Journal(this.library, {this.start, this.draft, List<Practice>? history})
    : history = history ?? [];

  factory Journal.fromJson(Object? value) {
    final json = object(value);
    if (json['schema'] != 1) throw const FormatException('备份版本不受支持');
    final library = Library.fromJson(json['library']);
    final start = json['start'] == null ? null : field(json['start'], 20);
    final draft = json['draft'] == null
        ? null
        : Practice.fromJson(json['draft']);
    final history = items(json['history'], Practice.fromJson);
    final ids = history.map((practice) => practice.id).toSet();
    if ((start != null &&
            !library.lessons.any((lesson) => lesson.key == start)) ||
        draft?.submitted == true ||
        ids.contains(draft?.id) ||
        ids.length != history.length ||
        history.any((practice) => !practice.submitted)) {
      throw const FormatException('备份中的练习或课程状态有冲突');
    }
    return Journal(library, start: start, draft: draft, history: history);
  }

  Library library;
  String? start;
  Practice? draft;
  final List<Practice> history;

  Practice? completedOn(String today) => history
      .where((practice) => practice.daily && practice.date == today)
      .firstOrNull;

  List<Focus> get focus {
    final entries = <String, Focus>{};
    for (final practice in history) {
      for (final answer in practice.answers) {
        final key = answer.question.prompt.character;
        final verdict = answer.verdict;
        if (verdict == Verdict.wrong || verdict == Verdict.blank) {
          final entry = entries.putIfAbsent(
            key,
            () => Focus(answer.question, practice.date),
          );
          entry.errors++;
          entry.streak = 0;
          entry.pending = false;
          entry.due = daysAfter(practice.date, 1);
        } else if (verdict == Verdict.pending) {
          final entry = entries.putIfAbsent(
            key,
            () => Focus(answer.question, practice.date),
          );
          entry.pending = true;
          entry.due = daysAfter(practice.date, 1);
        } else {
          final entry = entries[key];
          if (entry != null && entry.active) {
            entry.pending = false;
            // 同一天重复练习可以订正，但不能推进多个间隔阶段。
            if (practice.date.compareTo(entry.due) >= 0) {
              entry.streak = (entry.streak + 1).clamp(0, 3);
              entry.due = daysAfter(practice.date, entry.streak == 1 ? 3 : 7);
            }
          }
        }
      }
    }
    return entries.values.where((entry) => entry.active).toList()
      ..sort((a, b) => a.due.compareTo(b.due));
  }

  List<Question> dailyQuestions(String today) {
    if (completedOn(today) != null) return [];
    final due = focus
        .where((entry) => entry.due.compareTo(today) <= 0)
        .take(5)
        .map((entry) => reviewQuestion(entry))
        .toList();
    final characters = due.map((question) => question.prompt.character).toSet();
    final seen = history
        .expand((practice) => practice.answers)
        .where((answer) => !answer.question.review)
        .map((answer) => answer.question.id)
        .toSet();
    final lessons = library.lessons;
    final first = start == null
        ? 0
        : lessons.indexWhere((lesson) => lesson.key == start);
    final fresh = <Question>[];
    for (final lesson in lessons.skip(first)) {
      for (final word in lesson.words) {
        final id = '${library.edition}/${lesson.key}/${word.character}';
        if (!seen.contains(id) && characters.add(word.character)) {
          fresh.add(Question(id, word, lesson.label, false));
          if (fresh.length == 5) return [...due, ...fresh];
        }
      }
    }
    return [...due, ...fresh];
  }

  static Question reviewQuestion(Focus entry) => Question(
    entry.question.id,
    entry.question.prompt,
    entry.question.lesson,
    true,
  );

  Json toJson() => {
    'schema': 1,
    'library': library,
    'start': start,
    'draft': draft,
    'history': history,
  };
}

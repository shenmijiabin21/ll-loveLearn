import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/legacy.dart';

import 'device.dart';
import 'domain.dart';
import 'storage.dart';

final openJournal = FutureProvider<JournalStore>((ref) => JournalStore.open());
final controllerProvider = ChangeNotifierProvider<Controller>(
  (ref) => throw StateError('尚未加载练习'),
);
final speechProvider = Provider<Speech>((ref) => Speech());
final inkProvider = Provider<DigitalInk>((ref) => DigitalInk());

class Controller extends ChangeNotifier {
  Controller(this.store, this.data);

  static Future<Controller> load(JournalRepository store) async {
    final saved = await store.load();
    if (saved != null) return Controller(store, saved);
    // 默认载入人教部编版二三年级预置字库
    final asset = await rootBundle.loadString('assets/library_renjiao_23.json');
    return Controller(store, Journal(Library.fromJson(jsonDecode(asset))));
  }

  final JournalRepository store;
  Journal data;
  bool saveFailed = false;
  int _latestSave = 0;
  bool _disposed = false;
  String get today => day(DateTime.now());

  Future<bool> persist() async {
    final save = ++_latestSave;
    if (!_disposed) notifyListeners();
    var ok = false;
    try {
      await store.save(data);
      ok = true;
    } on Exception {
      ok = false;
    }
    if (save == _latestSave && !_disposed && saveFailed == ok) {
      saveFailed = !ok;
      notifyListeners();
    }
    return ok;
  }

  Practice? begin({bool daily = true}) {
    if (data.draft case final draft?) return draft;
    final questions = daily
        ? data.dailyQuestions(today)
        : data.focus.take(10).map(Journal.reviewQuestion).toList();
    if (questions.isEmpty) return null;
    final practice = Practice(
      DateTime.now().microsecondsSinceEpoch.toString(),
      today,
      daily,
      questions.map(Answer.new).toList(),
    );
    data.draft = practice;
    persist();
    return practice;
  }

  /// 立即落盘尚未写出的修改（网页端有合并窗口，提交/离开前需要）
  Future<bool> flush() async {
    try {
      await store.flush();
      return true;
    } on Exception {
      return false;
    }
  }

  Future<bool> submit(Practice practice, List<Grade> grades) async {
    if (data.draft != practice || grades.length != practice.answers.length) {
      return false;
    }
    for (var i = 0; i < grades.length; i++) {
      final answer = practice.answers[i];
      final grade = grades[i];
      answer.automatic = grade.verdict;
      answer.cellVerdicts = [for (final cell in grade.cells) cell.verdict];
      answer.cellCandidates = [for (final cell in grade.cells) cell.candidates];
    }
    practice.submitted = true;
    data.draft = null;
    data.history.add(practice);
    return persist();
  }

  /// 家长调整每次练习的新词数量；对已存在的草稿不生效，从下一次练习开始
  Future<bool> setSize(int size) {
    data.size = size.clamp(1, 20);
    notifyListeners();
    return persist();
  }

  Future<bool> replaceLibrary(Library library) {
    if (data.draft != null) throw StateError('请先完成当前练习');
    data.library = library;
    if (!library.lessons.any((lesson) => lesson.key == data.start)) {
      data.start = null;
    }
    return persist();
  }

  Future<bool> restore(Journal restored) {
    data = restored;
    return persist();
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}

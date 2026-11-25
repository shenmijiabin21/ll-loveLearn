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

  static Future<Controller> load(JournalStore store) async {
    final saved = await store.load();
    if (saved != null) return Controller(store, saved);
    final asset = await rootBundle.loadString('assets/demo.json');
    return Controller(store, Journal(Library.fromJson(jsonDecode(asset))));
  }

  final JournalStore store;
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

  Future<bool> submit(Practice practice, List<Grade> grades) async {
    if (data.draft != practice || grades.length != practice.answers.length) {
      return false;
    }
    for (var i = 0; i < grades.length; i++) {
      practice.answers[i].automatic = grades[i].verdict;
      practice.answers[i].candidates = grades[i].candidates;
    }
    practice.submitted = true;
    data.draft = null;
    data.history.add(practice);
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

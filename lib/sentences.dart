import 'dart:convert';

import 'package:flutter/services.dart';

/// 例句表（`assets/sentences.json`）：每个词语一条例句。
///
/// 读题时先读例句，再指定例句里要默写的词语，孩子听的是一个完整的句子，
/// 而不是一个孤零零的词。表里没有的词直接回退成「请默写词语：××。」
class SentenceBook {
  static Map<String, String> _book = const {};

  static bool get ready => _book.isNotEmpty;

  static Future<void> load() async {
    if (ready) return;
    try {
      final raw = jsonDecode(
        await rootBundle.loadString('assets/sentences.json'),
      );
      final book = <String, String>{};
      final table = raw is Map ? raw['sentences'] : null;
      if (table is Map) {
        for (final entry in table.entries) {
          final value = entry.value;
          if (value is String && value.isNotEmpty) {
            book['${entry.key}'] = value;
          }
        }
      }
      _book = book;
    } on Object {
      // 例句表缺失不影响默写本身，只是读题退回「请默写词语：××。」
      _book = const {};
    }
  }

  /// 供测试或恢复备份时直接注入。
  static void install(Map<String, String> book) {
    _book = book;
  }

  static String? of(String phrase) {
    final sentence = _book[phrase];
    return sentence == null || sentence.isEmpty ? null : sentence;
  }
}

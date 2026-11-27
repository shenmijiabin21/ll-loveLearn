import 'dart:convert';

import 'package:flutter/services.dart';

/// 词语拼音表（`assets/pinyin.json`）。
///
/// 优先用词级读法，正确处理多音字（如「重叠」chóng dié、「放假」fàng jià、
/// 「看守」kān shǒu）；词表里没有的词按单字兜底，再查不到就留空，界面不显示
/// 拼音而不是显示错的拼音。
class PinyinBook {
  static Map<String, List<String>> _words = const {};
  static Map<String, String> _chars = const {};

  static bool get ready => _words.isNotEmpty || _chars.isNotEmpty;

  static Future<void> load() async {
    if (ready) return;
    try {
      final raw = jsonDecode(await rootBundle.loadString('assets/pinyin.json'));
      final words = <String, List<String>>{};
      final chars = <String, String>{};
      if (raw is Map) {
        final wordTable = raw['words'];
        if (wordTable is Map) {
          for (final entry in wordTable.entries) {
            final value = entry.value;
            if (value is! List) continue;
            final syllables = value.whereType<String>().toList();
            if (syllables.isNotEmpty) words['${entry.key}'] = syllables;
          }
        }
        final charTable = raw['chars'];
        if (charTable is Map) {
          for (final entry in charTable.entries) {
            final value = entry.value;
            if (value is String && value.isNotEmpty) {
              chars['${entry.key}'] = value;
            }
          }
        }
      }
      _words = words;
      _chars = chars;
    } on Object {
      // 拼音表缺失或损坏时只是不显示拼音，听写流程照常可用。
      _words = const {};
      _chars = const {};
    }
  }

  /// 供测试或恢复备份时直接注入词表。
  static void install(
    Map<String, List<String>> words, [
    Map<String, String> chars = const {},
  ]) {
    _words = words;
    _chars = chars;
  }

  /// 返回与词语逐字对应的拼音音节，缺失位置为空字符串。
  static List<String> of(String phrase) {
    final letters = phrase.runes.map(String.fromCharCode).toList();
    final known = _words[phrase];
    if (known != null && known.length == letters.length) return known;
    return [for (final letter in letters) _chars[letter] ?? ''];
  }
}

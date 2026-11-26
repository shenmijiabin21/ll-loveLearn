import 'dart:convert';
import 'dart:ui' as ui;

import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';

/// 汉字笔顺数据（来源 hanzi-writer-data），坐标空间 1024×1024，y 轴向上。
/// 渲染时需做 y 翻转：y' = 900 - y。
class HanziStrokes {
  static Map<String, dynamic>? _all;
  static final Map<String, List<ui.Path>> _cache = {};

  static Future<Map<String, dynamic>> _asset() async {
    final cached = _all;
    if (cached != null) return cached;
    final raw = await rootBundle.loadString('assets/hanzi_strokes.json');
    final decoded = jsonDecode(raw) as Map<String, dynamic>;
    _all = decoded;
    return decoded;
  }

  /// 返回该字的笔画路径（1024 坐标系，y 已翻转）；无数据返回 null
  static Future<List<ui.Path>?> pathsFor(String character) async {
    final cached = _cache[character];
    if (cached != null) return cached;
    final all = await _asset();
    final entry = all[character];
    if (entry is! Map) return null;
    final raw = entry['strokes'];
    if (raw is! List || raw.isEmpty) return null;
    final paths = <ui.Path>[
      for (final item in raw)
        if (item is String) _parsePath(item),
    ];
    if (paths.isEmpty) return null;
    _cache[character] = paths;
    return paths;
  }

  /// 每笔的中心线（归一化到 0..1，y 已翻转），用于笔画正确性校验
  static Future<List<List<Offset>>?> mediansFor(String character) async {
    final all = await _asset();
    final entry = all[character];
    if (entry is! Map) return null;
    final raw = entry['medians'];
    if (raw is! List || raw.isEmpty) return null;
    final result = <List<Offset>>[];
    for (final stroke in raw) {
      if (stroke is! List) continue;
      final points = <Offset>[
        for (final p in stroke)
          if (p is List && p.length >= 2)
            Offset(
              (p[0] as num).toDouble() / 1024.0,
              (900 - (p[1] as num).toDouble()) / 1024.0,
            ),
      ];
      if (points.length >= 2) result.add(points);
    }
    return result.isEmpty ? null : result;
  }

  static const double _minY = 0;

  static ui.Path _parsePath(String d) {
    final path = ui.Path();
    final tokens = _tokenize(d);
    var i = 0;
    String cmd = 'M';
    var x = 0.0;
    var y = 0.0;
    var startX = 0.0;
    var startY = 0.0;

    double next() => i < tokens.length ? tokens[i++] : 0.0;

    while (i < tokens.length) {
      if (_isLetter(tokens[i])) {
        cmd = String.fromCharCode(tokens[i].toInt());
        i++;
        if (cmd == 'Z' || cmd == 'z') {
          path.close();
          x = startX;
          y = startY;
          continue;
        }
      }
      switch (cmd) {
        case 'M':
          x = next();
          y = next();
          startX = x;
          startY = y;
          path.moveTo(x, _flip(y));
          cmd = 'L';
        case 'L':
          x = next();
          y = next();
          path.lineTo(x, _flip(y));
        case 'Q':
          final cx = next();
          final cy = next();
          x = next();
          y = next();
          path.quadraticBezierTo(cx, _flip(cy), x, _flip(y));
        case 'C':
          final c1x = next();
          final c1y = next();
          final c2x = next();
          final c2y = next();
          x = next();
          y = next();
          path.cubicTo(c1x, _flip(c1y), c2x, _flip(c2y), x, _flip(y));
        default:
          // 未支持的命令：跳过一个数字避免死循环
          i++;
      }
    }
    return path;
  }

  static double _flip(double y) => 900 - y;

  // 负数以 -1e-5 的形式编码在列表里，配合下标游标解析
  static List<double> _tokenize(String d) {
    final tokens = <double>[];
    final pattern = RegExp(r'[MLQCZmlqcz]|-?\d*\.?\d+(?:e-?\d+)?');
    for (final m in pattern.allMatches(d)) {
      final s = m.group(0)!;
      final code = s.codeUnitAt(0);
      final isLetter =
          (code >= 65 && code <= 90) || (code >= 97 && code <= 122);
      tokens.add(isLetter ? code.toDouble() : double.parse(s));
    }
    return tokens;
  }

  static bool _isLetter(double v) =>
      (v >= 65 && v <= 90) || (v >= 97 && v <= 122);
}

/// 笔画比对：把学生画的一笔与参考中心线比较，返回是否通过
class StrokeMatch {
  const StrokeMatch({required this.ok, required this.distance});

  final bool ok;
  final double distance;

  static const int _samples = 24;

  /// [drawn] 归一化坐标（0..1）的学生笔画；[reference] 参考中心线
  static StrokeMatch compare(List<Offset> drawn, List<Offset> reference) {
    if (drawn.length < 2 || reference.length < 2) {
      return const StrokeMatch(ok: false, distance: 1);
    }
    final a = _resample(drawn, _samples);
    final b = _resample(reference, _samples);

    var total = 0.0;
    for (var i = 0; i < _samples; i++) {
      total += (a[i] - b[i]).distance;
    }
    final mean = total / _samples;

    // 长度比例：防止一个点或过长的涂抹通过
    final lenA = _length(a);
    final lenB = _length(b);
    final ratio = lenB <= 0 ? 0.0 : lenA / lenB;

    // 方向一致性（起止向量）
    final va = a.last - a.first;
    final vb = b.last - b.first;
    var cosine = 1.0;
    if (va.distance > 0.01 && vb.distance > 0.01) {
      cosine = (va.dx * vb.dx + va.dy * vb.dy) /
          (va.distance * vb.distance);
    }

    final shortStroke = lenB < 0.12; // 点、提等极短笔画放宽方向要求
    final ok =
        mean <= 0.13 &&
        ratio >= 0.35 &&
        ratio <= 3.0 &&
        (shortStroke || cosine >= 0.2);

    return StrokeMatch(ok: ok, distance: mean);
  }

  static List<Offset> _resample(List<Offset> points, int count) {
    final result = <Offset>[];
    final total = _length(points);
    if (total <= 0 || points.length < 2) {
      return List<Offset>.filled(count, points.first);
    }
    final step = total / (count - 1);
    var index = 0;
    var carried = 0.0;
    var current = points.first;
    result.add(current);
    for (var i = 0; i < count - 1; i++) {
      var target = step;
      while (index < points.length - 1) {
        final next = points[index + 1];
        final segment = (next - current).distance;
        if (carried + segment >= target) {
          final t = (target - carried) / segment;
          current = Offset(
            current.dx + (next.dx - current.dx) * t,
            current.dy + (next.dy - current.dy) * t,
          );
          carried = 0;
          target = 0;
          break;
        }
        carried += segment;
        current = next;
        index++;
      }
      result.add(current);
    }
    while (result.length < count) {
      result.add(points.last);
    }
    return result.take(count).toList();
  }

  static double _length(List<Offset> points) {
    var total = 0.0;
    for (var i = 1; i < points.length; i++) {
      total += (points[i] - points[i - 1]).distance;
    }
    return total;
  }
}



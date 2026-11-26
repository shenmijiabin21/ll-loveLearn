import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:ll_love_learn/strokes.dart';

List<Offset> line(Offset a, Offset b, {int n = 20}) => List.generate(
  n,
  (i) => Offset(
    a.dx + (b.dx - a.dx) * i / (n - 1),
    a.dy + (b.dy - a.dy) * i / (n - 1),
  ),
);

void main() {
  final reference = line(const Offset(0.2, 0.5), const Offset(0.8, 0.5));

  test('完全一致的一笔通过', () {
    final r = StrokeMatch.compare(reference, reference);
    expect(r.ok, isTrue, reason: 'distance=${r.distance}');
  });

  test('略有偏移/抖动的一笔通过', () {
    final drawn = [
      for (final p in reference)
        Offset(p.dx + 0.02, p.dy + 0.015),
    ];
    final r = StrokeMatch.compare(drawn, reference);
    expect(r.ok, isTrue, reason: 'distance=${r.distance}');
  });

  test('竖直方向的一笔被拒绝', () {
    final drawn = line(const Offset(0.5, 0.2), const Offset(0.5, 0.8));
    final r = StrokeMatch.compare(drawn, reference);
    expect(r.ok, isFalse, reason: 'distance=${r.distance}');
  });

  test('反向书写被拒绝', () {
    final drawn = line(const Offset(0.8, 0.5), const Offset(0.2, 0.5));
    final r = StrokeMatch.compare(drawn, reference);
    expect(r.ok, isFalse, reason: 'distance=${r.distance}');
  });

  test('过短的一笔（点）被拒绝', () {
    final drawn = line(const Offset(0.5, 0.5), const Offset(0.53, 0.5));
    final r = StrokeMatch.compare(drawn, reference);
    expect(r.ok, isFalse, reason: 'distance=${r.distance}');
  });

  test('极短参考笔画（点）允许方向自由', () {
    final dot = line(const Offset(0.5, 0.5), const Offset(0.56, 0.52));
    final drawn = line(const Offset(0.5, 0.5), const Offset(0.56, 0.52));
    final r = StrokeMatch.compare(drawn, dot);
    expect(r.ok, isTrue, reason: 'distance=${r.distance}');
  });
}

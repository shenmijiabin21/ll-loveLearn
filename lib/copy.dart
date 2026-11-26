import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/gestures.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import 'controller.dart';
import 'domain.dart';
import 'main.dart';
import 'math_preview.dart';
import 'strokes.dart';

/// 练习（临摹）入口：列出今天的字，点开逐笔引导练习
class CopyListPage extends ConsumerWidget {
  const CopyListPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final controller = ref.watch(controllerProvider);
    final data = controller.data;
    final today = controller.today;
    final completed = data.completedOn(today);
    final questions = completed != null
        ? completed.answers.map((answer) => answer.question).toList()
        : data.dailyQuestions(today);
    return PageBody(
      children: [
        const SectionTitle('练习', '照着笔顺一笔一笔写，写对才出现下一笔'),
        Panel(
          child: ListTile(
            leading: const Icon(Icons.calculate_outlined, color: forest),
            title: const Text('数学 · 分步练习'),
            subtitle: const Text('一步一步填，每步单独判定（体验版）'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => Navigator.of(context).push(
              MaterialPageRoute<void>(builder: (_) => const MathListPage()),
            ),
          ),
        ),
        if (questions.isEmpty)
          const Panel(child: ListTile(title: Text('今天还没有可练习的字。')))
        else
          for (final question in questions)
            Panel(
              child: ListTile(
                leading: CircleAvatar(
                  backgroundColor: sage,
                  foregroundColor: forest,
                  child: Text(
                    question.prompt.character,
                    style: const TextStyle(fontSize: 20),
                  ),
                ),
                title: Text(question.prompt.phrase),
                subtitle: Text(question.lesson),
                trailing: const Icon(Icons.chevron_right),
                onTap: () => Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    builder: (_) => CopyPage(
                      character: question.prompt.character,
                      phrase: question.prompt.phrase,
                    ),
                  ),
                ),
              ),
            ),
      ],
    );
  }
}

/// 练习（临摹）页：一次只显示一个笔画，写对之后才显示下一笔。
class CopyPage extends StatefulWidget {
  const CopyPage({super.key, required this.character, required this.phrase});

  final String character;
  final String phrase;

  @override
  State<CopyPage> createState() => _CopyPageState();
}

class _CopyPageState extends State<CopyPage> {
  List<ui.Path>? _paths;
  List<List<Offset>>? _medians;

  int _step = 0;
  final List<List<InkPoint>> _accepted = [];
  List<InkPoint> _current = [];
  int? _pointer;
  String? _hint;
  bool _done = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final paths = await HanziStrokes.pathsFor(widget.character);
    final medians = await HanziStrokes.mediansFor(widget.character);
    if (!mounted) return;
    setState(() {
      _paths = paths;
      _medians = medians;
    });
  }

  void _reset() => setState(() {
    _step = 0;
    _accepted.clear();
    _current = [];
    _done = false;
    _hint = null;
  });

  void _addPoint(Offset local, double side) {
    if (_current.length >= 4096) return;
    final x = (local.dx / side).clamp(0.0, 1.0);
    final y = (local.dy / side).clamp(0.0, 1.0);
    final last = _current.lastOrNull;
    if (last != null && (last.x - x).abs() < 1e-4 && (last.y - y).abs() < 1e-4) {
      return;
    }
    _current.add(
      InkPoint(x, y, DateTime.now().millisecondsSinceEpoch),
    );
  }

  void _finishStroke(double side) {
    final medians = _medians;
    final stroke = List<InkPoint>.of(_current);
    _current = [];
    if (medians == null || _step >= medians.length || stroke.length < 2) {
      setState(() {});
      return;
    }
    final drawn = [for (final p in stroke) Offset(p.x, p.y)];
    final match = StrokeMatch.compare(drawn, medians[_step]);
    setState(() {
      if (match.ok) {
        _accepted.add(stroke);
        _step++;
        _hint = null;
        if (_step >= medians.length) {
          _done = true;
        }
      } else {
        _hint = '这一笔还不太对，照着浅灰色的笔画再写一次';
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final total = _medians?.length ?? 0;
    return Scaffold(
      appBar: AppBar(title: Text('练习 · ${widget.character}')),
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 520),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(20, 10, 20, 12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(
                    '${widget.character} · ${widget.phrase}',
                    style: const TextStyle(
                      fontSize: 22,
                      fontWeight: FontWeight.w800,
                      color: forest,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    _done
                        ? '写完了，可以再练一次'
                        : total == 0
                        ? '该字暂无笔顺数据'
                        : '第 ${math.min(_step + 1, total)} / $total 笔',
                    style: const TextStyle(color: textMuted, fontSize: 13),
                  ),
                  const SizedBox(height: 8),
                  Expanded(
                    child: LayoutBuilder(
                      builder: (context, box) {
                        final side = math.max(
                          130.0,
                          math.min(
                            300.0,
                            math.min(box.maxWidth, (box.maxHeight - 10) / 2),
                          ),
                        );
                        return Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            _GuideGrid(
                              paths: _paths,
                              step: _step,
                              done: _done,
                              size: side,
                            ),
                            const SizedBox(height: 10),
                            _CopyBoard(
                              side: side,
                              accepted: _accepted,
                              current: _current,
                              enabled: !_done && total > 0,
                              pointer: _pointer,
                              onPointerDown: (p) => setState(() {
                                _pointer = p.pointer;
                                _addPoint(p.localPosition, side);
                              }),
                              onPointerMove: (p) {
                                if (_pointer == p.pointer) {
                                  setState(
                                    () => _addPoint(p.localPosition, side),
                                  );
                                }
                              },
                              onPointerUp: (p) {
                                _pointer = null;
                                _finishStroke(side);
                              },
                              onPointerCancel: (p) {
                                _pointer = null;
                                _finishStroke(side);
                              },
                            ),
                          ],
                        );
                      },
                    ),
                  ),
                  if (_hint != null)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 6),
                      child: Text(
                        _hint!,
                        style: const TextStyle(
                          color: Color(0xFFC62828),
                          fontSize: 13,
                        ),
                      ),
                    ),
                  Align(
                    alignment: Alignment.center,
                    child: Wrap(
                      spacing: 10,
                      children: [
                        OutlinedButton.icon(
                          onPressed: _reset,
                          icon: const Icon(Icons.refresh),
                          label: Text(_done ? '再练一次' : '重来'),
                        ),
                        if (_done)
                          FilledButton(
                            onPressed: () => Navigator.of(context).pop(),
                            child: const Text('返回'),
                          ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _GuideGrid extends StatelessWidget {
  const _GuideGrid({
    required this.paths,
    required this.step,
    required this.done,
    required this.size,
  });

  final List<ui.Path>? paths;
  final int step;
  final bool done;
  final double size;

  @override
  Widget build(BuildContext context) => CustomPaint(
    size: Size.square(size),
    painter: _GuidePainter(paths: paths, step: step, done: done),
  );
}

class _GuidePainter extends CustomPainter {
  _GuidePainter({required this.paths, required this.step, required this.done});

  final List<ui.Path>? paths;
  final int step;
  final bool done;

  static const _hintColor = Color(0xFFCBCBCB);
  static const _doneColor = Color(0xFF193D32);

  @override
  void paint(Canvas canvas, Size size) {
    _paintGrid(canvas, size);
    final list = paths;
    if (list == null) return;
    canvas.save();
    canvas.clipRect(Offset.zero & size);
    canvas.scale(size.width / 1024.0);
    final hint = Paint()..color = _hintColor;
    final solid = Paint()..color = _doneColor;
    for (var i = 0; i < list.length; i++) {
      if (i < step) {
        canvas.drawPath(list[i], solid);
      } else if (i == step && !done) {
        // 只提示当前这一笔
        canvas.drawPath(list[i], hint);
      }
    }
    canvas.restore();
  }

  @override
  bool shouldRepaint(_GuidePainter old) =>
      old.step != step || old.done != done || old.paths != paths;
}

class _CopyBoard extends StatelessWidget {
  const _CopyBoard({
    required this.side,
    required this.accepted,
    required this.current,
    required this.enabled,
    required this.pointer,
    required this.onPointerDown,
    required this.onPointerMove,
    required this.onPointerUp,
    required this.onPointerCancel,
  });

  final double side;
  final List<List<InkPoint>> accepted;
  final List<InkPoint> current;
  final bool enabled;
  final int? pointer;
  final void Function(PointerDownEvent) onPointerDown;
  final void Function(PointerMoveEvent) onPointerMove;
  final void Function(PointerUpEvent) onPointerUp;
  final void Function(PointerCancelEvent) onPointerCancel;

  @override
  Widget build(BuildContext context) => Semantics(
    label: '练习书写区',
    child: RawGestureDetector(
      gestures: enabled
          ? <Type, GestureRecognizerFactory>{
              _EagerPan: GestureRecognizerFactoryWithHandlers<_EagerPan>(
                _EagerPan.new,
                (_) {},
              ),
            }
          : const <Type, GestureRecognizerFactory>{},
      child: Listener(
        behavior: HitTestBehavior.opaque,
        onPointerDown: enabled ? onPointerDown : null,
        onPointerMove: enabled ? onPointerMove : null,
        onPointerUp: enabled ? onPointerUp : null,
        onPointerCancel: enabled ? onPointerCancel : null,
        child: CustomPaint(
          size: Size.square(side),
          painter: _BoardPainter(accepted: accepted, current: current),
        ),
      ),
    ),
  );
}

class _EagerPan extends PanGestureRecognizer {
  @override
  void addAllowedPointer(PointerDownEvent event) {
    super.addAllowedPointer(event);
    resolve(GestureDisposition.accepted);
  }
}

class _BoardPainter extends CustomPainter {
  _BoardPainter({required this.accepted, required this.current});

  final List<List<InkPoint>> accepted;
  final List<InkPoint> current;

  static const _ink = Color(0xFF193D32);

  @override
  void paint(Canvas canvas, Size size) {
    _paintGrid(canvas, size);
    final paint = Paint()
      ..color = _ink
      ..style = PaintingStyle.stroke
      ..strokeWidth = 3.2
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;
    for (final stroke in [...accepted, current]) {
      if (stroke.isEmpty) continue;
      final path = Path();
      path.moveTo(stroke.first.x * size.width, stroke.first.y * size.height);
      if (stroke.length == 1) {
        canvas.drawCircle(
          Offset(stroke.first.x * size.width, stroke.first.y * size.height),
          1.6,
          Paint()..color = _ink,
        );
        continue;
      }
      for (final p in stroke.skip(1)) {
        path.lineTo(p.x * size.width, p.y * size.height);
      }
      canvas.drawPath(path, paint);
    }
  }

  @override
  bool shouldRepaint(_BoardPainter old) => true;
}

void _paintGrid(Canvas canvas, Size size) {
  final rect = Offset.zero & size;
  canvas.drawRect(rect, Paint()..color = Colors.white);
  final border = Paint()
    ..color = const Color(0xFFDCE3D7)
    ..style = PaintingStyle.stroke
    ..strokeWidth = 1.4;
  canvas.drawRect(rect.deflate(0.7), border);
  final dash = Paint()
    ..color = const Color(0xFFE1E7DC)
    ..strokeWidth = 1;
  const segments = 12;
  for (var i = 0; i < segments; i += 2) {
    final a = size.height / segments * i;
    final b = size.height / segments * (i + 1);
    canvas.drawLine(Offset(size.width / 2, a), Offset(size.width / 2, b), dash);
    final c = size.width / segments * i;
    final d = size.width / segments * (i + 1);
    canvas.drawLine(Offset(c, size.height / 2), Offset(d, size.height / 2), dash);
  }
}

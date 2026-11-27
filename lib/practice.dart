import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' show PointMode;

import 'package:flutter/gestures.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart' hide Ink;

import 'controller.dart';
import 'device.dart';
import 'domain.dart';
import 'main.dart';
import 'presence.dart';
import 'remote.dart';

Color _frameColor(Verdict? verdict) => switch (verdict) {
  Verdict.correct => verdictOk,
  Verdict.pending => verdictWarn,
  _ => verdictNeutral,
};

void openPractice(BuildContext context, Practice practice) {
  Navigator.of(context).push(
    MaterialPageRoute<void>(builder: (_) => PracticePage(practice: practice)),
  );
}

void openResult(BuildContext context, Practice practice) {
  Navigator.of(context).push(
    MaterialPageRoute<void>(builder: (_) => ResultPage(practice: practice)),
  );
}

class PracticePage extends ConsumerStatefulWidget {
  const PracticePage({super.key, required this.practice});
  final Practice practice;

  @override
  ConsumerState<PracticePage> createState() => _PracticePageState();
}

class _PracticePageState extends ConsumerState<PracticePage>
    with WidgetsBindingObserver {
  Practice get practice => widget.practice;
  Answer get answer => practice.answers[practice.index];
  late final Speech _speech;
  late final Controller _controller;

  /// 网页端学生练习的状态上报器；手机端与测试里为 null
  PracticePresence? _presence;
  bool _busy = false;
  bool _playing = false;
  /// 默写整个词语，田字格逐字排列；[_focus] 记录最近落笔的格子。
  int _focus = 0;
  bool _showPinyin = true;

  bool get _anyInk => answer.cells.any((cell) => cell.isNotEmpty);

  void _undo() {
    var target = _focus.clamp(0, answer.cells.length - 1);
    if (answer.cells[target].isEmpty) {
      for (var i = answer.cells.length - 1; i >= 0; i--) {
        if (answer.cells[i].isNotEmpty) {
          target = i;
          break;
        }
      }
    }
    if (answer.cells[target].isEmpty) return;
    answer.cells[target].removeLast();
    _focus = target;
    _save();
  }

  void _clear() {
    for (final cell in answer.cells) {
      cell.clear();
    }
    _focus = 0;
    _save();
  }


  @override
  void initState() {
    super.initState();
    _speech = ref.read(speechProvider);
    _controller = ref.read(controllerProvider);
    _presence = ref.read(presenceProvider);
    // 已提交的练习只是回看，不需要上报「正在练习」
    if (!practice.submitted) _presence?.start(practice.id);
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed && !practice.submitted) {
      // 切后台/关标签页时绕过合并窗口，立即写出
      unawaited(_controller.persist().then((_) => _controller.flush()));
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _presence?.stop();
    unawaited(_speech.stop());
    // 这里不能 persist()：dispose 期间 notifyListeners 会触发
    // "Tried to modify a provider while the widget tree was building"。
    // 笔迹在每次落笔时已经 save 过，只需穿透合并窗口把待写内容写出。
    if (!practice.submitted) unawaited(_controller.flush());
    super.dispose();
  }

  void _save() {
    setState(() {});
    // persist 只把最新快照交给仓库并立即返回；flush 把等待它的 future
    // 正常结束掉，避免未处理的异步错误
    unawaited(_controller.persist().then((_) => _controller.flush()));
  }

  void _move(int index, {bool skip = false}) {
    if (_busy || _playing) return;
    unawaited(_speech.stop());
    if (skip) answer.skipped = true;
    practice.index = index;
    _save();
    // 换题立刻同步给家长端，不必等下一次心跳
    _presence?.flushNow();
  }

  Future<void> _play() async {
    final prompt = answer.question.prompt;
    setState(() => _playing = true);
    final played = await _speech.play(prompt.speech);
    if (!mounted) return;
    setState(() => _playing = false);
    if (played) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          hasMobileServices
              ? '普通话语音不可用。可在系统中准备语音，或请家长读题。'
              : '浏览器语音不可用。请确认系统已安装中文语音，或请家长读题。',
        ),
        action: SnackBarAction(
          label: '家长读题',
          onPressed: () {
            showDialog<void>(
              context: context,
              builder: (context) => AlertDialog(
                title: const Text('家长读题'),
                content: Text(prompt.speech),
                actions: [
                  TextButton(
                    onPressed: () => Navigator.pop(context),
                    child: const Text('收起'),
                  ),
                ],
              ),
            );
          },
        ),
      ),
    );
  }

  Future<void> _submit() async {
    if (_busy || _playing) return;
    final blanks = practice.answers.where((item) => item.untouched).length;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('提交整组听写？'),
        content: Text(
          blanks == 0
              ? '将批改全部 ${practice.answers.length} 题。'
              : '有 $blanks 题未写，提交后会标为空白。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('继续写'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('提交批改'),
          ),
        ],
      ),
    );
    if (!mounted || confirmed != true) return;
    setState(() => _busy = true);
    await _speech.stop();
    if (!mounted) return;
    try {
      // 先确保该组最后一笔已经落盘，再进入批改
      await _controller.flush();
      final grades = await ref.read(graderProvider).grade(practice.answers);
      if (!mounted) return;
      await _controller.submit(practice, grades);
      if (!mounted) return;
      // 告诉服务端「今天这一组完成了」：家长端立刻显示已完成，而不是等超时变离线
      _presence?.finish();
      setState(() => _busy = false);
      Navigator.of(context).pushReplacement(
        MaterialPageRoute<void>(builder: (_) => ResultPage(practice: practice)),
      );
    } catch (error) {
      if (!mounted) return;
      setState(() => _busy = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('批改失败：$error')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final last = practice.index == practice.answers.length - 1;
    final locked = _busy || _playing;
    return PopScope(
      canPop: !_busy,
      child: Scaffold(
        appBar: AppBar(title: Text(practice.daily ? '每日一练' : '重点复习')),
        body: SafeArea(
          // 练习页刻意不使用滚动容器：田字格按剩余高度自适应缩放，
          // 整页恰好铺满屏幕，书写时不会出现上下滑动。
          child: Stack(
            children: [
              Column(
                children: [
                  Expanded(
                    child: Center(
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 880),
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(20, 10, 20, 10),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          LinearProgressIndicator(
                            value:
                                (practice.index + 1) /
                                practice.answers.length,
                            borderRadius: BorderRadius.circular(10),
                          ),
                          const SizedBox(height: 10),
                          Row(
                            children: [
                              Expanded(
                                child: Text(
                                  '第 ${practice.index + 1} 题，共 ${practice.answers.length} 题',
                                  style: const TextStyle(
                                    fontSize: 22,
                                    fontWeight: FontWeight.w800,
                                    color: forest,
                                  ),
                                ),
                              ),
                              TextButton.icon(
                                onPressed: () => setState(
                                  () => _showPinyin = !_showPinyin,
                                ),
                                icon: Icon(
                                  _showPinyin
                                      ? Icons.visibility_off_outlined
                                      : Icons.visibility_outlined,
                                  size: 18,
                                ),
                                label: Text(_showPinyin ? '隐藏拼音' : '显示拼音'),
                              ),
                            ],
                          ),
                          const SizedBox(height: 2),
                          Text(
                            '${answer.question.review ? '复习词' : '新词'} · ${answer.question.lesson}'
                            ' · ${answer.question.prompt.phrase.length} 个字',
                            style: const TextStyle(
                              color: textMuted,
                              fontSize: 12,
                            ),
                          ),
                          const SizedBox(height: 8),
                          Wrap(
                            spacing: 8,
                            runSpacing: 6,
                            crossAxisAlignment: WrapCrossAlignment.center,
                            children: [
                              FilledButton.icon(
                                onPressed: locked ? null : _play,
                                icon: const Icon(Icons.volume_up_rounded),
                                label: const Text('播放题目'),
                              ),
                              const Text(
                                '先听例句，再听要写的词语，按顺序把每个字写进田字格。',
                                style: TextStyle(
                                  color: textMuted,
                                  fontSize: 12,
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 6),
                          Wrap(
                            spacing: 6,
                            runSpacing: 6,
                            children: [
                              for (
                                var i = 0;
                                i < practice.answers.length;
                                i++
                              )
                                ChoiceChip(
                                  label: Text('${i + 1}'),
                                  avatar:
                                      practice.answers[i].strokeCount > 0
                                      ? const Icon(
                                          Icons.edit_outlined,
                                          size: 14,
                                        )
                                      : practice.answers[i].skipped
                                      ? const Icon(Icons.redo, size: 14)
                                      : null,
                                  selected: i == practice.index,
                                  onSelected: locked ? null : (_) => _move(i),
                                ),
                            ],
                          ),
                          const SizedBox(height: 6),
                          Expanded(
                            child: LayoutBuilder(
                              builder: (context, box) {
                                // 听写只给空格子：笔顺引导属于「练习」功能。
                                // 词语逐字一个格子，宽屏并排、窄屏一起缩放。
                                final prompt = answer.question.prompt;
                                final letters = prompt.letters;
                                final syllables = prompt.syllables;
                                final count = math.max(1, letters.length);
                                const gap = 10.0;
                                final labelHeight = _showPinyin ? 26.0 : 0.0;
                                final fitWidth =
                                    (box.maxWidth - gap * (count - 1)) / count;
                                final side = math.max(
                                  48.0,
                                  math.min(
                                    200.0,
                                    math.min(
                                      fitWidth,
                                      box.maxHeight - labelHeight,
                                    ),
                                  ),
                                );
                                return Center(
                                  child: Row(
                                    mainAxisSize: MainAxisSize.min,
                                    mainAxisAlignment: MainAxisAlignment.center,
                                    children: [
                                      for (var i = 0; i < count; i++) ...[
                                        if (i > 0) const SizedBox(width: gap),
                                        Column(
                                          mainAxisSize: MainAxisSize.min,
                                          children: [
                                            SizedBox(
                                              height: labelHeight,
                                              child: Center(
                                                child: Text(
                                                  _showPinyin
                                                      ? syllables[i]
                                                      : '',
                                                  style: const TextStyle(
                                                    fontSize: 17,
                                                    fontWeight: FontWeight.w700,
                                                    color: forest,
                                                  ),
                                                ),
                                              ),
                                            ),
                                            InkBoard(
                                              key: ValueKey(
                                                '${practice.index}-$i',
                                              ),
                                              ink: answer.cells[i],
                                              enabled: !_busy,
                                              size: side,
                                              onStroke: (stroke) {
                                                answer.cells[i].add(stroke);
                                                answer.skipped = false;
                                                _focus = i;
                                                _presence?.stroke();
                                                _save();
                                              },
                                            ),
                                          ],
                                        ),
                                      ],
                                    ],
                                  ),
                                );
                              },
                            ),
                          ),
                          const SizedBox(height: 2),
                          Wrap(
                            alignment: WrapAlignment.center,
                            spacing: 8,
                            children: [
                              TextButton.icon(
                                onPressed: _busy || !_anyInk ? null : _undo,
                                icon: const Icon(Icons.undo),
                                label: const Text('撤销'),
                              ),
                              TextButton.icon(
                                onPressed: _busy || !_anyInk ? null : _clear,
                                icon: const Icon(Icons.delete_outline),
                                label: const Text('清空'),
                              ),

                            ],
                          ),
                          if (_busy)
                            const Center(
                              child: Padding(
                                padding: EdgeInsets.symmetric(vertical: 8),
                                child: Text('正在批改并保存笔迹…'),
                              ),
                            )
                          else
                            Wrap(
                              spacing: 10,
                              runSpacing: 8,
                              alignment: WrapAlignment.end,
                              children: [
                                if (practice.index > 0)
                                  OutlinedButton(
                                    onPressed: locked
                                        ? null
                                        : () => _move(practice.index - 1),
                                    child: const Text('上一题'),
                                  ),
                                if (!last)
                                  TextButton(
                                    onPressed: locked
                                        ? null
                                        : () => _move(
                                            practice.index + 1,
                                            skip: true,
                                          ),
                                    child: const Text('跳过'),
                                  ),
                                if (last)
                                  FilledButton(
                                    onPressed: locked ? null : _submit,
                                    child: const Text('提交批改'),
                                  )
                                else
                                  FilledButton(
                                    onPressed: locked
                                        ? null
                                        : () => _move(practice.index + 1),
                                    child: const Text('下一题'),
                                  ),
                              ],
                            ),
                        ],
                      ),
                    ),
                  ),
                ),
                  ),
                ],
              ),
              // 保存提示放在浮层，出现/消失都不会挤压田字格导致布局跳动
              const Positioned(
                left: 0,
                right: 0,
                top: 0,
                child: SaveNotice(),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class InkBoard extends StatefulWidget {
  const InkBoard({
    super.key,
    required this.ink,
    required this.size,
    this.enabled = true,
    this.onStroke,
  });

  final Ink ink;
  final double size;
  final bool enabled;
  final ValueChanged<List<InkPoint>>? onStroke;

  @override
  State<InkBoard> createState() => _InkBoardState();
}

class _InkBoardState extends State<InkBoard> {
  int? _pointer;
  List<InkPoint> _current = [];

  void _add(PointerEvent event) {
    if (_current.length >= 4096) return;
    final x = (event.localPosition.dx / widget.size).clamp(0.0, 1.0);
    final y = (event.localPosition.dy / widget.size).clamp(0.0, 1.0);
    final previous = _current.lastOrNull;
    if (previous?.x == x && previous?.y == y) return;
    final timestamp = DateTime.now().millisecondsSinceEpoch;
    _current.add(InkPoint(x, y, math.max(timestamp, previous?.time ?? 0)));
  }

  void _finish(PointerEvent event, {required bool addEnd}) {
    if (_pointer != event.pointer) return;
    if (addEnd) _add(event);
    final stroke = _current;
    setState(() {
      _pointer = null;
      _current = [];
    });
    if (stroke.isNotEmpty) widget.onStroke?.call(stroke);
  }

  @override
  Widget build(BuildContext context) => Semantics(
    label: widget.enabled ? '田字格手写区' : '提交的原笔迹',
    child: RawGestureDetector(
      // 指针一落下就抢占手势：父级 ListView 永远收不到拖动，
      // 否则写字时整页会跟着上下滑动。
      gestures: widget.enabled
          ? <Type, GestureRecognizerFactory>{
              _EagerPanGestureRecognizer:
                  GestureRecognizerFactoryWithHandlers<
                    _EagerPanGestureRecognizer
                  >(_EagerPanGestureRecognizer.new, (_) {}),
            }
          : const <Type, GestureRecognizerFactory>{},
      child: Listener(
        behavior: HitTestBehavior.opaque,
        onPointerDown: (event) {
          if (!widget.enabled ||
              widget.onStroke == null ||
              _pointer != null ||
              widget.ink.length >= 128) {
            return;
          }
          setState(() {
            _pointer = event.pointer;
            _add(event);
          });
        },
        onPointerMove: (event) {
          if (_pointer == event.pointer) setState(() => _add(event));
        },
        onPointerUp: (event) => _finish(event, addEnd: true),
        onPointerCancel: (event) => _finish(event, addEnd: false),
        child: CustomPaint(
          size: Size.square(widget.size),
          painter: _GridPainter([
            for (final stroke in widget.ink) List.of(stroke),
            List.of(_current),
          ]),
        ),
      ),
    ),
  );
}

/// 一接触就宣告胜利的手势识别器：用于独占田字格的拖动，
/// 避免外层可滚动列表把书写手势当成滚动。
class _EagerPanGestureRecognizer extends PanGestureRecognizer {
  @override
  void addAllowedPointer(PointerDownEvent event) {
    super.addAllowedPointer(event);
    resolve(GestureDisposition.accepted);
  }
}

class _GridPainter extends CustomPainter {
  const _GridPainter(this.strokes);
  final Ink strokes;

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;
    canvas.save();
    canvas.clipRect(rect);
    canvas.drawRect(rect, Paint()..color = const Color(0xFFFFFDF6));
    final guide = Paint()
      ..color = const Color(0xFFC6D2BF)
      ..strokeWidth = 1;
    final middle = size.width / 2;
    for (var position = 0.0; position < size.width; position += 14) {
      final end = math.min(position + 7, size.width);
      canvas.drawLine(Offset(position, middle), Offset(end, middle), guide);
      canvas.drawLine(Offset(middle, position), Offset(middle, end), guide);
    }
    canvas.drawRect(
      rect.deflate(1),
      Paint()
        ..color = const Color(0xFF829B82)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2,
    );
    final brush = Paint()
      ..color = forest
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round
      ..strokeWidth = math.max(2, size.width * 0.015)
      ..style = PaintingStyle.stroke;
    for (final stroke in strokes) {
      if (stroke.isEmpty) continue;
      final start = stroke.first;
      if (stroke.length == 1) {
        canvas.drawPoints(PointMode.points, [
          Offset(start.x * size.width, start.y * size.height),
        ], brush);
      } else {
        final path = Path()
          ..moveTo(start.x * size.width, start.y * size.height);
        for (final point in stroke.skip(1)) {
          path.lineTo(point.x * size.width, point.y * size.height);
        }
        canvas.drawPath(path, brush);
      }
    }
    canvas.restore();
  }

  @override
  bool shouldRepaint(_GridPainter oldDelegate) {
    if (oldDelegate.strokes.length != strokes.length) return true;
    for (var i = 0; i < strokes.length; i++) {
      final a = oldDelegate.strokes[i];
      final b = strokes[i];
      if (a.length != b.length) return true;
      if (a.isNotEmpty) {
        final pa = a.last;
        final pb = b.last;
        if (pa.x != pb.x || pa.y != pb.y) return true;
      }
    }
    return false;
  }
}

class ResultPage extends ConsumerWidget {
  const ResultPage({super.key, required this.practice});
  final Practice practice;

  Future<void> _correct(
    BuildContext context,
    Controller controller,
    Answer answer,
  ) async {
    final verdict = await showDialog<Verdict>(
      context: context,
      builder: (context) => SimpleDialog(
        title: const Text('家长订正'),
        children: [
          for (final verdict in Verdict.values)
            SimpleDialogOption(
              onPressed: () => Navigator.pop(context, verdict),
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 6),
                child: Text(verdict.label),
              ),
            ),
          if (answer.override != null)
            SimpleDialogOption(
              onPressed: () => Navigator.pop(context, answer.automatic),
              child: const Text('恢复自动批改'),
            ),
        ],
      ),
    );
    if (verdict == null) return;
    answer.override = verdict == answer.automatic ? null : verdict;
    await controller.persist();
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final controller = ref.watch(controllerProvider);
    return Scaffold(
      appBar: AppBar(title: const Text('批改结果')),
      body: SafeArea(
        child: Column(
          children: [
            const SaveNotice(),
            Expanded(
              child: PageBody(
                children: [
                  SectionTitle(
                    '本组练习完成',
                    '${practice.date} · ${practice.answers.length} 题',
                  ),
                  Panel(
                    color: sage,
                    child: Padding(
                      padding: const EdgeInsets.all(16),
                      child: Wrap(
                        spacing: 10,
                        runSpacing: 6,
                        children: [
                          for (final verdict in Verdict.values)
                            Chip(
                              label: Text(
                                '${verdict.label} ${practice.count(verdict)}',
                              ),
                            ),
                        ],
                      ),
                    ),
                  ),
                  if (practice.count(Verdict.pending) > 0)
                    const Padding(
                      padding: EdgeInsets.only(bottom: 14),
                      child: Text(
                        '田字框绿色表示识别正确，红色表示模型不确定，请家长核对后订正。',
                        style: TextStyle(color: textMuted),
                      ),
                    ),
                  for (final (index, answer) in practice.answers.indexed)
                    Panel(
                      child: Padding(
                        padding: const EdgeInsets.all(14),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Wrap(
                              spacing: 10,
                              runSpacing: 6,
                              crossAxisAlignment: WrapCrossAlignment.end,
                              children: [
                                for (
                                  var cell = 0;
                                  cell < answer.cells.length;
                                  cell++
                                )
                                  Column(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      Text(
                                        answer.question.prompt.syllables[cell],
                                        style: const TextStyle(
                                          fontSize: 12,
                                          color: textMuted,
                                        ),
                                      ),
                                      const SizedBox(height: 2),
                                      Container(
                                        decoration: BoxDecoration(
                                          borderRadius: BorderRadius.circular(
                                            6,
                                          ),
                                          border: Border.all(
                                            color: _frameColor(
                                              answer.cellVerdict(cell),
                                            ),
                                            width:
                                                answer.cellVerdict(cell) ==
                                                        Verdict.correct ||
                                                    answer.cellVerdict(cell) ==
                                                        Verdict.pending
                                                ? 2.5
                                                : 1,
                                          ),
                                        ),
                                        child: InkBoard(
                                          ink: answer.cells[cell],
                                          size: 74,
                                          enabled: false,
                                        ),
                                      ),
                                    ],
                                  ),
                              ],
                            ),
                            const SizedBox(height: 10),
                            Text(
                              '${index + 1}. ${answer.question.prompt.phrase}',
                              style: const TextStyle(
                                fontWeight: FontWeight.w800,
                                fontSize: 18,
                              ),
                            ),
                            Text(
                              answer.question.prompt.pinyinText,
                              style: const TextStyle(
                                color: textMuted,
                                fontSize: 13,
                              ),
                            ),
                            if (answer.question.prompt.sentence case final s?)
                              Text(
                                '例句：$s',
                                style: const TextStyle(
                                  color: textMuted,
                                  fontSize: 13,
                                ),
                              ),
                            Text(
                              '${answer.verdict?.label ?? '待确认'}${answer.override == null ? '' : ' · 家长订正'}',
                            ),
                            Wrap(
                              spacing: 10,
                              runSpacing: 2,
                              children: [
                                for (
                                  var cell = 0;
                                  cell < answer.cells.length;
                                  cell++
                                )
                                  if (answer.cellCandidate(cell).isNotEmpty)
                                    Text(
                                      '第 ${cell + 1} 字 ${answer.cellCandidate(cell).first}',
                                      style: TextStyle(
                                        fontWeight: FontWeight.w700,
                                        color: _frameColor(
                                          answer.cellVerdict(cell),
                                        ),
                                      ),
                                    ),
                              ],
                            ),
                            Wrap(
                              children: [
                                TextButton(
                                  onPressed: () =>
                                      _correct(context, controller, answer),
                                  child: const Text('家长订正'),
                                ),
                                if (!answer.untouched)
                                  TextButton(
                                    onPressed: () => showDialog<void>(
                                      context: context,
                                      builder: (context) => Dialog(
                                        child: Padding(
                                          padding: const EdgeInsets.all(14),
                                          child: SingleChildScrollView(
                                            child: Row(
                                              mainAxisSize: MainAxisSize.min,
                                              children: [
                                                for (
                                                  var cell = 0;
                                                  cell < answer.cells.length;
                                                  cell++
                                                ) ...[
                                                  if (cell > 0)
                                                    const SizedBox(width: 8),
                                                  InkBoard(
                                                    ink: answer.cells[cell],
                                                    enabled: false,
                                                    size: math.min(
                                                      200,
                                                      math.max(
                                                        90,
                                                        (MediaQuery.sizeOf(
                                                                      context,
                                                                        )
                                                                    .width -
                                                                120) /
                                                            answer.cells.length,
                                                      ),
                                                    ),
                                                  ),
                                                ],
                                              ],
                                            ),
                                          ),
                                        ),
                                      ),
                                    ),
                                    child: const Text('放大笔迹'),
                                  ),
                              ],
                            ),
                          ],
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

import 'package:material_ui/material_ui.dart';

import 'main.dart';
import 'math_question.dart';
import 'practice.dart' show verdictOk, verdictWarn;

/// 数学步骤练习的最小页面：只负责步骤展示、槽位输入和逐格判定。
///
/// 刻意不接动画、不做存储、不联网。目的是先确认交互节奏，
/// 动画渲染器和题库接入都建立在同一份步骤数据之上。
class MathStepPage extends StatefulWidget {
  const MathStepPage({super.key, required this.question});

  final MathQuestion question;

  @override
  State<MathStepPage> createState() => _MathStepPageState();
}

class _MathStepPageState extends State<MathStepPage> {
  late final TextEditingController _field;

  // 编辑中的格子文本。只保存当前这一格，切格时写回 _values。
  String _draft = '';

  /// 已填写的内容，键为「步骤序号/槽位 id」
  final Map<String, String> _values = {};

  int _step = 0;
  int _focus = 0;
  Map<String, SlotVerdict> _verdicts = {};
  bool _checked = false;
  bool _guided = false;

  MathQuestion get question => widget.question;
  MathStep get step => question.steps[_step];
  bool get _isLast => _step == question.steps.length - 1;

  @override
  void initState() {
    super.initState();
    _field = TextEditingController();
    _initializeStep();
  }

  @override
  void dispose() {
    _field.dispose();
    super.dispose();
  }

  String _valueOf(MathStep target, String slotId) {
    final index = identical(target, step) ? _step : question.steps.indexOf(target);
    return _values['$index/$slotId'] ?? '';
  }

  /// 进位、借位这类标记格默认排第一，但不是每道题都要求填，
  /// 因此把焦点放在第一个必填格上。
  void _initializeStep() {
    final slots = step.slots;
    _focus = slots.indexWhere((slot) => !slot.optional);
    if (_focus < 0) _focus = 0;
    _draft = _valueOf(step, slots[_focus].id);
    _field.value = TextEditingValue(
      text: _draft,
      selection: TextSelection.collapsed(offset: _draft.length),
    );
  }

  void _commit() {
    _values['$_step/${step.slots[_focus].id}'] = _field.text;
    _draft = _field.text;
  }

  /// 切到指定格子，把当前编辑内容先写回。
  void _selectSlot(int index) {
    _commit();
    _focus = index;
    _draft = _valueOf(step, step.slots[index].id);
    _field.value = TextEditingValue(
      text: _draft,
      selection: TextSelection.collapsed(offset: _draft.length),
    );
  }

  Map<String, SlotVerdict> _collect() => {
    for (final slot in step.slots) slot.id: judgeSlot(slot, _valueOf(step, slot.id)),
  };

  void _check() {
    _commit();
    final verdicts = _collect();
    final failed = step.slots
        .where((slot) => verdicts[slot.id] != SlotVerdict.correct)
        .toList();
    setState(() {
      _verdicts = verdicts;
      _checked = true;
    });
    // 聚焦第一个出错的格子，孩子不用自己找哪里错了。
    // 必须在 setState 之外切换，否则刚写回的文本会被这次切格覆盖。
    if (failed.isNotEmpty) {
      setState(() => _selectSlot(step.slots.indexOf(failed.first)));
    } else if (!_isLast) {
      _scheduleAdvance();
    }
  }

  void _scheduleAdvance() {
    final hold = step.hold;
    final from = _step;
    Future<void>.delayed(Duration(milliseconds: hold), () {
      // 期间可能已经手动跳过或切了格子，只在本步仍处于「已通过」时推进
      if (mounted && _step == from && _checked) _next();
    });
  }

  void _next() {
    if (_isLast) return;
    _commit();
    setState(() {
      _step++;
      _checked = false;
      _verdicts = {};
      _initializeStep();
    });
  }

  void _type(String chunk) {
    final slot = step.slots[_focus];
    final next = '${_field.text}$chunk';
    if (next.length > slot.width) return;
    _setDraft(next);
  }

  void _backspace() {
    final text = _field.text;
    if (text.isEmpty) return;
    _setDraft(text.substring(0, text.length - 1));
  }

  void _clear() {
    if (_field.text.isEmpty) return;
    _setDraft('');
  }

  void _setDraft(String text) {
    _field.value = TextEditingValue(
      text: text,
      selection: TextSelection.collapsed(offset: text.length),
    );
    setState(() {
      _commit();
      if (_checked) {
        _checked = false;
        _verdicts = {};
      }
    });
  }

  void _selectSlotByTap(int index) {
    if (index == _focus) return;
    setState(() {
      _selectSlot(index);
      _checked = false;
      _verdicts = {};
    });
  }

  Color _slotFrame(String slotId, bool focused) {
    if (!_checked) {
      return focused ? forest : const Color(0xFFCBD6C6);
    }
    return switch (_verdicts[slotId]) {
      SlotVerdict.correct => verdictOk,
      SlotVerdict.wrong || SlotVerdict.blank => verdictWarn,
      null => focused ? forest : const Color(0xFFCBD6C6),
    };
  }

  @override
  Widget build(BuildContext context) {
    final failed = step.slots
        .where((slot) => _verdicts[slot.id] != SlotVerdict.correct)
        .toList();
    final passed = _checked && failed.isEmpty;
    return Scaffold(
      appBar: AppBar(
        title: const Text('数学 · 分步练习'),
        actions: [
          if (!_guided)
            TextButton(
              onPressed: () => setState(() => _guided = true),
              child: const Text('看讲解'),
            )
          else
            const Padding(
              padding: EdgeInsets.only(right: 12),
              child: Center(
                child: Text('讲解模式', style: TextStyle(color: textMuted)),
              ),
            ),
        ],
      ),
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 720),
            child: ListView(
              padding: const EdgeInsets.fromLTRB(20, 12, 20, 24),
              children: [
                LinearProgressIndicator(
                  value: (_step + 1) / question.steps.length,
                  borderRadius: BorderRadius.circular(10),
                ),
                const SizedBox(height: 14),
                Text(
                  question.stem.text,
                  style: const TextStyle(
                    fontSize: 34,
                    fontWeight: FontWeight.w800,
                    color: forest,
                    letterSpacing: 1,
                  ),
                ),
                Text(
                  '${question.skill} · 第 ${_step + 1} / ${question.steps.length} 步',
                  style: const TextStyle(color: textMuted, fontSize: 12),
                ),
                const SizedBox(height: 16),
                Panel(
                  color: sage,
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Icon(Icons.lightbulb_outline, color: forest),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Text(
                            step.hint,
                            style: const TextStyle(
                              color: forest,
                              height: 1.5,
                              fontSize: 15,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                for (final slot in step.slots) _slotRow(slot),
                if (_checked)
                  Padding(
                    padding: const EdgeInsets.only(top: 6),
                    child: Text(
                      passed
                          ? (_isLast ? '全部填对了，这道题完成。' : '这一步对了，继续下一步。')
                          : '标红的格子还不对，可以重新填。',
                      style: TextStyle(
                        color: passed ? verdictOk : verdictWarn,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                const SizedBox(height: 12),
                _Keypad(
                  onTap: _type,
                  onBackspace: _backspace,
                  onClear: _clear,
                  onCheck: _check,
                  checkLabel: _isLast ? '完成' : '确认这一步',
                ),
                const SizedBox(height: 10),
                if (!_isLast)
                  Align(
                    alignment: Alignment.centerLeft,
                    child: TextButton(
                      onPressed: _next,
                      child: const Text('跳过这一步'),
                    ),
                  ),
                if (_isLast)
                  Padding(
                    padding: const EdgeInsets.only(top: 4),
                    child: Text(
                      _guided ? '本组记录会标记为「引导后完成」。' : '本组记录为「独立完成」。',
                      style: const TextStyle(color: textMuted, fontSize: 12),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _slotRow(MathSlot slot) {
    final index = step.slots.indexOf(slot);
    final focused = _focus == index;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        children: [
          SizedBox(
            width: 110,
            child: Text(
              slot.label,
              style: const TextStyle(
                fontWeight: FontWeight.w700,
                color: forest,
              ),
            ),
          ),
          GestureDetector(
            onTap: () => _selectSlotByTap(index),
            child: Container(
              constraints: BoxConstraints(minWidth: 26.0 * slot.width + 28),
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(10),
                border: Border.all(
                  color: _slotFrame(slot.id, focused),
                  width: focused || _checked ? 2.4 : 1.4,
                ),
              ),
              child: Text(
                _valueOf(step, slot.id).isEmpty ? '　' : _valueOf(step, slot.id),
                style: const TextStyle(
                  fontSize: 24,
                  fontWeight: FontWeight.w800,
                  color: forest,
                  letterSpacing: 2,
                ),
              ),
            ),
          ),
          if (slot.optional)
            const Padding(
              padding: EdgeInsets.only(left: 8),
              child: Text('可留空', style: TextStyle(color: textMuted, fontSize: 11)),
            ),
        ],
      ),
    );
  }
}

/// 独立数字键盘：槽位输入是结构化的小数据，键入选比手写更快也更可靠。
class _Keypad extends StatelessWidget {
  const _Keypad({
    required this.onTap,
    required this.onBackspace,
    required this.onClear,
    required this.onCheck,
    required this.checkLabel,
  });

  final ValueChanged<String> onTap;
  final VoidCallback onBackspace;
  final VoidCallback onClear;
  final VoidCallback onCheck;
  final String checkLabel;

  @override
  Widget build(BuildContext context) {
    Widget key(String text, {VoidCallback? onPressed, Widget? child}) =>
        SizedBox(
          width: 64,
          height: 52,
          child: OutlinedButton(
            onPressed: onPressed ?? () => onTap(text),
            style: OutlinedButton.styleFrom(
              padding: EdgeInsets.zero,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(12),
              ),
            ),
            child: child ??
                Text(
                  text,
                  style: const TextStyle(
                    fontSize: 22,
                    fontWeight: FontWeight.w700,
                    color: forest,
                  ),
                ),
          ),
        );

    return Center(
      child: Wrap(
        spacing: 8,
        runSpacing: 8,
        alignment: WrapAlignment.center,
        children: [
          for (var digit = 1; digit <= 9; digit++) key('$digit'),
          key('', onPressed: onClear, child: const Text('清空', style: TextStyle(fontSize: 13))),
          key('0'),
          key(
            '',
            onPressed: onBackspace,
            child: const Icon(Icons.backspace_outlined, size: 20),
          ),
          SizedBox(
            width: 132,
            height: 52,
            child: FilledButton(
              onPressed: onCheck,
              child: Text(checkLabel),
            ),
          ),
        ],
      ),
    );
  }
}

import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';

import 'math_question.dart';
import 'math_step.dart';
import 'theme.dart';

/// 数学题库的加载入口。第一版只读打包进去的样例题，
/// 等步骤交互稳定后再接数学题库资源和学科切换。
Future<MathLibrary> loadSampleMathLibrary() async {
  final raw = await rootBundle.loadString(
    'assets/samples/math_schema_samples.json',
  );
  return MathLibrary.fromJson(jsonDecode(raw));
}

/// 数学预览列表：先按题目逐条列出，点进去是分步练习。
class MathListPage extends StatefulWidget {
  const MathListPage({super.key});

  @override
  State<MathListPage> createState() => _MathListPageState();
}

class _MathListPageState extends State<MathListPage> {
  MathLibrary? _library;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final library = await loadSampleMathLibrary();
      if (mounted) setState(() => _library = library);
    } on FormatException catch (error) {
      if (mounted) setState(() => _error = '题库格式错误：${error.message}');
    } on Exception {
      if (mounted) setState(() => _error = '题库加载失败。');
    }
  }

  @override
  Widget build(BuildContext context) {
    final library = _library;
    return Scaffold(
      appBar: AppBar(title: const Text('数学 · 分步练习')),
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 880),
            child: switch ((library, _error)) {
              (_, final String error) => Center(
                child: Padding(
                  padding: const EdgeInsets.all(24),
                  child: Text(error),
                ),
              ),
              (null, _) => const Center(child: CircularProgressIndicator()),
              (final MathLibrary loaded, _) => ListView(
                padding: const EdgeInsets.fromLTRB(20, 14, 20, 24),
                children: [
                  SectionTitle(loaded.title, loaded.source),
                  if (loaded.sample)
                    const Padding(
                      padding: EdgeInsets.only(bottom: 12),
                      child: Text(
                        '示例题库，仅用于验证分步交互。',
                        style: TextStyle(color: textMuted, fontSize: 12),
                      ),
                    ),
                  for (final question in loaded.questions)
                    Panel(
                      child: ListTile(
                        leading: CircleAvatar(
                          backgroundColor: sage,
                          foregroundColor: forest,
                          child: Text('${question.difficulty}'),
                        ),
                        title: Text(
                          question.stem.text,
                          style: const TextStyle(
                            fontSize: 20,
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                        subtitle: Text(
                          '${question.skill} · ${question.steps.length} 步',
                        ),
                        trailing: const Icon(Icons.chevron_right),
                        onTap: () => Navigator.of(context).push(
                          MaterialPageRoute<void>(
                            builder: (_) =>
                                MathStepPage(question: question),
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            },
          ),
        ),
      ),
    );
  }
}

import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import 'controller.dart';
import 'domain.dart';
import 'main.dart';
import 'web_bridge_stub.dart'
    if (dart.library.js_interop) 'web_bridge.dart'
    as bridge;

class SettingsPage extends ConsumerStatefulWidget {
  const SettingsPage({super.key});

  @override
  ConsumerState<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends ConsumerState<SettingsPage> {
  bool _busy = false;

  void _message(String text) {
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));
    }
  }

  Future<void> _run(Future<void> Function() action) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await action();
    } on FormatException catch (error) {
      _message('文件格式错误：${error.message}');
    } on TypeError {
      _message('文件字段类型错误。');
    } on Exception {
      _message('操作未完成，请重试。');
    } on StateError {
      _message('请先完成当前听写。');
    } on ArgumentError {
      _message('文件字段取值错误。');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<Object?> _readJson(int maxBytes) async {
    final (name, size, text) = await bridge.pickTextFile('application/json');
    if (name == null) return null;
    if (size > maxBytes) throw const FormatException('文件过大');
    return jsonDecode(text);
  }

  Future<void> _importLibrary(Controller controller) => _run(() async {
    final raw = await _readJson(2 * 1024 * 1024);
    if (!mounted || raw == null) return;
    final library = Library.fromJson(raw);
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('更换字库？'),
        content: Text(
          '${library.title} · ${library.lessons.length} 课\n${library.source}'
          '\n\n新练习将使用此字库。已提交练习保留。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('导入'),
          ),
        ],
      ),
    );
    if (ok == true && mounted) {
      final saved = await controller.replaceLibrary(library);
      _message(saved ? '字库已导入。' : '字库已载入，保存待重试。');
    }
  });

  Future<void> _restore(Controller controller) => _run(() async {
    final raw = await _readJson(64 * 1024 * 1024);
    if (!mounted || raw == null) return;
    final journal = Journal.fromJson(raw);
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('从备份恢复？'),
        content: Text(
          '将用备份中的字库、${journal.history.length} 组练习及草稿替换当前记录。'
          '如需保留当前记录，请先导出备份。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('替换并恢复'),
          ),
        ],
      ),
    );
    if (ok == true && mounted) {
      final saved = await controller.restore(journal);
      _message(saved ? '备份已恢复。' : '备份已载入，保存待重试。');
    }
  });

  Future<void> _export(Controller controller) => _run(() async {
    final filename = '每日听写-${controller.today}.json';
    final bytes = Uint8List.fromList(utf8.encode(jsonEncode(controller.data)));
    bridge.downloadBytes(filename, 'application/json', bytes);
  });

  String _startLabel(Journal journal) {
    final start = journal.start;
    if (start == null) return '默认（按册次从后往前，从第一课开始）';
    final lesson = journal.library.lessons
        .where((lesson) => lesson.key == start)
        .firstOrNull;
    return lesson == null ? start : '${lesson.label} · ${lesson.title}';
  }

  Future<void> _pickStart(Controller controller) async {
    final journal = controller.data;
    final grouped = <String, List<Lesson>>{};
    for (final lesson in journal.library.lessons) {
      (grouped[lesson.volume] ??= <Lesson>[]).add(lesson);
    }
    final chosen = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('选择已学起点'),
        content: SizedBox(
          width: 420,
          height: 420,
          child: ListView(
            children: [
              ListTile(
                title: const Text('默认（从第一课开始）'),
                subtitle: const Text('按册次从后往前推进'),
                onTap: () => Navigator.pop(context, ''),
              ),
              for (final entry in grouped.entries) ...[
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 14, 16, 4),
                  child: Text(
                    volumes[entry.key] ?? entry.key,
                    style: const TextStyle(
                      fontWeight: FontWeight.w800,
                      color: textMuted,
                      fontSize: 13,
                    ),
                  ),
                ),
                for (final lesson in entry.value)
                  ListTile(
                    dense: true,
                    title: Text('${lesson.label} · ${lesson.title}'),
                    onTap: () => Navigator.pop(context, lesson.key),
                  ),
              ],
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('取消'),
          ),
        ],
      ),
    );
    if (chosen == null) return;
    journal.start = chosen.isEmpty ? null : chosen;
    await controller.persist();
  }

  @override
  Widget build(BuildContext context) {
    final controller = ref.watch(controllerProvider);
    final journal = controller.data;
    final hasDraft = journal.draft != null;
    // 独立路由页面必须有 Scaffold：ListTile 内部的 Ink 需要 Material 祖先，
    // 之前嵌在 Dashboard 的 Scaffold 里没问题，拆成单独页面后就会空指针。
    return Scaffold(
      appBar: AppBar(title: const Text('练习设置')),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 720),
          child: ListView(
            padding: const EdgeInsets.fromLTRB(20, 14, 20, 24),
            children: [
        const SectionTitle('练习设置', '教材、语音识别和本地资料'),
        Panel(
          child: Column(
            children: [
              ListTile(
                leading: const Icon(Icons.menu_book_outlined, color: forest),
                title: Text(journal.library.title),
                subtitle: Text(
                  '${journal.library.sample ? '示例数据 · ' : ''}${journal.library.source}',
                ),
              ),
              const Divider(height: 1),
              ListTile(
                enabled: !hasDraft && !_busy,
                leading: const Icon(Icons.flag_outlined),
                title: const Text('已学起点'),
                subtitle: Text(
                  _startLabel(journal),
                  overflow: TextOverflow.ellipsis,
                ),
                trailing: const Icon(Icons.chevron_right),
                onTap: hasDraft || _busy
                    ? null
                    : () => _pickStart(controller),
              ),
              ListTile(
                enabled: !hasDraft && !_busy,
                leading: const Icon(Icons.file_open_outlined),
                title: const Text('导入字库'),
                subtitle: const Text('选择含册次、课程、汉字和读题词语的 JSON 文件'),
                onTap: hasDraft || _busy
                    ? null
                    : () => _importLibrary(controller),
              ),
            ],
          ),
        ),
        Panel(
          child: Column(
            children: [
              ListTile(
                leading: const Icon(Icons.gesture_rounded, color: forest),
                title: const Text('手写识别'),
                subtitle: const Text('网页版由服务器识别，无需在浏览器下载模型'),
              ),
              const Divider(height: 1),
              ListTile(
                leading: const Icon(Icons.record_voice_over_outlined),
                title: const Text('试播普通话'),
                subtitle: const Text('使用浏览器语音，需系统已安装中文语音。'),
                onTap: _busy
                    ? null
                    : () => _run(() async {
                        final played = await ref
                            .read(speechProvider)
                            .play('每日听写。请写观察的第一个字。');
                        _message(played ? '正在播放。' : '浏览器语音暂不可用。');
                      }),
              ),
            ],
          ),
        ),
        Panel(
          child: Column(
            children: [
              ListTile(
                leading: const Icon(Icons.download_rounded, color: forest),
                title: const Text('导出备份'),
                subtitle: const Text('导出字库、练习、草稿和原笔迹'),
                onTap: _busy ? null : () => _export(controller),
              ),
              const Divider(height: 1),
              ListTile(
                leading: const Icon(Icons.restore),
                title: const Text('恢复备份'),
                subtitle: const Text('确认后替换本机记录'),
                onTap: _busy ? null : () => _restore(controller),
              ),
            ],
          ),
        ),
        if (_busy)
          const Center(
            child: Padding(
              padding: EdgeInsets.all(12),
              child: CircularProgressIndicator(),
            ),
          ),
            ],
          ),
        ),
      ),
    );
  }
}

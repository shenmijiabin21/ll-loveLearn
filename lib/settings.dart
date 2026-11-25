import 'dart:convert';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';
import 'package:share_plus/share_plus.dart';

import 'controller.dart';
import 'web_bridge_stub.dart'
    if (dart.library.js_interop) 'web_bridge.dart'
    as bridge;
import 'device.dart';
import 'domain.dart';
import 'main.dart';

class SettingsPage extends ConsumerStatefulWidget {
  const SettingsPage({super.key});

  @override
  ConsumerState<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends ConsumerState<SettingsPage> {
  bool _busy = false;
  bool? _ready;

  @override
  void initState() {
    super.initState();
    _checkModel();
  }

  Future<void> _checkModel() async {
    try {
      final ready = await ref.read(inkProvider).ready();
      if (mounted) setState(() => _ready = ready);
    } on Exception {
      if (mounted) setState(() => _ready = false);
    }
  }

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
    const types = [
      XTypeGroup(
        label: 'JSON',
        extensions: ['json'],
        mimeTypes: ['application/json'],
        uniformTypeIdentifiers: ['public.json'],
      ),
    ];
    final file = await openFile(acceptedTypeGroups: types);
    if (file == null) return null;
    if (await file.length() > maxBytes) throw const FormatException('文件过大');
    return jsonDecode(await file.readAsString());
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

  Future<void> _export(BuildContext anchor, Controller controller) =>
      _run(() async {
        final filename = '每日听写-${controller.today}.json';
        final bytes =
            Uint8List.fromList(utf8.encode(jsonEncode(controller.data)));
        if (kIsWeb) {
          bridge.downloadBytes(filename, 'application/json', bytes);
          return;
        }
        final box = anchor.findRenderObject()! as RenderBox;
        await SharePlus.instance.share(
          ShareParams(
            files: [XFile.fromData(bytes, mimeType: 'application/json')],
            fileNameOverrides: [filename],
            sharePositionOrigin: box.localToGlobal(Offset.zero) & box.size,
          ),
        );
      });

  @override
  Widget build(BuildContext context) {
    final controller = ref.watch(controllerProvider);
    final journal = controller.data;
    final hasDraft = journal.draft != null;
    return PageBody(
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
              Padding(
                padding: const EdgeInsets.all(16),
                child: DropdownButtonFormField<String>(
                  key: ValueKey((journal.library.edition, journal.start)),
                  initialValue: journal.start ?? '',
                  isExpanded: true,
                  decoration: InputDecoration(
                    labelText: '已学起点',
                    helperText: hasDraft ? '完成当前练习后可调整' : '从选定课向前练习，保留已练进度',
                    border: const OutlineInputBorder(),
                  ),
                  items: [
                    const DropdownMenuItem(
                      value: '',
                      child: Text('默认从三上最后一课开始'),
                    ),
                    for (final lesson in journal.library.lessons)
                      DropdownMenuItem(
                        value: lesson.key,
                        child: Text(
                          '${lesson.label} · ${lesson.title}',
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                  ],
                  onChanged: hasDraft || _busy
                      ? null
                      : (value) {
                          journal.start = value == '' ? null : value;
                          controller.persist();
                        },
                ),
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
                title: const Text('简体中文手写模型'),
                subtitle: Text(
                  !hasMobileServices
                      ? '自动识字功能在 iPhone、iPad 或 Android 上使用'
                      : _ready == true
                      ? '模型已就绪，可离线识别'
                      : _ready == null
                      ? '正在检查模型…'
                      : '首次需联网下载，随后可离线识别',
                ),
                trailing: hasMobileServices && _ready != true
                    ? TextButton(
                        onPressed: _busy || _ready == null
                            ? null
                            : () => _run(() async {
                                final downloaded = await ref
                                    .read(inkProvider)
                                    .download();
                                if (!mounted) return;
                                await _checkModel();
                                _message(
                                  downloaded ? '手写模型已下载。' : '下载未完成，请检查网络后重试。',
                                );
                              }),
                        child: const Text('下载'),
                      )
                    : null,
              ),
              const Divider(height: 1),
              ListTile(
                leading: const Icon(Icons.record_voice_over_outlined),
                title: const Text('试播普通话'),
                subtitle: const Text('使用系统语音。请提前准备普通话离线语音。'),
                onTap: _busy
                    ? null
                    : () => _run(() async {
                        final played = await ref
                            .read(speechProvider)
                            .play('每日听写。请写观察的第一个字。');
                        _message(played ? '正在播放。' : '系统普通话语音暂不可用。');
                      }),
              ),
            ],
          ),
        ),
        Panel(
          child: Column(
            children: [
              Builder(
                builder: (anchor) => ListTile(
                  leading: const Icon(Icons.ios_share, color: forest),
                  title: const Text('导出备份'),
                  subtitle: const Text('导出字库、练习、草稿和原笔迹'),
                  onTap: _busy ? null : () => _export(anchor, controller),
                ),
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
    );
  }
}

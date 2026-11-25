import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import 'controller.dart';
import 'domain.dart';
import 'practice.dart';
import 'settings.dart';
import 'web_app.dart';
import 'web_bridge_stub.dart'
    if (dart.library.js_interop) 'web_bridge.dart'
    as bridge;

const paper = Color(0xFFF8F5EC);
const forest = Color(0xFF193D32);
const sage = Color(0xFFE4ECDD);
const textMuted = Color(0xFF526358);

void main() {
  // 网页端禁用浏览器层滚动/下拉刷新，避免手写时整页跟着滑动
  if (kIsWeb) {
    bridge.lockPageScroll();
    bridge.warmUpSpeech();
  }
  runApp(const ProviderScope(child: DictationApp()));
}

ThemeData buildTheme() => ThemeData(
      useMaterial3: true,
      colorScheme: ColorScheme.fromSeed(
        seedColor: forest,
        primary: forest,
        surface: paper,
      ),
      scaffoldBackgroundColor: paper,
      appBarTheme: const AppBarTheme(
        backgroundColor: paper,
        foregroundColor: forest,
      ),
      navigationBarTheme: const NavigationBarThemeData(
        backgroundColor: paper,
        indicatorColor: sage,
      ),
      navigationRailTheme: const NavigationRailThemeData(
        backgroundColor: paper,
        indicatorColor: sage,
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          minimumSize: const Size(48, 48),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(14),
          ),
        ),
      ),
    );

Widget appShell(Widget home) => MaterialApp(
      title: '每日听写',
      debugShowCheckedModeBanner: false,
      locale: const Locale('zh', 'CN'),
      supportedLocales: const [Locale('zh', 'CN')],
      localizationsDelegates: GlobalMaterialLocalizations.delegates,
      theme: buildTheme(),
      home: home,
    );

final startup = FutureProvider<Controller>((ref) async {
  final store = await ref.watch(openJournal.future);
  return Controller.load(store);
});

class DictationApp extends ConsumerWidget {
  const DictationApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (kIsWeb) return const WebApp();
    final boot = ref.watch(startup);
    final app = appShell(
      boot.when(
        data: (_) => const Dashboard(),
        loading: () =>
            const Scaffold(body: Center(child: CircularProgressIndicator())),
        error: (error, _) => Scaffold(
          body: Center(
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Text('无法打开本地练习记录。'),
                  const SizedBox(height: 12),
                  FilledButton(
                    onPressed: () {
                      ref.invalidate(openJournal);
                      ref.invalidate(startup);
                    },
                    child: const Text('重试'),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
    final controller = boot.asData?.value;
    return controller == null
        ? app
        : ProviderScope(
            overrides: [controllerProvider.overrideWith((ref) => controller)],
            child: app,
          );
  }
}

class Dashboard extends ConsumerStatefulWidget {
  const Dashboard({super.key});

  @override
  ConsumerState<Dashboard> createState() => _DashboardState();
}

class _DashboardState extends ConsumerState<Dashboard> {
  int _section = 0;
  late final Timer _clock;

  @override
  void initState() {
    super.initState();
    _clock = Timer.periodic(const Duration(minutes: 1), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _clock.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    const destinations = [
      (Icons.edit_note_rounded, '今日'),
      (Icons.bookmark_outline_rounded, '重点'),
      (Icons.bar_chart_rounded, '统计'),
      (Icons.tune_rounded, '设置'),
    ];
    final content = switch (_section) {
      0 => const TodayPage(),
      1 => const FocusPage(),
      2 => const StatsPage(),
      _ => const SettingsPage(),
    };
    final wide = MediaQuery.sizeOf(context).width >= 760;
    return Scaffold(
      appBar: AppBar(
        title: const Row(
          children: [
            Icon(Icons.draw_rounded, size: 23),
            SizedBox(width: 10),
            Text(
              '每日听写',
              style: TextStyle(fontWeight: FontWeight.w800, fontSize: 21),
            ),
          ],
        ),
        actions: [
          if (kIsWeb) ...[
            IconButton(
              icon: const Icon(Icons.people_outline),
              tooltip: '切换孩子',
              onPressed: () => ref.read(webSessionProvider).backToChildren(),
            ),
            IconButton(
              icon: const Icon(Icons.logout),
              tooltip: '退出登录',
              onPressed: () => ref.read(webSessionProvider).signOut(),
            ),
          ],
        ],
      ),
      body: SafeArea(
        top: false,
        bottom: wide,
        child: Row(
          children: [
            if (wide) ...[
              NavigationRail(
                selectedIndex: _section,
                onDestinationSelected: (index) =>
                    setState(() => _section = index),
                labelType: NavigationRailLabelType.all,
                destinations: [
                  for (final (icon, label) in destinations)
                    NavigationRailDestination(
                      icon: Icon(icon),
                      label: Text(label),
                    ),
                ],
              ),
              const VerticalDivider(width: 1),
            ],
            Expanded(
              child: Column(
                children: [
                  const SaveNotice(),
                  Expanded(child: content),
                ],
              ),
            ),
          ],
        ),
      ),
      bottomNavigationBar: wide
          ? null
          : NavigationBar(
              selectedIndex: _section,
              onDestinationSelected: (index) =>
                  setState(() => _section = index),
              destinations: [
                for (final (icon, label) in destinations)
                  NavigationDestination(icon: Icon(icon), label: label),
              ],
            ),
    );
  }
}

class SaveNotice extends ConsumerWidget {
  const SaveNotice({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final controller = ref.watch(controllerProvider);
    if (!controller.saveFailed) return const SizedBox.shrink();
    return Material(
      color: Theme.of(context).colorScheme.errorContainer,
      child: ListTile(
        title: const Text('本次修改尚未保存'),
        trailing: TextButton(
          onPressed: controller.persist,
          child: const Text('重试'),
        ),
      ),
    );
  }
}

class PageBody extends StatelessWidget {
  const PageBody({super.key, required this.children});
  final List<Widget> children;

  @override
  Widget build(BuildContext context) => Center(
    child: ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 880),
      child: Align(
        alignment: Alignment.topCenter,
        child: ListView(
          padding: const EdgeInsets.fromLTRB(20, 14, 20, 24),
          children: children,
        ),
      ),
    ),
  );
}

class SectionTitle extends StatelessWidget {
  const SectionTitle(this.title, this.subtitle, {super.key});
  final String title;
  final String subtitle;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: 18),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          title,
          style: const TextStyle(
            fontSize: 30,
            fontWeight: FontWeight.w800,
            color: forest,
          ),
        ),
        const SizedBox(height: 5),
        Text(subtitle, style: const TextStyle(color: textMuted, height: 1.45)),
      ],
    ),
  );
}

class Panel extends StatelessWidget {
  const Panel({super.key, required this.child, this.color = Colors.white});
  final Widget child;
  final Color color;

  @override
  Widget build(BuildContext context) => Container(
    margin: const EdgeInsets.only(bottom: 12),
    clipBehavior: Clip.antiAlias,
    decoration: BoxDecoration(
      color: color,
      borderRadius: BorderRadius.circular(20),
      border: Border.all(color: const Color(0xFFDCE3D7)),
    ),
    child: child,
  );
}

class TodayPage extends ConsumerWidget {
  const TodayPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final controller = ref.watch(controllerProvider);
    final data = controller.data;
    final draft = data.draft;
    final completed = data.completedOn(controller.today);
    final questions = data.dailyQuestions(controller.today);
    final count = questions.where((question) => !question.review).length;
    final date = DateTime.now();
    return PageBody(
      children: [
        SectionTitle('今日听写', '${date.month} 月 ${date.day} 日 · 听词语，在田字格写字'),
        Panel(
          color: forest,
          child: Stack(
            children: [
              const Positioned(
                right: 12,
                top: 12,
                child: ExcludeSemantics(
                  child: Icon(
                    Icons.grid_on_rounded,
                    size: 95,
                    color: Color(0xFF426657),
                  ),
                ),
              ),
              Padding(
                padding: const EdgeInsets.all(22),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      draft != null
                          ? '继续练习'
                          : completed != null
                          ? '今日已完成'
                          : '每日一练',
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 26,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      draft != null
                          ? '第 ${draft.index + 1} / ${draft.answers.length} 题 · 继续上次的笔迹'
                          : completed != null
                          ? '${completed.answers.length} 题 · ${completed.count(Verdict.correct)} 题正确'
                          : questions.isEmpty
                          ? '今天没有新字或到期的复习字。'
                          : '$count 个新字 · ${questions.length - count} 个复习字',
                      style: const TextStyle(color: Color(0xFFECF2E9)),
                    ),
                    const SizedBox(height: 20),
                    if (draft != null || questions.isNotEmpty)
                      FilledButton.icon(
                        style: FilledButton.styleFrom(
                          backgroundColor: paper,
                          foregroundColor: forest,
                        ),
                        onPressed: () {
                          final practice = controller.begin();
                          if (practice != null) openPractice(context, practice);
                        },
                        icon: const Icon(Icons.play_arrow_rounded),
                        label: Text(draft == null ? '开始听写' : '继续听写'),
                      )
                    else if (completed != null)
                      FilledButton(
                        style: FilledButton.styleFrom(
                          backgroundColor: paper,
                          foregroundColor: forest,
                        ),
                        onPressed: () => openResult(context, completed),
                        child: const Text('查看批改'),
                      ),
                  ],
                ),
              ),
            ],
          ),
        ),
        Panel(
          child: ListTile(
            leading: const Icon(Icons.menu_book_outlined, color: forest),
            title: Text(data.library.title),
            subtitle: Text(
              data.library.sample
                  ? '示例字库 · 设置中可导入已核验字库'
                  : '按三上、二下、二上顺序，各册从后往前练习',
            ),
          ),
        ),
        if (completed != null && draft != null)
          TextButton(
            onPressed: () => openResult(context, completed),
            child: const Text('查看今日批改'),
          ),
      ],
    );
  }
}

class FocusPage extends ConsumerWidget {
  const FocusPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final controller = ref.watch(controllerProvider);
    final focus = controller.data.focus;
    final draft = controller.data.draft;
    return PageBody(
      children: [
        SectionTitle('重点复习', '汇总错字、空白和待确认字 · ${focus.length} 个待巩固'),
        if (focus.isEmpty)
          const Panel(
            child: ListTile(
              leading: Icon(Icons.eco_outlined),
              title: Text('目前没有待复习字。'),
            ),
          )
        else ...[
          Align(
            alignment: Alignment.centerLeft,
            child: FilledButton.icon(
              onPressed: () {
                final practice = controller.begin(daily: false);
                if (practice != null) openPractice(context, practice);
              },
              icon: const Icon(Icons.edit_outlined),
              label: Text(draft == null ? '复习重点字' : '继续当前练习'),
            ),
          ),
          const SizedBox(height: 16),
          for (final entry in focus)
            Panel(
              child: ListTile(
                leading: CircleAvatar(
                  backgroundColor: sage,
                  foregroundColor: forest,
                  child: Text(
                    entry.question.prompt.character,
                    style: const TextStyle(fontSize: 22),
                  ),
                ),
                title: Text(entry.question.prompt.phrase),
                subtitle: Text(
                  '${entry.pending ? '待确认 · ' : ''}错字或空白 ${entry.errors} 次 · 已巩固 ${entry.streak}/3',
                ),
                trailing: Text(
                  entry.due.compareTo(controller.today) <= 0
                      ? '已到期'
                      : entry.due,
                ),
              ),
            ),
        ],
      ],
    );
  }
}

class StatsPage extends ConsumerWidget {
  const StatsPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final controller = ref.watch(controllerProvider);
    final history = controller.data.history;
    final days = history.map((practice) => practice.date).toSet().length;
    final answers = history.expand((practice) => practice.answers).toList();
    final correct = answers
        .where((answer) => answer.verdict == Verdict.correct)
        .length;
    final pending = answers
        .where((answer) => answer.verdict == Verdict.pending)
        .length;
    final graded = answers.length - pending;
    return PageBody(
      children: [
        const SectionTitle('练习记录', '查看已提交练习和家长订正后的结果'),
        Panel(
          color: sage,
          child: Padding(
            padding: const EdgeInsets.all(18),
            child: Wrap(
              spacing: 30,
              runSpacing: 14,
              children: [
                _Metric('$days', '练习天数'),
                _Metric('${answers.length}', '累计题数'),
                _Metric(
                  graded == 0 ? '—' : '${(100 * correct / graded).round()}%',
                  '已确认正确率',
                ),
                _Metric('$pending', '待确认'),
              ],
            ),
          ),
        ),
        if (history.isEmpty)
          const Panel(child: ListTile(title: Text('提交第一次练习后，记录会显示在这里。')))
        else
          for (final practice in history.reversed)
            Panel(
              child: ListTile(
                leading: const Icon(Icons.history_rounded, color: forest),
                title: Text(
                  '${practice.date} · ${practice.daily ? '每日听写' : '重点复习'}',
                ),
                subtitle: Text(
                  '正确 ${practice.count(Verdict.correct)} / ${practice.answers.length} · 待确认 ${practice.count(Verdict.pending)}',
                ),
                trailing: const Icon(Icons.chevron_right),
                onTap: () => openResult(context, practice),
              ),
            ),
      ],
    );
  }
}

class _Metric extends StatelessWidget {
  const _Metric(this.value, this.label);
  final String value;
  final String label;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Text(
        value,
        style: const TextStyle(
          fontSize: 25,
          fontWeight: FontWeight.w800,
          color: forest,
        ),
      ),
      Text(label, style: const TextStyle(color: textMuted)),
    ],
  );
}

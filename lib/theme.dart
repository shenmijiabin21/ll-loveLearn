import 'package:material_ui/material_ui.dart';

// 主题与通用版式组件。
//
// 单独成文件是为了让不依赖练习流程的页面（例如数学分步练习）
// 也能使用同一套配色与版式，而不必 import main.dart —— main.dart 会经由
// practice.dart 引入 remote.dart 等业务模块，测试里没必要背上这些依赖。

const paper = Color(0xFFF8F5EC);
const forest = Color(0xFF193D32);
const sage = Color(0xFFE4ECDD);
const textMuted = Color(0xFF526358);

// 批改结果配色：正确=绿，待确认=红，其余保持中性
const verdictOk = Color(0xFF2E7D32);
const verdictWarn = Color(0xFFC62828);
const verdictNeutral = Color(0xFFDCE3D7);

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
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
    ),
  ),
);

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

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/legacy.dart';
import 'package:material_ui/material_ui.dart';

import 'controller.dart';
import 'domain.dart';
import 'main.dart';
import 'practice.dart';
import 'remote.dart';
import 'settings.dart';

final webSessionProvider = ChangeNotifierProvider<WebSession>((ref) {
  return WebSession();
});

/// 登录后的界面状态
enum WebScreen { login, admin, parentList, parentDetail, practice }

/// 在线状态的判重签名：只有它变了，家长页才需要重绘。
///
/// 必须覆盖界面真正显示的每个字段，否则会出现「接口变了、界面不重绘」。
/// 用 activeSeconds 而不是 onlineSeconds——后者是「距上次心跳多少秒」，
/// 每次心跳都归零，既不反映练习时长，也不能用来判重。
String presenceSignature(Map<String, ChildPresence> presences) => [
  for (final entry in presences.entries)
    '${entry.key}:${entry.value.state}:${entry.value.activeSeconds}'
        ':${entry.value.awayCount}:${entry.value.awaySeconds}',
].join('|');

class WebSession extends ChangeNotifier {
  ApiClient? _api;
  UserInfo? me;
  WebScreen screen = WebScreen.login;

  List<ChildInfo> children = [];
  List<ParentInfo> parents = [];
  Map<String, ChildSummary> summaries = {};
  /// 孩子的实时在线状态，按 child_id 索引；由服务端推导，客户端只展示
  Map<String, ChildPresence> presences = {};

  ChildInfo? activeChild;
  ChildSummary? activeSummary;
  Controller? controller;

  bool busy = false;
  /// 5 秒轮询的防重入标记：网络慢于 5 秒时不要叠加请求
  bool _presenceInFlight = false;
  String? error;

  ApiClient? get api => _api;
  bool get loggedIn => _api != null;
  bool get isAdmin => me?.isAdmin ?? false;
  bool get isParent => me?.isParent ?? false;
  bool get isStudent => me?.isStudent ?? false;

  WebSession() {
    final token = readStoredToken();
    if (token == null || token.isEmpty) return;
    _api = ApiClient(token: token);
    Future(() async {
      try {
        me = await _api!.me();
        await _routeAfterLogin();
        notifyListeners();
      } on Exception {
        _api = null;
        me = null;
        clearToken();
        notifyListeners();
      }
    });
  }

  Future<void> _guarded(Future<void> Function() action) async {
    if (busy) return;
    busy = true;
    error = null;
    notifyListeners();
    try {
      await action();
    } on Exception catch (e) {
      error = _friendly(e);
    } finally {
      busy = false;
      notifyListeners();
    }
  }

  static String _friendly(Object e) =>
      e is ApiException ? e.message : '操作失败：$e';

  /// 登录后按角色分流：学生直接进练习，家长进汇总，管理员进账号管理
  Future<void> _routeAfterLogin() async {
    final user = me;
    if (user == null) return;
    if (user.isAdmin) {
      parents = await _api!.listParents();
      screen = WebScreen.admin;
      return;
    }
    children = await _api!.listChildren();
    if (user.isStudent) {
      if (children.isNotEmpty) {
        await _enterChild(children.first, practice: true);
      } else {
        screen = WebScreen.parentList; // 无档案时给个可见的提示页
      }
      return;
    }
    await _loadSummaries();
    screen = WebScreen.parentList;
  }

  Future<void> _loadSummaries() async {
    // 并发拉取：孩子较多时不再串行等待 N 个 RTT
    final results = await Future.wait([
      for (final child in children)
        _api!
            .childSummary(child.id)
            .then<ChildSummary?>((value) => value)
            .catchError((Object _) => null),
    ]);
    summaries = {
      for (final (index, summary) in results.indexed)
        children[index].id: ?summary,
    };
    await _loadPresences();
  }

  /// 在线状态单独一次请求取全，失败不影响汇总展示
  Future<void> _loadPresences() async {
    try {
      presences = await _api!.listPresence();
    } on Exception {
      // 保留上一次的在线状态，避免网络抖动时整片闪成「不在页面」
    }
  }

  Future<void> _enterChild(ChildInfo child, {required bool practice}) async {
    activeChild = child;
    controller = await Controller.load(RemoteJournalStore(_api!, child.id));
    try {
      activeSummary = await _api!.childSummary(child.id);
    } on Exception {
      activeSummary = null;
    }
    screen = practice ? WebScreen.practice : WebScreen.parentDetail;
  }

  Future<void> login(String account, String password) => _guarded(() async {
    final result = await ApiClient().login(account, password);
    _api = ApiClient(token: result.token);
    me = result.user;
    persistToken(result.token);
    await _routeAfterLogin();
  });

  /// 家长查看某个学生的详情
  Future<void> openChild(ChildInfo child) => _guarded(() async {
    await _enterChild(child, practice: false);
  });

  /// 家长让学生重练
  Future<void> resetChild(String childId, String scope) => _guarded(() async {
    // 带上本机日期：服务器时区可能与本机差一天，否则会清错日子
    await _api!.resetChild(
      childId,
      scope: scope,
      date: day(DateTime.now()),
    );
    if (activeChild?.id == childId) {
      controller = await Controller.load(RemoteJournalStore(_api!, childId));
      try {
        activeSummary = await _api!.childSummary(childId);
      } on Exception {
        activeSummary = null;
      }
    }
    await _loadSummaries();
  });

  Future<void> backToList() => _guarded(() async {
    activeChild = null;
    activeSummary = null;
    controller = null;
    await _loadSummaries();
    screen = isStudent ? WebScreen.login : WebScreen.parentList;
  });

  /// 只刷新汇总，不动当前打开的孩子（列表页「刷新」按钮用）
  Future<void> refreshSummaries() => _guarded(_loadSummaries);

  /// 列表页定时刷新在线状态。不走 _guarded：静默刷新不该闪忙碌指示，
  /// 也不该在失败时覆盖用户正在看的错误提示。
  ///
  /// busy 期间跳过是必要的（避免与重练等操作抢同一份数据），但下一次
  /// 定时器会自然重试，所以最多晚 5 秒，不会漏掉状态更新。
  Future<void> refreshPresence() async {
    // 上一次还没回来就跳过这一拍：5 秒间隔下，网络抖动时请求会越堆越多
    if (_api == null || busy || _presenceInFlight) return;
    _presenceInFlight = true;
    try {
      // 只有状态或时长真的变了才重建，避免无意义的重绘
      final before = presenceSignature(presences);
      await _loadPresences();
      if (before != presenceSignature(presences)) notifyListeners();
    } finally {
      _presenceInFlight = false;
    }
  }

  // —— 管理员操作 ——
  Future<void> refreshParents() => _guarded(() async {
    parents = await _api!.listParents();
  });

  /// 给已有孩子档案补绑学生账号，保留历史记录
  Future<bool> bindStudent({
    required String childId,
    required String username,
    required String password,
    required String displayName,
  }) async {
    var ok = false;
    await _guarded(() async {
      await _api!.bindStudent(
        childId: childId,
        username: username,
        password: password,
        displayName: displayName,
      );
      parents = await _api!.listParents();
      ok = true;
    });
    return ok;
  }

  /// 给已有的家长账号新建一条孩子练习档案（暂不绑定学生登录）
  Future<bool> addChild({
    required String parentId,
    required String name,
  }) async {
    var ok = false;
    await _guarded(() async {
      await _api!.createChild(parentId, name);
      parents = await _api!.listParents();
      ok = true;
    });
    return ok;
  }

  /// 修改当前账号密码：其它设备上的旧令牌会立即失效
  Future<bool> changePassword(String current, String next) async {
    var ok = false;
    await _guarded(() async {
      final result = await _api!.changePassword(current, next);
      _api = ApiClient(token: result.token);
      persistToken(result.token);
      ok = true;
    });
    return ok;
  }

  Future<void> createParent(String username, String password, String name) =>
      _guarded(() async {
        await _api!.createParent(username, password, name);
        parents = await _api!.listParents();
      });

  Future<void> createStudent({
    required String parentId,
    required String username,
    required String password,
    required String studentName,
    required String childName,
  }) => _guarded(() async {
    await _api!.createStudent(
      parentId: parentId,
      username: username,
      password: password,
      studentName: studentName,
      childName: childName,
    );
    parents = await _api!.listParents();
  });

  void signOut() {
    // 尽力让服务端作废令牌；离线或后端不可用时也不阻塞本地退出
    final api = _api;
    if (api != null) {
      unawaited(
        api.post('/auth/logout', const <String, Object>{}).catchError((_) {}),
      );
    }
    _api = null;
    me = null;
    children = [];
    parents = [];
    summaries = {};
    activeChild = null;
    activeSummary = null;
    controller = null;
    error = null;
    screen = WebScreen.login;
    clearToken();
    notifyListeners();
  }
}

/// 把会话错误以 SnackBar 显示一次，避免挤在页面顶部被忽略
class SessionErrorListener extends ConsumerStatefulWidget {
  const SessionErrorListener({super.key, required this.child});
  final Widget child;

  @override
  ConsumerState<SessionErrorListener> createState() =>
      _SessionErrorListenerState();
}

class _SessionErrorListenerState extends ConsumerState<SessionErrorListener> {
  String? _shown;

  @override
  Widget build(BuildContext context) {
    ref.listen<WebSession>(webSessionProvider, (previous, next) {
      final error = next.error;
      if (error == null || error == _shown) return;
      _shown = error;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        ScaffoldMessenger.of(context)
          ..hideCurrentSnackBar()
          ..showSnackBar(SnackBar(content: Text(error)));
      });
    });
    return widget.child;
  }
}

/// 修改当前登录账号的密码（网页端学生/家长/管理员通用）
Future<void> showChangePasswordDialog(BuildContext context, WidgetRef ref) async {
  final current = TextEditingController();
  final next = TextEditingController();
  final confirm = TextEditingController();
  final ok = await showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      title: const Text('修改密码'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: current,
              decoration: const InputDecoration(labelText: '当前密码'),
              obscureText: true,
            ),
            TextField(
              controller: next,
              decoration: const InputDecoration(labelText: '新密码（至少 8 位）'),
              obscureText: true,
            ),
            TextField(
              controller: confirm,
              decoration: const InputDecoration(labelText: '再次输入新密码'),
              obscureText: true,
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context, false),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(context, true),
          child: const Text('保存'),
        ),
      ],
    ),
  );
  if (ok != true) return;
  if (!context.mounted) return;
  final messenger = ScaffoldMessenger.of(context);
  if (next.text.length < 8) {
    messenger.showSnackBar(const SnackBar(content: Text('新密码至少 8 位')));
    return;
  }
  if (next.text != confirm.text) {
    messenger.showSnackBar(const SnackBar(content: Text('两次输入的新密码不一致')));
    return;
  }
  final changed = await ref
      .read(webSessionProvider)
      .changePassword(current.text, next.text);
  if (!changed) return;
  messenger.showSnackBar(
    const SnackBar(content: Text('密码已更新，其它设备需要重新登录')),
  );
}

class WebApp extends ConsumerWidget {
  const WebApp({super.key});

  /// 用 MaterialApp.builder 包住导航器：这样 SnackBar 才能挂到页面的
  /// ScaffoldMessenger 上（包在 MaterialApp 外面会找不到祖先）
  Widget _wrap(Widget home) => appShell(
        home,
        builder: (context, child) =>
            SessionErrorListener(child: child ?? const SizedBox.shrink()),
      );

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final session = ref.watch(webSessionProvider);

    if (session.screen == WebScreen.practice && session.controller != null) {
      return ProviderScope(
        // 用 controller 身份做 key：家长重练后 controller 会换成新实例，
        // 强制重建作用域，否则界面仍显示重置前的历史。
        key: ObjectKey(session.controller),
        overrides: [
          controllerProvider.overrideWith((ref) => session.controller!),
          apiClientProvider.overrideWithValue(session.api!),
          graderProvider.overrideWith((ref) => WebGrader(session.api!)),
        ],
        // 学生端不显示「设置」：字库/进度等练习设置由家长端负责
        child: _wrap(const Dashboard(showSettings: false)),
      );
    }
    if (session.screen == WebScreen.parentDetail &&
        session.controller != null) {
      return ProviderScope(
        key: ObjectKey(session.controller),
        overrides: [
          controllerProvider.overrideWith((ref) => session.controller!),
          apiClientProvider.overrideWithValue(session.api!),
        ],
        child: _wrap(const ParentDetailScreen()),
      );
    }
    return _wrap(switch (session.screen) {
      WebScreen.admin => const AdminScreen(),
      WebScreen.parentList => const ParentScreen(),
      WebScreen.parentDetail => const ParentScreen(),
      WebScreen.practice => const ParentScreen(),
      WebScreen.login => const AuthScreen(),
    });
  }
}

class AuthScreen extends ConsumerStatefulWidget {
  const AuthScreen({super.key});

  @override
  ConsumerState<AuthScreen> createState() => _AuthScreenState();
}

class _AuthScreenState extends ConsumerState<AuthScreen> {
  final _account = TextEditingController();
  final _password = TextEditingController();

  @override
  void dispose() {
    _account.dispose();
    _password.dispose();
    super.dispose();
  }

  void _submit() {
    final account = _account.text.trim();
    final password = _password.text;
    if (account.isEmpty || password.isEmpty) return;
    ref.read(webSessionProvider).login(account, password);
  }

  @override
  Widget build(BuildContext context) {
    final session = ref.watch(webSessionProvider);
    return Scaffold(
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 400),
          child: ListView(
            shrinkWrap: true,
            padding: const EdgeInsets.all(24),
            children: [
              const Icon(Icons.draw_rounded, size: 48, color: forest),
              const SizedBox(height: 12),
              const Text(
                '每日听写',
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 28,
                  fontWeight: FontWeight.w800,
                  color: forest,
                ),
              ),
              const SizedBox(height: 4),
              const Text(
                '登录',
                textAlign: TextAlign.center,
                style: TextStyle(color: textMuted),
              ),
              const SizedBox(height: 24),
              TextField(
                controller: _account,
                decoration: const InputDecoration(
                  labelText: '账号',
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _password,
                decoration: const InputDecoration(
                  labelText: '密码',
                  border: OutlineInputBorder(),
                ),
                obscureText: true,
                onSubmitted: (_) => _submit(),
              ),
              const SizedBox(height: 12),
              // 登录失败由 SessionErrorListener 用 SnackBar 提示
              FilledButton(
                onPressed: session.busy ? null : _submit,
                child: Text(session.busy ? '请稍候…' : '登录'),
              ),
              const SizedBox(height: 8),
              const Text(
                '账号由管理员创建。学生登录后直接进入练习。',
                textAlign: TextAlign.center,
                style: TextStyle(color: textMuted, fontSize: 12),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 家长首页：学生列表 + 汇总概览
class ParentScreen extends ConsumerStatefulWidget {
  const ParentScreen({super.key});

  @override
  ConsumerState<ParentScreen> createState() => _ParentScreenState();
}

class _ParentScreenState extends ConsumerState<ParentScreen> {
  Timer? _poll;

  @override
  void initState() {
    super.initState();
    // 5 秒刷新一次：孩子端每 30 秒上报一次心跳，但家长看到的是「已练 N 分钟」，
    // 刷新太慢会让数字长时间不动，看起来像卡住了。5 秒足够灵敏，
    // 单次请求只是一个孩子一行的小 JSON，开销可以忽略。
    _poll = Timer.periodic(const Duration(seconds: 5), (_) {
      if (mounted) ref.read(webSessionProvider).refreshPresence();
    });
  }

  @override
  void dispose() {
    _poll?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final session = ref.watch(webSessionProvider);
    return Scaffold(
      appBar: AppBar(
        title: const Text('孩子的练习情况'),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            tooltip: '刷新',
            onPressed: session.busy ? null : () => session.refreshSummaries(),
          ),
          IconButton(
            icon: const Icon(Icons.logout),
            tooltip: '退出登录',
            onPressed: session.busy ? null : session.signOut,
          ),
        ],
      ),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 640),
          child: ListView(
            padding: const EdgeInsets.all(20),
            children: [
              if (session.busy)
                const Center(
                  child: Padding(
                    padding: EdgeInsets.all(16),
                    child: CircularProgressIndicator(),
                  ),
                ),
              if (session.children.isEmpty && !session.busy)
                const Padding(
                  padding: EdgeInsets.all(24),
                  child: Text(
                    '暂未关联学生，请联系管理员添加。',
                    textAlign: TextAlign.center,
                    style: TextStyle(color: textMuted),
                  ),
                ),
              for (final child in session.children)
                _ChildCard(
                  child: child,
                  summary: session.summaries[child.id],
                  presence: session.presences[child.id],
                  onOpen: () => session.openChild(child),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ChildCard extends StatelessWidget {
  const _ChildCard({
    required this.child,
    required this.summary,
    required this.onOpen,
    this.presence,
  });

  final ChildInfo child;
  final ChildSummary? summary;
  final ChildPresence? presence;
  final VoidCallback onOpen;

  @override
  Widget build(BuildContext context) {
    final s = summary;
    final accuracy = s?.accuracy;
    final p = presence;
    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      child: InkWell(
        onTap: onOpen,
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  const CircleAvatar(child: Icon(Icons.child_care)),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          child.name,
                          style: const TextStyle(
                            fontSize: 18,
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                        Text(
                          child.studentUsername == null
                              ? '未绑定学生账号'
                              : '学生账号 ${child.studentUsername}',
                          style: const TextStyle(color: textMuted, fontSize: 12),
                        ),
                      ],
                    ),
                  ),
                  const Icon(Icons.chevron_right),
                ],
              ),
              if (p != null) ...[
                const SizedBox(height: 10),
                _PresenceChip(presence: p),
              ],
              const SizedBox(height: 12),
              Wrap(
                spacing: 22,
                runSpacing: 8,
                children: [
                  _Metric('${s?.practiceDays ?? 0}', '练习天数'),
                  _Metric('${s?.totalQuestions ?? 0}', '累计题数'),
                  _Metric(accuracy == null ? '—' : '$accuracy%', '正确率'),
                  _Metric('${s?.pending ?? 0}', '待确认'),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 家长端一句话在线状态。状态本身来自服务端推导，这里只负责呈现。
class _PresenceChip extends StatelessWidget {
  const _PresenceChip({required this.presence});

  final ChildPresence presence;

  @override
  Widget build(BuildContext context) {
    final (color, icon) = switch (presence.state) {
      'practicing' => (verdictOk, Icons.edit_rounded),
      'idle' => (const Color(0xFFB26A00), Icons.hourglass_bottom_rounded),
      'away' => (const Color(0xFF8A6D3B), Icons.exit_to_app_rounded),
      _ => (textMuted, Icons.cloud_off_rounded),
    };
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 15, color: color),
        const SizedBox(width: 6),
        Text(
          presence.label,
          style: TextStyle(color: color, fontSize: 13, fontWeight: FontWeight.w600),
        ),
        if (presence.awayCount > 0) ...[
          const SizedBox(width: 10),
          Text(
            '今天离开 ${presence.awayCount} 次',
            style: const TextStyle(color: textMuted, fontSize: 12),
          ),
        ],
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
          fontSize: 20,
          fontWeight: FontWeight.w800,
          color: forest,
        ),
      ),
      Text(label, style: const TextStyle(color: textMuted, fontSize: 12)),
    ],
  );
}

/// 家长查看单个学生：汇总 + 历史记录 + 重练
class ParentDetailScreen extends ConsumerWidget {
  const ParentDetailScreen({super.key});

  Future<void> _confirmReset(
    BuildContext context,
    WidgetRef ref,
    String childId,
    String scope,
  ) async {
    final label = scope == 'today' ? '今天的练习' : '全部练习记录';
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('让学生重练？'),
        content: Text('将清除该学生的$label，之后可以重新开始。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('确定清除'),
          ),
        ],
      ),
    );
    if (ok == true) {
      await ref.read(webSessionProvider).resetChild(childId, scope);
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final session = ref.watch(webSessionProvider);
    final controller = ref.watch(controllerProvider);
    final summary = session.activeSummary;
    final child = session.activeChild;
    final history = controller.data.history;
    final accuracy = summary?.accuracy;
    return Scaffold(
      appBar: AppBar(
        title: Text(child == null ? '练习情况' : '${child.name} 的练习情况'),
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          onPressed: () => session.backToList(),
        ),
      ),
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 720),
            child: ListView(
              padding: const EdgeInsets.all(20),
              children: [
                if (summary != null)
                  Panel(
                    color: sage,
                    child: Padding(
                      padding: const EdgeInsets.all(16),
                      child: Wrap(
                        spacing: 28,
                        runSpacing: 12,
                        children: [
                          _Metric('${summary.practiceDays}', '练习天数'),
                          _Metric('${summary.totalQuestions}', '累计题数'),
                          _Metric(
                            accuracy == null ? '—' : '$accuracy%',
                            '正确率',
                          ),
                          _Metric('${summary.correct}', '正确'),
                          _Metric('${summary.pending}', '待确认'),
                        ],
                      ),
                    ),
                  ),
                const SizedBox(height: 6),
                Wrap(
                  spacing: 10,
                  runSpacing: 8,
                  children: [
                    FilledButton.icon(
                      onPressed: session.busy || child == null
                          ? null
                          : () => _confirmReset(
                              context,
                              ref,
                              child.id,
                              'today',
                            ),
                      icon: const Icon(Icons.restart_alt),
                      label: const Text('重练今天'),
                    ),
                    OutlinedButton.icon(
                      onPressed: session.busy || child == null
                          ? null
                          : () => _confirmReset(
                              context,
                              ref,
                              child.id,
                              'all',
                            ),
                      icon: const Icon(Icons.delete_sweep_outlined),
                      label: const Text('清空全部'),
                    ),
                    // 练习设置（字库、已学起点、导入/备份）由家长负责，
                    // 学生端不提供入口。
                    OutlinedButton.icon(
                      onPressed: child == null
                          ? null
                          : () => Navigator.of(context).push(
                              MaterialPageRoute<void>(
                                builder: (_) => const SettingsPage(),
                              ),
                            ),
                      icon: const Icon(Icons.tune_rounded),
                      label: const Text('练习设置'),
                    ),
                  ],
                ),
                const SizedBox(height: 14),
                const SectionTitle('历史记录', '点开可查看原笔迹与批改结果'),
                if (history.isEmpty)
                  const Panel(
                    child: ListTile(title: Text('还没有提交过练习。')),
                  )
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
            ),
          ),
        ),
      ),
    );
  }
}

/// 管理员：建家长、建学生账号
class AdminScreen extends ConsumerStatefulWidget {
  const AdminScreen({super.key});

  @override
  ConsumerState<AdminScreen> createState() => _AdminScreenState();
}

class _AdminScreenState extends ConsumerState<AdminScreen> {
  final _username = TextEditingController();
  final _password = TextEditingController();
  final _name = TextEditingController();

  @override
  void dispose() {
    _username.dispose();
    _password.dispose();
    _name.dispose();
    super.dispose();
  }

  void _createParent() {
    final username = _username.text.trim();
    final password = _password.text;
    final name = _name.text.trim();
    if (!RegExp(r'^[a-zA-Z0-9]+$').hasMatch(username)) {
      _toast('账号只能包含英文和数字');
      return;
    }
    if (password.length < 8) {
      _toast('密码至少 8 位');
      return;
    }
    // 提交成功后清空；失败时保留输入，避免用户重填
    ref.read(webSessionProvider).createParent(username, password, name).then((
      _,
    ) {
      if (!mounted) return;
      final session = ref.read(webSessionProvider);
      if (session.error != null) return;
      _username.clear();
      _password.clear();
      _name.clear();
    });
  }

  void _toast(String text) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));
  }

  /// 给已有档案（可能已有练习记录）补绑学生账号
  Future<void> _bindStudent(ParentInfo parent, ChildInfo child) async {
    final username = TextEditingController();
    final password = TextEditingController();
    final display = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('为「${child.name}」开通学生登录'),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text(
                '该档案已有的练习记录会保留。',
                style: TextStyle(color: textMuted, fontSize: 12),
              ),
              TextField(
                controller: username,
                decoration: const InputDecoration(labelText: '学生账号（英文数字）'),
              ),
              TextField(
                controller: password,
                decoration: const InputDecoration(labelText: '密码（至少 8 位）'),
                obscureText: true,
              ),
              TextField(
                controller: display,
                decoration: InputDecoration(labelText: '学生姓名（默认「${child.name}」）'),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('绑定'),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    final account = username.text.trim();
    if (!RegExp(r'^[a-zA-Z0-9]+$').hasMatch(account)) {
      _toast('学生账号只能包含英文和数字');
      return;
    }
    if (password.text.length < 8) {
      _toast('密码至少 8 位');
      return;
    }
    final bound = await ref.read(webSessionProvider).bindStudent(
          childId: child.id,
          username: account,
          password: password.text,
          displayName: display.text.trim().isEmpty
              ? child.name
              : display.text.trim(),
        );
    if (!mounted) return;
    final session = ref.read(webSessionProvider);
    if (bound) {
      _toast('已为该档案绑定学生账号 ${child.name}');
    } else {
      _toast(session.error ?? '绑定失败');
    }
  }

  /// 先建孩子档案，之后再单独开通学生登录
  Future<void> _addChild(ParentInfo parent) async {
    final name = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('为 ${parent.name.isEmpty ? parent.username : parent.name} 新建练习档案'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: name,
              decoration: const InputDecoration(labelText: '练习档案名'),
            ),
            const Padding(
              padding: EdgeInsets.only(top: 8),
              child: Text(
                '先建档案、后开学生登录也可以：之后点该档案旁的「开通学生登录」即可。',
                style: TextStyle(color: textMuted, fontSize: 12),
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('创建'),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    final childName = name.text.trim();
    if (childName.isEmpty) {
      _toast('请填写练习档案名');
      return;
    }
    final added = await ref
        .read(webSessionProvider)
        .addChild(parentId: parent.id, name: childName);
    if (!mounted) return;
    final session = ref.read(webSessionProvider);
    _toast(added ? '已创建练习档案' : (session.error ?? '创建失败'));
  }

  Future<void> _addStudent(ParentInfo parent) async {
    final username = TextEditingController();
    final password = TextEditingController();
    final studentName = TextEditingController();
    final childName = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('为 ${parent.name.isEmpty ? parent.username : parent.name} 添加学生'),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: username,
                decoration: const InputDecoration(
                  labelText: '学生账号（英文数字）',
                ),
              ),
              TextField(
                controller: password,
                decoration: const InputDecoration(labelText: '密码（至少 8 位）'),
                obscureText: true,
              ),
              TextField(
                controller: studentName,
                decoration: const InputDecoration(labelText: '学生姓名'),
              ),
              TextField(
                controller: childName,
                decoration: const InputDecoration(labelText: '练习档案名（可同姓名）'),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('创建'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    if (!RegExp(r'^[a-zA-Z0-9]+$').hasMatch(username.text.trim())) {
      _toast('学生账号只能包含英文和数字');
      return;
    }
    if (password.text.length < 8) {
      _toast('密码至少 8 位');
      return;
    }
    if (childName.text.trim().isEmpty) {
      _toast('请填写练习档案名');
      return;
    }
    await ref.read(webSessionProvider).createStudent(
          parentId: parent.id,
          username: username.text.trim(),
          password: password.text,
          studentName: studentName.text.trim(),
          childName: childName.text.trim(),
        );
  }

  @override
  Widget build(BuildContext context) {
    final session = ref.watch(webSessionProvider);
    return Scaffold(
      appBar: AppBar(
        title: const Text('管理员 · 账号管理'),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            tooltip: '刷新',
            onPressed: session.busy ? null : () => session.refreshParents(),
          ),
          IconButton(
            icon: const Icon(Icons.logout),
            tooltip: '退出登录',
            onPressed: session.busy ? null : session.signOut,
          ),
        ],
      ),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 620),
          child: ListView(
            padding: const EdgeInsets.all(20),
            children: [
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text(
                        '添加家长',
                        style: TextStyle(
                          fontSize: 18,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      const SizedBox(height: 12),
                      TextField(
                        controller: _username,
                        decoration: const InputDecoration(
                          labelText: '账号（仅英文和数字）',
                          border: OutlineInputBorder(),
                        ),
                      ),
                      const SizedBox(height: 12),
                      TextField(
                        controller: _password,
                        decoration: const InputDecoration(
                          labelText: '密码（至少 8 位）',
                          border: OutlineInputBorder(),
                        ),
                        obscureText: true,
                      ),
                      const SizedBox(height: 12),
                      TextField(
                        controller: _name,
                        decoration: const InputDecoration(
                          labelText: '称呼（可选）',
                          border: OutlineInputBorder(),
                        ),
                      ),
                      const SizedBox(height: 12),
                      FilledButton(
                        onPressed: session.busy ? null : _createParent,
                        child: const Text('添加家长'),
                      ),
                    ],
                  ),
                ),
              ),
              if (session.busy)
                const Center(
                  child: Padding(
                    padding: EdgeInsets.all(16),
                    child: CircularProgressIndicator(),
                  ),
                ),
              for (final parent in session.parents)
                Card(
                  margin: const EdgeInsets.only(top: 12),
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          parent.name.isEmpty
                              ? parent.username
                              : '${parent.name}（${parent.username}）',
                          style: const TextStyle(fontWeight: FontWeight.w700),
                        ),
                        const SizedBox(height: 4),
                        if (parent.children.isEmpty)
                          const Text(
                            '还没有学生账号',
                            style: TextStyle(color: textMuted, fontSize: 12),
                          )
                        else
                          for (final c in parent.children)
                            Padding(
                              padding: const EdgeInsets.only(top: 2),
                              child: Row(
                                children: [
                                  const Icon(
                                    Icons.person_outline,
                                    size: 16,
                                    color: textMuted,
                                  ),
                                  const SizedBox(width: 6),
                                  Expanded(
                                    child: Text(
                                      c.studentUsername == null
                                          ? '${c.name}（未绑定学生账号）'
                                          : '${c.name} · 账号 ${c.studentUsername}',
                                      style: const TextStyle(fontSize: 13),
                                    ),
                                  ),
                                  if (c.studentUsername == null)
                                    TextButton(
                                      onPressed: session.busy
                                          ? null
                                          : () => _bindStudent(parent, c),
                                      child: const Text('开通学生登录'),
                                    ),
                                ],
                              ),
                            ),
                        const SizedBox(height: 8),
                        Align(
                          alignment: Alignment.centerRight,
                          child: Wrap(
                            spacing: 4,
                            children: [
                              TextButton.icon(
                                onPressed: session.busy
                                    ? null
                                    : () => _addChild(parent),
                                icon: const Icon(Icons.folder_open_outlined),
                                label: const Text('加练习档案'),
                              ),
                              TextButton.icon(
                                onPressed: session.busy
                                    ? null
                                    : () => _addStudent(parent),
                                icon: const Icon(Icons.person_add_alt),
                                label: const Text('添加学生'),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

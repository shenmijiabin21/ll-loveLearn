import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/legacy.dart';
import 'package:material_ui/material_ui.dart';

import 'controller.dart';
import 'main.dart';
import 'remote.dart';

final webSessionProvider = ChangeNotifierProvider<WebSession>((ref) {
  return WebSession();
});

class WebSession extends ChangeNotifier {
  ApiClient? _api;
  bool _isAdmin = false;
  List<ChildInfo> children = [];
  List<ParentInfo> parents = [];
  String? selectedChildId;
  Controller? controller;
  bool busy = false;
  String? error;

  ApiClient? get api => _api;
  bool get loggedIn => _api != null;
  bool get isAdmin => _isAdmin;

  WebSession() {
    final token = readStoredToken();
    if (token == null || token.isEmpty) return;
    _api = ApiClient(token: token);
    Future(() async {
      try {
        final me = await _api!.me();
        _isAdmin = me.isAdmin;
        await _refresh();
        notifyListeners();
      } on Exception {
        _api = null;
        clearToken();
        notifyListeners();
      }
    });
  }

  Future<void> _refresh() async {
    if (_isAdmin) {
      parents = await _api!.listParents();
    } else {
      children = await _api!.listChildren();
    }
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

  Future<void> login(String account, String password) => _guarded(() async {
        final result = await ApiClient().login(account, password);
        _api = ApiClient(token: result.token);
        _isAdmin = result.user.isAdmin;
        persistToken(result.token);
        await _refresh();
      });

  Future<void> createParent(String username, String password, String name) =>
      _guarded(() async {
        await _api!.createParent(username, password, name);
        await _refresh();
      });

  Future<void> createChild(String parentId, String name) => _guarded(() async {
        await _api!.createChild(parentId, name);
        await _refresh();
      });

  Future<void> selectChild(String id) => _guarded(() async {
        selectedChildId = id;
        controller = null;
        final store = RemoteJournalStore(_api!, id);
        controller = await Controller.load(store);
      });

  void backToChildren() {
    selectedChildId = null;
    controller = null;
    error = null;
    notifyListeners();
  }

  void signOut() {
    _api = null;
    _isAdmin = false;
    children = [];
    parents = [];
    selectedChildId = null;
    controller = null;
    error = null;
    clearToken();
    notifyListeners();
  }

  static String _friendly(Object e) =>
      e is ApiException ? e.message : '操作失败，请重试';
}

class WebApp extends ConsumerWidget {
  const WebApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final session = ref.watch(webSessionProvider);
    // ProviderScope 必须包在 MaterialApp 外层，否则 push 出来的路由
    // （练习页/结果页）不在覆盖范围内，取 controllerProvider 会抛异常导致灰屏。
    if (session.controller != null) {
      final api = session.api!;
      return ProviderScope(
        overrides: [
          controllerProvider.overrideWith((ref) => session.controller!),
          apiClientProvider.overrideWithValue(api),
          // 显式覆盖识别器，避免依赖 apiClientProvider 的继承解析
          graderProvider.overrideWith((ref) => WebGrader(api)),
        ],
        child: appShell(const Dashboard()),
      );
    }
    final home = session.loggedIn
        ? (session.isAdmin ? const AdminScreen() : const ChildScreen())
        : const AuthScreen();
    return appShell(home);
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
              if (session.error != null)
                Text(
                  session.error!,
                  style: TextStyle(
                    color: Theme.of(context).colorScheme.error,
                  ),
                ),
              const SizedBox(height: 12),
              FilledButton(
                onPressed: session.busy ? null : _submit,
                child: Text(session.busy ? '请稍候…' : '登录'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

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

  String _parentTitle(ParentInfo p) =>
      p.name.isEmpty ? p.username : p.name + '（' + p.username + '）';

  String _parentSubtitle(ParentInfo p) {
    if (p.children.isEmpty) return '孩子：暂无';
    return '孩子：' + p.children.map((c) => c.name).join('、');
  }

  void _createParent() {
    final username = _username.text.trim();
    final password = _password.text;
    final name = _name.text.trim();
    if (!RegExp(r'^[a-zA-Z0-9]+$').hasMatch(username)) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('账号只能包含英文和数字')),
      );
      return;
    }
    if (password.length < 8) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('密码至少 8 位')),
      );
      return;
    }
    ref.read(webSessionProvider).createParent(username, password, name);
    _username.clear();
    _password.clear();
    _name.clear();
  }

  Future<void> _addChild(ParentInfo parent) async {
    final controller = TextEditingController();
    final dialogTitle = '为 ' +
        (parent.name.isEmpty ? parent.username : parent.name) +
        ' 添加孩子';
    final name = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(dialogTitle),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: const InputDecoration(labelText: '孩子名字'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, controller.text.trim()),
            child: const Text('添加'),
          ),
        ],
      ),
    );
    if (name != null && name.isNotEmpty) {
      ref.read(webSessionProvider).createChild(parent.id, name);
    }
  }

  @override
  Widget build(BuildContext context) {
    final session = ref.watch(webSessionProvider);
    return Scaffold(
      appBar: AppBar(
        title: const Text('管理员 · 账号管理'),
        actions: [
          IconButton(
            icon: const Icon(Icons.logout),
            tooltip: '退出登录',
            onPressed: session.busy ? null : session.signOut,
          ),
        ],
      ),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 560),
          child: ListView(
            padding: const EdgeInsets.all(20),
            children: [
              if (session.error != null)
                Padding(
                  padding: const EdgeInsets.only(bottom: 12),
                  child: Text(
                    session.error!,
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.error,
                    ),
                  ),
                ),
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text('添加家长',
                          style: TextStyle(
                              fontSize: 18, fontWeight: FontWeight.w700)),
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
              const SizedBox(height: 8),
              if (session.busy)
                const Center(
                  child: Padding(
                    padding: EdgeInsets.all(16),
                    child: CircularProgressIndicator(),
                  ),
                ),
              for (final p in session.parents)
                Card(
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Row(
                      children: [
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                _parentTitle(p),
                                style: const TextStyle(
                                    fontWeight: FontWeight.w700),
                              ),
                              Text(
                                _parentSubtitle(p),
                                style: const TextStyle(color: textMuted),
                              ),
                            ],
                          ),
                        ),
                        TextButton.icon(
                          onPressed:
                              session.busy ? null : () => _addChild(p),
                          icon: const Icon(Icons.child_care),
                          label: const Text('添加孩子'),
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

class ChildScreen extends ConsumerWidget {
  const ChildScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final session = ref.watch(webSessionProvider);
    return Scaffold(
      appBar: AppBar(
        title: const Text('选择孩子'),
        actions: [
          IconButton(
            icon: const Icon(Icons.logout),
            tooltip: '退出登录',
            onPressed: session.busy ? null : session.signOut,
          ),
        ],
      ),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 480),
          child: ListView(
            padding: const EdgeInsets.all(20),
            children: [
              if (session.error != null)
                Padding(
                  padding: const EdgeInsets.only(bottom: 12),
                  child: Text(
                    session.error!,
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.error,
                    ),
                  ),
                ),
              if (session.busy)
                const Center(
                  child: Padding(
                    padding: EdgeInsets.all(24),
                    child: CircularProgressIndicator(),
                  ),
                ),
              if (session.children.isEmpty && !session.busy)
                const Padding(
                  padding: EdgeInsets.all(24),
                  child: Text(
                    '暂未关联孩子，请联系管理员添加。',
                    textAlign: TextAlign.center,
                    style: TextStyle(color: textMuted),
                  ),
                ),
              for (final child in session.children)
                Card(
                  child: ListTile(
                    leading: const CircleAvatar(
                      child: Icon(Icons.child_care),
                    ),
                    title: Text(child.name),
                    trailing: const Icon(Icons.chevron_right),
                    onTap: session.busy
                        ? null
                        : () => session.selectChild(child.id),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

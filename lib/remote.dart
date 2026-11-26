import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;

import 'device.dart';
import 'domain.dart';
import 'storage.dart';
import 'token_store_stub.dart'
    if (dart.library.js_interop) 'token_store_web.dart'
    as token;

const apiBase = String.fromEnvironment('API_BASE_URL', defaultValue: '/api');

class ApiException implements Exception {
  ApiException(this.status, this.message);
  final int status;
  final String message;

  @override
  String toString() => message;
}

class ApiClient {
  ApiClient({this.token});
  String? token;

  Map<String, String> get _headers => {
    'Content-Type': 'application/json',
    if (token != null) 'Authorization': 'Bearer $token',
  };

  Uri _uri(String path) => Uri.parse('$apiBase$path');

  Future<dynamic> _send(String method, String path, {Object? body}) async {
    final uri = _uri(path);
    final headers = _headers;
    http.Response resp;
    try {
      resp = switch (method) {
        'GET' => await http.get(uri, headers: headers),
        'POST' => await http.post(uri, headers: headers, body: jsonEncode(body)),
        'PUT' => await http.put(uri, headers: headers, body: jsonEncode(body)),
        'PATCH' =>
          await http.patch(uri, headers: headers, body: jsonEncode(body)),
        'DELETE' => await http.delete(uri, headers: headers),
        _ => throw UnsupportedError(method),
      };
    } on Exception {
      throw ApiException(0, '网络不可用，请检查连接');
    }
    if (resp.statusCode >= 200 && resp.statusCode < 300) {
      if (resp.body.isEmpty) return null;
      return jsonDecode(resp.body);
    }
    var message = '请求失败 (${resp.statusCode})';
    try {
      final decoded = jsonDecode(resp.body);
      if (decoded is Map && decoded['detail'] is String) {
        message = decoded['detail'] as String;
      }
    } on Exception {
      // 保留默认提示
    }
    throw ApiException(resp.statusCode, message);
  }

  Future<dynamic> get(String path) => _send('GET', path);
  Future<dynamic> post(String path, Object body) =>
      _send('POST', path, body: body);
  Future<dynamic> put(String path, Object body) => _send('PUT', path, body: body);
  Future<dynamic> patch(String path, Object body) =>
      _send('PATCH', path, body: body);
  Future<dynamic> delete(String path) => _send('DELETE', path);

  Future<AuthResult> login(String account, String password) async {
    final json = await post('/auth/login', {
      'account': account,
      'password': password,
    });
    return AuthResult.fromJson(json);
  }

  Future<UserInfo> me() async => UserInfo.fromJson(await get('/auth/me'));

  Future<List<ChildInfo>> listChildren() async {
    final json = await get('/children') as List;
    return [for (final item in json) ChildInfo.fromJson(item)];
  }

  Future<List<ParentInfo>> listParents() async {
    final json = await get('/admin/users') as List;
    return [for (final item in json) ParentInfo.fromJson(item)];
  }

  Future<void> createParent(String username, String password, String name) async {
    await post('/admin/users', {
      'username': username,
      'password': password,
      'display_name': name,
      'role': 'parent',
    });
  }

  /// 创建学生账号，同时为其建一条孩子档案并关联到家长
  Future<void> createStudent({
    required String parentId,
    required String username,
    required String password,
    required String studentName,
    required String childName,
  }) async {
    await post('/admin/users', {
      'username': username,
      'password': password,
      'display_name': studentName,
      'role': 'student',
      'parent_id': parentId,
      'child_name': childName,
    });
  }

  Future<ChildSummary> childSummary(String childId) async =>
      ChildSummary.fromJson(await get('/children/$childId/summary'));

  /// scope: today（只清今天，可重练）/ all（清空全部）
  Future<void> resetChild(String childId, {String scope = 'today'}) async {
    await post('/children/$childId/reset', {'scope': scope});
  }

  Future<ChildInfo> createChild(String parentId, String name) async {
    final json = await post('/admin/children', {
      'parent_id': parentId,
      'name': name,
    });
    return ChildInfo.fromJson(json);
  }
}

class UserInfo {
  UserInfo({
    required this.id,
    required this.username,
    required this.name,
    required this.isAdmin,
    required this.role,
  });

  factory UserInfo.fromJson(Object? value) {
    final m = value as Map<String, dynamic>;
    final isAdmin = (m['is_admin'] as bool?) ?? false;
    final role = (m['role'] as String?) ?? (isAdmin ? 'admin' : 'parent');
    return UserInfo(
      id: m['id'] as String,
      username: (m['username'] as String?) ?? '',
      name: (m['display_name'] as String?) ?? '',
      isAdmin: isAdmin,
      role: role,
    );
  }

  final String id;
  final String username;
  final String name;
  final bool isAdmin;

  /// admin / parent / student
  final String role;

  bool get isStudent => role == 'student';
  bool get isParent => role == 'parent';
}

class AuthResult {
  AuthResult({required this.token, required this.user});

  factory AuthResult.fromJson(Object? value) {
    final m = value as Map<String, dynamic>;
    return AuthResult(
      token: m['access_token'] as String,
      user: UserInfo.fromJson(m['user']),
    );
  }

  final String token;
  final UserInfo user;
}

class ChildInfo {
  ChildInfo({required this.id, required this.name, this.studentUsername});

  factory ChildInfo.fromJson(Object? value) {
    final m = value as Map<String, dynamic>;
    return ChildInfo(
      id: m['id'] as String,
      name: m['name'] as String,
      studentUsername: m['student_username'] as String?,
    );
  }

  final String id;
  final String name;
  final String? studentUsername;
}

class RecentPractice {
  RecentPractice({
    required this.date,
    required this.kind,
    required this.total,
    required this.correct,
    required this.pending,
  });

  factory RecentPractice.fromJson(Object? value) {
    final m = value as Map<String, dynamic>;
    return RecentPractice(
      date: (m['date'] as String?) ?? '',
      kind: (m['kind'] as String?) ?? '',
      total: (m['total'] as num?)?.toInt() ?? 0,
      correct: (m['correct'] as num?)?.toInt() ?? 0,
      pending: (m['pending'] as num?)?.toInt() ?? 0,
    );
  }

  final String date;
  final String kind;
  final int total;
  final int correct;
  final int pending;
}

class ChildSummary {
  ChildSummary({
    required this.childId,
    required this.childName,
    required this.studentUsername,
    required this.practiceDays,
    required this.totalQuestions,
    required this.correct,
    required this.wrong,
    required this.blank,
    required this.pending,
    required this.recent,
  });

  factory ChildSummary.fromJson(Object? value) {
    final m = value as Map<String, dynamic>;
    int pick(String k) => (m[k] as num?)?.toInt() ?? 0;
    return ChildSummary(
      childId: (m['child_id'] as String?) ?? '',
      childName: (m['child_name'] as String?) ?? '',
      studentUsername: m['student_username'] as String?,
      practiceDays: pick('practice_days'),
      totalQuestions: pick('total_questions'),
      correct: pick('correct'),
      wrong: pick('wrong'),
      blank: pick('blank'),
      pending: pick('pending'),
      recent: [
        for (final r in (m['recent'] as List? ?? []))
          RecentPractice.fromJson(r),
      ],
    );
  }

  final String childId;
  final String childName;
  final String? studentUsername;
  final int practiceDays;
  final int totalQuestions;
  final int correct;
  final int wrong;
  final int blank;
  final int pending;
  final List<RecentPractice> recent;

  /// 已确认题目的正确率；没有已确认题目时返回 null
  int? get accuracy {
    final graded = correct + wrong;
    if (graded == 0) return null;
    return (100 * correct / graded).round();
  }
}

class ParentInfo {
  ParentInfo({
    required this.id,
    required this.username,
    required this.name,
    required this.children,
  });

  factory ParentInfo.fromJson(Object? value) {
    final m = value as Map<String, dynamic>;
    return ParentInfo(
      id: m['id'] as String,
      username: (m['username'] as String?) ?? '',
      name: (m['display_name'] as String?) ?? '',
      children: [
        for (final c in (m['children'] as List? ?? [])) ChildInfo.fromJson(c),
      ],
    );
  }

  final String id;
  final String username;
  final String name;
  final List<ChildInfo> children;
}

class RemoteJournalStore implements JournalRepository {
  RemoteJournalStore(this.api, this.childId);

  final ApiClient api;
  final String childId;
  int _revision = 0;

  // 串行化 + 合并：每写一笔都会触发保存，若并发 PUT 会因 revision 撞车返回 409。
  // 这里保证同一时刻只有一个写入在飞，多余的请求合并成一次，且始终写最新数据。
  Future<void> _chain = Future<void>.value();
  bool _queued = false;

  @override
  Future<Journal?> load() async {
    try {
      final json =
          await api.get('/children/$childId/journal') as Map<String, dynamic>;
      _revision = json['revision'] as int;
      return Journal.fromJson(json['payload']);
    } on ApiException catch (error) {
      if (error.status == 404) return null;
      rethrow;
    }
  }

  Map<String, dynamic> _body(Journal journal) => {
    'revision': _revision == 0 ? null : _revision,
    'payload': journal.toJson(),
  };

  Future<void> _write(Journal journal) async {
    try {
      final json =
          await api.put('/children/$childId/journal', _body(journal))
              as Map<String, dynamic>;
      _revision = json['revision'] as int;
    } on ApiException catch (error) {
      if (error.status != 409) rethrow;
      // 版本冲突：取回服务端最新 revision 后重写一次
      final current =
          await api.get('/children/$childId/journal') as Map<String, dynamic>;
      _revision = current['revision'] as int;
      final json =
          await api.put('/children/$childId/journal', _body(journal))
              as Map<String, dynamic>;
      _revision = json['revision'] as int;
    }
  }

  @override
  Future<void> save(Journal journal) {
    if (_queued) return _chain;
    _queued = true;
    final task = _chain.then((_) async {
      _queued = false;
      await _write(journal);
    });
    _chain = task.then<void>((_) {}, onError: (Object _, StackTrace __) {});
    return task;
  }
}

class WebGrader implements Grader {
  WebGrader(this.api);

  final ApiClient api;

  @override
  Future<List<Grade>> grade(List<Answer> answers) async {
    try {
      final items = [
        for (final answer in answers)
          {
            'expected': answer.question.prompt.character,
            'strokes': [
              for (final stroke in answer.ink)
                [
                  for (final point in stroke) [point.x, point.y, point.time],
                ],
            ],
          },
      ];
      // 不限制候选字范围：识别到什么就展示什么
      final result = (await api.post('/grade', {'items': items}) as List)
          .cast<Map<String, dynamic>>();
      return [
        for (final item in result)
          (
            verdict: Verdict.values.byName(item['verdict'] as String),
            candidates: (item['candidates'] as List).cast<String>(),
          ),
      ];
    } catch (_) {
      // 识别不可用时一律回退到待确认，由家长订正，不能卡住提交流程
      return [
        for (final answer in answers)
          answer.ink.isEmpty
              ? (verdict: Verdict.blank, candidates: const <String>[])
              : (verdict: Verdict.pending, candidates: const <String>[]),
      ];
    }
  }
}

final apiClientProvider = Provider<ApiClient>((ref) => throw StateError('尚未登录'));

final graderProvider = Provider<Grader>((ref) {
  if (kIsWeb) return WebGrader(ref.watch(apiClientProvider));
  return DigitalInk();
});

// —— token 持久化（仅 web，localStorage）——
// 具体实现走条件导入，避免 remote.dart 顶层引入 package:web ——
// 那会让 VM 平台的测试因为 dart:js_interop 不可用而无法加载。
String? readStoredToken() => kIsWeb ? token.readToken() : null;

void persistToken(String value) {
  if (!kIsWeb) return;
  token.writeToken(value);
}

void clearToken() {
  if (!kIsWeb) return;
  token.removeToken();
}

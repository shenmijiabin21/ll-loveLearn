import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;
import 'package:web/web.dart' as web;

import 'device.dart';
import 'domain.dart';
import 'storage.dart';

const apiBase = String.fromEnvironment('API_BASE_URL', defaultValue: '/api');
const _tokenKey = 'll-love-learn-token';

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
    });
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
  });

  factory UserInfo.fromJson(Object? value) {
    final m = value as Map<String, dynamic>;
    return UserInfo(
      id: m['id'] as String,
      username: (m['username'] as String?) ?? '',
      name: (m['display_name'] as String?) ?? '',
      isAdmin: (m['is_admin'] as bool?) ?? false,
    );
  }

  final String id;
  final String username;
  final String name;
  final bool isAdmin;
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
  ChildInfo({required this.id, required this.name});

  factory ChildInfo.fromJson(Object? value) {
    final m = value as Map<String, dynamic>;
    return ChildInfo(id: m['id'] as String, name: m['name'] as String);
  }

  final String id;
  final String name;
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

  @override
  Future<void> save(Journal journal) async {
    final json = await api.put('/children/$childId/journal', {
      'revision': _revision == 0 ? null : _revision,
      'payload': journal.toJson(),
    }) as Map<String, dynamic>;
    _revision = json['revision'] as int;
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
      // 把本次练习涉及的字作为候选集，显著提升判别力
      final allowed =
          answers.map((a) => a.question.prompt.character).toSet().toList();
      final result =
          (await api.post('/grade', {
                'items': items,
                'allowed': allowed,
              })
                  as List)
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
String? readStoredToken() {
  if (!kIsWeb) return null;
  try {
    return web.window.localStorage.getItem(_tokenKey);
  } on Exception {
    return null;
  }
}

void persistToken(String token) {
  if (!kIsWeb) return;
  try {
    web.window.localStorage.setItem(_tokenKey, token);
  } on Exception {
    // 忽略存储失败，保持内存态即可
  }
}

void clearToken() {
  if (!kIsWeb) return;
  try {
    web.window.localStorage.removeItem(_tokenKey);
  } on Exception {
    // 忽略
  }
}

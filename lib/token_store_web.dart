import 'package:web/web.dart' as web;

const _key = 'll-love-learn-token';

String? readToken() {
  try {
    return web.window.localStorage.getItem(_key);
  } on Exception {
    return null;
  }
}

void writeToken(String token) {
  try {
    web.window.localStorage.setItem(_key, token);
  } on Exception {
    // 忽略存储失败，保持内存态即可
  }
}

void removeToken() {
  try {
    web.window.localStorage.removeItem(_key);
  } on Exception {
    // 忽略
  }
}

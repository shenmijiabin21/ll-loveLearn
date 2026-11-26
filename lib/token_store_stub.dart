// 非 web 编译目标（flutter test 的 Dart VM）没有 localStorage。
// 返回空值即可：测试只覆盖练习流程，不碰登录令牌。

String? readToken() => null;

void writeToken(String token) {}

void removeToken() {}

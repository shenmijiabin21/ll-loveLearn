/// 非网页平台的 token 存储空实现。
///
/// 移动端 token 只存在内存里：本地版不需要登录，走不到这里。
String? readToken() => null;

void writeToken(String token) {}

void removeToken() {}

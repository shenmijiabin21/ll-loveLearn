import time
import uuid
from typing import Optional

from fastapi import Depends, HTTPException, status
from fastapi.security import HTTPAuthorizationCredentials, HTTPBearer
from sqlalchemy.ext.asyncio import AsyncSession

from .database import get_db
from .models import ROLE_ADMIN, ROLE_STUDENT, Child, User
from .security import decode_access_token

bearer_scheme = HTTPBearer(auto_error=False)


async def get_current_user(
    credentials: Optional[HTTPAuthorizationCredentials] = Depends(bearer_scheme),
    db: AsyncSession = Depends(get_db),
) -> User:
    if credentials is None:
        raise HTTPException(status.HTTP_401_UNAUTHORIZED, "未登录")
    claims = decode_access_token(credentials.credentials)
    if claims is None:
        raise HTTPException(status.HTTP_401_UNAUTHORIZED, "登录已失效")
    try:
        uid = uuid.UUID(str(claims.get("sub")))
    except (TypeError, ValueError):
        raise HTTPException(status.HTTP_401_UNAUTHORIZED, "登录已失效")
    user = await db.get(User, uid)
    if user is None:
        raise HTTPException(status.HTTP_401_UNAUTHORIZED, "账号不存在")
    # 改密等操作会递增 token_version，旧令牌随即作废
    if int(claims.get("ver") or 0) != int(user.token_version or 0):
        raise HTTPException(status.HTTP_401_UNAUTHORIZED, "登录已失效")
    return user


def is_admin(user: User) -> bool:
    return bool(user.is_admin) or user.role_or_default == ROLE_ADMIN


async def get_current_admin(user: User = Depends(get_current_user)) -> User:
    if not is_admin(user):
        raise HTTPException(status.HTTP_403_FORBIDDEN, "需要管理员权限")
    return user


def ensure_child_access(child: Child, user: User) -> None:
    """admin 全通；parent 需自己名下的孩子；student 需与该孩子绑定。"""
    if is_admin(user):
        return
    if user.role_or_default == ROLE_STUDENT:
        if child.student_user_id is not None and child.student_user_id == user.id:
            return
        raise HTTPException(status.HTTP_403_FORBIDDEN, "无权访问该学生")
    if child.user_id == user.id:
        return
    raise HTTPException(status.HTTP_403_FORBIDDEN, "无权访问该孩子")


async def load_child(child_id: str, db: AsyncSession) -> Child:
    try:
        cid = uuid.UUID(str(child_id))
    except (AttributeError, TypeError, ValueError):
        raise HTTPException(status.HTTP_400_BAD_REQUEST, "孩子 ID 无效")
    child = await db.get(Child, cid)
    if child is None:
        raise HTTPException(status.HTTP_404_NOT_FOUND, "孩子不存在")
    return child


# —— 登录限速：按账号做进程内滑动窗口，防止公网下的字典爆破 ——
# 单实例足够；多实例部署需换成共享存储（Redis 等）。
# 达到上限后在窗口内直接 429，不再跑 bcrypt：既阻断爆破，也避免
# 有人用错误密码把 CPU 打满。代价是窗口期内该账号无法登录（5 分钟）。
LOGIN_WINDOW_SECONDS = 300
LOGIN_MAX_FAILURES = 10
_LOGIN_MAX_KEYS = 20000
_login_failures: dict[str, list[float]] = {}


def _recent_failures(key: str, now: float) -> list[float]:
    recent = [t for t in _login_failures.get(key, []) if now - t < LOGIN_WINDOW_SECONDS]
    if recent:
        _login_failures[key] = recent
    else:
        _login_failures.pop(key, None)
    return recent


def _prune(now: float) -> None:
    """失败表只保留窗口内的条目，避免随机用户名把内存撑大。"""
    if len(_login_failures) <= _LOGIN_MAX_KEYS:
        return
    for key in list(_login_failures):
        _recent_failures(key, now)


def check_login_allowed(account: str) -> None:
    recent = _recent_failures(account.strip().lower(), time.time())
    if len(recent) >= LOGIN_MAX_FAILURES:
        raise HTTPException(
            status.HTTP_429_TOO_MANY_REQUESTS,
            "尝试次数过多，请 5 分钟后再试",
        )


def record_login_failure(account: str) -> None:
    key = account.strip().lower()
    now = time.time()
    _prune(now)
    recent = _recent_failures(key, now)
    recent.append(now)
    _login_failures[key] = recent


def clear_login_failures(account: str) -> None:
    _login_failures.pop(account.strip().lower(), None)

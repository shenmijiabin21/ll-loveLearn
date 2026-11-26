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
    user_id = decode_access_token(credentials.credentials)
    if user_id is None:
        raise HTTPException(status.HTTP_401_UNAUTHORIZED, "登录已失效")
    try:
        uid = uuid.UUID(user_id)
    except ValueError:
        raise HTTPException(status.HTTP_401_UNAUTHORIZED, "登录已失效")
    user = await db.get(User, uid)
    if user is None:
        raise HTTPException(status.HTTP_401_UNAUTHORIZED, "账号不存在")
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

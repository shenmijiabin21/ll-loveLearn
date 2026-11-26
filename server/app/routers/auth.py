from fastapi import APIRouter, Depends, HTTPException, status
from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from ..database import get_db
from ..deps import (
    check_login_allowed,
    clear_login_failures,
    get_current_user,
    record_login_failure,
)
from ..models import User
from ..schemas import ChangePasswordIn, LoginIn, MessageOut, TokenOut, UserOut
from ..security import (
    burn_password_check,
    create_access_token,
    hash_password,
    verify_password,
)

router = APIRouter(prefix="/auth", tags=["auth"])


def _token(user: User) -> TokenOut:
    return TokenOut(
        access_token=create_access_token(str(user.id), user.token_version or 0),
        user=UserOut.of(user),
    )


@router.get("/me", response_model=UserOut)
async def me(user: User = Depends(get_current_user)):
    return UserOut.of(user)


@router.post("/login", response_model=TokenOut)
async def login(body: LoginIn, db: AsyncSession = Depends(get_db)):
    account = body.account.strip()
    check_login_allowed(account)
    user = await db.scalar(select(User).where(User.username == account))
    if user is None:
        # 账号不存在也跑一次校验，避免通过响应时间枚举用户名
        burn_password_check(body.password)
        record_login_failure(account)
        raise HTTPException(status.HTTP_401_UNAUTHORIZED, "账号或密码错误")
    if not verify_password(body.password, user.password_hash):
        record_login_failure(account)
        raise HTTPException(status.HTTP_401_UNAUTHORIZED, "账号或密码错误")
    clear_login_failures(account)
    return _token(user)


@router.post("/password", response_model=TokenOut)
async def change_password(
    body: ChangePasswordIn,
    user: User = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    if not verify_password(body.current_password, user.password_hash):
        raise HTTPException(status.HTTP_400_BAD_REQUEST, "当前密码不正确")
    if body.current_password == body.new_password:
        raise HTTPException(status.HTTP_400_BAD_REQUEST, "新密码不能与当前密码相同")
    user.password_hash = hash_password(body.new_password)
    # 递增版本使所有旧令牌失效，并给当前会话签发新令牌
    user.token_version = (user.token_version or 0) + 1
    await db.commit()
    await db.refresh(user)
    return _token(user)


@router.post("/logout", response_model=MessageOut)
async def logout(
    user: User = Depends(get_current_user), db: AsyncSession = Depends(get_db)
):
    """注销全部设备：递增令牌版本，使已签发的令牌全部失效。"""
    user.token_version = (user.token_version or 0) + 1
    await db.commit()
    return MessageOut(message="已退出登录")

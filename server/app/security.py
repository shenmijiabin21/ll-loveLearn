import logging
import os
import secrets
from datetime import datetime, timedelta, timezone
from pathlib import Path
from typing import Any, Optional

import bcrypt
import jwt

from .config import settings

log = logging.getLogger("uvicorn.error")


def _load_jwt_secret() -> str:
    """优先用环境变量；否则读取/生成本地密钥文件，避免使用公开的默认密钥。"""
    if settings.jwt_secret:
        return settings.jwt_secret
    path = Path(settings.jwt_secret_file)
    try:
        existing = path.read_text(encoding="utf-8").strip()
        if existing:
            return existing
    except OSError:
        pass
    generated = secrets.token_urlsafe(48)
    try:
        path.write_text(generated, encoding="utf-8")
        try:
            os.chmod(path, 0o600)
        except OSError:
            pass
        log.warning(
            "未设置 JWT_SECRET，已生成随机密钥并保存到 %s；"
            "多实例部署请改用环境变量统一配置。",
            path.resolve(),
        )
    except OSError:
        log.warning("未设置 JWT_SECRET 且无法写入密钥文件，本次运行使用临时随机密钥。")
    return generated


JWT_SECRET = _load_jwt_secret()


def hash_password(password: str) -> str:
    return bcrypt.hashpw(password.encode("utf-8"), bcrypt.gensalt()).decode("utf-8")


def verify_password(password: str, hashed: str) -> bool:
    try:
        return bcrypt.checkpw(password.encode("utf-8"), hashed.encode("utf-8"))
    except ValueError:
        return False


# 账号不存在时也跑一次校验，避免通过响应时间枚举用户名
DUMMY_HASH = hash_password("no-such-account-placeholder")


def burn_password_check(password: str) -> None:
    verify_password(password, DUMMY_HASH)


def create_access_token(user_id: str, token_version: int = 0) -> str:
    expire = datetime.now(timezone.utc) + timedelta(
        minutes=settings.access_token_expire_minutes
    )
    payload = {"sub": str(user_id), "ver": token_version, "exp": expire}
    return jwt.encode(payload, JWT_SECRET, algorithm=settings.jwt_algorithm)


def decode_access_token(token: str) -> Optional[dict[str, Any]]:
    try:
        return jwt.decode(token, JWT_SECRET, algorithms=[settings.jwt_algorithm])
    except jwt.PyJWTError:
        return None

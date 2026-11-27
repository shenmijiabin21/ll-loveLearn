import logging
import secrets
import string
from contextlib import asynccontextmanager

from fastapi import FastAPI
from fastapi.middleware.cors import CORSMiddleware
from sqlalchemy import select, text

from . import models  # noqa: F401
from .config import settings
from .database import Base, SessionLocal, engine
from .routers import admin, auth, children, grade, journal, live, presence
from .security import hash_password

log = logging.getLogger("uvicorn.error")


def _generate_password(length: int = 16) -> str:
    alphabet = string.ascii_letters + string.digits
    return "".join(secrets.choice(alphabet) for _ in range(length))


@asynccontextmanager
async def lifespan(app: FastAPI):
    async with engine.begin() as conn:
        await conn.run_sync(Base.metadata.create_all)
    # 种子管理员账号（不存在时创建）
    async with SessionLocal() as session:
        existing = await session.scalar(
            select(models.User).where(
                models.User.username == settings.admin_username
            )
        )
        if existing is None:
            password = settings.admin_password or _generate_password()
            session.add(
                models.User(
                    username=settings.admin_username,
                    password_hash=hash_password(password),
                    display_name="管理员",
                    is_admin=True,
                    role=models.ROLE_ADMIN,
                )
            )
            await session.commit()
            if not settings.admin_password:
                # 只在自动生成时打印；登录后请尽快用「修改密码」替换
                log.warning(
                    "首次启动已创建管理员 %s，初始密码：%s （仅本次显示，登录后请立即修改）",
                    settings.admin_username,
                    password,
                )
    yield


app = FastAPI(title="每日听写 API", lifespan=lifespan)

app.add_middleware(
    CORSMiddleware,
    allow_origins=[o.strip() for o in settings.cors_origins.split(",") if o.strip()],
    allow_credentials=False,
    allow_methods=["*"],
    allow_headers=["*"],
)

app.include_router(auth.router)
app.include_router(children.router)
app.include_router(journal.router)
app.include_router(presence.router)
app.include_router(grade.router)
app.include_router(admin.router)
# 家长端实时通道（WebSocket）：/ws/live?token=...
app.include_router(live.router)


@app.get("/health")
async def health():
    # 进程活着不代表数据库可用：探活顺带查一次连接
    try:
        async with SessionLocal() as session:
            await session.execute(text("SELECT 1"))
    except Exception:
        return {"status": "degraded", "database": "unavailable"}
    return {"status": "ok", "database": "ok"}

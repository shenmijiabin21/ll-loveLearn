from contextlib import asynccontextmanager

from fastapi import FastAPI
from fastapi.middleware.cors import CORSMiddleware
from sqlalchemy import select

from . import models  # noqa: F401
from .config import settings
from .database import Base, SessionLocal, engine
from .routers import admin, auth, children, grade, journal
from .security import hash_password


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
            session.add(
                models.User(
                    username=settings.admin_username,
                    password_hash=hash_password(settings.admin_password),
                    display_name="管理员",
                    is_admin=True,
                    role=models.ROLE_ADMIN,
                )
            )
            await session.commit()
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
app.include_router(grade.router)
app.include_router(admin.router)


@app.get("/health")
async def health():
    return {"status": "ok"}

import uuid
from datetime import datetime
from typing import Optional

from sqlalchemy import BigInteger, DateTime, ForeignKey, String, func
from sqlalchemy.dialects.postgresql import JSONB, UUID
from sqlalchemy.orm import Mapped, mapped_column, relationship

from .database import Base

ROLE_ADMIN = "admin"
ROLE_PARENT = "parent"
ROLE_STUDENT = "student"


class User(Base):
    __tablename__ = "users"

    id: Mapped[uuid.UUID] = mapped_column(
        UUID(as_uuid=True), primary_key=True, default=uuid.uuid4
    )
    email: Mapped[Optional[str]] = mapped_column(
        String(255), unique=True, index=True, nullable=True
    )
    username: Mapped[str] = mapped_column(String(64), unique=True, index=True)
    password_hash: Mapped[str] = mapped_column(String(255))
    display_name: Mapped[str] = mapped_column(String(100), default="")
    # 兼容字段：管理员恒为 True，与 role == "admin" 等价
    is_admin: Mapped[bool] = mapped_column(default=False)
    # 改密后递增，使旧令牌立即失效
    token_version: Mapped[int] = mapped_column(
        BigInteger, default=0, server_default="0"
    )
    role: Mapped[str] = mapped_column(
        String(16), default=ROLE_PARENT, server_default=ROLE_PARENT
    )
    # 学生指向自己的家长；家长/管理员为 None
    parent_id: Mapped[Optional[uuid.UUID]] = mapped_column(
        UUID(as_uuid=True),
        ForeignKey("users.id", ondelete="SET NULL"),
        nullable=True,
        index=True,
    )
    created_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), server_default=func.now()
    )

    children: Mapped[list["Child"]] = relationship(
        back_populates="parent",
        cascade="all, delete-orphan",
        foreign_keys="Child.user_id",
    )

    @property
    def role_or_default(self) -> str:
        """旧库里 role 可能为空或与 is_admin 不一致时的兜底取值。"""
        if self.is_admin:
            return ROLE_ADMIN
        return self.role or ROLE_PARENT


class Child(Base):
    __tablename__ = "children"

    id: Mapped[uuid.UUID] = mapped_column(
        UUID(as_uuid=True), primary_key=True, default=uuid.uuid4
    )
    user_id: Mapped[uuid.UUID] = mapped_column(
        UUID(as_uuid=True),
        ForeignKey("users.id", ondelete="CASCADE"),
        index=True,
    )
    # 该孩子对应的学生账号（可空：老数据或只有家长账号的孩子）
    student_user_id: Mapped[Optional[uuid.UUID]] = mapped_column(
        UUID(as_uuid=True),
        ForeignKey("users.id", ondelete="SET NULL"),
        nullable=True,
        index=True,
    )
    name: Mapped[str] = mapped_column(String(100))
    created_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), server_default=func.now()
    )

    parent: Mapped["User"] = relationship(
        back_populates="children", foreign_keys="Child.user_id"
    )
    journal: Mapped[Optional["Journal"]] = relationship(
        back_populates="child", cascade="all, delete-orphan", uselist=False
    )


class Journal(Base):
    __tablename__ = "journals"

    child_id: Mapped[uuid.UUID] = mapped_column(
        ForeignKey("children.id", ondelete="CASCADE"), primary_key=True
    )
    revision: Mapped[int] = mapped_column(BigInteger, default=1)
    payload: Mapped[dict] = mapped_column(JSONB)
    updated_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), server_default=func.now(), onupdate=func.now()
    )

    child: Mapped["Child"] = relationship(back_populates="journal")


class Presence(Base):
    """孩子端「是否正在练习」的心跳。

    每（孩子, 日期）一行。客户端只上报素材（是否可见、落笔数、离开累计），
    在线状态一律由服务端按 last_seen_at 推导：关掉网页、拔网线、强杀进程
    都不会再上报，超时后自然变成离线，不需要客户端发「结束」事件。
    """

    __tablename__ = "presence"

    child_id: Mapped[uuid.UUID] = mapped_column(
        ForeignKey("children.id", ondelete="CASCADE"), primary_key=True
    )
    # 服务器本地日期 YYYY-MM-DD，与 children._today() 一致
    day: Mapped[str] = mapped_column(String(10), primary_key=True)
    # 当前这一次练习的 ID；换练习或提交后由客户端更新
    practice_id: Mapped[Optional[str]] = mapped_column(String(64), nullable=True)
    last_seen_at: Mapped[Optional[datetime]] = mapped_column(
        DateTime(timezone=True), nullable=True
    )
    last_stroke_at: Mapped[Optional[datetime]] = mapped_column(
        DateTime(timezone=True), nullable=True
    )
    # 非空表示页面当前不可见（切标签页/最小化）；回到前台时清空
    away_since: Mapped[Optional[datetime]] = mapped_column(
        DateTime(timezone=True), nullable=True
    )
    # 以下为客户端累计值，服务端只取最大值，重复/乱序上报不会把数字改小
    strokes: Mapped[int] = mapped_column(BigInteger, default=0, server_default="0")
    away_count: Mapped[int] = mapped_column(BigInteger, default=0, server_default="0")
    away_seconds: Mapped[int] = mapped_column(
        BigInteger, default=0, server_default="0"
    )
    active_seconds: Mapped[int] = mapped_column(
        BigInteger, default=0, server_default="0"
    )

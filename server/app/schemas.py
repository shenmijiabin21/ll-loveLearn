import json
import uuid
from datetime import datetime
from typing import Any, Literal, Optional

from pydantic import BaseModel, Field, field_validator

# 用户名：仅英文和数字
USERNAME_PATTERN = r"^[a-zA-Z0-9]{1,32}$"

# 单个孩子的练习记录上限（明文 JSON 大致 16MB）。客户端每笔迹一点约 30 字节，
# 128 笔 × 4096 点的极端情况下才会接近，正常练习远低于此值。
MAX_PAYLOAD_BYTES = 16 * 1024 * 1024


class LoginIn(BaseModel):
    account: str = Field(min_length=1, max_length=32)
    password: str


class ChangePasswordIn(BaseModel):
    current_password: str
    new_password: str = Field(min_length=8, max_length=72)


class MessageOut(BaseModel):
    message: str


class UserOut(BaseModel):
    model_config = {"from_attributes": True}

    id: uuid.UUID
    username: str
    display_name: str
    is_admin: bool = False
    role: str = "parent"

    @classmethod
    def of(cls, user: Any) -> "UserOut":
        role = getattr(user, "role_or_default", None)
        if not isinstance(role, str) or not role:
            role = "parent"
        return cls(
            id=user.id,
            username=user.username,
            display_name=user.display_name,
            is_admin=bool(user.is_admin),
            role=role,
        )


class TokenOut(BaseModel):
    access_token: str
    token_type: str = "bearer"
    user: UserOut


class CreateUserIn(BaseModel):
    username: str = Field(min_length=1, max_length=32, pattern=USERNAME_PATTERN)
    password: str = Field(min_length=8, max_length=72)
    display_name: str = Field(default="", max_length=100)
    role: Literal["parent", "student"] = "parent"
    parent_id: Optional[uuid.UUID] = None
    child_name: Optional[str] = Field(default=None, max_length=100)


class ChildOut(BaseModel):
    model_config = {"from_attributes": True}

    id: uuid.UUID
    name: str
    student_user_id: Optional[uuid.UUID] = None
    # 家长端展示用：该孩子绑定的学生账号
    student_username: Optional[str] = None


class CreateChildIn(BaseModel):
    parent_id: uuid.UUID
    name: str = Field(min_length=1, max_length=100)


class BindStudentIn(BaseModel):
    """给已存在的孩子档案绑定/新建一个学生账号（保留历史记录）。"""

    username: str = Field(min_length=1, max_length=32, pattern=USERNAME_PATTERN)
    password: str = Field(min_length=8, max_length=72)
    display_name: str = Field(default="", max_length=100)


class AdminChildOut(BaseModel):
    id: uuid.UUID
    name: str
    student_username: Optional[str] = None


class AdminUserOut(BaseModel):
    id: uuid.UUID
    username: str
    display_name: str
    role: str = "parent"
    children: list[AdminChildOut] = Field(default_factory=list)


class ResetIn(BaseModel):
    scope: Literal["today", "all"]
    # 客户端本地日期（YYYY-MM-DD）；缺省时按服务端日期处理
    date: Optional[str] = Field(default=None, pattern=r"^\d{4}-\d{2}-\d{2}$")


class ResetOut(BaseModel):
    ok: bool = True
    scope: str


class SummaryRecentOut(BaseModel):
    date: str
    kind: str
    total: int = 0
    correct: int = 0
    pending: int = 0


class ChildSummaryOut(BaseModel):
    child_id: uuid.UUID
    child_name: str
    student_username: Optional[str] = None
    practice_days: int = 0
    total_questions: int = 0
    correct: int = 0
    wrong: int = 0
    blank: int = 0
    pending: int = 0
    recent: list[SummaryRecentOut] = Field(default_factory=list)


class JournalPut(BaseModel):
    revision: Optional[int] = None
    payload: dict[str, Any]

    @field_validator("payload")
    @classmethod
    def _limit_payload(cls, value: dict[str, Any]) -> dict[str, Any]:
        """单行 JSONB 全量重写，必须在入口挡住异常大的请求体。"""
        size = len(json.dumps(value, ensure_ascii=False))
        if size > MAX_PAYLOAD_BYTES:
            raise ValueError(
                f"练习记录过大（{size} 字节，上限 {MAX_PAYLOAD_BYTES}）"
            )
        return value


class JournalOut(BaseModel):
    model_config = {"from_attributes": True}

    child_id: uuid.UUID
    revision: int
    payload: dict[str, Any]
    updated_at: datetime


class PresenceIn(BaseModel):
    """孩子端心跳。只上报素材，状态由服务端推导。"""

    # 客户端本地日期，避免服务器时区与本机不一致时记到别的日子
    date: Optional[str] = Field(default=None, pattern=r"^\d{4}-\d{2}-\d{2}$")
    practice_id: Optional[str] = Field(default=None, max_length=64)
    # 页面当前是否可见（切到别的标签页 / 最小化时为 False）
    visible: bool = True
    # 距最近一次落笔多少秒；本次练习还没落笔时为 None。
    # 上报时间差而不是布尔值：布尔值一旦为真就永远为真，
    # 停笔的孩子会被一直算作「正在练习」。
    last_stroke_age_seconds: Optional[int] = Field(
        default=None, ge=0, le=86_400 * 7
    )
    # 以下均为累计值，服务端只取最大值
    strokes: int = Field(default=0, ge=0, le=1_000_000)
    away_count: int = Field(default=0, ge=0, le=1_000_000)
    away_seconds: int = Field(default=0, ge=0, le=86_400 * 7)
    active_seconds: int = Field(default=0, ge=0, le=86_400 * 7)
    # 今日是否已完成（提交后不再算「在练习」）
    done: bool = False


class PresenceOut(BaseModel):
    child_id: uuid.UUID
    child_name: Optional[str] = None
    day: Optional[str] = None
    state: str = "offline"
    practice_id: Optional[str] = None
    online_seconds: Optional[int] = None
    away_seconds_now: Optional[int] = None
    strokes: int = 0
    away_count: int = 0
    away_seconds: int = 0
    active_seconds: int = 0
    done: bool = False
    last_seen_at: Optional[datetime] = None

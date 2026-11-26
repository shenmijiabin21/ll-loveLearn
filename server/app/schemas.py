import uuid
from datetime import datetime
from typing import Any, Literal, Optional

from pydantic import BaseModel, Field

# 用户名：仅英文和数字
USERNAME_PATTERN = r"^[a-zA-Z0-9]{1,32}$"


class LoginIn(BaseModel):
    account: str = Field(min_length=1, max_length=32)
    password: str


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


class JournalOut(BaseModel):
    model_config = {"from_attributes": True}

    child_id: uuid.UUID
    revision: int
    payload: dict[str, Any]
    updated_at: datetime

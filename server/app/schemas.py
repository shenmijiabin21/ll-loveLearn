import uuid
from datetime import datetime
from typing import Any, Optional

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


class TokenOut(BaseModel):
    access_token: str
    token_type: str = "bearer"
    user: UserOut


class CreateUserIn(BaseModel):
    username: str = Field(min_length=1, max_length=32, pattern=USERNAME_PATTERN)
    password: str = Field(min_length=8, max_length=72)
    display_name: str = Field(default="", max_length=100)


class ChildOut(BaseModel):
    model_config = {"from_attributes": True}
    id: uuid.UUID
    name: str


class CreateChildIn(BaseModel):
    parent_id: uuid.UUID
    name: str = Field(min_length=1, max_length=100)


class ParentOut(BaseModel):
    id: uuid.UUID
    username: str
    display_name: str
    children: list[ChildOut] = []


class JournalPut(BaseModel):
    revision: Optional[int] = None
    payload: dict[str, Any]


class JournalOut(BaseModel):
    model_config = {"from_attributes": True}
    child_id: uuid.UUID
    revision: int
    payload: dict[str, Any]
    updated_at: datetime

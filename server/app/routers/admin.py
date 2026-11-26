import uuid
from typing import Optional

from fastapi import APIRouter, Depends, HTTPException
from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from ..database import get_db
from ..deps import get_current_admin
from ..models import ROLE_PARENT, ROLE_STUDENT, Child, User
from ..schemas import (
    AdminChildOut,
    AdminUserOut,
    BindStudentIn,
    ChildOut,
    CreateChildIn,
    CreateUserIn,
    UserOut,
)
from ..security import hash_password

router = APIRouter(
    prefix="/admin", tags=["admin"], dependencies=[Depends(get_current_admin)]
)


@router.get("/users", response_model=list[AdminUserOut])
async def list_users(db: AsyncSession = Depends(get_db)):
    # 只列家长：学生账号挂在各自家长的 children 条目里（student_username），
    # 单独再列一行会造成重复展示。
    users = list(
        await db.scalars(
            select(User)
            .where(User.is_admin.is_(False), User.role != ROLE_STUDENT)
            .order_by(User.created_at)
        )
    )
    children = list(await db.scalars(select(Child).order_by(Child.created_at)))

    student_ids = {
        child.student_user_id
        for child in children
        if child.student_user_id is not None
    }
    usernames: dict[uuid.UUID, str] = {}
    if student_ids:
        rows = await db.execute(
            select(User.id, User.username).where(User.id.in_(student_ids))
        )
        usernames = {row[0]: row[1] for row in rows}

    grouped: dict[uuid.UUID, list[AdminChildOut]] = {}
    for child in children:
        student_username: Optional[str] = None
        if child.student_user_id is not None:
            student_username = usernames.get(child.student_user_id)
        grouped.setdefault(child.user_id, []).append(
            AdminChildOut(
                id=child.id,
                name=child.name,
                student_username=student_username,
            )
        )

    return [
        AdminUserOut(
            id=user.id,
            username=user.username,
            display_name=user.display_name,
            role=user.role_or_default,
            children=grouped.get(user.id, []),
        )
        for user in users
    ]


@router.post("/users", response_model=UserOut, status_code=201)
async def create_user(body: CreateUserIn, db: AsyncSession = Depends(get_db)):
    username = body.username.strip()
    existing = await db.scalar(select(User).where(User.username == username))
    if existing is not None:
        raise HTTPException(409, "该账号已存在")

    if body.role == ROLE_STUDENT:
        if body.parent_id is None:
            raise HTTPException(400, "创建学生账号需要指定家长")
        child_name = (body.child_name or "").strip()
        if not child_name:
            raise HTTPException(400, "创建学生账号需要指定孩子姓名")
        parent = await db.get(User, body.parent_id)
        if parent is None or parent.is_admin:
            raise HTTPException(404, "家长账号不存在")
        if parent.role_or_default != ROLE_PARENT:
            raise HTTPException(400, "指定的账号不是家长")
        # 学生账号与孩子档案在同一事务内创建
        student = User(
            username=username,
            password_hash=hash_password(body.password),
            display_name=body.display_name or child_name,
            is_admin=False,
            role=ROLE_STUDENT,
            parent_id=parent.id,
        )
        db.add(student)
        await db.flush()
        db.add(
            Child(
                user_id=parent.id,
                student_user_id=student.id,
                name=child_name,
            )
        )
        await db.commit()
        await db.refresh(student)
        return UserOut.of(student)

    user = User(
        username=username,
        password_hash=hash_password(body.password),
        display_name=body.display_name,
        is_admin=False,
        role=ROLE_PARENT,
    )
    db.add(user)
    await db.commit()
    await db.refresh(user)
    return UserOut.of(user)


@router.post("/children/{child_id}/student", response_model=UserOut, status_code=201)
async def bind_student(
    child_id: uuid.UUID,
    body: BindStudentIn,
    db: AsyncSession = Depends(get_db),
):
    """给已有孩子档案绑定学生账号，保留其历史练习记录。

    场景：孩子档案先建好了（甚至已有练习记录），之后才要开学生登录。
    """
    child = await db.get(Child, child_id)
    if child is None:
        raise HTTPException(404, "孩子不存在")
    if child.student_user_id is not None:
        raise HTTPException(409, "该孩子已绑定学生账号")
    username = body.username.strip()
    existing = await db.scalar(select(User).where(User.username == username))
    if existing is not None:
        raise HTTPException(409, "该账号已存在")
    parent = await db.get(User, child.user_id)
    if parent is None:
        raise HTTPException(404, "家长账号不存在")
    student = User(
        username=username,
        password_hash=hash_password(body.password),
        display_name=body.display_name or child.name,
        role=ROLE_STUDENT,
        parent_id=parent.id,
    )
    db.add(student)
    await db.flush()
    child.student_user_id = student.id
    await db.commit()
    await db.refresh(student)
    return UserOut.of(student)


@router.post("/children", response_model=ChildOut, status_code=201)
async def create_child(body: CreateChildIn, db: AsyncSession = Depends(get_db)):
    parent = await db.get(User, body.parent_id)
    if parent is None or parent.is_admin:
        raise HTTPException(404, "家长账号不存在")
    child = Child(user_id=parent.id, name=body.name)
    db.add(child)
    await db.commit()
    await db.refresh(child)
    return child

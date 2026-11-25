from fastapi import APIRouter, Depends, HTTPException
from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from ..database import get_db
from ..deps import get_current_admin
from ..models import Child, User
from ..schemas import ChildOut, CreateChildIn, CreateUserIn, ParentOut, UserOut
from ..security import hash_password

router = APIRouter(
    prefix="/admin", tags=["admin"], dependencies=[Depends(get_current_admin)]
)


@router.get("/users", response_model=list[ParentOut])
async def list_parents(db: AsyncSession = Depends(get_db)):
    parents = await db.scalars(
        select(User).where(User.is_admin == False).order_by(User.created_at)
    )
    result = []
    for p in parents:
        children = await db.scalars(
            select(Child).where(Child.user_id == p.id).order_by(Child.created_at)
        )
        result.append(
            ParentOut(
                id=p.id,
                username=p.username,
                display_name=p.display_name,
                children=[ChildOut.model_validate(c) for c in children],
            )
        )
    return result


@router.post("/users", response_model=UserOut, status_code=201)
async def create_parent(body: CreateUserIn, db: AsyncSession = Depends(get_db)):
    username = body.username.strip()
    existing = await db.scalar(select(User).where(User.username == username))
    if existing is not None:
        raise HTTPException(409, "该账号已存在")
    user = User(
        username=username,
        password_hash=hash_password(body.password),
        display_name=body.display_name,
        is_admin=False,
    )
    db.add(user)
    await db.commit()
    await db.refresh(user)
    return user


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

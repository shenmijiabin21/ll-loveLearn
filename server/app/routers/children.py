from fastapi import APIRouter, Depends
from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from ..database import get_db
from ..deps import get_current_user
from ..models import Child, User
from ..schemas import ChildOut

router = APIRouter(prefix="/children", tags=["children"])


@router.get("", response_model=list[ChildOut])
async def list_children(
    user: User = Depends(get_current_user), db: AsyncSession = Depends(get_db)
):
    result = await db.scalars(
        select(Child).where(Child.user_id == user.id).order_by(Child.created_at)
    )
    return list(result)

from fastapi import APIRouter, Depends, HTTPException
from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from ..database import get_db
from ..deps import ensure_child_access, get_current_user, load_child
from ..models import Journal, User
from ..schemas import JournalOut, JournalPut

router = APIRouter(prefix="/children", tags=["journal"])


@router.get("/{child_id}/journal", response_model=JournalOut)
async def get_journal(
    child_id: str,
    user: User = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    child = await load_child(child_id, db)
    ensure_child_access(child, user)
    journal = await db.scalar(select(Journal).where(Journal.child_id == child.id))
    if journal is None:
        raise HTTPException(404, "暂无记录")
    return journal


@router.put("/{child_id}/journal", response_model=JournalOut)
async def put_journal(
    child_id: str,
    body: JournalPut,
    user: User = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    child = await load_child(child_id, db)
    ensure_child_access(child, user)
    # FOR UPDATE 防止并发覆盖，revision 做乐观锁
    journal = await db.scalar(
        select(Journal).where(Journal.child_id == child.id).with_for_update()
    )
    if journal is None:
        journal = Journal(child_id=child.id, revision=1, payload=body.payload)
        db.add(journal)
    else:
        if body.revision is not None and body.revision != journal.revision:
            raise HTTPException(409, "记录已被其他窗口修改，请刷新")
        journal.revision += 1
        journal.payload = body.payload
    await db.commit()
    await db.refresh(journal)
    return journal

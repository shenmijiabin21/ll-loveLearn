from fastapi import APIRouter, Depends, HTTPException
from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from ..database import get_db
from ..deps import ensure_child_access, get_current_user, load_child
from ..live import hub
from ..models import Child, Journal, User
from ..schemas import JournalOut, JournalPut

router = APIRouter(prefix="/children", tags=["journal"])


def _progress(payload: object) -> dict:
    """从整份练习记录里取出家长端要看的进度（当前题号 / 已写题数）。"""
    draft = payload.get("draft") if isinstance(payload, dict) else None
    if not isinstance(draft, dict):
        return {"submitted": True}

    answers = draft.get("answers")
    answers = answers if isinstance(answers, list) else []

    def written(answer: object) -> bool:
        if not isinstance(answer, dict):
            return False
        cells = answer.get("cells")
        if isinstance(cells, list) and cells:
            return any(isinstance(cell, list) and cell for cell in cells)
        ink = answer.get("ink")
        return isinstance(ink, list) and bool(ink)

    try:
        index = int(draft.get("index") or 0) + 1
    except (TypeError, ValueError):
        index = 0
    return {
        "practice_id": draft.get("id"),
        "index": min(index, len(answers)) if answers else 0,
        "total": len(answers),
        "written": sum(1 for answer in answers if written(answer)),
        "submitted": False,
    }


async def _publish_progress(child: Child, payload: object) -> None:
    """孩子每存一次笔迹就推一次进度，家长端因此能看到「正在写第几题」。"""
    try:
        await hub.publish(
            {"type": "progress", **_progress(payload)},
            parent_user_id=child.user_id,
            student_user_id=child.student_user_id,
            child_id=child.id,
        )
    except Exception:  # 推送失败不能影响保存
        pass


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
    # commit 之后再推：家长看到的必须是已经落盘的状态
    await _publish_progress(child, journal.payload)
    return journal

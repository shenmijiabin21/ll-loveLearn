"""孩子端上报心跳、家长端查看「是否正在练习」。

状态永远由服务端按时间差推导（见 app/presence.py），客户端只提供素材。
这样孩子关掉网页或断网后，家长端不需要任何「结束」消息也能看到离线。
"""

import uuid
from datetime import date, datetime, timedelta, timezone

from fastapi import APIRouter, Depends
from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from ..database import get_db
from ..deps import ensure_child_access, get_current_user, is_admin, load_child
from ..models import ROLE_STUDENT, Child, Presence, User
from ..presence import derive_from_row
from ..schemas import PresenceIn, PresenceOut

router = APIRouter(prefix="/children", tags=["presence"])


def _today() -> str:
    # 服务器本地日期，与 children._today() 一致
    return date.today().isoformat()


def _as_out(child: Child, row: Presence | None, day: str) -> PresenceOut:
    state, online, away_now = derive_from_row(row)
    if row is None:
        return PresenceOut(child_id=child.id, child_name=child.name, day=day, state=state)
    return PresenceOut(
        child_id=child.id,
        child_name=child.name,
        day=row.day,
        state=state,
        practice_id=row.practice_id,
        online_seconds=online,
        away_seconds_now=away_now,
        strokes=row.strokes or 0,
        away_count=row.away_count or 0,
        away_seconds=row.away_seconds or 0,
        active_seconds=row.active_seconds or 0,
        done=False,
        last_seen_at=row.last_seen_at,
    )


@router.post("/{child_id}/presence", response_model=PresenceOut)
async def report_presence(
    child_id: str,
    body: PresenceIn,
    user: User = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    """孩子端心跳。服务端只记录素材，并回传推导后的状态。"""
    child = await load_child(child_id, db)
    ensure_child_access(child, user)

    day = body.date or _today()
    now = datetime.now(timezone.utc)

    row = await db.get(Presence, (child.id, day))
    if row is None:
        row = Presence(child_id=child.id, day=day)
        db.add(row)

    previous_practice = row.practice_id
    row.last_seen_at = now
    row.practice_id = body.practice_id

    # 换了一次练习：落笔时间清零，避免上组练习的笔迹把新练习判成 practicing
    if body.practice_id != previous_practice:
        row.last_stroke_at = None

    # 客户端只给「距上次落笔多少秒」，由服务端换算成绝对时间。
    # 用相对值而不是绝对时间戳，可以避开孩子设备时钟不准的问题。
    if body.last_stroke_age_seconds is not None:
        row.last_stroke_at = now - timedelta(seconds=body.last_stroke_age_seconds)

    # 离开状态只由客户端明确告知时切换；页面重新可见即清空
    if body.visible:
        row.away_since = None
    elif row.away_since is None:
        row.away_since = now

    # 累计值取最大值：重复投递或乱序不会把数字改小
    row.strokes = max(row.strokes or 0, body.strokes)
    row.away_count = max(row.away_count or 0, body.away_count)
    row.away_seconds = max(row.away_seconds or 0, body.away_seconds)
    row.active_seconds = max(row.active_seconds or 0, body.active_seconds)

    await db.commit()
    return _as_out(child, row, day)


@router.get("/{child_id}/presence", response_model=PresenceOut)
async def get_presence(
    child_id: str,
    user: User = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    child = await load_child(child_id, db)
    ensure_child_access(child, user)
    day = _today()
    row = await db.get(Presence, (child.id, day))
    return _as_out(child, row, day)


@router.get("/presence", response_model=list[PresenceOut])
async def list_presence(
    user: User = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    """家长列表页一次拿全，避免每个孩子各发一次请求。"""
    stmt = select(Child)
    if not is_admin(user):
        if user.role_or_default == ROLE_STUDENT:
            stmt = stmt.where(Child.student_user_id == user.id)
        else:
            stmt = stmt.where(Child.user_id == user.id)
    children = list(await db.scalars(stmt.order_by(Child.created_at)))
    if not children:
        return []

    day = _today()
    rows = await db.scalars(
        select(Presence).where(
            Presence.child_id.in_([c.id for c in children]),
            Presence.day == day,
        )
    )
    by_child: dict[uuid.UUID, Presence] = {row.child_id: row for row in rows}
    return [_as_out(child, by_child.get(child.id), day) for child in children]

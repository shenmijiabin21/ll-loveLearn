"""孩子端上报心跳、家长端读取「是否正在练习」。

状态永远由服务端按时间差推导（见 app/presence.py），客户端只提供素材。
这样孩子关掉网页或断网后，家长端不需要任何「结束」消息也能看到离线。

实时通道：每次上报成功都会向 WebSocket 订阅者推一条 presence 事件
（见 app/live.py 与 app/routers/live.py），所以家长端看到的是推送到达的
那一刻，而不是轮询的下一个周期。REST 接口保留下来做首屏与断线兜底。
"""

import uuid
from datetime import date, datetime, timedelta, timezone

from fastapi import APIRouter, Depends
from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from ..database import get_db
from ..deps import ensure_child_access, get_current_user, is_admin, load_child
from ..live import hub
from ..models import ROLE_STUDENT, Child, Presence, User
from ..presence import derive_from_row
from ..schemas import PresenceIn, PresenceOut

router = APIRouter(prefix="/children", tags=["presence"])


def _today() -> str:
    # 服务器本地日期，与 children._today() 一致
    return date.today().isoformat()


def to_out(child: Child, row: Presence | None, day: str) -> PresenceOut:
    state, online, away_now = derive_from_row(row)
    base = PresenceOut(
        child_id=child.id,
        child_name=child.name,
        day=row.day if row is not None else day,
        state=state,
        online_seconds=online,
        away_seconds_now=away_now,
    )
    if row is None:
        return base
    return base.model_copy(
        update={
            "practice_id": row.practice_id,
            "strokes": row.strokes or 0,
            "away_count": row.away_count or 0,
            "away_seconds": row.away_seconds or 0,
            "active_seconds": row.active_seconds or 0,
            "done": bool(row.done),
            "last_seen_at": row.last_seen_at,
        }
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
    row.done = body.done

    # 换了一次练习：落笔时间清零，避免上组练习的笔迹把新练习判成 practicing
    if body.practice_id != previous_practice:
        row.last_stroke_at = None
        # 新练习开始（或提交后 practice_id 归空）时，完成标记以本次上报为准
        row.done = body.done

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

    out = to_out(child, row, day)
    await hub.publish(
        {"type": "presence", "presence": out.model_dump(mode="json")},
        parent_user_id=child.user_id,
        student_user_id=child.student_user_id,
        child_id=child.id,
    )
    return out


@router.get("/presence", response_model=list[PresenceOut])
async def list_presence(
    user: User = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    """首屏 / 断线兜底：一次拿全，避免每个孩子各发一次请求。"""
    children = await visible_children(db, user)
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
    return [to_out(child, by_child.get(child.id), day) for child in children]


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
    return to_out(child, row, day)


async def visible_children(db: AsyncSession, user: User) -> list[Child]:
    """这个账号能看到的孩子：管理员全部，家长自己名下，学生自己绑定的。"""
    stmt = select(Child)
    if not is_admin(user):
        if user.role_or_default == ROLE_STUDENT:
            stmt = stmt.where(Child.student_user_id == user.id)
        else:
            stmt = stmt.where(Child.user_id == user.id)
    return list(await db.scalars(stmt.order_by(Child.created_at)))

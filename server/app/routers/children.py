from datetime import date
from typing import Any, Optional

from fastapi import APIRouter, Depends
from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from ..database import get_db
from ..deps import (
    ensure_child_access,
    get_current_user,
    is_admin,
    load_child,
)
from ..models import ROLE_STUDENT, Child, Journal, User
from ..schemas import (
    ChildOut,
    ChildSummaryOut,
    ResetIn,
    ResetOut,
    SummaryRecentOut,
)

router = APIRouter(prefix="/children", tags=["children"])

VERDICTS = ("correct", "wrong", "blank", "pending")
KIND_DAILY = "每日听写"
KIND_REVIEW = "重点复习"
RECENT_LIMIT = 20


@router.get("", response_model=list[ChildOut])
async def list_children(
    user: User = Depends(get_current_user), db: AsyncSession = Depends(get_db)
):
    stmt = select(Child)
    if not is_admin(user):
        if user.role_or_default == ROLE_STUDENT:
            stmt = stmt.where(Child.student_user_id == user.id)
        else:
            stmt = stmt.where(Child.user_id == user.id)
    children = list(await db.scalars(stmt.order_by(Child.created_at)))
    # 一次性取学生账号名，供家长端显示「学生账号 xxx」
    student_ids = {c.student_user_id for c in children if c.student_user_id}
    usernames: dict[uuid.UUID, str] = {}
    if student_ids:
        rows = await db.execute(
            select(User.id, User.username).where(User.id.in_(student_ids))
        )
        usernames = {row[0]: row[1] for row in rows}
    return [
        ChildOut(
            id=c.id,
            name=c.name,
            student_user_id=c.student_user_id,
            student_username=usernames.get(c.student_user_id)
            if c.student_user_id
            else None,
        )
        for c in children
    ]


def _today() -> str:
    # 服务器本地日期，与客户端 date 字段同为 YYYY-MM-DD
    return date.today().isoformat()


def _records(payload: Any) -> list[dict]:
    if not isinstance(payload, dict):
        return []
    history = payload.get("history")
    if not isinstance(history, list):
        return []
    return [item for item in history if isinstance(item, dict)]


def _answers(record: dict) -> list[dict]:
    answers = record.get("answers")
    if not isinstance(answers, list):
        return []
    return [item for item in answers if isinstance(item, dict)]


def _verdict(answer: dict) -> Optional[str]:
    # override 优先于 automatic，与客户端 Answer.verdict 一致
    value = answer.get("override")
    if not value:
        value = answer.get("automatic")
    return value if isinstance(value, str) else None


def _tally(record: dict) -> dict:
    counts = {verdict: 0 for verdict in VERDICTS}
    answers = _answers(record)
    for answer in answers:
        verdict = _verdict(answer)
        if verdict in counts:
            counts[verdict] += 1
    counts["total"] = len(answers)
    return counts


def _kind(record: dict) -> str:
    return KIND_DAILY if record.get("daily") else KIND_REVIEW


@router.get("/{child_id}/summary", response_model=ChildSummaryOut)
async def child_summary(
    child_id: str,
    user: User = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    child = await load_child(child_id, db)
    ensure_child_access(child, user)

    journal = await db.scalar(select(Journal).where(Journal.child_id == child.id))
    records = _records(journal.payload if journal is not None else None)

    totals = {verdict: 0 for verdict in VERDICTS}
    total_questions = 0
    days: set[str] = set()
    for record in records:
        tally = _tally(record)
        total_questions += tally["total"]
        for verdict in VERDICTS:
            totals[verdict] += tally[verdict]
        day = record.get("date")
        if isinstance(day, str) and day:
            days.add(day)

    ordered = sorted(records, key=lambda item: str(item.get("date") or ""), reverse=True)
    recent = []
    for record in ordered[:RECENT_LIMIT]:
        tally = _tally(record)
        recent.append(
            SummaryRecentOut(
                date=str(record.get("date") or ""),
                kind=_kind(record),
                total=tally["total"],
                correct=tally["correct"],
                pending=tally["pending"],
            )
        )

    student_username = None
    if child.student_user_id is not None:
        student_username = await db.scalar(
            select(User.username).where(User.id == child.student_user_id)
        )

    return ChildSummaryOut(
        child_id=child.id,
        child_name=child.name,
        student_username=student_username,
        practice_days=len(days),
        total_questions=total_questions,
        correct=totals["correct"],
        wrong=totals["wrong"],
        blank=totals["blank"],
        pending=totals["pending"],
        recent=recent,
    )


@router.post("/{child_id}/reset", response_model=ResetOut)
async def reset_child(
    child_id: str,
    body: ResetIn,
    user: User = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    child = await load_child(child_id, db)
    ensure_child_access(child, user)

    journal = await db.scalar(
        select(Journal).where(Journal.child_id == child.id).with_for_update()
    )
    if journal is None:
        return ResetOut(ok=True, scope=body.scope)

    if body.scope == "all":
        await db.delete(journal)
        await db.commit()
        return ResetOut(ok=True, scope=body.scope)

    payload = dict(journal.payload) if isinstance(journal.payload, dict) else {}
    history = payload.get("history")
    today = _today()
    if isinstance(history, list):
        payload["history"] = [
            item
            for item in history
            if not (isinstance(item, dict) and item.get("date") == today)
        ]
    else:
        payload["history"] = []
    payload["draft"] = None
    journal.payload = payload
    journal.revision = (journal.revision or 0) + 1
    await db.commit()
    return ResetOut(ok=True, scope=body.scope)

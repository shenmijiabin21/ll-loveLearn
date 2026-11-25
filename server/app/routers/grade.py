from fastapi import APIRouter, Depends
from fastapi.concurrency import run_in_threadpool
from pydantic import BaseModel, Field

from ..deps import get_current_user
from ..models import User
from ..recognition.raster import rasterize
from ..recognition.recognizer import get_recognizer

router = APIRouter(prefix="/grade", tags=["grade"])


class GradeItem(BaseModel):
    expected: str = Field(min_length=1, max_length=2)
    # 每笔一个点序列，点为 [x, y, t]；x/y 归一化到 [0,1]，t 为时间戳
    strokes: list[list[list[float]]]


class GradeIn(BaseModel):
    items: list[GradeItem] = Field(min_length=1, max_length=20)


class GradeResult(BaseModel):
    expected: str
    verdict: str
    candidates: list[str]


@router.post("", response_model=list[GradeResult])
async def grade(body: GradeIn, user: User = Depends(get_current_user)):
    recognizer = get_recognizer()
    results: list[GradeResult] = []
    for item in body.items:
        strokes = [s for s in item.strokes if s]
        if not strokes:
            results.append(
                GradeResult(expected=item.expected, verdict="blank", candidates=[])
            )
            continue
        valid = all(
            len(p) >= 2 and 0.0 <= p[0] <= 1.0 and 0.0 <= p[1] <= 1.0
            for s in strokes
            for p in s
        )
        if not valid:
            results.append(
                GradeResult(expected=item.expected, verdict="pending", candidates=[])
            )
            continue
        img = rasterize(strokes)
        out = await run_in_threadpool(recognizer.classify, item.expected, img)
        results.append(
            GradeResult(
                expected=item.expected,
                verdict=out["verdict"],
                candidates=out["candidates"],
            )
        )
    return results

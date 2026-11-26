"""由心跳素材推导「孩子此刻是否在练习」。

关键原则：状态由服务端按时间差计算，不采信客户端自报的状态。
孩子关掉网页、拔网线、强杀浏览器都不会再上报，超时后自然变成离线。

判定顺序（先命中先返回）：
    offline    最后心跳距今 > OFFLINE_AFTER，说明页面已经没了
    away       页面不可见（切标签页 / 最小化）
    idle       页面可见但很久没落笔，多用来抓「开着页面在干别的事」
    practicing 其余情况
"""

from datetime import datetime, timezone
from typing import Literal, Optional

PresenceState = Literal["practicing", "idle", "away", "offline"]

# 心跳超时：客户端每 30 秒至少上报一次，留 3 倍余量，
# 避免一次网络抖动就把家长端的「正在练习」闪成「不在页面」。
OFFLINE_AFTER_SECONDS = 90

# 页面可见但超过这个时长没有新笔迹，算「没在动」。
# 小学生写字时查字典、思考的停顿通常远短于这个值；
# 而把页面开着去看视频，笔迹会立刻停住。
IDLE_AFTER_SECONDS = 180

# 回顾窗口：超过多久没动静就不再展示「已离开 N 分钟」
STALE_AFTER_SECONDS = 6 * 3600


def _now() -> datetime:
    return datetime.now(timezone.utc)


def _elapsed(now: datetime, when: Optional[datetime]) -> Optional[float]:
    """秒数差。库里可能存成无时区的值，统一按 UTC 处理。"""
    if when is None:
        return None
    if when.tzinfo is None:
        when = when.replace(tzinfo=timezone.utc)
    return (now - when).total_seconds()


def derive_state(
    *,
    last_seen_at: Optional[datetime],
    last_stroke_at: Optional[datetime],
    away_since: Optional[datetime],
    now: Optional[datetime] = None,
) -> tuple[PresenceState, Optional[int], Optional[int]]:
    """返回 (状态, 在线秒数, 离开秒数)。后两者可能为 None。"""
    now = now or _now()
    since_seen = _elapsed(now, last_seen_at)

    if since_seen is None or since_seen > OFFLINE_AFTER_SECONDS:
        return "offline", None, None

    if away_since is not None:
        return "away", int(since_seen), int(_elapsed(now, away_since) or 0)

    since_stroke = _elapsed(now, last_stroke_at)
    if since_stroke is not None and since_stroke > IDLE_AFTER_SECONDS:
        return "idle", int(since_seen), 0

    return "practicing", int(since_seen), 0


def derive_from_row(row, now: Optional[datetime] = None):
    """Presence ORM 行的便捷包装。row 为 None 时视为从未上线。"""
    if row is None:
        return "offline", None, None
    return derive_state(
        last_seen_at=row.last_seen_at,
        last_stroke_at=row.last_stroke_at,
        away_since=row.away_since,
        now=now,
    )


def is_fresh(last_seen_at: Optional[datetime], now: Optional[datetime] = None) -> bool:
    """今天这一行是否值得展示（太久以前的不再显示状态）。"""
    elapsed = _elapsed(now or _now(), last_seen_at)
    return elapsed is not None and elapsed < STALE_AFTER_SECONDS

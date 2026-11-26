"""在线状态推导的单元测试。

这些阈值决定了家长端会看到「正在练习」还是「不在页面」，
所以边界必须钉死——改动 app/presence.py 的常量时要同步改这里。
"""

from datetime import datetime, timedelta, timezone

from app.presence import (
    IDLE_AFTER_SECONDS,
    OFFLINE_AFTER_SECONDS,
    derive_state,
)

NOW = datetime(2026, 11, 26, 12, 0, 0, tzinfo=timezone.utc)


def at(**kwargs):
    return NOW - timedelta(**kwargs)


def test_never_reported_is_offline():
    state, online, away = derive_state(
        last_seen_at=None, last_stroke_at=None, away_since=None, now=NOW
    )
    assert state == "offline"
    assert online is None
    assert away is None


def test_fresh_heartbeat_with_recent_stroke_is_practicing():
    state, online, away = derive_state(
        last_seen_at=at(seconds=10),
        last_stroke_at=at(seconds=5),
        away_since=None,
        now=NOW,
    )
    assert state == "practicing"
    assert online == 10
    assert away == 0


def test_heartbeat_timeout_beats_everything_else():
    # 页面可见性问题不重要：心跳都断了，说明页面已经没了
    state, _, _ = derive_state(
        last_seen_at=at(seconds=OFFLINE_AFTER_SECONDS + 1),
        last_stroke_at=at(seconds=1),
        away_since=None,
        now=NOW,
    )
    assert state == "offline"


def test_exactly_at_timeout_still_online():
    # 边界包含：正好 90 秒还算在线，避免一次网络抖动就闪成离线
    state, _, _ = derive_state(
        last_seen_at=at(seconds=OFFLINE_AFTER_SECONDS),
        last_stroke_at=at(seconds=1),
        away_since=None,
        now=NOW,
    )
    assert state == "practicing"


def test_long_gap_without_stroke_is_idle():
    state, _, _ = derive_state(
        last_seen_at=at(seconds=5),
        last_stroke_at=at(seconds=IDLE_AFTER_SECONDS + 1),
        away_since=None,
        now=NOW,
    )
    assert state == "idle"


def test_no_stroke_yet_is_not_idle():
    # 刚开始练习还没落笔：不能立刻判成发呆
    state, _, _ = derive_state(
        last_seen_at=at(seconds=5), last_stroke_at=None, away_since=None, now=NOW
    )
    assert state == "practicing"


def test_away_wins_over_idle():
    state, online, away = derive_state(
        last_seen_at=at(seconds=20),
        last_stroke_at=at(minutes=30),
        away_since=at(seconds=15),
        now=NOW,
    )
    assert state == "away"
    assert online == 20
    assert away == 15


def test_away_expires_with_heartbeat():
    # 离开中但心跳也停了：离线优先，家长端不该一直显示「已离开」在涨时间
    state, _, _ = derive_state(
        last_seen_at=at(minutes=5),
        last_stroke_at=at(minutes=30),
        away_since=at(minutes=5),
        now=NOW,
    )
    assert state == "offline"


def test_naive_datetime_is_treated_as_utc():
    # Postgres 可能返回不带时区的值，不能让比较直接抛异常
    state, _, _ = derive_state(
        last_seen_at=at(seconds=5).replace(tzinfo=None),
        last_stroke_at=at(seconds=1).replace(tzinfo=None),
        away_since=None,
        now=NOW,
    )
    assert state == "practicing"

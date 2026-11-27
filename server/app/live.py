"""WebSocket 实时推送中心（进程内单实例实现）。

家长端不再轮询：连一条 WebSocket 坐等推送。孩子每次上报心跳、落笔保存、
换题或提交，服务端立刻把最新状态推给所有关心这个孩子的连接。

为什么把「谁能看谁」放在发布侧判断：
    连接本身只记 user_id 与 is_admin，发布时才用孩子的 parent/student 关系
    过滤。这样管理员新建孩子、家长被重新绑定之后，已有连接立刻生效，
    不需要重连或重新订阅。

多实例部署时这里要换成 Redis pub/sub 之类的跨进程通道；当前只有一台服务器。
"""

from __future__ import annotations

import json
import logging
import uuid
from typing import Any, Optional

from fastapi import WebSocket

log = logging.getLogger("uvicorn.error")


class _Conn:
    """一条家长端连接。"""

    __slots__ = ("ws", "user_id", "is_admin")

    def __init__(self, ws: WebSocket, user_id: uuid.UUID, is_admin: bool) -> None:
        self.ws = ws
        self.user_id = user_id
        self.is_admin = is_admin


class Hub:
    def __init__(self) -> None:
        self._conns: set[_Conn] = set()

    @property
    def size(self) -> int:
        return len(self._conns)

    def register(
        self, ws: WebSocket, *, user_id: uuid.UUID, is_admin: bool
    ) -> _Conn:
        conn = _Conn(ws, user_id, is_admin)
        self._conns.add(conn)
        return conn

    def unregister(self, conn: _Conn) -> None:
        self._conns.discard(conn)

    def _allows(
        self,
        conn: _Conn,
        parent_user_id: Optional[uuid.UUID],
        student_user_id: Optional[uuid.UUID],
    ) -> bool:
        if conn.is_admin:
            return True
        if parent_user_id is not None and conn.user_id == parent_user_id:
            return True
        if student_user_id is not None and conn.user_id == student_user_id:
            return True
        return False

    async def publish(
        self,
        event: dict[str, Any],
        *,
        parent_user_id: Optional[uuid.UUID] = None,
        student_user_id: Optional[uuid.UUID] = None,
        child_id: Optional[uuid.UUID] = None,
    ) -> int:
        """把事件推给能看到这个孩子的人，返回实际送达的连接数。"""
        if not self._conns:
            return 0
        payload = dict(event)
        if child_id is not None:
            payload.setdefault("child_id", str(child_id))
        text = json.dumps(payload, ensure_ascii=False)
        targets = [
            conn
            for conn in list(self._conns)
            if self._allows(conn, parent_user_id, student_user_id)
        ]
        sent = 0
        for conn in targets:
            try:
                await conn.ws.send_text(text)
                sent += 1
            except Exception:  # 连接已断/正在关闭，直接摘掉，不影响其它连接
                self.unregister(conn)
        return sent


hub = Hub()

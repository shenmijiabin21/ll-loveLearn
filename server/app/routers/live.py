"""家长端实时通道：一条 WebSocket 收全部推送。

`/ws/live?token=JWT`——浏览器不能给 WebSocket 带自定义请求头，所以令牌走查询
参数（连接建立后立即校验签名、账号与 token_version）。

首帧推 `snapshot`（当前所有可见孩子的在线状态），之后由服务端主动推：
    presence  孩子心跳 / 落笔保存 / 切走页面
    progress  孩子的练习进度（第几题、已写几题、是否已提交）

为什么还要每 TICK_SECONDS 补推一次 snapshot：
    「正在练习 → 空闲 → 离线」是时间流逝造成的，没有任何客户端事件可以触发，
    只能由服务端按时间差重新推导后补一帧。
"""

import asyncio
import json
import logging
import uuid

from fastapi import APIRouter, WebSocket, WebSocketDisconnect
from sqlalchemy import select

from ..database import SessionLocal
from ..deps import is_admin
from ..live import hub
from ..models import Presence, User
from ..security import decode_access_token
from .presence import _today, to_out, visible_children

router = APIRouter(tags=["live"])
log = logging.getLogger("uvicorn.error")

# 补推间隔：比离线阈值（90 秒）短，也足够让「已练 N 分钟」动起来
TICK_SECONDS = 10


async def snapshot(user_id: uuid.UUID) -> dict:
    async with SessionLocal() as db:
        user = await db.get(User, user_id)
        if user is None:
            return {"type": "snapshot", "presence": []}
        children = await visible_children(db, user)
        day = _today()
        rows = []
        if children:
            rows = list(
                await db.scalars(
                    select(Presence).where(
                        Presence.child_id.in_([c.id for c in children]),
                        Presence.day == day,
                    )
                )
            )
        by_child = {row.child_id: row for row in rows}
        return {
            "type": "snapshot",
            "presence": [
                to_out(child, by_child.get(child.id), day).model_dump(mode="json")
                for child in children
            ],
        }


@router.websocket("/ws/live")
async def live(ws: WebSocket):
    claims = decode_access_token(ws.query_params.get("token") or "")
    user_id: uuid.UUID | None = None
    if claims is not None:
        try:
            user_id = uuid.UUID(str(claims.get("sub")))
        except (TypeError, ValueError):
            user_id = None
    if user_id is None:
        await ws.close(code=4401)
        return

    async with SessionLocal() as db:
        user = await db.get(User, user_id)
        if user is None or int(claims.get("ver") or 0) != int(user.token_version or 0):
            await ws.close(code=4401)
            return
        admin = is_admin(user)

    await ws.accept()
    conn = hub.register(ws, user_id=user_id, is_admin=admin)
    try:
        await ws.send_text(json.dumps(await snapshot(user_id), ensure_ascii=False))
        while True:
            try:
                message = await asyncio.wait_for(
                    ws.receive_text(), timeout=TICK_SECONDS
                )
            except asyncio.TimeoutError:
                await ws.send_text(
                    json.dumps(await snapshot(user_id), ensure_ascii=False)
                )
                continue
            # 客户端只用 ping 探活；状态变更一律由服务端主动推
            if message == "ping":
                await ws.send_text('{"type":"pong"}')
    except WebSocketDisconnect:
        pass
    except Exception as error:  # 连接被对端掐断、写失败等
        log.info("实时通道断开：%s", error)
    finally:
        hub.unregister(conn)

# 每日听写 后端 API

FastAPI + PostgreSQL + RapidOCR（onnxruntime 手写识别，可选）。

> 识别只跑识别网络（`use_det=False`）：整格栅格图会被文字检测判成无文字，
> 导致结果全为待确认。预处理为细笔画 + 大留白，并用双渲染取最优置信度。

## 本地开发

```sh
cd server
python -m venv .venv
# Windows 激活：.venv\Scripts\activate
pip install -r requirements.txt                 # 核心 API
pip install -r requirements-recognition.txt      # 可选：手写识别
cp .env.example .env                              # 改 JWT_SECRET 等
uvicorn app.main:app --reload
```

需要本地 PostgreSQL（默认连 `localhost:5432/dictation`）。表在启动时自动创建。

## 接口

认证（账号由管理员创建，没有自助注册）：

- `POST /auth/login` —— 同一账号 5 分钟内失败 10 次会返回 429
- `GET  /auth/me`
- `POST /auth/password` —— 改密后递增 `token_version`，其它设备的旧令牌立即失效
- `POST /auth/logout` —— 注销全部设备

孩子与记录：

- `GET  /children` —— admin 全量；家长看自己名下；学生看绑定的那一个
- `GET  /children/{id}/summary` —— 练习天数、正确率、最近记录
- `POST /children/{id}/reset` —— `scope=today|all`，可带客户端本地 `date`
- `GET/PUT /children/{id}/journal` —— JSONB + revision 乐观锁，单条上限 16MB

管理端（需 admin）：

- `GET  /admin/users` —— 家长列表及其孩子
- `POST /admin/users` —— 建家长，或 `role=student` 时同时建孩子档案
- `POST /admin/children` —— 只建孩子档案（之后再单独开通学生登录）
- `POST /admin/children/{id}/student` —— 给已有档案补绑学生账号，保留历史记录

其他：

- `POST /grade` —— 笔迹 -> 栅格化 -> 识别 -> verdict；`items` 每项是一个田字格的笔迹（`expected` 为这一格应该写的字），默写词语时按字逐个提交；`allowed` 为本次练习涉及的候选字集合（最多 120 项 / 200 字）

家长端实时监控：

- `POST /children/{id}/presence` —— 孩子端心跳，只报素材（可见性、距上次落笔多少秒、累计笔数/时长、今天是否已提交），**状态由服务端按时间差推导**，客户端自报的状态不作数；每次上报成功都会立刻向 WebSocket 订阅者推 `presence`
- `GET  /children/presence` —— 首屏与断线兜底，一次取全部可见孩子的状态
- `GET  /children/{id}/presence` —— 单个孩子
- `WS   /ws/live?token=JWT` —— 家长端实时通道。首帧 `snapshot`（全部可见孩子的状态），之后服务端主动推 `presence`（状态变化）与 `progress`（第几题 / 已写几题 / 是否已提交），每 10 秒补推一次 snapshot，让「正在练习 → 空闲 → 离线」随时间自然过渡。浏览器不能给 WebSocket 带自定义头，所以令牌走查询参数，连接后立即校验签名与 `token_version`
- 状态取值：`practicing` 在写 / `idle` 开着页面但停笔超过 180 秒 / `away` 切走页面 / `done` 今天这一组已提交 / `offline` 心跳超时 90 秒
- `GET  /health` —— 顺带检查数据库连通性

接口文档：启动后访问 `http://localhost:8000/docs`。

## 数据模型

```
users    (id, email, username, password_hash, display_name, is_admin,
          token_version, role, parent_id, created_at)
children (id, user_id, student_user_id, name, created_at)
journals (child_id, revision, payload jsonb, updated_at)
```

表在启动时自动创建（`create_all`）。已有库新增列的情况请手动补：

```sql
ALTER TABLE users ADD COLUMN IF NOT EXISTS token_version BIGINT NOT NULL DEFAULT 0;
```

每个孩子一行 `journals`，`payload` 即前端 `Journal` 的 JSON（字库/草稿/历史/笔迹）。

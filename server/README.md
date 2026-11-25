# 每日听写 后端 API

FastAPI + PostgreSQL + RapidOCR（onnxruntime 手写识别，可选）。

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

- `POST /auth/register`、`POST /auth/login`
- `GET/POST /children`、`PATCH/DELETE /children/{id}`
- `GET/PUT /children/{id}/journal`（JSONB + revision 乐观锁）
- `POST /grade`（笔迹 -> 栅格化 -> 识别 -> verdict）
- `GET /health`

接口文档：启动后访问 `http://localhost:8000/docs`。

## 数据模型

```
users    (id, email, password_hash, display_name, created_at)
children (id, user_id, name, created_at)
journals (child_id, revision, payload jsonb, updated_at)
```

每个孩子一行 `journals`，`payload` 即前端 `Journal` 的 JSON（字库/草稿/历史/笔迹）。

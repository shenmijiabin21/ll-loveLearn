# 部署指南（云服务器）

## 前置
- 一台云服务器（2C2G 即可，识别用 ONNX runtime 内存约 100-150MB；建议加 2GB swap 兜底）
- 安装 Docker + Docker Compose 插件
- 一个域名（可选；有域名才能自动 HTTPS）

## 一、本地构建前端
在项目根目录执行（需要 Flutter SDK）：

```sh
flutter pub get --enforce-lockfile
flutter build web --release --no-pub
```

产物在 `build/web`，docker-compose 会把它挂载给 Caddy。

> 开发联调：`flutter run -d chrome --dart-define=API_BASE_URL=http://localhost:8000`
> 生产同源：不传 `API_BASE_URL`，前端默认请求 `/api/*`，由 Caddy 反代到后端。

## 二、配置环境变量
在项目根目录新建 `.env`（供 docker-compose 读取）：

```
# 服务器域名；留空或 localhost 则只开 HTTP
DOMAIN=dictation.example.com
# JWT 密钥，务必改成长随机字符串
JWT_SECRET=改成一个长随机串
# 识别阈值，可后调
MIN_CONF=0.6
# 判定模式：conservative（只自动判正确，推荐）/ standard
VERDICT_MODE=conservative
```

## 三、启动
> 首次部署必须先构建基础镜像 `ll-base`（apt/pip 已内置国内镜像源），
> 否则 `docker compose up` 会因找不到 `ll-base:latest` 失败。

推荐直接用一键脚本：

```sh
sh deploy/deploy.sh
```

等价的手动步骤：

```sh
docker build -t ll-base:latest -f server/Dockerfile.base server/
docker compose up -d --build
docker compose ps                 # 确认 db / api / caddy 都在运行
curl http://localhost/api/health  # 返回 {"status":"ok"}
```

> 说明：`deploy/Caddyfile` 默认监听 `:80`，便于用 IP 直连测试；
> 配置了域名后把首行改成 `{$DOMAIN}` 即可自动申请 HTTPS 证书。

首次调用识别接口时，RapidOCR 会加载模型，第一次批改会慢一些。

## 四、数据备份
```sh
# 导出数据库
docker compose exec db pg_dump -U dictation dictation > backup.sql
# 恢复
docker compose exec -T db psql -U dictation dictation < backup.sql
```
建议用 cron 每天执行一次并异地保存。

## 五、识别说明
- 后端 `POST /grade` 把笔迹按外接框裁剪后栅格化成 224×224 灰度图（细笔画、大留白），用 RapidOCR（onnxruntime 版 PP-OCR）**只跑识别网络**。
- **不要开启文字检测**：整格栅格图会被检测网络判成「没有文字」而返回空结果，导致全部题目变成待确认。代码里已固定 `use_det=False, use_cls=False, use_rec=True`。
- 同一笔迹会渲染两套（原图 + 轻微高斯模糊）取最高置信度，提升稳定性。
- **识别模型用 PP-OCRv5（mobile）**，构建镜像时自动下载并替换包内自带的 v4。实测同一批真实笔迹：
  v4 对形变较大的字输出均匀分布（判不出），v5 能稳定识别且候选领先幅度明显。
- 前端会带上本次练习涉及的字（`allowed`）做**候选字约束解码**，只在几个字之间比较，
  判别力显著高于在 1.8 万字里开集检索。
- 实测（真实学生笔迹）：v5 下正确字置信度约 0.38–0.40、领先幅度 0.22–0.25；`MIN_CONF` 默认 0.5（作用于回退的开集识别）。
- 默认 `VERDICT_MODE=conservative`：只在置信度达标且识别结果与目标字一致时判「正确」，其余一律「待确认」，杜绝误判；家长订正兜底。
  想看自动判「错字」，把 `VERDICT_MODE=standard`（错字阈值 `min_conf_wrong=0.75`，需按自己孩子的笔迹复核）。
- 若服务器内存仍紧张，可把 `Dockerfile.recognition` 换成 `Dockerfile`（纯 API，识别接口会回退为待确认）。

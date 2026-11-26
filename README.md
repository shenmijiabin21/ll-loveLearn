# 每日听写（网页版）

给小学二年级、三年级上册使用的听写练习，网页端使用「Flutter Web 前端 + FastAPI 后端 + PostgreSQL + 服务端手写识别」，部署到云服务器。

## 开始使用

1. 用管理员创建的账号登录。学生登录后直接进入练习，家长登录后查看孩子汇总并进入练习设置。
2. 在「练习设置」查看当前字库和已学起点。内置字库是自编示例，正式练习前请导入核验过的教材字库。
3. 在「今日」打开每日一练。点「播放题目」听词语和目标字的位置，用手指、触控笔或鼠标在田字格书写。可撤销、清空、跳过或点题号回看。完成的笔划和题号会保存，退出后可以继续。
4. 到最后一题提交整组。结果显示正确、错字、空白或待确认。家长可放大原笔迹、订正，或恢复自动批改。
5. 「重点」可复习错字、空白和待确认字，「统计」可查看历史。通过「练习设置」导出或恢复 JSON 备份。备份包含原笔迹，建议保存在自己控制的位置。

默认顺序是三上 → 二下 → 二上，每册按课号倒序。同一课的字沿用导入顺序。每天最多安排 5 个到期复习字和 5 个新字，一天只生成一组每日任务。未提交的草稿跨天保留，计入开始那天。重点字默认次日复习，到期答对后间隔 3 天、7 天，第 3 次到期答对后移出待复习列表。提前复习可以重练，提前答对不会缩短间隔。

## 教材字库

JSON 结构面向可替换的人教部编版教材数据。导入时按实际教材的版次和课号录入，标明核验来源。项目没有附带正式教材字表。

- [assets/demo.json](assets/demo.json) 提供可导入的结构示例，`sample` 为 `true`，册次和课号仅展示排序。
- `schema` 当前为 `1`。每个版本使用独立的 `edition`，允许字母、数字、点、下划线和连字符。同一版本沿用已经完成的课程字进度。
- `title` 写教材版本名称，`source` 写核验来源、版次或印次。核验后才将 `sample` 设为 `false`。
- `volume` 支持 `3a`（三上）、`2b`（二下）、`2a`（二上）。每册 `number` 不重复，每课目标字不重复。
- 每个 `words` 项填写 `character`、`phrase` 和从 1 起算的 `position`。例如用「大门」的第二个字提示「门」。词语须包含 2 至 8 个汉字。

## 技术说明

- Flutter 3.50.1、Riverpod。大屏使用侧栏导航，练习页面并排显示题目和田字格。
- 登录/注册、多孩子档案、孩子各自的听写进度存云端数据库。后端 `server/`（FastAPI），数据模型见 `server/README.md`。
- 网页端把笔迹上传到 `POST /grade`，服务端栅格化后用 RapidOCR（onnxruntime 版 PP-OCR）识别；不确定时回退「待确认 + 家长订正」。
- 语音使用浏览器 SpeechSynthesis 读题（依赖系统中文语音）。语音不可用时可用「家长读题」。
- 笔迹以归一化坐标和时间戳保存，字库更换后仍能查看既有记录。
- 导出备份走浏览器下载，恢复备份用浏览器文件选择，均不需要额外插件。

## 运行与开发

```sh
flutter --version
flutter pub get --enforce-lockfile
flutter analyze --no-pub
flutter test --no-pub
flutter run -d chrome --dart-define=API_BASE_URL=http://localhost:8000
```

## 构建与部署

```sh
flutter pub get --enforce-lockfile
flutter build web --release --no-pub   # 产物在 build/web
```

部署见 [deploy/README.md](deploy/README.md)（Docker Compose + Caddy + HTTPS）。生产环境不传 `API_BASE_URL`，前端默认请求 `/api/*`，由 Caddy 反代到后端。
